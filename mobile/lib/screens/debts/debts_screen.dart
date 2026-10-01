import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../../widgets/entity_form.dart';
import '../networth/finance_shared.dart';
import 'debt_detail_screen.dart';

class _DebtList {
  _DebtList.fromJson(Map<String, dynamic> j)
      : items = (j['results'] as List)
            .map((e) => Liability.fromJson(e as Map<String, dynamic>))
            .toList(),
        totalBalance = money(j['total_balance']),
        totalPaid = money(j['total_paid']);
  final List<Liability> items;
  final double totalBalance;
  final double totalPaid;
}

/// Liabilities: loans, mortgages, credit cards and what's been paid on them.
class DebtsScreen extends StatefulWidget {
  const DebtsScreen({super.key});

  @override
  State<DebtsScreen> createState() => _DebtsScreenState();
}

class _DebtsScreenState extends State<DebtsScreen> {
  final _loader = GlobalKey<LoadBuilderState<_DebtList>>();

  Future<_DebtList> _load() async => _DebtList.fromJson(
      await context.read<Session>().api.get('debts/') as Map<String, dynamic>);

  Future<void> _reload() async => _loader.currentState?.reload();

  Future<void> _add() async {
    if (await openDebtForm(context)) _reload();
  }

  Future<void> _open(Liability l) async {
    await push(context, DebtDetailScreen(id: l.id));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final symbol = context.watch<Session>().currencySymbol;
    return Scaffold(
      appBar: AppBar(title: const Text('Debts')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('Add debt'),
      ),
      body: LoadBuilder<_DebtList>(
        key: _loader,
        load: _load,
        builder: (context, data, reload) {
          if (data.items.isEmpty) {
            return EmptyState(
              icon: Icons.credit_card_off_outlined,
              title: 'No debts recorded',
              message: 'Track loans, mortgages and credit cards, and log payments as you make them.',
              action: FilledButton.icon(
                  onPressed: _add, icon: const Icon(Icons.add), label: const Text('Add debt')),
            );
          }
          return ListView(
            padding: const EdgeInsets.only(top: 12, bottom: 96),
            children: [
              StatRow(children: [
                StatTile(
                    label: 'Outstanding',
                    value: fmtMoney(data.totalBalance, symbol: symbol),
                    color: AppColors.expense,
                    icon: Icons.account_balance_outlined),
                StatTile(
                    label: 'Paid so far',
                    value: fmtMoney(data.totalPaid, symbol: symbol),
                    color: AppColors.income,
                    icon: Icons.check_circle_outline),
              ]),
              SectionHeader('${data.items.length} debt${data.items.length == 1 ? '' : 's'}'),
              for (final l in data.items)
                _DebtCard(debt: l, symbol: symbol, onTap: () => _open(l)),
            ],
          );
        },
      ),
    );
  }
}

class _DebtCard extends StatelessWidget {
  const _DebtCard({required this.debt, required this.symbol, required this.onTap});
  final Liability debt;
  final String symbol;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final l = debt;
    final sub = [
      l.liabilityTypeDisplay,
      if (l.lender.isNotEmpty) l.lender,
      if (l.interestRate != null && l.interestRate! > 0) '${l.interestRate}% APR',
    ].join(' · ');
    final cleared = l.balance <= 0;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              IconBadge(iconData: liabilityIcon(l.liabilityType), color: '#dc3545', size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l.name, style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                  Text(sub, style: t.bodySmall?.copyWith(color: AppColors.muted)),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(fmtIn(l.balance, l.currency, symbol),
                    style: t.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: cleared ? AppColors.income : AppColors.expense)),
                if (cleared) const StatusChip('Paid off', color: AppColors.income),
              ]),
            ]),
            const SizedBox(height: 12),
            ProgressLine(percent: l.pct, color: AppColors.income),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                child: Text(
                  'Paid ${fmtIn(l.paid, l.currency, symbol)} of ${fmtIn(l.original, l.currency, symbol)}',
                  style: t.bodySmall?.copyWith(color: AppColors.muted),
                ),
              ),
              Text(fmtPct(l.pct), style: t.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
            ]),
            if (l.dueDate != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Due ${fmtDate(l.dueDate)}',
                    style: t.bodySmall?.copyWith(color: AppColors.muted)),
              ),
          ]),
        ),
      ),
    );
  }
}

IconData liabilityIcon(String type) => switch (type) {
      'mortgage' => Icons.home_work_outlined,
      'credit_card' => Icons.credit_card,
      'loan' => Icons.account_balance_outlined,
      _ => Icons.receipt_long_outlined,
    };

/// Create ([existing] null) or edit a liability. Resolves true when saved.
Future<bool> openDebtForm(BuildContext context, {Liability? existing}) {
  return openMetaForm(context, (meta, session) {
    final r = existing?.raw;
    return EntityFormScreen(
      title: existing == null ? 'Add debt' : 'Edit debt',
      initial: r == null
          ? {'liability_type': 'loan', 'currency': session.household?.baseCurrency?.id}
          : {
              'name': r['name'],
              'liability_type': r['liability_type'],
              'lender': r['lender'],
              'balance': r['balance'],
              'original_amount': r['original_amount'],
              'currency': existing!.currency?.id,
              'interest_rate': r['interest_rate'],
              'start_date': r['start_date'],
              'due_date': r['due_date'],
              'notes': r['notes'],
            },
      fields: [
        const FieldSpec.text('name', 'Name', required: true, hint: 'e.g. Car loan'),
        FieldSpec.select('liability_type', 'Type',
            options: choiceOptions(meta, 'liability_type'), required: true),
        const FieldSpec.text('lender', 'Lender', hint: 'Bank, person, or institution'),
        const FieldSpec.money('balance', 'Current balance', required: true,
            help: 'What you still owe today.'),
        const FieldSpec.money('original_amount', 'Original amount',
            help: 'Optional. Used to show how much has been paid off.'),
        FieldSpec.select('currency', 'Currency', options: currencyOptions(meta)),
        const FieldSpec.money('interest_rate', 'Interest rate (% APR)'),
        const FieldSpec.date('start_date', 'Start date'),
        const FieldSpec.date('due_date', 'Due date'),
        const FieldSpec.multiline('notes', 'Notes'),
      ],
      onSubmit: (v) => existing == null
          ? session.api.post('debts/', v)
          : session.api.patch('debts/${existing.id}/', v),
    );
  });
}
