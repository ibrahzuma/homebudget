import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import 'transaction_form.dart';
import 'transaction_tile.dart';
import 'txn_events.dart';

/// Every field of one transaction, with edit and delete.
class TransactionDetailScreen extends StatefulWidget {
  const TransactionDetailScreen({super.key, required this.id});
  final int id;

  @override
  State<TransactionDetailScreen> createState() => _TransactionDetailScreenState();
}

class _TransactionDetailScreenState extends State<TransactionDetailScreen> {
  final _loader = GlobalKey<LoadBuilderState<Txn>>();
  Txn? _txn;

  Future<Txn> _load() async {
    final api = context.read<Session>().api;
    final t = Txn.fromJson(await api.get('transactions/${widget.id}/') as Map<String, dynamic>);
    if (mounted) setState(() => _txn = t);
    return t;
  }

  Future<void> _edit() async {
    final t = _txn;
    if (t == null) return;
    if (await openTransactionForm(context, existing: t)) {
      await _loader.currentState?.reload();
    }
  }

  Future<void> _delete() async {
    final t = _txn;
    if (t == null) return;
    final ok = await confirm(context,
        title: 'Delete transaction?',
        message: '${t.title} · ${fmtIn(t.amount, t.currency, context.read<Session>().currencySymbol)}'
            ' on ${fmtDate(t.date)} will be removed permanently.');
    if (!ok || !mounted) return;
    final api = context.read<Session>().api;
    final done = await runAction(context, () => api.delete('transactions/${t.id}/'),
        success: 'Transaction deleted');
    if (done) {
      notifyTransactionsChanged();
      if (mounted) Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Transaction'),
        actions: [
          IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: _txn == null ? null : _edit),
          IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: _txn == null ? null : _delete),
        ],
      ),
      body: LoadBuilder<Txn>(
        key: _loader,
        load: _load,
        builder: (context, t, _) => ListView(
          padding: const EdgeInsets.only(top: 8, bottom: 32),
          children: [
            _Header(txn: t),
            _Details(txn: t),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.txn});
  final Txn txn;

  @override
  Widget build(BuildContext context) {
    final cat = txn.category;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        child: Column(children: [
          IconBadge(
            icon: cat?.icon,
            iconData: cat == null ? Icons.receipt_long_outlined : null,
            color: cat?.color,
            size: 56,
          ),
          const SizedBox(height: 12),
          Text(txn.title,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
          TxnAmount(txn: txn, large: true),
          const SizedBox(height: 8),
          StatusChip(txn.isIncome ? 'Income' : 'Expense',
              color: txn.isIncome ? AppColors.income : AppColors.expense),
        ]),
      ),
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.txn});
  final Txn txn;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final sym = session.currencySymbol;
    final source = session.meta?.label('transaction_source', txn.source) ?? humanize(txn.source);
    final rows = <(IconData, String, String)>[
      (Icons.event_outlined, 'Date', fmtDate(txn.date)),
      (Icons.sell_outlined, 'Category', txn.category?.name ?? 'Uncategorized'),
      (Icons.storefront_outlined, 'Payee', txn.payee.isEmpty ? '—' : txn.payee),
      (Icons.notes_outlined, 'Description', txn.description.isEmpty ? '—' : txn.description),
      (Icons.payments_outlined, 'Amount', fmtIn(txn.amount, txn.currency, sym)),
      (Icons.currency_exchange, 'Currency',
          txn.currency == null ? session.currencyCode : '${txn.currency!.code} · ${txn.currency!.name}'),
      (Icons.account_balance_wallet_outlined, 'In ${session.currencyCode}',
          txn.amountBase == null ? 'No exchange rate' : fmtMoney(txn.amountBase, symbol: sym)),
      (Icons.bookmark_outline, 'Project', txn.project?.name ?? '—'),
      (Icons.input_outlined, 'Source', source),
      (Icons.person_outline, 'Added by', txn.user.username),
    ];
    return Card(
      child: Column(children: [
        for (final (icon, label, value) in rows)
          ListTile(
            dense: true,
            leading: Icon(icon, color: AppColors.muted),
            title: Text(label, style: const TextStyle(color: AppColors.muted)),
            trailing: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.55),
              child: Text(value,
                  textAlign: TextAlign.end,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            ),
          ),
      ]),
    );
  }
}
