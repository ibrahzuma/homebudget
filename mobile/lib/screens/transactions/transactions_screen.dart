import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../import_export/import_export_screen.dart';
import 'filter_sheet.dart';
import 'pager.dart';
import 'transaction_detail_screen.dart';
import 'transaction_form.dart';
import 'transaction_tile.dart';
import 'txn_events.dart';

/// Bottom tab: searchable, filterable, infinitely scrolling transaction list
/// grouped by day, with totals for the current filter.
class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key});

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  late final Pager<Txn> _pager = Pager(_fetch);
  final _scroll = ScrollController();
  final _search = TextEditingController();
  Timer? _debounce;
  TxnFilters _filters = const TxnFilters();

  @override
  void initState() {
    super.initState();
    _pager.addListener(_onPager);
    _scroll.addListener(_onScroll);
    transactionsChanged.addListener(_onExternalChange);
    _pager.refresh();
  }

  @override
  void dispose() {
    transactionsChanged.removeListener(_onExternalChange);
    _pager.dispose();
    _scroll.dispose();
    _search.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onPager() => setState(() {});

  void _onExternalChange() => _pager.refresh();

  void _onScroll() {
    if (_scroll.position.extentAfter < 600) _pager.loadMore();
  }

  Future<Paged<Txn>> _fetch(int page, int size) async {
    final api = context.read<Session>().api;
    final json = await api.get('transactions/', query: {
      ..._filters.query,
      'q': _search.text.trim(),
      'page': page,
      'page_size': size,
    }) as Map<String, dynamic>;
    return Paged.fromJson(json, Txn.fromJson);
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _pager.refresh(clear: true));
    setState(() {}); // toggle the clear button
  }

  void _applyFilters(TxnFilters f) {
    setState(() => _filters = f);
    _pager.refresh(clear: true);
  }

  void _clearAll() {
    _search.clear();
    _applyFilters(const TxnFilters());
  }

  Future<void> _openFilters() async {
    final meta = await metaForForm(context);
    if (meta == null || !mounted) return;
    final f = await showTxnFilterSheet(context, _filters, meta);
    if (f != null) _applyFilters(f);
  }

  Future<void> _pullToRefresh() async {
    final err = await _pager.refresh();
    if (err != null && mounted && _pager.items.isNotEmpty) showError(context, err);
  }

  void _openDetail(Txn t) => push(context, TransactionDetailScreen(id: t.id));

  bool get _isFiltered => _filters.activeCount > 0 || _search.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Transactions'),
        actions: [
          IconButton(
            tooltip: 'Filters',
            onPressed: _openFilters,
            icon: CountBadge(count: _filters.activeCount, child: const Icon(Icons.tune)),
          ),
          PopupMenuButton<String>(
            onSelected: (_) => push(context, const ImportExportScreen()),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'csv', child: Text('Import / export CSV')),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: _SearchField(
            controller: _search,
            onChanged: _onSearchChanged,
            onClear: () {
              _search.clear();
              _onSearchChanged('');
            },
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'txn-add',
        onPressed: () => openTransactionForm(context, type: _filters.type ?? 'expense'),
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
      body: Column(children: [
        if (_filters.activeCount > 0)
          _ActiveFilterChips(filters: _filters, onChanged: _applyFilters),
        Expanded(child: _body()),
      ]),
    );
  }

  Widget _body() {
    if (_pager.isInitialLoading) return const Center(child: CircularProgressIndicator());
    if (!_pager.loaded && _pager.error != null) {
      return ErrorState(error: _pager.error, onRetry: _pager.retry);
    }
    if (_pager.items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _pullToRefresh,
        child: _isFiltered
            ? EmptyState(
                icon: Icons.search_off,
                title: 'No matching transactions',
                message: 'Try a different search or loosen the filters.',
                action: OutlinedButton(onPressed: _clearAll, child: const Text('Clear filters')),
              )
            : EmptyState(
                icon: Icons.receipt_long_outlined,
                title: 'No transactions yet',
                message: 'Record income and expenses to see where your money goes.',
                action: FilledButton.icon(
                  onPressed: () => openTransactionForm(context),
                  icon: const Icon(Icons.add),
                  label: const Text('Add transaction'),
                ),
              ),
      );
    }

    final days = _groupByDay(_pager.items);
    return RefreshIndicator(
      onRefresh: _pullToRefresh,
      child: ListView.builder(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 96),
        itemCount: days.length + 2,
        itemBuilder: (context, i) {
          if (i == 0) return _TotalsCard(page: _pager.last!);
          if (i == days.length + 1) return _footer();
          final day = days[i - 1];
          return _DayGroup(day: day, onTap: _openDetail);
        },
      ),
    );
  }

  Widget _footer() {
    if (_pager.error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Text(_pager.error.toString(), textAlign: TextAlign.center),
          TextButton(onPressed: _pager.retry, child: const Text('Retry')),
        ]),
      );
    }
    if (_pager.hasNext) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text('That\'s everything',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.muted)),
    );
  }
}

