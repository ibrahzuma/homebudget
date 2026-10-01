import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../../widgets/entity_form.dart';
import '../networth/finance_shared.dart';
import 'lent_detail_screen.dart';

class _LentList {
  _LentList.fromJson(Map<String, dynamic> j)
      : items = (j['results'] as List)
            .map((e) => Receivable.fromJson(e as Map<String, dynamic>))
            .toList(),
        totalOutstanding = money(j['total_outstanding']),
        totalReceived = money(j['total_received']),
        overdueCount = j['overdue_count'] as int? ?? 0;
  final List<Receivable> items;
  final double totalOutstanding;
  final double totalReceived;
  final int overdueCount;
}

/// Money lent to other people (receivables) and their repayments.
class LentScreen extends StatefulWidget {
  const LentScreen({super.key});

  @override
  State<LentScreen> createState() => _LentScreenState();
}

class _LentScreenState extends State<LentScreen> {
  final _loader = GlobalKey<LoadBuilderState<_LentList>>();

  Future<_LentList> _load() async => _LentList.fromJson(
      await context.read<Session>().api.get('lent/') as Map<String, dynamic>);

  Future<void> _reload() async => _loader.currentState?.reload();

  Future<void> _add() async {
    if (await openLentForm(context)) _reload();
  }

  Future<void> _open(Receivable r) async {
    await push(context, LentDetailScreen(id: r.id));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final symbol = context.watch<Session>().currencySymbol;
    return Scaffold(
      appBar: AppBar(title: const Text('Money lent')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('Lend money'),
      ),
      body: LoadBuilder<_LentList>(
        key: _loader,
        load: _load,
        builder: (context, data, reload) {
          if (data.items.isEmpty) {
            return EmptyState(
              icon: Icons.handshake_outlined,
              title: 'Nobody owes you money',
              message: 'Record money you lend to friends or family and track repayments.',
              action: FilledButton.icon(
                  onPressed: _add, icon: const Icon(Icons.add), label: const Text('Lend money')),
            );
          }
          return ListView(
            padding: const EdgeInsets.only(top: 12, bottom: 96),
            children: [
              StatRow(children: [
                StatTile(
                    label: 'Outstanding',
                    value: fmtMoney(data.totalOutstanding, symbol: symbol),
                    color: AppColors.info,
                    icon: Icons.schedule),
                StatTile(
                    label: 'Received',
                    value: fmtMoney(data.totalReceived, symbol: symbol),
                    color: AppColors.income,
                    icon: Icons.call_received),
                StatTile(
                    label: 'Overdue',
                    value: '${data.overdueCount}',
                    color: data.overdueCount > 0 ? AppColors.expense : null,
                    icon: Icons.warning_amber_rounded),
              ]),
              SectionHeader('${data.items.length} loan${data.items.length == 1 ? '' : 's'}'),
              for (final r in data.items)
                _LentCard(item: r, symbol: symbol, onTap: () => _open(r)),
            ],
          );
        },
      ),
    );
  }
}

class _LentCard extends StatelessWidget {
  const _LentCard({required this.item, required this.symbol, required this.onTap});
  final Receivable item;
  final String symbol;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final r = item;
    final sub = [
      if (r.description.isNotEmpty) r.description,
      if (r.lentDate != null) 'Lent ${fmtDate(r.lentDate)}',
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CircleAvatar(
                radius: 18,
                child: Text(r.debtorName.isEmpty ? '?' : r.debtorName[0].toUpperCase()),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(r.debtorName, style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                  if (sub.isNotEmpty)
                    Text(sub,
                        style: t.bodySmall?.copyWith(color: AppColors.muted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(fmtIn(r.balance, r.currency, symbol),
                    style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                LentStatusChip(item: r),
              ]),
            ]),
            const SizedBox(height: 12),
            ProgressLine(percent: r.pct, color: AppColors.income),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                child: Text(
                  'Received ${fmtIn(r.received, r.currency, symbol)} of ${fmtIn(r.original, r.currency, symbol)}',
                  style: t.bodySmall?.copyWith(color: AppColors.muted),
                ),
              ),
              if (r.dueDate != null)
                Text('Due ${fmtDateShort(r.dueDate)}',
                    style: t.bodySmall?.copyWith(
                        color: r.isOverdue ? AppColors.expense : AppColors.muted,
                        fontWeight: r.isOverdue ? FontWeight.w600 : null)),
            ]),
          ]),
        ),
      ),
    );
  }
}

/// Overdue / active / paid / written off.
class LentStatusChip extends StatelessWidget {
  const LentStatusChip({super.key, required this.item});
  final Receivable item;

  @override
  Widget build(BuildContext context) {
    if (item.isOverdue) return const StatusChip('Overdue', color: AppColors.expense);
    return switch (item.status) {
      'paid' => const StatusChip('Paid', color: AppColors.income),
      'written_off' => const StatusChip('Written off'),
      _ => const StatusChip('Active', color: AppColors.info),
    };
  }
}

/// Create ([existing] null) or edit money lent. Resolves true when saved.
Future<bool> openLentForm(BuildContext context, {Receivable? existing}) {
  return openMetaForm(context, (meta, session) {
    final r = existing?.raw;
    return EntityFormScreen(
      title: existing == null ? 'Lend money' : 'Edit loan',
      initial: r == null
          ? {
              'lent_date': DateTime.now(),
              'status': 'active',
              'currency': session.household?.baseCurrency?.id,
              'record_as_expense': false,
            }
          : {
              'debtor_name': r['debtor_name'],
              'debtor_contact': r['debtor_contact'],
              'description': r['description'],
              'balance': r['balance'],
              'original_amount': r['original_amount'],
              'currency': existing!.currency?.id,
              'interest_rate': r['interest_rate'],
              'lent_date': r['lent_date'],
              'due_date': r['due_date'],
              'status': r['status'],
              'notes': r['notes'],
            },
      fields: [
        const FieldSpec.text('debtor_name', 'Borrower', required: true,
            hint: 'Name of the borrower'),
        const FieldSpec.text('debtor_contact', 'Contact', hint: 'Phone or email'),
        const FieldSpec.text('description', 'What for', hint: 'e.g. tuition, emergency fund'),
        const FieldSpec.money('balance', 'Outstanding amount', required: true,
            help: 'What they still owe you.'),
        const FieldSpec.money('original_amount', 'Original amount',
            help: 'Optional. Used to show how much has been repaid.'),
        FieldSpec.select('currency', 'Currency', options: currencyOptions(meta)),
        const FieldSpec.money('interest_rate', 'Interest rate (%)'),
        const FieldSpec.date('lent_date', 'Date lent', required: true),
        const FieldSpec.date('due_date', 'Expected repayment date'),
        FieldSpec.select('status', 'Status',
            options: choiceOptions(meta, 'receivable_status'), required: true),
        const FieldSpec.multiline('notes', 'Notes'),
        if (existing == null)
          const FieldSpec.toggle('record_as_expense', 'Also record as a household expense',
              help: 'Turn on only for a brand-new loan when you want the cash outflow tracked.'),
      ],
      onSubmit: (v) => existing == null
          ? session.api.post('lent/', v)
          : session.api.patch('lent/${existing.id}/', v),
    );
  });
}
