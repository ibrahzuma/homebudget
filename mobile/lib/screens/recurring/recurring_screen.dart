import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../../widgets/entity_form.dart';
import '../networth/finance_shared.dart';

/// Recurring income and bills, with a manual "run due now".
class RecurringScreen extends StatefulWidget {
  const RecurringScreen({super.key});

  @override
  State<RecurringScreen> createState() => _RecurringScreenState();
}

class _RecurringScreenState extends State<RecurringScreen> {
  final _loader = GlobalKey<LoadBuilderState<List<Recurring>>>();
  bool _running = false;

  Session get _session => context.read<Session>();

  Future<List<Recurring>> _load() async {
    final list = await _session.api.get('recurring/') as List;
    final items = list.map((e) => Recurring.fromJson(e as Map<String, dynamic>)).toList();
    // Active first, then soonest due.
    items.sort((a, b) {
      if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
      return a.nextDueDate.compareTo(b.nextDueDate);
    });
    return items;
  }

  Future<void> _reload() async => _loader.currentState?.reload();

  Future<void> _add() async {
    if (await _openForm()) _reload();
  }

  Future<void> _edit(Recurring r) async {
    if (await _openForm(existing: r)) _reload();
  }

  Future<void> _delete(Recurring r) async {
    final ok = await confirmDelete(
      context,
      title: 'Delete "${r.name}"?',
      message: 'Transactions it already created are kept.',
      action: () => _session.api.delete('recurring/${r.id}/'),
      success: 'Recurring item deleted',
    );
    if (ok) _reload();
  }

  Future<void> _runNow() async {
    setState(() => _running = true);
    int created = 0;
    final ok = await runAction(context, () async {
      final res = await _session.api.post('recurring/run-now/') as Map<String, dynamic>;
      created = res['created'] as int? ?? 0;
    });
    if (!mounted) return;
    setState(() => _running = false);
    if (!ok) return;
    showOk(
        context,
        created == 0
            ? 'Nothing was due.'
            : 'Created $created transaction${created == 1 ? '' : 's'}.');
    if (created > 0) {
      _session.refreshBadges();
      _reload();
    }
  }

