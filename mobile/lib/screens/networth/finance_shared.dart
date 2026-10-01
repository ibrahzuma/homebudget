// Small helpers shared by the net worth, debts, lent, goals, projects,
// recurring and report screens.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../../widgets/entity_form.dart';

/// The form pickers, fetching them first if the session hasn't yet.
Future<Meta> ensureMeta(Session session) async {
  if (session.meta == null) await session.refreshMeta();
  return session.meta!;
}

List<Option> currencyOptions(Meta meta) =>
    [for (final c in meta.currencies) Option(c.id, '${c.code} · ${c.name}')];

List<Option> choiceOptions(Meta meta, String key) =>
    [for (final c in meta.choicesFor(key)) Option(c.value, c.label)];

List<Option> categoryOptions(Meta meta, String? type) => [
      for (final c in meta.categories)
        if (type == null || c.type == type) Option(c.id, c.name),
    ];

/// Builds a form once the pickers are available and pushes it.
/// Resolves true when the form saved.
Future<bool> openMetaForm(
  BuildContext context,
  EntityFormScreen Function(Meta meta, Session session) build,
) async {
  final session = context.read<Session>();
  final Meta meta;
  try {
    meta = await ensureMeta(session);
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
  if (!context.mounted) return false;
  return openForm(context, build(meta, session));
}

/// Confirms, deletes via [action] and reports. Returns whether it deleted.
Future<bool> confirmDelete(
  BuildContext context, {
  required String title,
  String? message,
  required Future<void> Function() action,
  String? success,
}) async {
  if (!await confirm(context, title: title, message: message)) return false;
  if (!context.mounted) return false;
  return runAction(context, action, success: success);
}

/// Edit / delete overflow menu for detail app bars.
class EditDeleteMenu extends StatelessWidget {
  const EditDeleteMenu({super.key, required this.onEdit, required this.onDelete});
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
      itemBuilder: (_) => const [
        PopupMenuItem(
            value: 'edit',
            child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Edit'))),
        PopupMenuItem(
            value: 'delete',
            child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Delete'))),
      ],
    );
  }
}

/// Label / value line inside an info card.
class InfoRow extends StatelessWidget {
  const InfoRow(this.label, this.value, {super.key, this.valueColor});
  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 120,
          child: Text(label, style: t.bodyMedium?.copyWith(color: AppColors.muted)),
        ),
        Expanded(
          child: Text(value,
              textAlign: TextAlign.end,
              style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w500, color: valueColor)),
        ),
      ]),
    );
  }
}

/// A card of [InfoRow]s, skipping rows whose value is empty.
class InfoCard extends StatelessWidget {
  const InfoCard({super.key, required this.rows});
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final visible = rows.where((r) => r.$2.isNotEmpty && r.$2 != '—').toList();
    if (visible.isEmpty) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(children: [for (final r in visible) InfoRow(r.$1, r.$2)]),
      ),
    );
  }
}

/// Big number with a caption, for the top of detail screens.
class HeadlineAmount extends StatelessWidget {
  const HeadlineAmount({super.key, required this.caption, required this.amount, this.color});
  final String caption;
  final String amount;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(caption, style: t.labelLarge?.copyWith(color: AppColors.muted)),
      const SizedBox(height: 4),
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(amount,
            style: t.headlineMedium?.copyWith(fontWeight: FontWeight.w700, color: color)),
      ),
    ]);
  }
}

/// One payment / repayment row with a delete button.
class PaymentTile extends StatelessWidget {
  const PaymentTile({
    super.key,
    required this.payment,
    required this.symbol,
    required this.linkedLabel,
    required this.onDelete,
  });
  final Payment payment;
  final String symbol;

  /// e.g. "Recorded as expense"; shown when the payment has a transaction.
  final String linkedLabel;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final p = payment;
    final sub = [
      if (p.transactionId != null) linkedLabel,
      if (p.notes.isNotEmpty) p.notes,
    ].join(' · ');
    return ListTile(
      leading: const CircleAvatar(child: Icon(Icons.receipt_long_outlined, size: 20)),
      title: Text(fmtIn(p.amount, p.currency, symbol),
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(sub.isEmpty ? fmtDate(p.date) : '${fmtDate(p.date)}\n$sub'),
      isThreeLine: sub.isNotEmpty,
      trailing: IconButton(
        tooltip: 'Delete',
        icon: const Icon(Icons.delete_outline),
        onPressed: onDelete,
      ),
    );
  }
}

/// Transaction row used on project detail and the monthly report.
class TxnTile extends StatelessWidget {
  const TxnTile({super.key, required this.txn, required this.symbol, this.showUser = true});
  final Txn txn;
  final String symbol;
  final bool showUser;

  @override
  Widget build(BuildContext context) {
    final t = txn;
    final color = t.isIncome ? AppColors.income : AppColors.expense;
    final sub = [
      fmtDateShort(t.date),
      if (t.category != null) t.category!.name,
      if (showUser) t.user.username,
    ].join(' · ');
    return ListTile(
      leading: t.category == null
          ? IconBadge(iconData: Icons.sell_outlined, color: '#6c757d', size: 36)
          : IconBadge(icon: t.category!.icon, color: t.category!.color, size: 36),
      title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(
        fmtIn(t.isIncome ? t.amount : -t.amount, t.currency, symbol, signed: true),
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Small coloured legend dot + label for charts.
class LegendDot extends StatelessWidget {
  const LegendDot({super.key, required this.color, required this.label, this.dashed = false});
  final Color color;
  final String label;
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: dashed ? 14 : 10,
        height: dashed ? 3 : 10,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(dashed ? 2 : 5),
        ),
      ),
      const SizedBox(width: 6),
      Text(label, style: Theme.of(context).textTheme.labelMedium),
    ]);
  }
}
