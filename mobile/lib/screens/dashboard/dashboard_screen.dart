import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../core/realtime.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../alerts/alerts_screen.dart';
import '../transactions/transaction_form.dart';
import '../transactions/txn_events.dart';
import 'dashboard_cards.dart';

/// Bottom tab "Home": this month at a glance, mirroring the web dashboard.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _loader = GlobalKey<LoadBuilderState<Dashboard>>();
  StreamSubscription<Map<String, dynamic>>? _events;

  @override
  void initState() {
    super.initState();
    transactionsChanged.addListener(_reload);
    // New/answered money requests change the "waiting for you" list.
    _events = context
        .read<Realtime>()
        .myEvents
        .where((e) => '${e['kind']}'.startsWith('request.'))
        .listen((_) => _reload());
  }

  @override
  void dispose() {
    transactionsChanged.removeListener(_reload);
    _events?.cancel();
    super.dispose();
  }

  void _reload() => _loader.currentState?.reload();

  Future<Dashboard> _load() async {
    final session = context.read<Session>();
    final badges = session.refreshBadges(); // pull-to-refresh also updates the badges
    final json = await session.api.get('dashboard/') as Map<String, dynamic>;
    await badges;
    return Dashboard.fromJson(json);
  }

  Future<void> _quickAdd() async {
    final type = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.north_east, color: AppColors.expense),
            title: const Text('Add expense'),
            onTap: () => Navigator.pop(ctx, 'expense'),
          ),
          ListTile(
            leading: const Icon(Icons.south_west, color: AppColors.income),
            title: const Text('Add income'),
            onTap: () => Navigator.pop(ctx, 'income'),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (type != null && mounted) await openTransactionForm(context, type: type);
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    return Scaffold(
      appBar: AppBar(
        title: Text(session.household?.name ?? 'Home'),
        actions: [
          IconButton(
            tooltip: 'Alerts',
            onPressed: () => push(context, const AlertsScreen()),
            icon: CountBadge(
              count: session.badges.unreadAlerts,
              child: const Icon(Icons.notifications_outlined),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'dash-add',
        onPressed: _quickAdd,
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
      body: LoadBuilder<Dashboard>(
        key: _loader,
        load: _load,
        builder: (context, d, _) => _DashboardBody(data: d, onChanged: _reload),
      ),
    );
  }
}

class _DashboardBody extends StatelessWidget {
  const _DashboardBody({required this.data, required this.onChanged});
  final Dashboard data;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final d = data;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        MonthHeader(label: d.monthLabel),
        if (d.pendingMyApprovals.isNotEmpty)
          ApprovalsCard(requests: d.pendingMyApprovals, onReturn: onChanged),
        MonthTotals(data: d),
        if (d.members.length > 1) MemberSplitCard(members: d.members, data: d),
        ForecastCard(forecast: d.forecast),
        if (d.nextMeeting != null) NextMeetingCard(meeting: d.nextMeeting!),
        NetWorthCard(data: d),
        BudgetsSection(budgets: d.budgets),
        GoalsSection(goals: d.activeGoals),
        UpcomingSection(items: d.upcoming),
        RecentSection(items: d.recent),
      ],
    );
  }
}
