import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../../widgets/entity_form.dart';
import '../networth/finance_shared.dart';
import 'goals_screen.dart';

/// One goal: progress, plan and contribution history.
class GoalDetailScreen extends StatefulWidget {
  const GoalDetailScreen({super.key, required this.id});
  final int id;

  @override
  State<GoalDetailScreen> createState() => _GoalDetailScreenState();
}

class _GoalDetailScreenState extends State<GoalDetailScreen> {
  final _loader = GlobalKey<LoadBuilderState<Goal>>();
  Goal? _goal;

  Session get _session => context.read<Session>();
  String get _path => 'goals/${widget.id}/';

  Future<Goal> _load() async {
    final g = Goal.fromJson(await _session.api.get(_path) as Map<String, dynamic>);
    if (mounted) setState(() => _goal = g);
    return g;
  }

  Future<void> _reload() async => _loader.currentState?.reload();

  Future<void> _edit() async {
    final g = _goal;
    if (g != null && await openGoalForm(context, existing: g)) _reload();
  }

  Future<void> _delete() async {
    final g = _goal;
    if (g == null) return;
    final ok = await confirmDelete(
      context,
      title: 'Delete "${g.name}"?',
      message: 'The goal and its contribution history will be removed.',
      action: () => _session.api.delete(_path),
      success: 'Goal deleted',
    );
    if (ok && mounted) Navigator.pop(context);
  }

  Future<void> _contribute() async {
    final g = _goal;
    if (g == null) return;
    Goal? updated;
    final saved = await openForm(
      context,
      EntityFormScreen(
        title: 'Add contribution',
        submitLabel: 'Add contribution',
        intro: Text('Adding to ${g.name}.', style: const TextStyle(color: AppColors.muted)),
        initial: {'date': DateTime.now(), 'record_as_expense': false},
        fields: const [
          FieldSpec.money('amount', 'Amount', required: true),
          FieldSpec.date('date', 'Date', required: true),
          FieldSpec.multiline('notes', 'Notes'),
          FieldSpec.toggle('record_as_expense', 'Also record as a household expense',
              help: 'Only turn this on if the money is leaving your spendable funds.'),
        ],
        onSubmit: (v) async {
          final res = await _session.api.post('${_path}contributions/', v);
          updated = Goal.fromJson(res as Map<String, dynamic>);
        },
      ),
    );
    if (!saved || !mounted) return;
    if (updated?.status == 'achieved' && g.status != 'achieved') {
      _celebrate(g.name);
    } else {
      showOk(context, 'Contribution added');
    }
    _reload();
  }

  void _celebrate(String name) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        backgroundColor: AppColors.income,
        duration: const Duration(seconds: 5),
        content: Row(children: [
          const Icon(Icons.emoji_events, color: Colors.white),
          const SizedBox(width: 12),
          Expanded(
            child: Text('Goal reached! "$name" is fully funded.',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ]),
      ));
  }

  Future<void> _deleteContribution(GoalContribution c, String symbol) async {
    final g = _goal!;
    final ok = await confirmDelete(
      context,
      title: 'Delete this contribution?',
      message: 'The saved amount goes down by ${fmtIn(c.amount, g.currency, symbol)}'
          '${c.transactionId != null ? ', and the expense recorded for it is removed' : ''}.',
      action: () => _session.api.delete('${_path}contributions/${c.id}/'),
      success: 'Contribution deleted',
    );
    if (ok) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final symbol = context.watch<Session>().currencySymbol;
    return Scaffold(
      appBar: AppBar(
        title: Text(_goal?.name ?? 'Goal'),
        actions: [if (_goal != null) EditDeleteMenu(onEdit: _edit, onDelete: _delete)],
      ),
      floatingActionButton: _goal == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _contribute,
              icon: const Icon(Icons.add),
              label: const Text('Add contribution'),
            ),
      body: LoadBuilder<Goal>(
        key: _loader,
        load: _load,
        builder: (context, g, reload) => ListView(
          padding: const EdgeInsets.only(top: 12, bottom: 96),
          children: [
            _GoalHeader(goal: g, symbol: symbol),
            const SizedBox(height: 12),
            InfoCard(rows: [
              ('Target date', g.targetDate == null ? '' : fmtDate(g.targetDate)),
              ('Months left', g.monthsRemaining == null ? '' : '${g.monthsRemaining}'),
              ('Needed / month',
                  g.monthlyNeeded == null ? '' : fmtIn(g.monthlyNeeded, g.currency, symbol)),
              ('Planned / month',
                  g.monthlyContribution == null
                      ? ''
                      : fmtIn(g.monthlyContribution, g.currency, symbol)),
              ('Currency', g.currency?.code ?? ''),
              ('Notes', g.notes),
            ]),
            SectionHeader('Contributions (${g.contributions.length})'),
            if (g.contributions.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text('No contributions yet.', style: TextStyle(color: AppColors.muted)),
              )
            else
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(children: [
                  for (final c in g.contributions)
                    _ContributionTile(
                      contribution: c,
                      amount: fmtIn(c.amount, g.currency, symbol),
                      onDelete: () => _deleteContribution(c, symbol),
                    ),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}

class _GoalHeader extends StatelessWidget {
  const _GoalHeader({required this.goal, required this.symbol});
  final Goal goal;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final g = goal;
    final t = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Row(children: [
            GoalRing(goal: g, size: 96),
            const SizedBox(width: 18),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                GoalStatusChip(status: g.status),
                const SizedBox(height: 8),
                HeadlineAmount(
                  caption: 'Saved',
                  amount: fmtIn(g.currentAmount, g.currency, symbol),
                  color: hexColor(g.color),
                ),
                Text('of ${fmtIn(g.targetAmount, g.currency, symbol)}',
                    style: t.bodyMedium?.copyWith(color: AppColors.muted)),
              ]),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: Text(
                g.amountRemaining > 0
                    ? '${fmtIn(g.amountRemaining, g.currency, symbol)} to go'
                    : 'Target reached',
                style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ]),
          if (g.status == 'active') ...[
            const SizedBox(height: 6),
            GoalPaceLine(goal: g, symbol: symbol),
          ],
        ]),
      ),
    );
  }
}

class _ContributionTile extends StatelessWidget {
  const _ContributionTile(
      {required this.contribution, required this.amount, required this.onDelete});
  final GoalContribution contribution;
  final String amount;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final c = contribution;
    final sub = [
      fmtDate(c.date),
      if (c.user != null) c.user!.username,
      if (c.transactionId != null) 'Recorded as expense',
    ].join(' · ');
    return ListTile(
      leading: const CircleAvatar(child: Icon(Icons.savings_outlined, size: 20)),
      title: Text(amount, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(c.notes.isEmpty ? sub : '$sub\n${c.notes}'),
      isThreeLine: c.notes.isNotEmpty,
      trailing: IconButton(
          tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: onDelete),
    );
  }
}
