import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';

/// One transaction row: category icon, title, who/what, signed amount.
class TransactionTile extends StatelessWidget {
  const TransactionTile({super.key, required this.txn, this.onTap, this.showDate = false});

  final Txn txn;
  final VoidCallback? onTap;
  final bool showDate;

  @override
  Widget build(BuildContext context) {
    final cat = txn.category;
    final subtitle = [
      cat?.name ?? 'Uncategorized',
      txn.user.username,
      if (showDate) fmtDateShort(txn.date),
      if (txn.project != null) txn.project!.name,
    ].join(' · ');

    return ListTile(
      onTap: onTap,
      leading: cat == null
          ? IconBadge(
              iconData: txn.isIncome ? Icons.south_west : Icons.north_east,
              color: '#6c757d',
            )
          : IconBadge(icon: cat.icon, color: cat.color),
      title: Text(txn.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: TxnAmount(txn: txn),
    );
  }
}

/// Signed amount in the transaction's own currency, with the base-currency
/// equivalent underneath when they differ.
class TxnAmount extends StatelessWidget {
  const TxnAmount({super.key, required this.txn, this.large = false});
  final Txn txn;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final sym = session.currencySymbol;
    final t = Theme.of(context).textTheme;
    final color = txn.isIncome ? AppColors.income : AppColors.expense;
    final foreign = txn.currency != null &&
        txn.currency!.code != session.currencyCode &&
        txn.amountBase != null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: large ? CrossAxisAlignment.center : CrossAxisAlignment.end,
      children: [
        Text(
          fmtIn(txn.isIncome ? txn.amount : -txn.amount, txn.currency, sym, signed: true),
          style: (large ? t.headlineMedium : t.titleSmall)
              ?.copyWith(color: color, fontWeight: FontWeight.w700),
        ),
        if (foreign)
          Text('≈ ${fmtMoney(txn.amountBase, symbol: sym)}',
              style: t.bodySmall?.copyWith(color: AppColors.muted)),
      ],
    );
  }
}
