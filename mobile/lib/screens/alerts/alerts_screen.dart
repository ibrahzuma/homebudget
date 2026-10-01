import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../links.dart';
import '../transactions/pager.dart';

/// Budget, request and household notifications. Tapping one marks it read
/// and opens the related screen when there is one.
class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  late final Pager<AlertItem> _pager = Pager(_fetch, pageSize: 30);
  final _scroll = ScrollController();
  bool _unreadOnly = false;

  @override
  void initState() {
    super.initState();
    _pager.addListener(_onPager);
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 400) _pager.loadMore();
    });
    _pager.refresh();
  }

  @override
  void dispose() {
    _pager.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onPager() => setState(() {});

  Future<Paged<AlertItem>> _fetch(int page, int size) async {
    final api = context.read<Session>().api;
    final json = await api.get('alerts/', query: {
      'unread': _unreadOnly ? 1 : null,
      'page': page,
      'page_size': size,
    }) as Map<String, dynamic>;
    return Paged.fromJson(json, AlertItem.fromJson);
  }

  void _setUnreadOnly(bool v) {
    setState(() => _unreadOnly = v);
    _pager.refresh(clear: true);
  }

  Future<void> _refresh() async {
    final session = context.read<Session>();
    final badges = session.refreshBadges();
    final err = await _pager.refresh();
    await badges;
    if (err != null && mounted && _pager.items.isNotEmpty) showError(context, err);
  }

  Future<void> _open(AlertItem a) async {
    final session = context.read<Session>();
    if (!a.isRead) {
      try {
        final res = await session.api.post('alerts/${a.id}/read/') as Map<String, dynamic>;
        final updated = AlertItem.fromJson(res);
        if (_unreadOnly) {
          _pager.items.removeWhere((x) => x.id == a.id);
          _onPager();
        } else {
          _pager.replaceWhere((x) => x.id == a.id, updated);
        }
        session.refreshBadges();
      } catch (e) {
        if (mounted) showError(context, e);
        return;
      }
    }
    if (mounted) openWebLink(context, a.linkUrl);
  }

  Future<void> _markAllRead() async {
    final session = context.read<Session>();
    final ok = await runAction(context, () => session.api.post('alerts/read-all/'),
        success: 'All alerts marked as read');
    if (!ok) return;
    session.refreshBadges();
    await _pager.refresh(clear: _unreadOnly);
  }

  @override
  Widget build(BuildContext context) {
    final unread = context.watch<Session>().badges.unreadAlerts;
    final anyUnread = unread > 0 || _pager.items.any((a) => !a.isRead);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Alerts'),
        actions: [
          IconButton(
            tooltip: 'Mark all as read',
            icon: const Icon(Icons.done_all),
            onPressed: anyUnread ? _markAllRead : null,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Row(children: [
              ChoiceChip(
                label: const Text('All'),
                selected: !_unreadOnly,
                onSelected: (_) => _setUnreadOnly(false),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: Text(unread > 0 ? 'Unread ($unread)' : 'Unread'),
                selected: _unreadOnly,
                onSelected: (_) => _setUnreadOnly(true),
              ),
            ]),
          ),
        ),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_pager.isInitialLoading) return const Center(child: CircularProgressIndicator());
    if (!_pager.loaded && _pager.error != null) {
      return ErrorState(error: _pager.error, onRetry: _pager.retry);
    }
    if (_pager.items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: EmptyState(
          icon: Icons.notifications_none,
          title: _unreadOnly ? 'You\'re all caught up' : 'No alerts yet',
          message: _unreadOnly
              ? 'No unread alerts.'
              : 'We\'ll notify you when budgets approach their limits or when there\'s '
                  'household activity to review.',
        ),
      );
    }
    final items = _pager.items;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: items.length + 1,
        itemBuilder: (context, i) {
          if (i == items.length) return _footer();
          return _AlertCard(alert: items[i], onTap: () => _open(items[i]));
        },
      ),
    );
  }

  Widget _footer() {
    if (_pager.error != null) {
      return TextButton(onPressed: _pager.retry, child: const Text('Couldn\'t load more · Retry'));
    }
    if (_pager.hasNext) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return const SizedBox(height: 24);
  }
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({required this.alert, required this.onTap});
  final AlertItem alert;
  final VoidCallback onTap;

  static IconData _icon(String level) => switch (level) {
        'danger' => Icons.error_outline,
        'warning' => Icons.warning_amber_rounded,
        'success' => Icons.check_circle_outline,
        _ => Icons.info_outline,
      };

  @override
  Widget build(BuildContext context) {
    final a = alert;
    final color = AppColors.forLevel(a.level);
    final t = Theme.of(context).textTheme;
    final unread = !a.isRead;
    final hasLink = a.linkUrl.isNotEmpty;

    return Card(
      clipBehavior: Clip.antiAlias,
      color: unread ? color.withValues(alpha: 0.06) : null,
      child: InkWell(
        onTap: onTap,
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(width: 4, color: unread ? color : Colors.transparent),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(_icon(a.level), color: color),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(a.title,
                          style: t.titleSmall?.copyWith(
                              fontWeight: unread ? FontWeight.w700 : FontWeight.w500)),
                      if (a.message.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(a.message,
                            style: t.bodyMedium?.copyWith(
                                color: unread ? null : AppColors.muted)),
                      ],
                      const SizedBox(height: 6),
                      Text(fmtDateTime(a.createdAt),
                          style: t.bodySmall?.copyWith(color: AppColors.muted)),
                    ]),
                  ),
                  if (unread)
                    Container(
                      width: 10,
                      height: 10,
                      margin: const EdgeInsets.only(top: 4, left: 8),
                      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                    )
                  else if (hasLink)
                    const Icon(Icons.chevron_right, color: AppColors.muted),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
