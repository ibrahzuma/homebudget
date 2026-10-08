import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/notifications.dart';
import '../../core/realtime.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import 'chat_widgets.dart';

/// Bottom tab: household chat.
///
/// Lives in the shell's IndexedStack, so it stays mounted while other tabs
/// show. Fetching the latest page marks the chat read on the server, so the
/// first load waits until the tab is actually visible, and live messages are
/// only marked read while it is.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  static const _pageSize = 50;

  final _messages = <ChatMessage>[]; // oldest first
  final _ids = <int>{};
  final _scroll = ScrollController();
  final _composer = TextEditingController();
  StreamSubscription<Map<String, dynamic>>? _sub;

  bool _visible = false;
  bool _loaded = false;
  bool _loading = false;
  bool _loadingOlder = false;
  bool _hasMore = false;
  bool _sending = false;
  Object? _error;

  Session get _session => context.read<Session>();
  ApiClient get _api => _session.api;
  bool get _onScreen => _visible && (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    _sub = context
        .read<Realtime>()
        .events
        .where((e) => e['kind'] == 'chat.new')
        .listen(_onLiveMessage);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final wasVisible = _visible;
    _visible = Visibility.of(context);
    // Messages land in the thread live while this tab is up; no banner needed.
    context.read<BackgroundAlerts>().setMuted('chat.', _visible);
    if (_visible && !wasVisible) {
      // Defer: we may be mid-build of the shell.
      WidgetsBinding.instance.addPostFrameCallback((_) => _becameVisible());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The socket may have dropped while backgrounded; catch up on resume.
    if (state == AppLifecycleState.resumed && mounted && _onScreen) _catchUp();
  }

  @override
  void dispose() {
    context.read<BackgroundAlerts>().setMuted('chat.', false);
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _scroll.dispose();
    _composer.dispose();
    super.dispose();
  }

  void _becameVisible() {
    if (!mounted) return;
    _loaded ? _catchUp() : _loadLatest();
  }

  // ---- loading ----

  List<ChatMessage> _parse(Map<String, dynamic> res) => (res['results'] as List)
      .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
      .toList();

  /// Replace everything with the newest page (also marks the chat read).
  Future<void> _loadLatest() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await _api.get('chat/', query: {'limit': _pageSize}) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _messages.clear();
        _ids.clear();
        _addAll(_parse(res));
        _hasMore = res['has_more'] == true;
        _loaded = true;
      });
      _fillViewportLater();
      _session.refreshBadges();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Fetch only messages newer than the last one we have.
  Future<void> _catchUp() async {
    if (!_loaded || _messages.isEmpty) return _loadLatest();
    try {
      final res = await _api.get('chat/',
          query: {'limit': _pageSize, 'after': _messages.last.id}) as Map<String, dynamic>;
      if (!mounted) return;
      if (res['has_more'] == true) {
        // Too far behind to stitch the gap; start again from the newest page.
        await _loadLatest();
        return;
      }
      setState(() => _addAll(_parse(res)));
      _session.refreshBadges();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || !_hasMore || _messages.isEmpty) return;
    setState(() => _loadingOlder = true);
    try {
      final res = await _api.get('chat/',
          query: {'limit': _pageSize, 'before': _messages.first.id}) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _addAll(_parse(res));
        _hasMore = res['has_more'] == true;
      });
      _fillViewportLater();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  /// Merge messages, dropping ones we already have, keeping id order.
  void _addAll(Iterable<ChatMessage> incoming) {
    var added = false;
    for (final m in incoming) {
      if (_ids.add(m.id)) {
        _messages.add(m);
        added = true;
      }
    }
    if (added) _messages.sort((a, b) => a.id.compareTo(b.id));
  }

  /// If a page doesn't fill the screen there's nothing to scroll, so keep
  /// pulling older pages until it does.
  void _fillViewportLater() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients && _scroll.position.maxScrollExtent <= 0) _loadOlder();
    });
  }

  void _onScroll() {
    // The list is reversed, so the max extent is the oldest end.
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 300) _loadOlder();
  }

  // ---- live + sending ----

  void _onLiveMessage(Map<String, dynamic> e) {
    if (!_loaded) return; // the first load will include it
    final ChatMessage msg;
    try {
      msg = ChatMessage.fromEvent(e);
    } catch (_) {
      return;
    }
    if (_ids.contains(msg.id)) return; // e.g. our own message, already added
    setState(() => _addAll([msg]));
    final fromOther = msg.sender.id != _session.user?.id;
    if (fromOther && _onScreen) _markRead();
  }

  Future<void> _markRead() async {
    try {
      await _api.post('chat/read/');
    } catch (_) {
      return; // not worth bothering the user over
    }
    _session.refreshBadges();
  }

  Future<void> _send() async {
    final body = _composer.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final res = await _api.post('chat/', {'body': body}) as Map<String, dynamic>;
      if (!mounted) return;
      _composer.clear();
      setState(() => _addAll([ChatMessage.fromJson(res)]));
      _scrollToNewest();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _scrollToNewest() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    final household = context.select<Session, String>((s) => s.household?.name ?? 'Chat');
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Chat'),
          Text(household,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.muted)),
        ]),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _catchUp,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(children: [
        Expanded(child: _body()),
        ChatComposer(
          controller: _composer,
          sending: _sending,
          enabled: _loaded,
          onSend: _send,
        ),
      ]),
    );
  }

  Widget _body() {
    if (!_loaded) {
      if (_error != null) return ErrorState(error: _error, onRetry: _loadLatest);
      return const Center(child: CircularProgressIndicator());
    }
    if (_messages.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadLatest,
        child: const EmptyState(
          icon: Icons.forum_outlined,
          title: 'No messages yet',
          message: 'Say hi to your household. Everyone in it sees this chat.',
        ),
      );
    }
    final me = context.select<Session, int?>((s) => s.user?.id);
    return ChatMessageList(
      controller: _scroll,
      messages: _messages,
      myId: me,
      loadingOlder: _loadingOlder,
      hasMore: _hasMore,
    );
  }
}