  Future<bool> _openForm({Recurring? existing}) {
    return openMetaForm(context, (meta, session) {
      final r = existing;
      return EntityFormScreen(
        title: r == null ? 'New recurring item' : 'Edit recurring item',
        initial: r == null
            ? {
                'transaction_type': 'expense',
                'currency': session.household?.baseCurrency?.id,
                'frequency': 'monthly',
                'start_date': DateTime.now(),
                'auto_create': true,
                'is_active': true,
              }
            : {
                'name': r.name,
                'transaction_type': r.type,
                'category': r.category?.id,
                'amount': r.raw['amount'],
                'currency': r.currency?.id,
                'payee': r.payee,
                'frequency': r.frequency,
                'start_date': r.startDate,
                'next_due_date': r.nextDueDate,
                'end_date': r.endDate,
                'auto_create': r.autoCreate,
                'is_active': r.isActive,
                'notes': r.notes,
              },
        fields: [
          const FieldSpec.text('name', 'Name', required: true, hint: 'e.g. Rent, Netflix'),
          FieldSpec.select('transaction_type', 'Type',
              options: choiceOptions(meta, 'transaction_type'), required: true),
          FieldSpec.select('category', 'Category',
              optionsBuilder: (v) =>
                  categoryOptions(meta, v['transaction_type'] as String? ?? 'expense')),
          const FieldSpec.money('amount', 'Amount', required: true),
          FieldSpec.select('currency', 'Currency', options: currencyOptions(meta)),
          const FieldSpec.text('payee', 'Payee / source'),
          FieldSpec.select('frequency', 'Frequency',
              options: choiceOptions(meta, 'frequency'), required: true),
          const FieldSpec.date('start_date', 'Start date', required: true),
          FieldSpec.date('next_due_date', 'Next due date',
              required: r != null, help: r == null ? 'Leave blank to use the start date.' : null),
          const FieldSpec.date('end_date', 'End date', help: 'Optional. Stops after this date.'),
          const FieldSpec.toggle('auto_create', 'Create automatically',
              help: 'Add the transaction on its due date without asking.'),
          const FieldSpec.toggle('is_active', 'Active'),
          const FieldSpec.multiline('notes', 'Notes'),
        ],
        onSubmit: (v) => r == null
            ? session.api.post('recurring/', v)
            : session.api.patch('recurring/${r.id}/', v),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recurring'),
        actions: [
          _running
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox(
                      width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : IconButton(
                  tooltip: 'Run due now',
                  icon: const Icon(Icons.play_circle_outline),
                  onPressed: _runNow,
                ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
      body: LoadBuilder<List<Recurring>>(
        key: _loader,
        load: _load,
        builder: (context, items, reload) {
          if (items.isEmpty) {
            return EmptyState(
              icon: Icons.repeat,
              title: 'No recurring items',
              message: 'Add rent, salaries and subscriptions so they are recorded for you.',
              action: FilledButton.icon(
                  onPressed: _add, icon: const Icon(Icons.add), label: const Text('Add recurring')),
            );
          }
          return ListView(
            padding: const EdgeInsets.only(top: 8, bottom: 96),
            children: [
              _SummaryRow(items: items),
              const SizedBox(height: 4),
              for (final r in items)
                _RecurringTile(
                  item: r,
                  frequencyLabel: session.meta?.label('frequency', r.frequency) ??
                      humanize(r.frequency),
                  symbol: session.currencySymbol,
                  onTap: () => _edit(r),
                  onDelete: () => _delete(r),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Active / due this week / overdue counts.
class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.items});
  final List<Recurring> items;

  @override
  Widget build(BuildContext context) {
    final active = items.where((r) => r.isActive).toList();
    final dueSoon = active.where((r) => r.daysUntilDue <= 7).length;
    final overdue = active.where((r) => r.daysUntilDue < 0).length;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: StatRow(children: [
        StatTile(label: 'Active', value: '${active.length}', icon: Icons.repeat),
        StatTile(
            label: 'Due in 7 days',
            value: '$dueSoon',
            icon: Icons.event_outlined,
            color: dueSoon > 0 ? AppColors.warning : null),
        StatTile(
            label: 'Overdue',
            value: '$overdue',
            icon: Icons.warning_amber_rounded,
            color: overdue > 0 ? AppColors.expense : null),
      ]),
    );
  }
}

class _RecurringTile extends StatelessWidget {
  const _RecurringTile({
    required this.item,
    required this.frequencyLabel,
    required this.symbol,
    required this.onTap,
    required this.onDelete,
  });
  final Recurring item;
  final String frequencyLabel;
  final String symbol;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final r = item;
    final t = Theme.of(context).textTheme;
    final income = r.type == 'income';
    final color = income ? AppColors.income : AppColors.expense;
    final dueColor = !r.isActive
        ? AppColors.muted
        : r.daysUntilDue < 0
            ? AppColors.expense
            : (r.daysUntilDue <= 3 ? AppColors.warning : AppColors.muted);
    final sub = [
      frequencyLabel,
      if (r.category != null) r.category!.name,
      if (r.payee.isNotEmpty) r.payee,
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
          child: Row(children: [
            Opacity(
              opacity: r.isActive ? 1 : 0.5,
              child: r.category == null
                  ? IconBadge(
                      iconData: income ? Icons.south_west : Icons.north_east,
                      color: income ? '#198754' : '#dc3545',
                      size: 38)
                  : IconBadge(icon: r.category!.icon, color: r.category!.color, size: 38),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r.name,
                    style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                Text(sub,
                    style: t.bodySmall?.copyWith(color: AppColors.muted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text(
                    'Next ${fmtDateShort(r.nextDueDate)} (${fmtRelativeDays(r.daysUntilDue)})',
                    style: t.bodySmall?.copyWith(color: dueColor, fontWeight: FontWeight.w500),
                  ),
                  if (!r.isActive) const StatusChip('Paused'),
                  if (r.isActive && !r.autoCreate) const StatusChip('Manual', color: AppColors.info),
                ]),
              ]),
            ),
            const SizedBox(width: 8),
            Text(
              fmtIn(income ? r.amount : -r.amount, r.currency, symbol, signed: true),
              style: t.titleSmall?.copyWith(color: color, fontWeight: FontWeight.w700),
            ),
            PopupMenuButton<String>(
              onSelected: (v) => v == 'edit' ? onTap() : onDelete(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Edit')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ]),
        ),
      ),
    );
  }
}
