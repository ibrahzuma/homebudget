import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../../widgets/entity_form.dart';
import '../networth/finance_shared.dart';
import 'debts_screen.dart';

/// One debt: progress, details and payment history.
class DebtDetailScreen extends StatefulWidget {
  const DebtDetailScreen({super.key, required this.id});
  final int id;

  @override
  State<DebtDetailScreen> createState() => _DebtDetailScreenState();
}

class _DebtDetailScreenState extends State<DebtDetailScreen> {
  final _loader = GlobalKey<LoadBuilderState<Liability>>();
  Liability? _debt;

  Session get _session => context.read<Session>();
  String get _path => 'debts/${widget.id}/';

  Future<Liability> _load() async {
    final l = Liability.fromJson(await _session.api.get(_path) as Map<String, dynamic>);
    if (mounted) setState(() => _debt = l);
    return l;
  }

  Future<void> _reload() async => _loader.currentState?.reload();

  Future<void> _edit() async {
    final d = _debt;
    if (d != null && await openDebtForm(context, existing: d)) _reload();
  }

  Future<void> _delete() async {
    final d = _debt;
    if (d == null) return;
    final ok = await confirmDelete(
      context,
      title: 'Delete "${d.name}"?',
      message: 'This removes the debt and its payment history.',
      action: () => _session.api.delete(_path),
      success: 'Debt deleted',
    );
    if (ok && mounted) Navigator.pop(context);
  }

  Future<void> _recordPayment() async {
    final d = _debt;
    if (d == null) return;
    final saved = await openMetaForm(context, (meta, session) {
      return EntityFormScreen(
        title: 'Record payment',
        submitLabel: 'Record payment',
        intro: Text('Paying towards ${d.name}. The balance goes down by the amount paid.',
            style: const TextStyle(color: AppColors.muted)),
        initial: {
          'date': DateTime.now(),
          'amount': d.raw['balance'],
          'currency': d.currency?.id ?? session.household?.baseCurrency?.id,
          'record_as_expense': true,
        },
        fields: [
          const FieldSpec.date('date', 'Date', required: true),
          const FieldSpec.money('amount', 'Amount', required: true),
          FieldSpec.select('currency', 'Currency', options: currencyOptions(meta)),
          const FieldSpec.multiline('notes', 'Notes'),
          const FieldSpec.toggle('record_as_expense', 'Also record as a household expense'),
          FieldSpec.select('expense_category', 'Expense category',
              options: categoryOptions(meta, 'expense'),
              help: 'Leave blank to use a "Debt Payment" category.',
              visibleWhen: (v) => v['record_as_expense'] == true),
        ],
        onSubmit: (v) => session.api.post('${_path}payments/', v),
      );
    });
    if (saved && mounted) {
      showOk(context, 'Payment recorded');
      _reload();
    }
  }

  Future<void> _deletePayment(Payment p, String symbol) async {
    final ok = await confirmDelete(
      context,
      title: 'Delete this payment?',
      message: 'The debt balance goes back up by ${fmtIn(p.amount, p.currency, symbol)}'
          '${p.transactionId != null ? ', and the expense recorded for it is removed' : ''}.',
      action: () => _session.api.delete('${_path}payments/${p.id}/'),
      success: 'Payment deleted',
    );
    if (ok) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final symbol = context.watch<Session>().currencySymbol;
    return Scaffold(
      appBar: AppBar(
        title: Text(_debt?.name ?? 'Debt'),
        actions: [if (_debt != null) EditDeleteMenu(onEdit: _edit, onDelete: _delete)],
      ),
      floatingActionButton: _debt == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _recordPayment,
              icon: const Icon(Icons.payments_outlined),
              label: const Text('Record payment'),
            ),
      body: LoadBuilder<Liability>(
        key: _loader,
        load: _load,
        builder: (context, d, reload) => ListView(
          padding: const EdgeInsets.only(top: 12, bottom: 96),
          children: [
            _ProgressCard(debt: d, symbol: symbol),
            const SizedBox(height: 12),
            InfoCard(rows: [
              ('Type', d.liabilityTypeDisplay),
              ('Lender', d.lender),
              ('Interest rate', d.interestRate == null ? '' : '${d.interestRate}% APR'),
              ('Start date', d.startDate == null ? '' : fmtDate(d.startDate)),
              ('Due date', d.dueDate == null ? '' : fmtDate(d.dueDate)),
              ('Currency', d.currency?.code ?? ''),
              ('Notes', d.notes),
            ]),
            SectionHeader('Payments (${d.payments.length})'),
            if (d.payments.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text('No payments yet. Tap "Record payment" after you pay.',
                    style: TextStyle(color: AppColors.muted)),
              )
            else
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(children: [
                  for (final p in d.payments)
                    PaymentTile(
                      payment: p,
                      symbol: symbol,
                      linkedLabel: 'Recorded as expense',
                      onDelete: () => _deletePayment(p, symbol),
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
  const _ProgressCard({required this.debt, required this.symbol});
  final Liability debt;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final d = debt;
    final t = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          HeadlineAmount(
            caption: 'Outstanding balance',
            amount: fmtIn(d.balance, d.currency, symbol),
            color: d.balance <= 0 ? AppColors.income : AppColors.expense,
          ),
          const SizedBox(height: 16),
          ProgressLine(percent: d.pct, color: AppColors.income, height: 10),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: Text('Paid ${fmtIn(d.paid, d.currency, symbol)}',
                  style: t.bodyMedium?.copyWith(color: AppColors.income)),
            ),
            Text('${fmtPct(d.pct)} of ${fmtIn(d.original, d.currency, symbol)}',
                style: t.bodyMedium?.copyWith(color: AppColors.muted)),
          ]),
        ]),
      ),
    );
  }
}
