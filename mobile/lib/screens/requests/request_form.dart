import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/entity_form.dart';

/// "Request money" form. The approver list excludes the current user, and
/// categories are limited to expense ones (the server enforces both too).
EntityFormScreen requestMoneyForm(Session session, Meta meta) {
  final me = session.user?.id;
  final others = meta.members.where((m) => m.id != me).toList();
  final base = session.household?.baseCurrency;

  return EntityFormScreen(
    title: 'Request money',
    submitLabel: 'Send request',
    intro: const _RequestIntro(),
    initial: {
      if (others.length == 1) 'approver': others.first.id,
      'currency': base?.id,
    },
    fields: [
      FieldSpec.select('approver', 'Ask',
          required: true,
          options: [for (final m in others) Option(m.id, m.username)]),
      const FieldSpec.money('amount', 'Amount', required: true),
      FieldSpec.select('currency', 'Currency',
          options: [for (final c in meta.currencies) Option(c.id, '${c.code} (${c.symbol})')],
          help: 'Defaults to the household base currency.'),
      const FieldSpec.text('purpose', 'Purpose', required: true, hint: 'What is this money for?'),
      FieldSpec.select('category', 'Expense category',
          options: [
            for (final c in meta.categoriesOfType('expense')) Option(c.id, c.name),
          ],
          help: 'Used for the expense recorded when the request is approved.'),
      const FieldSpec.multiline('notes', 'Notes'),
    ],
    onSubmit: (values) async {
      await session.api.post('requests/', values);
    },
  );
}

class _RequestIntro extends StatelessWidget {
  const _RequestIntro();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        'Your partner gets notified and can approve or reject. '
        'If they approve, the amount is recorded as one expense for you.',
        style: t.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// Makes sure picker data is loaded before opening a form.
Future<Meta> ensureMeta(Session session) async {
  if (session.meta == null) await session.refreshMeta();
  return session.meta!;
}
