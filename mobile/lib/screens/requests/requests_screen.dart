import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/notifications.dart';
import '../../core/realtime.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../../widgets/entity_form.dart';
import '../household/household_settings_screen.dart';
import 'request_common.dart';
import 'request_detail_screen.dart';
import 'request_form.dart';

export 'request_detail_screen.dart' show RequestDetailScreen;

class _RequestLists {
  _RequestLists.fromJson(Map<String, dynamic> j)
      : incoming = _parse(j['incoming']),
        outgoing = _parse(j['outgoing']);

  final List<MoneyRequest> incoming;
  final List<MoneyRequest> outgoing;

  /// Pending first, otherwise keep the server's newest-first order.
  static List<MoneyRequest> _parse(dynamic v) {
    final all = (v as List? ?? const [])
        .map((e) => MoneyRequest.fromJson(e as Map<String, dynamic>))
        .toList();
    return [
      ...all.where((r) => r.status == 'pending'),
      ...all.where((r) => r.status != 'pending'),
    ];
  }
}

/// Bottom tab: money requests to approve and the ones you made.
class RequestsScreen extends StatefulWidget {
  const RequestsScreen({super.key});

  @override
  State<RequestsScreen> createState() => _RequestsScreenState();
}

class _RequestsScreenState extends State<RequestsScreen> {
  final _loader = GlobalKey<LoadBuilderState<_RequestLists>>();
  StreamSubscription<Map<String, dynamic>>? _sub;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    _sub = context.read<Realtime>().myEvents.where(isRequestEvent).listen(_onEvent);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // False while another bottom tab is showing (IndexedStack keeps us mounted).
    _visible = Visibility.of(context);
    // While this tab is up the list reloads and snackbars itself, so a push
    // banner over the top would only repeat it.
    context.read<BackgroundAlerts>().setMuted('request.', _visible);
  }

  @override
  void dispose() {
    context.read<BackgroundAlerts>().setMuted('request.', false);
    _sub?.cancel();
    super.dispose();
  }

  Future<_RequestLists> _load() async {
    final api = context.read<Session>().api;
    return _RequestLists.fromJson(await api.get('requests/') as Map<String, dynamic>);
  }

  Future<void> _reload() async {
    await _loader.currentState?.reload();
  }

  void _onEvent(Map<String, dynamic> e) {
    _reload();
    final onTop = ModalRoute.of(context)?.isCurrent ?? true;
    if (!_visible || !onTop) return;
    final id = e['request_id'] as int?;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(e['message'] as String? ?? 'A money request was updated.'),
        action: id == null
            ? null
            : SnackBarAction(label: 'View', onPressed: () => _open(id)),
      ));
  }

  Future<void> _open(int id) async {
    await push(context, RequestDetailScreen(id: id));
    if (!mounted) return;
    _reload();
    context.read<Session>().refreshBadges();
  }

  Future<void> _newRequest() async {
    final session = context.read<Session>();
    if (!session.hasPartner) {
      await _explainNoPartner();
      return;
    }
    final Meta meta;
    try {
      meta = await ensureMeta(session);
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (!mounted) return;
    final saved = await openForm(context, requestMoneyForm(session, meta));
    if (!saved || !mounted) return;
    showOk(context, 'Request sent');
    _reload();
    session.refreshBadges();
  }

  Future<void> _explainNoPartner() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Invite a partner first'),
        content: const Text(
            'Money requests go to another member of your household. '
            'Invite your partner or add them by username, then come back here.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Household settings')),
        ],
      ),
    );
    if (go == true && mounted) await push(context, const HouseholdSettingsScreen());
  }

  @override
  Widget build(BuildContext context) {
    final pending = context.select<Session, int>((s) => s.badges.pendingRequests);
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Requests'),
          automaticallyImplyLeading: Navigator.of(context).canPop(),
          bottom: TabBar(tabs: [
            Tab(child: _TabLabel('To approve', count: pending)),
            const Tab(text: 'My requests'),
          ]),
        ),
        floatingActionButton: FloatingActionButton.extended(
          heroTag: 'requests-fab',
          onPressed: _newRequest,
          icon: const Icon(Icons.add),
          label: const Text('Request money'),
        ),
        body: LoadBuilder<_RequestLists>(
          key: _loader,
          load: _load,
          builder: (context, data, reload) => TabBarView(children: [
            _RequestList(
              requests: data.incoming,
              incoming: true,
              onRefresh: reload,
              onOpen: _open,
              empty: const EmptyState(
                icon: Icons.inbox_outlined,
                title: 'Nothing to approve',
                message: 'When your partner asks you for money, it shows up here.',
              ),
            ),
            _RequestList(
              requests: data.outgoing,
              incoming: false,
              onRefresh: reload,
              onOpen: _open,
              empty: EmptyState(
                icon: Icons.outbox_outlined,
                title: "You haven't made any requests",
                message: 'Ask a household member for money; they can approve or reject it.',
                action: FilledButton.icon(
                  onPressed: _newRequest,
                  icon: const Icon(Icons.add),
                  label: const Text('Request money'),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _TabLabel extends StatelessWidget {
  const _TabLabel(this.label, {required this.count});
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text(label),
      if (count > 0) ...[
        const SizedBox(width: 6),
        Badge(label: Text('$count')),
      ],
    ]);
  }
}

class _RequestList extends StatelessWidget {
  const _RequestList({
    required this.requests,
    required this.incoming,
    required this.onRefresh,
    required this.onOpen,
    required this.empty,
  });

  final List<MoneyRequest> requests;
  final bool incoming;
  final Future<void> Function() onRefresh;
  final void Function(int id) onOpen;
  final Widget empty;

  @override
  Widget build(BuildContext context) {
    // Each tab gets its own indicator: the outer one can't see scrolls
    // nested inside the TabBarView's page view.
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: requests.isEmpty
          ? empty
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(top: 8, bottom: 96),
              itemCount: requests.length,
              itemBuilder: (_, i) => _RequestCard(
                request: requests[i],
                incoming: incoming,
                onTap: () => onOpen(requests[i].id),
              ),
            ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({required this.request, required this.incoming, required this.onTap});
  final MoneyRequest request;
  final bool incoming;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final r = request;
    final symbol = context.select<Session, String>((s) => s.currencySymbol);
    final pending = r.status == 'pending';
    final other = incoming ? r.requester : r.approver;
    final scheme = Theme.of(context).colorScheme;
    final subtitle = [
      '${incoming ? 'From' : 'To'} ${other.username}',
      fmtDateShort(r.createdAt.toLocal()),
      if (r.category != null) r.category!.name,
    ].join(' · ');

    return Card(
      color: pending ? Color.alphaBlend(AppColors.warning.withValues(alpha: 0.07), scheme.surface) : null,
      shape: pending
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: AppColors.warning.withValues(alpha: 0.5)),
            )
          : null,
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          child: Text(other.username.isEmpty ? '?' : other.username[0].toUpperCase()),
        ),
        title: Text(r.purpose, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(requestAmount(r, symbol),
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            RequestStatusChip(r.status),
          ],
        ),
      ),
    );
  }
}
