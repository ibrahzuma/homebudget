import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../networth/finance_shared.dart';
import 'projects_screen.dart';

/// One project: budget usage and the transactions tagged with it.
class ProjectDetailScreen extends StatefulWidget {
  const ProjectDetailScreen({super.key, required this.id});
  final int id;

  @override
  State<ProjectDetailScreen> createState() => _ProjectDetailScreenState();
}

class _ProjectDetailScreenState extends State<ProjectDetailScreen> {
  final _loader = GlobalKey<LoadBuilderState<Project>>();
  Project? _project;

  Session get _session => context.read<Session>();
  String get _path => 'projects/${widget.id}/';

  Future<Project> _load() async {
    final p = Project.fromJson(await _session.api.get(_path) as Map<String, dynamic>);
    if (mounted) setState(() => _project = p);
    return p;
  }

  Future<void> _edit() async {
    final p = _project;
    if (p != null && await openProjectForm(context, existing: p)) {
      _loader.currentState?.reload();
    }
  }

  Future<void> _delete() async {
    final p = _project;
    if (p == null) return;
    final session = _session;
    final ok = await confirmDelete(
      context,
      title: 'Delete "${p.name}"?',
      message: 'Tagged transactions are kept; they just lose the project tag.',
      action: () => session.api.delete(_path),
      success: 'Project deleted',
    );
    if (!ok) return;
    refreshProjectPickers(session);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final symbol = context.watch<Session>().currencySymbol;
    return Scaffold(
      appBar: AppBar(
        title: Text(_project?.name ?? 'Project'),
        actions: [if (_project != null) EditDeleteMenu(onEdit: _edit, onDelete: _delete)],
      ),
      body: LoadBuilder<Project>(
        key: _loader,
        load: _load,
        builder: (context, p, reload) => ListView(
          padding: const EdgeInsets.only(top: 12, bottom: 32),
          children: [
            _Header(project: p, symbol: symbol),
            const SizedBox(height: 12),
            StatRow(children: [
              StatTile(
                  label: 'Spent',
                  value: fmtIn(p.spent, p.currency, symbol),
                  color: AppColors.expense,
                  icon: Icons.arrow_upward),
              StatTile(
                  label: 'Income received',
                  value: fmtIn(p.incomeReceived, p.currency, symbol),
                  color: AppColors.income,
                  icon: Icons.arrow_downward),
              if (p.budget > 0)
                StatTile(
                    label: p.isOverBudget ? 'Over budget' : 'Remaining',
                    value: fmtIn((p.budget - p.spent).abs(), p.currency, symbol),
                    color: p.isOverBudget ? AppColors.expense : null,
                    icon: Icons.account_balance_wallet_outlined),
            ]),
            SectionHeader('Transactions (${p.transactions.length})'),
            if (p.transactions.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  'No transactions tagged yet. Pick this project when adding a transaction.',
                  style: TextStyle(color: AppColors.muted),
                ),
              )
            else
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(children: [
                  for (final t in p.transactions) TxnTile(txn: t, symbol: symbol),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.project, required this.symbol});
  final Project project;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final p = project;
    final t = Theme.of(context).textTheme;
    final dates = projectDates(p);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            IconBadge(icon: p.icon, color: p.color, size: 48),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.name, style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                if (dates.isNotEmpty)
                  Text(dates, style: t.bodySmall?.copyWith(color: AppColors.muted)),
              ]),
            ),
            ProjectStatusChip(status: p.status),
          ]),
          if (p.description.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(p.description, style: t.bodyMedium),
          ],
          const SizedBox(height: 16),
          ProjectSpendBar(project: p, symbol: symbol),
        ]),
      ),
    );
  }
}
