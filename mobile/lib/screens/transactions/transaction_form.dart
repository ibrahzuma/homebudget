import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../../widgets/entity_form.dart';
import 'txn_events.dart';

/// Picker data, fetching it first if the session hasn't loaded it yet.
Future<Meta> ensureMeta(Session session) async {
  if (session.meta == null) await session.refreshMeta();
  return session.meta!;
}

/// Loads [Meta] for a form, reporting failures as a snackbar. Null when it
/// couldn't be loaded or the context went away.
Future<Meta?> metaForForm(BuildContext context) async {
  final session = context.read<Session>();
  try {
    final meta = await ensureMeta(session);
    return context.mounted ? meta : null;
  } catch (e) {
    if (context.mounted) showError(context, e);
    return null;
  }
}

List<Option> typeOptions(Meta meta) {
  final choices = meta.choicesFor('transaction_type');
  if (choices.isEmpty) {
    return const [Option('expense', 'Expense'), Option('income', 'Income')];
  }
  return [for (final c in choices) Option(c.value, c.label)];
}

/// Create (no [existing]) or edit a transaction. Resolves true when saved.
Future<bool> openTransactionForm(BuildContext context,
    {Txn? existing, String type = 'expense'}) async {
  final meta = await metaForForm(context);
  if (meta == null || !context.mounted) return false;
  final session = context.read<Session>();

  // A completed project isn't in the picker, but an existing link must survive an edit.
  final projects = [
    for (final p in meta.projects) Option(p.id, p.name),
    if (existing?.project != null && !meta.projects.any((p) => p.id == existing!.project!.id))
      Option(existing!.project!.id, existing.project!.name),
  ];
  final initialType = existing?.type ?? type;

  final form = EntityFormScreen(
    title: existing != null
        ? 'Edit transaction'
        : (initialType == 'income' ? 'New income' : 'New expense'),
    initial: {
      'transaction_type': initialType,
      'category': existing?.category?.id,
      'amount': existing?.amountRaw,
      'currency': existing?.currency?.id ?? session.household?.baseCurrency?.id,
      'payee': existing?.payee,
      'description': existing?.description,
      'date': existing?.date ?? DateTime.now(),
      'project': existing?.project?.id,
    },
    fields: [
      FieldSpec.select('transaction_type', 'Type', options: typeOptions(meta), required: true),
      FieldSpec.select(
        'category',
        'Category',
        help: 'Leave empty to let your auto-categorize rules pick one.',
        optionsBuilder: (v) => [
          for (final c in meta.categoriesOfType(v['transaction_type'] as String? ?? initialType))
            Option(c.id, c.name),
        ],
      ),
      const FieldSpec.money('amount', 'Amount', required: true),
      FieldSpec.select('currency', 'Currency', required: true, options: [
        for (final c in meta.currencies) Option(c.id, '${c.code} · ${c.name}'),
      ]),
      const FieldSpec.text('payee', 'Payee', hint: 'e.g. TotalEnergies, Shoprite'),
      const FieldSpec.text('description', 'Description', hint: 'Optional notes'),
      const FieldSpec.date('date', 'Date', required: true),
      if (projects.isNotEmpty) FieldSpec.select('project', 'Project', options: projects),
    ],
    onSubmit: (values) async {
      if (existing == null) {
        await session.api.post('transactions/', values);
      } else {
        await session.api.patch('transactions/${existing.id}/', values);
      }
    },
  );

  final saved = await openForm(context, form);
  if (saved) {
    notifyTransactionsChanged();
    session.refreshBadges(); // a new expense can trigger budget alerts
  }
  return saved;
}
