import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../debts/debt_detail_screen.dart';
import '../networth/finance_shared.dart';
import 'group_forms.dart';

/// One vikoba or mchezo: what you have paid in, what you have collected, the
/// rotation, and any loan taken from the group.
class GroupDetailScreen extends StatefulWidget {
  const GroupDetailScreen({super.key, required this.id});
  final int id;

  @override
  State<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends State<GroupDetailScreen> {
  final _loader = GlobalKey<LoadBuilderState<ContributionGroup>>();
  ContributionGroup? _group;

  Session get _session => context.read<Session>();
  String get _path => 'groups/${widget.id}/';

  Future<ContributionGroup> _load() async {
    final g = ContributionGroup.fromJson(
        await _session.api.get(_path) as Map<String, dynamic>);
    if (mounted) setState(() => _group = g);
    return g;
  }

  /// Adopt a group the server just handed back, so the screen updates without
  /// a second round trip.
  void _adopt(ContributionGroup? updated) {
    if (updated == null || !mounted) return;
    setState(() => _group = updated);
    _loader.currentState?.reload();
  }

  Future<void> _edit() async {
    final g = _group;
    if (g == null) return;
    if (await openGroupForm(context, existing: g)) _loader.currentState?.reload();
  }

  Future<void> _delete() async {
    final g = _group;
    if (g == null) return;
    final ok = await confirmDelete(
      context,
      title: 'Delete "${g.name}"?',
      message: 'The group, its rotation and its record of what you paid in and '
          'received will be removed. Transactions already in your books stay, and '
          'so does any loan from this group — that remains under Debts.',
      action: () => _session.api.delete(_path),
      success: 'Group deleted',
    );
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final symbol = context.watch<Session>().currencySymbol;
    final g = _group;
    return Scaffold(
      appBar: AppBar(
        title: Text(g?.name ?? 'Group'),
        actions: [if (g != null) EditDeleteMenu(onEdit: _edit, onDelete: _delete)],
      ),
      body: LoadBuilder<ContributionGroup>(
        key: _loader,
        load: _load,
        builder: (context, group, reload) => RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              _Header(group: group, symbol: symbol),
              _Actions(
                group: group,
                onContribute: () async =>
                    _adopt(await openContributionForm(context, group)),
                onPayout: () async => _adopt(await openPayoutForm(context, group)),
                onLoan: () async => _adopt(await openGroupLoanForm(context, group)),
              ),
              if (group.isMchezo) _Rotation(group: group, onChanged: _adopt),
              if (group.isVikoba) _Loans(group: group, symbol: symbol, onAdd: () async {
                _adopt(await openGroupLoanForm(context, group));
              }),
              _Ledger(group: group, symbol: symbol),
              if (group.notes.isNotEmpty) ...[
                const SectionHeader('Notes'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(group.notes),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.group, required this.symbol});
  final ContributionGroup group;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final g = group;
    final due = g.nextDueDate;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Row(children: [
          IconBadge(icon: g.icon, color: g.color, size: 52),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(g.groupTypeDisplay,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: AppColors.muted)),
              Text(
                '${fmtIn(g.contributionAmount, g.currency, symbol)} '
                '${g.frequencyDisplay.toLowerCase()}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ]),
          ),
          if (!g.isActive) const StatusChip('Ended'),
        ]),
      ),
      if (due != null && g.isActive)
        Card(
          color: g.isOverdue
              ? AppColors.expense.withValues(alpha: 0.1)
              : (g.isDueSoon ? AppColors.warning.withValues(alpha: 0.12) : null),
          child: ListTile(
            leading: Icon(Icons.event,
                color: g.isOverdue ? AppColors.expense : AppColors.muted),
            title: Text('Next collection ${fmtDate(due)}'),
            subtitle: Text(g.isOverdue
                ? 'Overdue'
                : (g.daysUntilDue == null ? '' : fmtRelativeDays(g.daysUntilDue!))),
          ),
        ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(children: [
          Expanded(
              child: StatTile(
                  label: 'Paid in',
                  value: fmtIn(g.totalContributed, g.currency, symbol),
                  color: AppColors.expense)),
          const SizedBox(width: 8),
          Expanded(
              child: StatTile(
                  label: 'Received',
                  value: fmtIn(g.totalReceived, g.currency, symbol),
                  color: AppColors.income)),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(children: [
          Expanded(
              child: StatTile(
                  label: g.netPosition >= 0 ? 'Group holds' : 'Ahead by',
                  value: fmtIn(g.netPosition.abs(), g.currency, symbol))),
          const SizedBox(width: 8),
          Expanded(
            child: g.isMchezo
                ? StatTile(
                    label: 'A full pot',
                    value: g.expectedPayout == null
                        ? 'add members'
                        : fmtIn(g.expectedPayout, g.currency, symbol))
                : StatTile(
                    label: 'Loans outstanding',
                    value: fmtIn(g.outstandingLoans, g.currency, symbol),
                    color: AppColors.warning),
          ),
        ]),
      ),
    ]);
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.group,
    required this.onContribute,
    required this.onPayout,
    required this.onLoan,
  });
  final ContributionGroup group;
  final VoidCallback onContribute;
  final VoidCallback onPayout;
  final VoidCallback onLoan;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(
            onPressed: onContribute,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Contribute')),
        OutlinedButton.icon(
            onPressed: onPayout,
            icon: const Icon(Icons.payments_outlined, size: 18),
            label: const Text('Received')),
        if (group.isVikoba)
          OutlinedButton.icon(
              onPressed: onLoan,
              icon: const Icon(Icons.account_balance, size: 18),
              label: const Text('Loan')),
      ]),
    );
  }
}