class _Day {
  _Day(this.date);
  final DateTime date;
  final List<Txn> txns = [];
}

/// Items arrive sorted newest-first, so consecutive grouping is enough.
List<_Day> _groupByDay(List<Txn> items) {
  final days = <_Day>[];
  for (final t in items) {
    if (days.isEmpty || !DateUtils.isSameDay(days.last.date, t.date)) days.add(_Day(t.date));
    days.last.txns.add(t);
  }
  return days;
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged, required this.onClear});
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search payee or description',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(icon: const Icon(Icons.clear), onPressed: onClear),
          isDense: true,
          filled: true,
          fillColor: Theme.of(context).colorScheme.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(28),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}

/// Removable chips for each active filter.
class _ActiveFilterChips extends StatelessWidget {
  const _ActiveFilterChips({required this.filters, required this.onChanged});
  final TxnFilters filters;
  final ValueChanged<TxnFilters> onChanged;

  @override
  Widget build(BuildContext context) {
    final meta = context.watch<Session>().meta;
    final f = filters;
    String? name<T>(Iterable<T>? list, bool Function(T) test, String Function(T) label) {
      final hit = list?.where(test).firstOrNull;
      return hit == null ? null : label(hit);
    }

    final chips = <(String, TxnFilters)>[
      if (f.type != null) (capitalize(f.type!), f.copyWith(type: () => null)),
      if (f.member != null)
        (name(meta?.members, (m) => m.id == f.member, (m) => m.username) ?? 'Member',
            f.copyWith(member: () => null)),
      if (f.uncategorized) ('Uncategorized', f.copyWith(uncategorized: false)),
      if (f.category != null && !f.uncategorized)
        (name(meta?.categories, (c) => c.id == f.category, (c) => c.name) ?? 'Category',
            f.copyWith(category: () => null)),
      if (f.project != null)
        (name(meta?.projects, (p) => p.id == f.project, (p) => p.name) ?? 'Project',
            f.copyWith(project: () => null)),
      if (f.hasDates) (f.dateLabel(), f.withoutDates()),
    ];

    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        children: [
          for (final (label, without) in chips)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InputChip(
                label: Text(label),
                onDeleted: () => onChanged(without),
                visualDensity: VisualDensity.compact,
              ),
            ),
          if (chips.length > 1)
            TextButton(onPressed: () => onChanged(const TxnFilters()), child: const Text('Clear all')),
        ],
      ),
    );
  }
}

/// Count and income/expense/net for everything matching the filter
/// (server-side totals in the base currency, not just the loaded page).
class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.page});
  final Paged<Txn> page;

  @override
  Widget build(BuildContext context) {
    final sym = context.watch<Session>().currencySymbol;
    final totals = page.extra['totals'] as Map<String, dynamic>? ?? const {};
    final income = double.tryParse('${totals['income'] ?? 0}') ?? 0;
    final expense = double.tryParse('${totals['expense'] ?? 0}') ?? 0;
    final t = Theme.of(context).textTheme;

    Widget figure(String label, double v, Color? color) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: t.labelSmall?.copyWith(color: AppColors.muted)),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(fmtMoney(v, symbol: sym),
                  style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700, color: color)),
            ),
          ]),
        );

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${NumberFormat.decimalPattern().format(page.count)} '
              'transaction${page.count == 1 ? '' : 's'}',
              style: t.labelMedium?.copyWith(color: AppColors.muted)),
          const SizedBox(height: 8),
          Row(children: [
            figure('Income', income, AppColors.income),
            figure('Expenses', expense, AppColors.expense),
            figure('Net', income - expense,
                income - expense < 0 ? AppColors.expense : AppColors.income),
          ]),
        ]),
      ),
    );
  }
}

class _DayGroup extends StatelessWidget {
  const _DayGroup({required this.day, required this.onTap});
  final _Day day;
  final ValueChanged<Txn> onTap;

  String _label() {
    final today = DateUtils.dateOnly(DateTime.now());
    final diff = today.difference(DateUtils.dateOnly(day.date)).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    final sameYear = day.date.year == today.year;
    return DateFormat(sameYear ? 'EEEE, d MMM' : 'EEE, d MMM yyyy').format(day.date);
  }

  @override
  Widget build(BuildContext context) {
    final sym = context.watch<Session>().currencySymbol;
    final net = day.txns.fold<double>(
        0, (sum, t) => sum + (t.amountBase ?? 0) * (t.isIncome ? 1 : -1));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          _label(),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
          trailing: Text(fmtMoney(net, symbol: sym, signed: true),
              style: Theme.of(context).textTheme.labelMedium?.copyWith(color: AppColors.muted)),
        ),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(children: [
            for (var i = 0; i < day.txns.length; i++) ...[
              if (i > 0) const Divider(height: 1, indent: 72),
              TransactionTile(txn: day.txns[i], onTap: () => onTap(day.txns[i])),
            ],
          ]),
        ),
      ],
    );
  }
}
