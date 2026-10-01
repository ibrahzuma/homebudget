import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';

/// Shown to a signed-in user with no household: create one, or join a
/// partner's with an invite code/link.
class HouseholdSetupScreen extends StatefulWidget {
  const HouseholdSetupScreen({super.key});

  @override
  State<HouseholdSetupScreen> createState() => _HouseholdSetupScreenState();
}

class _HouseholdSetupScreenState extends State<HouseholdSetupScreen> {
  final _name = TextEditingController();
  final _partner = TextEditingController();
  final _code = TextEditingController();
  List<Currency> _currencies = [];
  int? _currencyId;
  bool _busy = false;
  ApiException? _createError;
  String? _joinError;

  @override
  void initState() {
    super.initState();
    _loadCurrencies();
  }

  Future<void> _loadCurrencies() async {
    try {
      final res = await context.read<Session>().api.get('currencies/') as Map<String, dynamic>;
      final list = (res['currencies'] as List)
          .map((e) => Currency.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() {
        _currencies = list;
        _currencyId = list.where((c) => c.code == 'TZS').firstOrNull?.id ??
            list.where((c) => c.code == 'USD').firstOrNull?.id;
      });
    } catch (_) {
      // Optional: without the list the server defaults to USD.
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _partner.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _createError = ApiException(400, 'Give your household a name.', {
            'name': ['Required']
          }));
      return;
    }
    setState(() {
      _busy = true;
      _createError = null;
    });
    final session = context.read<Session>();
    try {
      final res = await session.api.post('household/', {
        'name': _name.text.trim(),
        if (_currencyId != null) 'base_currency': _currencyId,
        if (_partner.text.trim().isNotEmpty) 'partner_username': _partner.text.trim(),
      });
      final notice = (res as Map<String, dynamic>)['notice'] as String?;
      await session.householdChanged();
      if (mounted && notice != null) showOk(context, notice);
    } on ApiException catch (e) {
      setState(() => _createError = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _join() async {
    final code = _code.text.trim();
    if (code.isEmpty) {
      setState(() => _joinError = 'Paste the invite code or link.');
      return;
    }
    setState(() {
      _busy = true;
      _joinError = null;
    });
    final session = context.read<Session>();
    try {
      await session.api.post('household/join/', {'code': code});
      await session.householdChanged();
    } on ApiException catch (e) {
      setState(() => _joinError = e.errorFor('code') ?? e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final session = context.watch<Session>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Set up your household'),
        actions: [
          TextButton(onPressed: session.logout, child: const Text('Sign out')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Hi ${session.user?.username ?? ''}! Your budget is shared by everyone in a '
              'household. Create a new one, or join your partner\'s.'),
          const SizedBox(height: 16),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Join with an invite', style: t.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text('Your partner can create an invite link in Household settings.',
                    style: t.textTheme.bodySmall),
                const SizedBox(height: 12),
                TextField(
                  controller: _code,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Invite code or link',
                    errorText: _joinError,
                    prefixIcon: const Icon(Icons.link),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.tonal(
                    onPressed: _busy ? null : _join, child: const Text('Join household')),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Create a new household', style: t.textTheme.titleMedium),
                const SizedBox(height: 12),
                if (_createError != null && _createError!.errorFor('name') == null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(_createError!.message, style: TextStyle(color: t.colorScheme.error)),
                  ),
                TextField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    labelText: 'Household name',
                    hintText: 'e.g. The Mushi Family',
                    errorText: _createError?.errorFor('name'),
                  ),
                ),
                const SizedBox(height: 12),
                if (_currencies.isNotEmpty) ...[
                  DropdownButtonFormField<int>(
                    initialValue: _currencyId,
                    decoration: const InputDecoration(labelText: 'Base currency'),
                    items: [
                      for (final c in _currencies)
                        DropdownMenuItem(value: c.id, child: Text('${c.code} — ${c.name}')),
                    ],
                    onChanged: (v) => setState(() => _currencyId = v),
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: _partner,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: "Partner's username (optional)",
                    helperText: 'Only if they already have an account. You can invite them later.',
                    errorText: _createError?.errorFor('partner_username'),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy ? null : _create,
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  child: const Text('Create household'),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
