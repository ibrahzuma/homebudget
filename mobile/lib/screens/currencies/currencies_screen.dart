import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../../widgets/entity_form.dart';

class _CurrencyData {
  _CurrencyData.fromJson(Map<String, dynamic> j)
      : currencies = (j['currencies'] as List)
            .map((e) => Currency.fromJson(e as Map<String, dynamic>))
            .toList(),
        rates = (j['rates'] as List)
            .map((e) => ExchangeRate.fromJson(e as Map<String, dynamic>))
            .toList();
  final List<Currency> currencies;
  final List<ExchangeRate> rates;
}

final _rateFormat = NumberFormat('#,##0.######');

/// Currencies and the exchange rates used to convert into the base currency.
class CurrenciesScreen extends StatefulWidget {
  const CurrenciesScreen({super.key});

  @override
  State<CurrenciesScreen> createState() => _CurrenciesScreenState();
}

class _CurrenciesScreenState extends State<CurrenciesScreen> {
  final _loader = GlobalKey<LoadBuilderState<_CurrencyData>>();
  _CurrencyData? _data;

  Session get _session => context.read<Session>();

  Future<_CurrencyData> _load() async {
    final d = _CurrencyData.fromJson(await _session.api.get('currencies/') as Map<String, dynamic>);
    _data = d;
    return d;
  }

  Future<void> _addCurrency() async {
    final saved = await openForm(
      context,
      EntityFormScreen(
        title: 'Add currency',
        fields: const [
          FieldSpec.text('code', 'Code', required: true, hint: 'e.g. ZAR', help: 'Up to 5 letters.'),
          FieldSpec.text('name', 'Name', required: true, hint: 'e.g. South African Rand'),
          FieldSpec.text('symbol', 'Symbol', required: true, hint: 'e.g. R'),
        ],
        onSubmit: (v) async {
          await _session.api.post('currencies/', {...v, 'code': (v['code'] as String).toUpperCase()});
        },
      ),
    );
    if (!saved || !mounted) return;
    showOk(context, 'Currency added. Set a rate so amounts in it convert.');
    _loader.currentState?.reload();
    _session.refreshMeta().catchError((_) {});
  }

  /// New rate, or update [existing] (the server upserts by currency pair).
  Future<void> _setRate([ExchangeRate? existing]) async {
    final currencies = _data?.currencies ?? const <Currency>[];
    if (currencies.length < 2) {
      showError(context, 'Add at least two currencies first.');
      return;
    }
    final base = _session.household?.baseCurrency;
    final options = [for (final c in currencies) Option(c.id, '${c.code} · ${c.name}')];
    final saved = await openForm(
      context,
      EntityFormScreen(
        title: existing == null ? 'Set exchange rate' : 'Update rate',
        intro: const _RateIntro(),
        initial: existing == null
            ? {'to_currency': base?.id}
            : {
                'from_currency': existing.from.id,
                'to_currency': existing.to.id,
                'rate': existing.rateRaw,
              },
        fields: [
          FieldSpec.select('from_currency', 'From (1 unit of)', required: true, options: options),
          FieldSpec.select('to_currency', 'To', required: true, options: options),
          const FieldSpec.money('rate', 'Rate', required: true,
              help: 'How many "To" units one "From" unit buys, e.g. 1 USD = 2500 TZS.'),
        ],
        onSubmit: (v) async {
          await _session.api.post('currencies/rates/', v);
        },
      ),
    );
    if (!saved || !mounted) return;
    showOk(context, 'Rate saved. Base amounts were recomputed.');
    _loader.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    final baseId = context.select<Session, int?>((s) => s.household?.baseCurrency?.id);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Currencies & rates'),
        actions: [
          IconButton(
              tooltip: 'Add currency', onPressed: _addCurrency, icon: const Icon(Icons.add_card)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'currencies-fab',
        onPressed: () => _setRate(),
        icon: const Icon(Icons.currency_exchange),
        label: const Text('Set rate'),
      ),
      body: LoadBuilder<_CurrencyData>(
        key: _loader,
        load: _load,
        builder: (context, d, reload) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(top: 8, bottom: 96),
          children: [
            const _Tip(),
            SectionHeader('Exchange rates (${d.rates.length})'),
            if (d.rates.isEmpty)
              _EmptyRates(onAdd: () => _setRate())
            else
              Card(
                child: Column(children: [
                  for (final r in d.rates) _RateTile(rate: r, onTap: () => _setRate(r)),
                ]),
              ),
            SectionHeader('Currencies (${d.currencies.length})',
                trailing: TextButton.icon(
                    onPressed: _addCurrency, icon: const Icon(Icons.add), label: const Text('Add'))),
            Card(
              child: Column(children: [
                for (final c in d.currencies) _CurrencyTile(currency: c, isBase: c.id == baseId),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tip extends StatelessWidget {
  const _Tip();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Text(
        'Record transactions, assets and debts in any currency. Exchange rates convert '
        'them into your base currency for totals and charts.',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.muted),
      ),
    );
  }
}

class _RateIntro extends StatelessWidget {
  const _RateIntro();

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(top: 8),
      color: AppColors.warning.withValues(alpha: 0.1),
      child: const Padding(
        padding: EdgeInsets.all(12),
        child: Text(
          'Saving a rate recomputes the base-currency amounts of existing '
          'transactions in these currencies. Setting a pair that already exists '
          'replaces its rate.',
        ),
      ),
    );
  }
}

class _EmptyRates extends StatelessWidget {
  const _EmptyRates({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          const Text('No exchange rates set yet.', style: TextStyle(color: AppColors.muted)),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: onAdd,
            icon: const Icon(Icons.currency_exchange),
            label: const Text('Set a rate'),
          ),
        ]),
      ),
    );
  }
}

class _RateTile extends StatelessWidget {
  const _RateTile({required this.rate, required this.onTap});
  final ExchangeRate rate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final r = rate;
    final inverse = r.rate == 0 ? null : 1 / r.rate;
    return ListTile(
      onTap: onTap,
      leading: const Icon(Icons.swap_horiz),
      title: Text('1 ${r.from.code} = ${_rateFormat.format(r.rate)} ${r.to.code}',
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text([
        if (inverse != null) '1 ${r.to.code} = ${_rateFormat.format(inverse)} ${r.from.code}',
        if (r.updatedAt != null) 'updated ${fmtDateTime(r.updatedAt)}',
      ].join(' · ')),
      trailing: const Icon(Icons.edit_outlined, size: 20),
    );
  }
}

class _CurrencyTile extends StatelessWidget {
  const _CurrencyTile({required this.currency, required this.isBase});
  final Currency currency;
  final bool isBase;

  @override
  Widget build(BuildContext context) {
    final c = currency;
    return ListTile(
      leading: CircleAvatar(
        child: FittedBox(
          child: Padding(padding: const EdgeInsets.all(4), child: Text(c.symbol)),
        ),
      ),
      title: Text(c.code, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(c.name),
      trailing: isBase ? const StatusChip('Base', color: AppColors.income) : null,
    );
  }
}
