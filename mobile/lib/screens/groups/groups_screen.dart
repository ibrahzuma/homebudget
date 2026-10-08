import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import 'group_detail_screen.dart';
import 'group_forms.dart';

export 'group_detail_screen.dart' show GroupDetailScreen;

/// Vikoba and mchezo: the savings groups the household pays into.
class GroupsScreen extends StatefulWidget {
  const GroupsScreen({super.key});

  @override
  State<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends State<GroupsScreen> {
  final _loader = GlobalKey<LoadBuilderState<GroupIndex>>();

  Future<GroupIndex> _load() async {
    final res = await context.read<Session>().api.get('groups/');
    return GroupIndex.fromJson(res as Map<String, dynamic>);
  }

  Future<void> _reload() async => _loader.currentState?.reload();

  Future<void> _add() async {
    if (await openGroupForm(context)) _reload();
  }

  Future<void> _open(ContributionGroup g) async {
    await push(context, GroupDetailScreen(id: g.id));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final symbol = context.watch<Session>().currencySymbol;
    return Scaffold(
      appBar: AppBar(title: const Text('Vikoba & Mchezo')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('New group'),
      ),
      body: LoadBuilder<GroupIndex>(
        key: _loader,
        load: _load,
        builder: (context, index, reload) {
          if (index.groups.isEmpty) {
            return EmptyState(
              icon: Icons.groups_outlined,
              title: 'No groups yet',
              message: 'Add a vikoba to track what you save with the group and any '
                  'loan you take from it, or a mchezo to follow the rotation and '
                  'know when your turn to collect comes round.',
              action: FilledButton.icon(
                  onPressed: _add,
                  icon: const Icon(Icons.add),
                  label: const Text('New group')),
            );
          }

          final vikoba = index.groups.where((g) => g.isVikoba).toList();
          final mchezo = index.groups.where((g) => g.isMchezo).toList();
          final due = index.groups.where((g) => g.isOverdue || g.isDueSoon).toList();

          return RefreshIndicator(
            onRefresh: reload,
            child: ListView(
              padding: const EdgeInsets.only(bottom: 88),
              children: [
                if (due.isNotEmpty) _DueBanner(groups: due, onTap: _open),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(children: [
                    Expanded(
                        child: StatTile(
                            label: 'Paid in',
                            value: fmtMoney(index.contributed, symbol: symbol),
                            icon: Icons.arrow_upward,
                            color: AppColors.expense)),
                    const SizedBox(width: 8),
                    Expanded(
                        child: StatTile(
                            label: 'Received',
                            value: fmtMoney(index.received, symbol: symbol),
                            icon: Icons.arrow_downward,
                            color: AppColors.income)),
                  ]),
                ),
                if (index.outstandingLoans > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: StatTile(
                        label: 'Loans outstanding',
                        value: fmtMoney(index.outstandingLoans, symbol: symbol),
                        icon: Icons.account_balance,
                        color: AppColors.warning),
                  ),
                for (final section in [
                  ('Vikoba — savings & loans', vikoba),
                  ('Mchezo — rotating pot', mchezo),
                ])
                  if (section.$2.isNotEmpty) ...[
                    SectionHeader(section.$1),
                    for (final g in section.$2)
                      _GroupCard(group: g, symbol: symbol, onTap: () => _open(g)),
                  ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _DueBanner extends StatelessWidget {
  const _DueBanner({required this.groups, required this.onTap});
  final List<ContributionGroup> groups;
  final void Function(ContributionGroup) onTap;

  @override
  Widget build(BuildContext context) {
    final overdue = groups.where((g) => g.isOverdue).length;
    return Card(
      color: AppColors.warning.withValues(alpha: 0.12),
      child: ListTile(
        leading: const Icon(Icons.event_busy, color: AppColors.warning),
        title: Text(overdue > 0
            ? '$overdue contribution${overdue == 1 ? '' : 's'} overdue'
            : 'Contribution due soon'),
        subtitle: Text(groups.map((g) => g.name).join(', ')),
        onTap: () => onTap(groups.first),
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.group, required this.symbol, required this.onTap});
  final ContributionGroup group;
  final String symbol;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final g = group;
    final t = Theme.of(context).textTheme;
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              IconBadge(icon: g.icon, color: g.color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(g.name,
                      style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis),
                  Text(
                    '${fmtIn(g.contributionAmount, g.currency, symbol)} '
                    '${g.frequencyDisplay.toLowerCase()}'
                    '${g.isMchezo && g.memberCount > 0 ? ' · ${g.memberCount} members' : ''}',
                    style: t.bodySmall?.copyWith(color: AppColors.muted),
                  ),
                ]),
              ),
              if (!g.isActive)
                const StatusChip('Ended')
              else if (g.nextDueDate != null)
                StatusChip(
                  g.isOverdue ? 'Overdue' : 'Due ${fmtDateShort(g.nextDueDate)}',
                  color: g.isOverdue
                      ? AppColors.expense
                      : (g.isDueSoon ? AppColors.warning : AppColors.muted),
                ),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              _Figure(label: 'Paid in', value: fmtIn(g.totalContributed, g.currency, symbol)),
              _Figure(label: 'Received', value: fmtIn(g.totalReceived, g.currency, symbol)),
              if (g.isMchezo)
                _Figure(
                    label: 'My turn',
                    value: g.myTurnDate == null ? '—' : fmtDateShort(g.myTurnDate))
              else
                _Figure(
                    label: 'Loans',
                    value: fmtIn(g.outstandingLoans, g.currency, symbol)),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: t.labelSmall?.copyWith(color: AppColors.muted)),
        Text(value, style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
