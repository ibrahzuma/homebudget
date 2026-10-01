import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../../widgets/entity_form.dart';
import '../categories/categories_screen.dart';
import '../transactions/transaction_form.dart';

final _monthFmt = DateFormat('MMMM yyyy');

/// Monthly budgets: this month with live progress, then upcoming and past
/// months.
class BudgetsScreen extends StatefulWidget {
  const BudgetsScreen({super.key});

  @override
  State<BudgetsScreen> createState() => _BudgetsScreenState();
}

class _BudgetsScreenState extends State<BudgetsScreen> {
  final _loader = GlobalKey<LoadBuilderState<List<BudgetRow>>>();

  Future<List<BudgetRow>> _load() async {
    final res = await context.read<Session>().api.get('budgets/') as List;
    return [for (final b in res) BudgetRow.fromJson(b as Map<String, dynamic>)];
  }

  Future<void> _openForm([BudgetRow? existing]) async {
    final meta = await metaForForm(context);
    if (meta == null || !mounted) return;
    final session = context.read<Session>();
    final expenseCats = meta.categoriesOfType('expense');
    if (expenseCats.isEmpty) {
      showError(context, 'Add an expense category first.');
      return;
    }
    final now = DateTime.now();
    final form = EntityFormScreen(
      title: existing == null ? 'Set budget' : 'Edit budget',
      initial: {
        'category': existing?.category.id,
        'monthly_limit': existing?.limit.toStringAsFixed(2),
        'month': existing?.month ?? DateTime(now.year, now.month),
      },
      fields: [
        FieldSpec.select('category', 'Expense category', required: true, options: [
          for (final c in expenseCats) Option(c.id, c.name),
        ]),
        FieldSpec.money('monthly_limit', 'Monthly limit (${session.currencyCode})',
            required: true),
        const FieldSpec.date('month', 'Month',
            required: true, help: 'Any day in the month works; budgets are per month.'),
      ],
      onSubmit: (v) async {
        if (existing == null) {
          await session.api.post('budgets/', v);
        } else {
          await session.api.patch('budgets/${existing.id}/', v);
        }
      },
    );
    if (await openForm(context, form)) {
      session.refreshBadges();
      await _loader.currentState?.reload();
    }
  }

  Future<void> _delete(BudgetRow b) async {
    final label = b.month == null ? '' : ' for ${_monthFmt.format(b.month!)}';
    final ok = await confirm(context, title: 'Delete the ${b.category.name} budget$label?');
    if (!ok || !mounted) return;
    final api = context.read<Session>().api;
    if (await runAction(context, () => api.delete('budgets/${b.id}/'), success: 'Budget deleted')) {
      await _loader.currentState?.reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Budgets'),
        actions: [
          IconButton(
            tooltip: 'Categories',
            icon: const Icon(Icons.sell_outlined),
            onPressed: () => push(context, const CategoriesScreen()),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(),
        icon: const Icon(Icons.add),
        label: const Text('Set budget'),
      ),
      body: LoadBuilder<List<BudgetRow>>(
        key: _loader,
        load: _load,
        builder: (context, rows, _) {
          if (rows.isEmpty) {
            return EmptyState(
              icon: Icons.pie_chart_outline,
              title: 'No budgets set yet',
              message: 'Set a monthly limit per expense category and get alerted at 80% and 100%.',
              action: FilledButton.icon(
                onPressed: () => _openForm(),
                icon: const Icon(Icons.add),
                label: const Text('Set budget'),
              ),
            );
          }
          return _BudgetList(rows: rows, onEdit: _openForm, onDelete: _delete);
        },
      ),
    );
  }
}

class _BudgetList extends StatelessWidget {
  const _BudgetList({required this.rows, required this.onEdit, required this.onDelete});
  final List<BudgetRow> rows;
  final ValueChanged<BudgetRow> onEdit;
  final ValueChanged<BudgetRow> onDelete;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final thisMonth = DateTime(now.year, now.month);
    final current = rows.where((b) => b.isCurrent).toList();
    final upcoming = rows.where((b) => !b.isCurrent && b.month != null && b.month!.isAfter(thisMonth)).toList()
      ..sort((a, b) => a.month!.compareTo(b.month!));
    final past = rows.where((b) => !b.isCurrent && !upcoming.contains(b)).toList();

