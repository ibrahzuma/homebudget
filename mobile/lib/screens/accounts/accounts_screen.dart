import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../../widgets/entity_form.dart';
import '../networth/finance_shared.dart';

/// A Material icon for an account, chosen by mobile-money network or type.
IconData accountIcon(Account a) {
  switch (a.provider) {
    case 'vodacom':
    case 'yas':
    case 'halotel':
    case 'airtel':
    case 'azampesa':
      return Icons.smartphone_outlined;
  }
  return switch (a.accountType) {
    'bank' => Icons.account_balance_outlined,
    'cash' => Icons.payments_outlined,
    _ => Icons.account_balance_wallet_outlined,
  };
}

/// Bank accounts and mobile-money wallets, each with its live balance.
class AccountsScreen extends StatefulWidget {
  const AccountsScreen({super.key});

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  final _loader = GlobalKey<LoadBuilderState<AccountsOverview>>();

  Session get _session => context.read<Session>();

  Future<AccountsOverview> _load() async =>
      AccountsOverview.fromJson(await _session.api.get('accounts/') as Map<String, dynamic>);

  Future<void> _reload() async {
    // Keep the transaction-form account picker in step with any change here.
    await _session.refreshMeta();
    await _loader.currentState?.reload();
  }

  Future<void> _add() async {
    if (await openAccountForm(context)) _reload();
  }

