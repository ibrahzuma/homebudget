import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../../widgets/entity_form.dart';
import '../networth/finance_shared.dart';

/// The forms behind a vikoba or mchezo: the group itself, paying in, collecting,
/// borrowing, and the rotation. Every one posts to an endpoint that does the
/// bookkeeping server-side (`budget_app/services.py`), so the app only collects
/// input — see `docs/mobile-api.md`.

const _frequencies = [
  Option('daily', 'Daily'),
  Option('weekly', 'Weekly'),
  Option('biweekly', 'Every two weeks'),
  Option('monthly', 'Monthly'),
  Option('quarterly', 'Quarterly'),
  Option('yearly', 'Yearly'),
];

const _types = [
  Option('vikoba', 'Vikoba — savings you can borrow against'),
  Option('mchezo', 'Mchezo — rotating pot, one member each time'),
];

/// Create or edit a group. Resolves true when saved.
Future<bool> openGroupForm(BuildContext context, {ContributionGroup? existing}) async {
  final session = context.read<Session>();
  final Meta meta;
  try {
    meta = await ensureMeta(session);
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
  if (!context.mounted) return false;

  final currencies = [
    for (final c in meta.currencies) Option(c.id, '${c.code} (${c.symbol})'),
  ];
  return openForm(
    context,
    EntityFormScreen(
      title: existing == null ? 'New group' : 'Edit ${existing.name}',
      submitLabel: 'Save',
      intro: const Text(
        'A vikoba builds up savings you can borrow against. A mchezo collects '
        'from everyone on an agreed date and hands the whole pot to one member, '
        'turn by turn.',
        style: TextStyle(color: AppColors.muted),
      ),
      initial: existing?.raw ??
          {
            'group_type': 'mchezo',
            'frequency': 'monthly',
            'start_date': DateTime.now(),
            'is_active': true,
          },
      fields: [
        const FieldSpec.text('name', 'Name', required: true, hint: 'e.g. Mama Lishe Vikoba'),
        const FieldSpec.select('group_type', 'Kind of group',
            options: _types, required: true),
        const FieldSpec.money('contribution_amount', 'What you pay in each time',
            required: true),
        FieldSpec.select('currency', 'Currency', options: currencies),
        const FieldSpec.select('frequency', 'How often', options: _frequencies, required: true),
        const FieldSpec.date('start_date', 'Started', required: true),
        const FieldSpec.date('next_due_date', 'Next collection date',
            help: 'Leave empty if you do not want reminders.'),
        const FieldSpec.toggle('is_active', 'Still running'),
        const FieldSpec.multiline('notes', 'Notes'),
      ],
      onSubmit: (values) async {
        if (existing == null) {
          await session.api.post('groups/', values);
        } else {
          await session.api.patch('groups/${existing.id}/', values);
        }
      },
    ),
  );
}

/// Pay into the group. Leaving the approver empty records it immediately;
/// choosing a partner sends it for approval and records nothing until they say
/// yes. Returns the refreshed group when saved.
Future<ContributionGroup?> openContributionForm(
    BuildContext context, ContributionGroup group) async {
  final session = context.read<Session>();
  final me = session.user?.id;
  final partners = [
    for (final m in session.household?.members ?? const <UserBrief>[])
      if (m.id != me) Option(m.id, m.username),
  ];
  ContributionGroup? updated;
  final saved = await openForm(
    context,
    EntityFormScreen(
      title: 'Contribute to ${group.name}',
      submitLabel: 'Save contribution',
      intro: Text(
        partners.isEmpty
            ? 'Recorded as a household expense.'
            : 'Leave the approver empty to record it now, or pick your partner to '
                'send it for approval first — the expense is recorded when they approve.',
        style: const TextStyle(color: AppColors.muted),
      ),
      initial: {
        'amount': group.contributionAmount,
        'date': group.nextDueDate ?? DateTime.now(),
      },
      fields: [
        const FieldSpec.money('amount', 'Amount', required: true),
        const FieldSpec.date('date', 'Date', required: true),
        if (partners.isNotEmpty)
          FieldSpec.select('approver', 'Ask for approval from', options: partners),
        const FieldSpec.multiline('notes', 'Notes'),
      ],
      onSubmit: (values) async {
        final res = await session.api.post('groups/${group.id}/contribute/', values);
        updated = ContributionGroup.fromJson(res as Map<String, dynamic>);
      },
    ),
  );
  return saved ? updated : null;
}

/// Record money collected from the group. Comes in as income.
Future<ContributionGroup?> openPayoutForm(
    BuildContext context, ContributionGroup group) async {
  final session = context.read<Session>();
  final mine = group.myMember;
  final slots = [
    for (final m in group.members)
      Option(m.id,
          '${m.turnOrder}. ${m.name}${m.isMine ? ' (you)' : ''}'
          '${m.turnDate == null ? '' : ' — ${fmtDateShort(m.turnDate)}'}'),
  ];
  ContributionGroup? updated;
  final saved = await openForm(
    context,
    EntityFormScreen(
      title: 'Received from ${group.name}',
      submitLabel: 'Save payout',
      intro: Text(
        group.isMchezo
            ? 'Your turn to collect the pot. Recorded as household income.'
            : 'A share-out from the group. Recorded as household income.',
        style: const TextStyle(color: AppColors.muted),
      ),
      initial: {
        'amount': group.expectedPayout ?? group.contributionAmount,
        'date': mine?.turnDate ?? DateTime.now(),
        if (mine != null) 'member': mine.id,
        'record_as_income': true,
      },
      fields: [
        const FieldSpec.money('amount', 'Amount received', required: true),
        const FieldSpec.date('date', 'Date', required: true),
        if (group.isMchezo && slots.isNotEmpty)
          FieldSpec.select('member', 'Which turn this settles', options: slots),
        const FieldSpec.toggle('record_as_income', 'Record as household income'),
        const FieldSpec.multiline('notes', 'Notes'),
      ],
      onSubmit: (values) async {
        final res = await session.api.post('groups/${group.id}/payouts/', values);
        updated = ContributionGroup.fromJson(res as Map<String, dynamic>);
      },
    ),
  );
  return saved ? updated : null;
}

/// Record a loan taken from a vikoba. Saved as a debt, so it also turns up
/// under Debts with the usual repayment screens.
Future<ContributionGroup?> openGroupLoanForm(
    BuildContext context, ContributionGroup group) async {
  final session = context.read<Session>();
  final Meta meta;
  try {
    meta = await ensureMeta(session);
  } catch (e) {
    if (context.mounted) showError(context, e);
    return null;
  }
  if (!context.mounted) return null;
  final currencies = [
    for (final c in meta.currencies) Option(c.id, '${c.code} (${c.symbol})'),
  ];

  ContributionGroup? updated;
  final saved = await openForm(
    context,
    EntityFormScreen(
      title: 'Loan from ${group.name}',
      submitLabel: 'Save loan',
      intro: const Text(
        'Saved as a debt, so it also appears under Debts where you record '
        'repayments.',
        style: TextStyle(color: AppColors.muted),
      ),
      initial: {
        'name': 'Loan from ${group.name}',
        'start_date': DateTime.now(),
        if (group.currency != null) 'currency': group.currency!.id,
        'record_as_income': false,
      },
      fields: [
        const FieldSpec.text('name', 'What the loan is for', required: true),
        const FieldSpec.money('balance', 'Amount still owed', required: true),
        const FieldSpec.money('original_amount', 'Amount borrowed'),
        FieldSpec.select('currency', 'Currency', options: currencies),
        const FieldSpec.money('interest_rate', 'Interest rate (annual %)'),
        const FieldSpec.date('start_date', 'Taken on'),
        const FieldSpec.date('due_date', 'Final repayment due'),
        const FieldSpec.toggle('record_as_income', 'Also record the cash as income',
            help: 'Usually left off — borrowing is not really income, and the '
                'debt itself is what gets tracked.'),
        const FieldSpec.multiline('notes', 'Notes'),
      ],
      onSubmit: (values) async {
        final res = await session.api.post('groups/${group.id}/loans/', values);
        updated = ContributionGroup.fromJson(res as Map<String, dynamic>);
      },
    ),
  );
  return saved ? updated : null;
}

/// Add or edit one slot in the rotation.
Future<ContributionGroup?> openMemberForm(
    BuildContext context, ContributionGroup group, {GroupMember? existing}) async {
  final session = context.read<Session>();
  ContributionGroup? updated;
  final saved = await openForm(
    context,
    EntityFormScreen(
      title: existing == null ? 'Add member' : 'Edit ${existing.name}',
      submitLabel: 'Save member',
      intro: const Text(
        'Turn 1 collects first. Mark your own slot so the app can tell you when '
        'your turn comes round.',
        style: TextStyle(color: AppColors.muted),
      ),
      initial: existing == null
          ? {'turn_order': group.memberCount + 1, 'is_mine': false}
          : {
              'name': existing.name,
              'turn_order': existing.turnOrder,
              'turn_date': existing.turnDate,
              'is_mine': existing.isMine,
              'phone': existing.phone,
              'notes': existing.notes,
            },
      fields: const [
        FieldSpec.text('name', 'Name', required: true),
        FieldSpec.integer('turn_order', 'Turn', required: true,
            help: '1 collects first.'),
        FieldSpec.date('turn_date', 'Collects on'),
        FieldSpec.toggle('is_mine', "This is our household's turn"),
        FieldSpec.text('phone', 'Phone', keyboard: TextInputType.phone),
        FieldSpec.multiline('notes', 'Notes'),
      ],
      onSubmit: (values) async {
        final res = existing == null
            ? await session.api.post('groups/${group.id}/members/', values)
            : await session.api
                .patch('groups/${group.id}/members/${existing.id}/', values);
        updated = ContributionGroup.fromJson(res as Map<String, dynamic>);
      },
    ),
  );
  return saved ? updated : null;
}