    // Past budgets grouped by month, newest first (the API already orders by -month).
    final pastByMonth = <DateTime?, List<BudgetRow>>{};
    for (final b in past) {
      pastByMonth.putIfAbsent(b.month, () => []).add(b);
    }

    Widget card(BudgetRow b) =>
        _BudgetCard(budget: b, onEdit: () => onEdit(b), onDelete: () => onDelete(b));

    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        SectionHeader('This month · ${_monthFmt.format(thisMonth)}'),
        if (current.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('No budgets for this month yet.', style: TextStyle(color: AppColors.muted)),
            ),
          )
        else ...[
          _MonthSummary(rows: current),
          ...current.map(card),
        ],
        if (upcoming.isNotEmpty) ...[
          const SectionHeader('Upcoming'),
          ...upcoming.map(card),
        ],
        for (final e in pastByMonth.entries) ...[
          SectionHeader(e.key == null ? 'Past' : _monthFmt.format(e.key!)),
          ...e.value.map(card),
        ],
      ],
    );
  }
}

/// Totals across this month's budgets.
class _MonthSummary extends StatelessWidget {
  const _MonthSummary({required this.rows});
  final List<BudgetRow> rows;

  @override
  Widget build(BuildContext context) {
    final sym = context.watch<Session>().currencySymbol;
    final limit = rows.fold<double>(0, (s, b) => s + b.limit);
    final spent = rows.fold<double>(0, (s, b) => s + (b.spent ?? 0));
    final over = rows.where((b) => b.over).length;
    final pct = limit == 0 ? 0.0 : spent / limit * 100;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(children: [
        StatRow(children: [
          StatTile(label: 'Budgeted', value: fmtMoney(limit, symbol: sym)),
          StatTile(label: 'Spent', value: fmtMoney(spent, symbol: sym), color: AppColors.expense),
          StatTile(
            label: 'Left',
            value: fmtMoney(limit - spent, symbol: sym),
            color: limit - spent < 0 ? AppColors.expense : AppColors.income,
          ),
        ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(children: [
            Expanded(child: ProgressLine(percent: pct)),
            const SizedBox(width: 12),
            Text(fmtPct(pct)),
          ]),
        ),
        if (over > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(children: [
              const Icon(Icons.warning_amber, size: 16, color: AppColors.expense),
              const SizedBox(width: 6),
              Text('$over budget${over == 1 ? ' is' : 's are'} over the limit',
                  style: const TextStyle(color: AppColors.expense)),
            ]),
          ),
      ]),
    );
  }
}

class _BudgetCard extends StatelessWidget {
  const _BudgetCard({required this.budget, required this.onEdit, required this.onDelete});
  final BudgetRow budget;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final sym = context.watch<Session>().currencySymbol;
    final b = budget;
    final t = Theme.of(context).textTheme;
    final theme = Theme.of(context).cardTheme;
    final overShape = b.over
        ? RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: AppColors.expense, width: 1.5),
          )
        : theme.shape;

    return Card(
      shape: overShape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              IconBadge(icon: b.category.icon, color: b.category.color, size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(b.category.name, style: t.titleSmall),
                  Text(
                    b.isCurrent
                        ? '${fmtMoney(b.spent, symbol: sym)} of ${fmtMoney(b.limit, symbol: sym)}'
                        : 'Limit ${fmtMoney(b.limit, symbol: sym)}',
                    style: t.bodySmall?.copyWith(color: AppColors.muted),
                  ),
                ]),
              ),
              if (b.over) const StatusChip('Over budget', color: AppColors.expense),
              PopupMenuButton<String>(
                onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ]),
            if (b.isCurrent) ...[
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: ProgressLine(percent: b.pct ?? 0, color: b.over ? AppColors.expense : null),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: _RemainingLine(budget: b, symbol: sym),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

class _RemainingLine extends StatelessWidget {
  const _RemainingLine({required this.budget, required this.symbol});
  final BudgetRow budget;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    final left = budget.limit - (budget.spent ?? 0);
    return Row(children: [
      Text(fmtPct(budget.pct), style: style?.copyWith(color: AppColors.muted)),
      const Spacer(),
      Text(
        left < 0
            ? 'Over by ${fmtMoney(-left, symbol: symbol)}'
            : '${fmtMoney(left, symbol: symbol)} left',
        style: style?.copyWith(
          color: left < 0 ? AppColors.expense : AppColors.muted,
          fontWeight: left < 0 ? FontWeight.w600 : null,
        ),
      ),
    ]);
  }
}