  Future<void> _open(Account a) async {
    await push(context, AccountDetailScreen(account: a));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final symbol = context.watch<Session>().currencySymbol;
    final code = context.watch<Session>().currencyCode;
    return Scaffold(
      appBar: AppBar(title: const Text('Accounts')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('Add account'),
      ),
      body: LoadBuilder<AccountsOverview>(
        key: _loader,
        load: _load,
        builder: (context, data, reload) {
          if (data.accounts.isEmpty) {
            return EmptyState(
              icon: Icons.account_balance_wallet_outlined,
              title: 'No accounts yet',
              message: 'Add your bank accounts and mobile-money wallets '
                  '(M-Pesa, Mixx by Yas, Halopesa…) to see how much each one holds.',
              action: FilledButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.add),
                label: const Text('Add your first account'),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.only(top: 12, bottom: 96),
            children: [
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Total across accounts',
                        style: Theme.of(context)
                            .textTheme
                            .labelLarge
                            ?.copyWith(color: AppColors.muted)),
                    const SizedBox(height: 4),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(fmtMoney(data.totalBase, symbol: symbol),
                          style: Theme.of(context)
                              .textTheme
                              .headlineMedium
                              ?.copyWith(fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(height: 2),
                    Text('In $code, converting other currencies at your saved rates.',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: AppColors.muted)),
                    if (data.byType.isNotEmpty) ...[
                      const Divider(height: 20),
                      for (final e in data.byType.entries)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(e.key),
                              Text(fmtMoney(e.value, symbol: symbol),
                                  style: const TextStyle(fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                    ],
                  ]),
                ),
              ),
              const SectionHeader('Your accounts'),
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(children: [
                  for (final a in data.accounts) AccountTile(account: a, symbol: symbol, onTap: () => _open(a)),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Text(
                  'A balance is the opening balance plus income, minus expenses, '
                  'for every transaction tagged to the account.',
                  style:
                      Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.muted),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class AccountTile extends StatelessWidget {
  const AccountTile({super.key, required this.account, required this.symbol, required this.onTap});
  final Account account;
  final String symbol;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final a = account;
    final sub = [
      a.accountTypeDisplay,
      if (a.providerDisplay.isNotEmpty) a.providerDisplay,
      if (!a.isActive) 'Inactive',
    ].join(' · ');
    return ListTile(
      onTap: onTap,
      leading: IconBadge(iconData: accountIcon(a), color: a.color, size: 40),
      title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(
        fmtIn(a.balance, a.currency, symbol),
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: a.balance < 0 ? AppColors.expense : null,
        ),
      ),
    );
  }
}

/// One account: balance, details, edit and delete.
class AccountDetailScreen extends StatefulWidget {
  const AccountDetailScreen({super.key, required this.account});
  final Account account;

  @override
  State<AccountDetailScreen> createState() => _AccountDetailScreenState();
}

class _AccountDetailScreenState extends State<AccountDetailScreen> {
  final _loader = GlobalKey<LoadBuilderState<Account>>();
  late Account _account = widget.account;

  Session get _session => context.read<Session>();
  String get _path => 'accounts/${widget.account.id}/';

  Future<Account> _load() async {
    final a = Account.fromJson(await _session.api.get(_path) as Map<String, dynamic>);
    if (mounted) setState(() => _account = a);
    return a;
  }

  Future<void> _edit() async {
    if (await openAccountForm(context, existing: _account)) {
      await _session.refreshMeta();
      _loader.currentState?.reload();
    }
  }

  Future<void> _delete() async {
    final ok = await confirmDelete(
      context,
      title: 'Delete "${_account.name}"?',
      message: 'Its transactions are kept but will no longer be attributed to an account.',
      action: () => _session.api.delete(_path),
      success: 'Account deleted',
    );
    if (ok) {
      await _session.refreshMeta();
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final symbol = context.watch<Session>().currencySymbol;
    return Scaffold(
      appBar: AppBar(
        title: Text(_account.name),
        actions: [EditDeleteMenu(onEdit: _edit, onDelete: _delete)],
      ),
      body: LoadBuilder<Account>(
        key: _loader,
        load: _load,
        builder: (context, a, reload) => ListView(
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  IconBadge(iconData: accountIcon(a), color: a.color, size: 52),
                  const SizedBox(width: 16),
                  Expanded(
                    child: HeadlineAmount(
                      caption: 'Balance',
                      amount: fmtIn(a.balance, a.currency, symbol),
                      color: a.balance < 0 ? AppColors.expense : AppColors.income,
                    ),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            InfoCard(rows: [
              ('Type', a.accountTypeDisplay),
              ('Provider', a.providerDisplay),
              ('Number', a.accountNumber),
              ('Currency', a.currency?.code ?? ''),
              ('Opening balance', fmtIn(a.openingBalance, a.currency, symbol)),
              ('Status', a.isActive ? 'Active' : 'Inactive'),
              ('Notes', a.notes),
            ]),
          ],
        ),
      ),
    );
  }
}

/// Create ([existing] null) or edit an account. Resolves true when saved.
Future<bool> openAccountForm(BuildContext context, {Account? existing}) {
  return openMetaForm(context, (meta, session) {
    final r = existing?.raw;
    return EntityFormScreen(
      title: existing == null ? 'Add account' : 'Edit account',
      initial: r == null
          ? {
              'account_type': 'mobile_money',
              'currency': session.household?.baseCurrency?.id,
              'opening_balance': '0',
              'is_active': true,
            }
          : {
              'name': r['name'],
              'account_type': r['account_type'],
              'provider': r['provider'],
              'account_number': r['account_number'],
              'currency': existing!.currency?.id,
              'opening_balance': r['opening_balance'],
              'is_active': r['is_active'],
              'notes': r['notes'],
            },
      fields: [
        const FieldSpec.text('name', 'Name', required: true, hint: 'e.g. My M-Pesa, CRDB Salary'),
        FieldSpec.select('account_type', 'Type',
            options: choiceOptions(meta, 'account_type'), required: true),
        FieldSpec.select('provider', 'Provider',
            options: choiceOptions(meta, 'account_provider'),
            help: 'Network or bank, if it helps you tell accounts apart'),
        const FieldSpec.text('account_number', 'Number',
            hint: 'Phone or account number (optional)'),
        FieldSpec.select('currency', 'Currency', options: currencyOptions(meta)),
        const FieldSpec.money('opening_balance', 'Opening balance',
            help: 'Balance before you started recording transactions here. '
                'Income and expenses tagged to this account adjust it automatically.'),
        const FieldSpec.toggle('is_active', 'Active'),
        const FieldSpec.multiline('notes', 'Notes'),
      ],
      onSubmit: (v) => existing == null
          ? session.api.post('accounts/', v)
          : session.api.patch('accounts/${existing.id}/', v),
    );
  });
}
