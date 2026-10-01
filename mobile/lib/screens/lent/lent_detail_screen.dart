import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../../widgets/entity_form.dart';
import '../networth/finance_shared.dart';
import 'lent_screen.dart';

/// One loan to someone else: progress, details and repayments.
class LentDetailScreen extends StatefulWidget {
  const LentDetailScreen({super.key, required this.id});
  final int id;

  @override
  State<LentDetailScreen> createState() => _LentDetailScreenState();
}

class _LentDetailScreenState extends State<LentDetailScreen> {
  final _loader = GlobalKey<LoadBuilderState<Receivable>>();
  Receivable? _item;

  Session get _session => context.read<Session>();
  String get _path => 'lent/${widget.id}/';

  Future<Receivable> _load() async {
    final r = Receivable.fromJson(await _session.api.get(_path) as Map<String, dynamic>);
    if (mounted) setState(() => _item = r);
    return r;
  }

  Future<void> _reload() async => _loader.currentState?.reload();

  Future<void> _edit() async {
    final r = _item;
    if (r != null && await openLentForm(context, existing: r)) _reload();
  }

  Future<void> _delete() async {
    final r = _item;
    if (r == null) return;
    final ok = await confirmDelete(
      context,
      title: 'Delete loan to ${r.debtorName}?',
      message: 'This removes the record and its repayment history.',
      action: () => _session.api.delete(_path),
      success: 'Loan deleted',
    );
    if (ok && mounted) Navigator.pop(context);
  }

  Future<void> _recordRepayment() async {
    final r = _item;
    if (r == null) return;
    final saved = await openMetaForm(context, (meta, session) {
      return EntityFormScreen(
        title: 'Record repayment',
        submitLabel: 'Record repayment',
        intro: Text('Money received back from ${r.debtorName}.',
            style: const TextStyle(color: AppColors.muted)),
        initial: {
          'date': DateTime.now(),
          'amount': r.raw['balance'],
          'currency': r.currency?.id ?? session.household?.baseCurrency?.id,
          'record_as_income': true,
        },
        fields: [
          const FieldSpec.date('date', 'Date', required: true),
          const FieldSpec.money('amount', 'Amount', required: true),
          FieldSpec.select('currency', 'Currency', options: currencyOptions(meta)),
          const FieldSpec.multiline('notes', 'Notes'),
          const FieldSpec.toggle('record_as_income', 'Also record as household income'),
        ],
        onSubmit: (v) => session.api.post('${_path}repayments/', v),
      );
    });
    if (saved && mounted) {
      showOk(context, 'Repayment recorded');
      _reload();
    }
  }

  Future<void> _deleteRepayment(Payment p, String symbol) async {
    final ok = await confirmDelete(
      context,
      title: 'Delete this repayment?',
      message: 'The outstanding amount goes back up by ${fmtIn(p.amount, p.currency, symbol)}'
          '${p.transactionId != null ? ', and the income recorded for it is removed' : ''}.',
      action: () => _session.api.delete('${_path}repayments/${p.id}/'),
      success: 'Repayment deleted',
    );
    if (ok) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final symbol = context.watch<Session>().currencySymbol;
    final canRecord = _item != null && (_item!.status == 'active' || _item!.balance > 0);
    return Scaffold(
      appBar: AppBar(
        title: Text(_item?.debtorName ?? 'Money lent'),
        actions: [if (_item != null) EditDeleteMenu(onEdit: _edit, onDelete: _delete)],
      ),
      floatingActionButton: !canRecord
          ? null
          : FloatingActionButton.extended(
              onPressed: _recordRepayment,
              icon: const Icon(Icons.call_received),
              label: const Text('Record repayment'),
            ),
      body: LoadBuilder<Receivable>(
        key: _loader,
        load: _load,
        builder: (context, r, reload) => ListView(
          padding: const EdgeInsets.only(top: 12, bottom: 96),
          children: [
            _ProgressCard(item: r, symbol: symbol),
            const SizedBox(height: 12),
            InfoCard(rows: [
              ('Contact', r.debtorContact),
              ('For', r.description),
              ('Lent on', r.lentDate == null ? '' : fmtDate(r.lentDate)),
              ('Due', r.dueDate == null ? '' : fmtDate(r.dueDate)),
              ('Interest rate', r.interestRate == null ? '' : '${r.interestRate}%'),
              ('Currency', r.currency?.code ?? ''),
              ('Notes', r.notes),
            ]),
            SectionHeader('Repayments (${r.payments.length})'),
            if (r.payments.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text('No repayments yet.', style: TextStyle(color: AppColors.muted)),
              )
            else
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(children: [
                  for (final p in r.payments)
                    PaymentTile(
                      payment: p,
                      symbol: symbol,
                      linkedLabel: 'Recorded as income',
                      onDelete: () => _deleteRepayment(p, symbol),
                    ),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.item, required this.symbol});
  final Receivable item;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final r = item;
    final t = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: HeadlineAmount(
                caption: 'Still owed to you',
                amount: fmtIn(r.balance, r.currency, symbol),
              ),
            ),
            LentStatusChip(item: r),
          ]),
          const SizedBox(height: 16),
          ProgressLine(percent: r.pct, color: AppColors.income, height: 10),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: Text('Received ${fmtIn(r.received, r.currency, symbol)}',
                  style: t.bodyMedium?.copyWith(color: AppColors.income)),
            ),
            Text('${fmtPct(r.pct)} of ${fmtIn(r.original, r.currency, symbol)}',
                style: t.bodyMedium?.copyWith(color: AppColors.muted)),
          ]),
          if (r.isOverdue && r.dueDate != null) ...[
            const SizedBox(height: 8),
            Text(
              'Overdue since ${fmtDate(r.dueDate)}',
              style: t.bodyMedium?.copyWith(color: AppColors.expense, fontWeight: FontWeight.w600),
            ),
          ],
        ]),
      ),
    );
  }
}