class _Rotation extends StatelessWidget {
  const _Rotation({required this.group, required this.onChanged});
  final ContributionGroup group;
  final void Function(ContributionGroup?) onChanged;

  @override
  Widget build(BuildContext context) {
    final nextId = group.nextTurn?.id;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionHeader(
        'The rotation',
        trailing: TextButton.icon(
          onPressed: () async => onChanged(await openMemberForm(context, group)),
          icon: const Icon(Icons.person_add_alt, size: 18),
          label: const Text('Add'),
        ),
      ),
      if (group.members.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Add everyone in the group and the date each one collects. The app '
            'then knows what a full pot is worth and when your turn comes round.',
            style: TextStyle(color: AppColors.muted),
          ),
        )
      else
        for (final m in group.members)
          Card(
            color: m.isMine
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.07)
                : null,
            child: ListTile(
              leading: CircleAvatar(
                radius: 16,
                child: Text('${m.turnOrder}',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ),
              title: Row(children: [
                Flexible(child: Text(m.name, overflow: TextOverflow.ellipsis)),
                if (m.isMine) ...[
                  const SizedBox(width: 6),
                  const StatusChip('You'),
                ],
              ]),
              subtitle: Text(m.turnDate == null
                  ? 'No date set'
                  : 'Collects ${fmtDate(m.turnDate)}'),
              trailing: m.hasReceived
                  ? StatusChip('Collected ${fmtDateShort(m.receivedOn)}',
                      color: AppColors.income)
                  : (m.id == nextId
                      ? const StatusChip('Next up', color: AppColors.warning)
                      : null),
              onTap: () async =>
                  onChanged(await openMemberForm(context, group, existing: m)),
            ),
          ),
    ]);
  }
}

class _Loans extends StatelessWidget {
  const _Loans({required this.group, required this.symbol, required this.onAdd});
  final ContributionGroup group;
  final String symbol;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionHeader(
        'Loans from this vikoba',
        trailing: TextButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Record')),
      ),
      if (group.loans.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'No loan taken from this vikoba. If you borrow, record it here and it '
            'becomes a debt with the usual repayment tracking.',
            style: TextStyle(color: AppColors.muted),
          ),
        )
      else ...[
        for (final l in group.loans)
          Card(
            child: ListTile(
              leading: const Icon(Icons.account_balance, color: AppColors.warning),
              title: Text(l.name),
              subtitle: Text('Still owed ${fmtIn(l.balance, l.currency, symbol)}'
                  '${l.dueDate == null ? '' : ' · due ${fmtDateShort(l.dueDate)}'}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => push(context, DebtDetailScreen(id: l.id)),
            ),
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text(
            'These are ordinary debts, so they also appear under Debts, where '
            'repayments are recorded.',
            style: TextStyle(color: AppColors.muted, fontSize: 12),
          ),
        ),
      ],
    ]);
  }
}

class _Ledger extends StatelessWidget {
  const _Ledger({required this.group, required this.symbol});
  final ContributionGroup group;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final g = group;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SectionHeader('My contributions'),
      if (g.contributions.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('Nothing paid in yet.', style: TextStyle(color: AppColors.muted)),
        )
      else
        for (final c in g.contributions)
          Card(
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.arrow_upward, color: AppColors.expense),
              title: Text(fmtIn(c.amount, c.currency, symbol)),
              subtitle: Text([
                fmtDate(c.date),
                if (c.user != null) c.user!.username,
                if (c.notes.isNotEmpty) c.notes,
              ].join(' · ')),
              trailing: c.awaitingApproval
                  ? const StatusChip('Awaiting approval', color: AppColors.warning)
                  : (c.transactionId != null ? const StatusChip('Recorded') : null),
            ),
          ),
      const SectionHeader('Money received'),
      if (g.payouts.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            g.isMchezo
                ? 'Your turn has not come round yet.'
                : 'No share-out received yet.',
            style: const TextStyle(color: AppColors.muted),
          ),
        )
      else
        for (final p in g.payouts)
          Card(
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.arrow_downward, color: AppColors.income),
              title: Text(fmtIn(p.amount, p.currency, symbol)),
              subtitle: Text([
                fmtDate(p.date),
                if (p.notes.isNotEmpty) p.notes,
              ].join(' · ')),
              trailing:
                  p.transactionId != null ? const StatusChip('Income') : null,
            ),
          ),
    ]);
  }
}
