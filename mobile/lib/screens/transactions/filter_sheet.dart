import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/models.dart';

/// Transaction list filters, mapped 1:1 onto the `transactions/` query params.
class TxnFilters {
  const TxnFilters({
    this.type,
    this.member,
    this.category,
    this.project,
    this.uncategorized = false,
    this.from,
    this.to,
  });

  final String? type; // income | expense
  final int? member;
  final int? category;
  final int? project;
  final bool uncategorized;
  final DateTime? from;
  final DateTime? to;

  bool get hasDates => from != null || to != null;

  int get activeCount => [
        type != null,
        member != null,
        category != null || uncategorized,
        project != null,
        hasDates,
      ].where((x) => x).length;

  Map<String, dynamic> get query => {
        'type': type,
        'member': member,
        'category': uncategorized ? null : category,
        'uncategorized': uncategorized ? 1 : null,
        'project': project,
        'date_from': from == null ? null : apiDate(from!),
        'date_to': to == null ? null : apiDate(to!),
      };

  TxnFilters copyWith({
    String? Function()? type,
    int? Function()? member,
    int? Function()? category,
    int? Function()? project,
    bool? uncategorized,
    DateTime? Function()? from,
    DateTime? Function()? to,
  }) =>
      TxnFilters(
        type: type != null ? type() : this.type,
        member: member != null ? member() : this.member,
        category: category != null ? category() : this.category,
        project: project != null ? project() : this.project,
        uncategorized: uncategorized ?? this.uncategorized,
        from: from != null ? from() : this.from,
        to: to != null ? to() : this.to,
      );

  TxnFilters withoutDates() => copyWith(from: () => null, to: () => null);

  String dateLabel() {
    if (from != null && to != null) return '${fmtDateShort(from)} – ${fmtDateShort(to)}';
    if (from != null) return 'From ${fmtDateShort(from)}';
    return 'Until ${fmtDateShort(to)}';
  }
}

/// Bottom sheet to edit [current]. Resolves to the new filters, or null if
/// dismissed.
Future<TxnFilters?> showTxnFilterSheet(BuildContext context, TxnFilters current, Meta meta) {
  return showModalBottomSheet<TxnFilters>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => _FilterSheet(initial: current, meta: meta),
  );
}

class _FilterSheet extends StatefulWidget {
  const _FilterSheet({required this.initial, required this.meta});
  final TxnFilters initial;
  final Meta meta;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late TxnFilters _f = widget.initial;

  Meta get _meta => widget.meta;

  void _set(TxnFilters f) => setState(() => _f = f);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Filter transactions', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            _typeSelector(),
            const SizedBox(height: 16),
            if (_meta.members.length > 1) ...[_memberField(), const SizedBox(height: 12)],
            _categoryField(),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Uncategorized only'),
              value: _f.uncategorized,
              onChanged: (v) => _set(_f.copyWith(uncategorized: v, category: () => null)),
            ),
            if (_meta.projects.isNotEmpty) ...[_projectField(), const SizedBox(height: 12)],
            _DateRangePicker(
              filters: _f,
              onChanged: (from, to) => _set(_f.copyWith(from: () => from, to: () => to)),
            ),
            const SizedBox(height: 20),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, const TxnFilters()),
                  child: const Text('Reset'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, _f),
                  child: const Text('Apply'),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _typeSelector() => SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: '', label: Text('All')),
          ButtonSegment(value: 'income', label: Text('Income')),
          ButtonSegment(value: 'expense', label: Text('Expense')),
        ],
        selected: {_f.type ?? ''},
        onSelectionChanged: (s) {
          final type = s.first.isEmpty ? null : s.first;
          // Drop a category that no longer matches the chosen type.
          final keep = type == null ||
              _meta.categories.any((c) => c.id == _f.category && c.type == type);
          _set(_f.copyWith(type: () => type, category: keep ? null : () => null));
        },
      );

  Widget _memberField() => DropdownButtonFormField<int?>(
        initialValue: _f.member,
        decoration: const InputDecoration(labelText: 'Member'),
        items: [
          const DropdownMenuItem(value: null, child: Text('All members')),
          for (final m in _meta.members) DropdownMenuItem(value: m.id, child: Text(m.username)),
        ],
        onChanged: (v) => _set(_f.copyWith(member: () => v)),
      );

  Widget _categoryField() {
    final cats = _f.type == null ? _meta.categories : _meta.categoriesOfType(_f.type!);
    return DropdownButtonFormField<int?>(
      key: ValueKey('cat-${_f.type}-${_f.uncategorized}'),
      initialValue: cats.any((c) => c.id == _f.category) ? _f.category : null,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Category'),
      items: [
        const DropdownMenuItem(value: null, child: Text('All categories')),
        for (final c in cats)
          DropdownMenuItem(
            value: c.id,
            child: Text(_f.type == null ? '${c.name} (${capitalize(c.type)})' : c.name,
                overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: _f.uncategorized ? null : (v) => _set(_f.copyWith(category: () => v)),
    );
  }

  Widget _projectField() => DropdownButtonFormField<int?>(
        initialValue: _meta.projects.any((p) => p.id == _f.project) ? _f.project : null,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Project'),
        items: [
          const DropdownMenuItem(value: null, child: Text('Any project')),
          for (final p in _meta.projects) DropdownMenuItem(value: p.id, child: Text(p.name)),
        ],
        onChanged: (v) => _set(_f.copyWith(project: () => v)),
      );
}

/// Quick date presets plus a custom range picker.
class _DateRangePicker extends StatelessWidget {
  const _DateRangePicker({required this.filters, required this.onChanged});
  final TxnFilters filters;
  final void Function(DateTime? from, DateTime? to) onChanged;

  bool _is(DateTime from, DateTime to) =>
      filters.from != null &&
      filters.to != null &&
      DateUtils.isSameDay(filters.from, from) &&
      DateUtils.isSameDay(filters.to, to);

  @override
  Widget build(BuildContext context) {
    final now = DateUtils.dateOnly(DateTime.now());
    final presets = <(String, DateTime, DateTime)>[
      ('This month', DateTime(now.year, now.month), DateTime(now.year, now.month + 1, 0)),
      ('Last month', DateTime(now.year, now.month - 1), DateTime(now.year, now.month, 0)),
      ('Last 30 days', now.subtract(const Duration(days: 29)), now),
      ('This year', DateTime(now.year), DateTime(now.year, 12, 31)),
    ];
    final isPreset = presets.any((p) => _is(p.$2, p.$3));

    return InputDecorator(
      decoration: const InputDecoration(labelText: 'Date'),
      child: Wrap(spacing: 8, runSpacing: 4, children: [
        ChoiceChip(
          label: const Text('Any time'),
          selected: !filters.hasDates,
          onSelected: (_) => onChanged(null, null),
        ),
        for (final (label, from, to) in presets)
          ChoiceChip(
            label: Text(label),
            selected: _is(from, to),
            onSelected: (_) => onChanged(from, to),
          ),
        ChoiceChip(
          avatar: const Icon(Icons.date_range, size: 18),
          label: Text(filters.hasDates && !isPreset ? filters.dateLabel() : 'Custom…'),
          selected: filters.hasDates && !isPreset,
          onSelected: (_) async {
            final range = await showDateRangePicker(
              context: context,
              firstDate: DateTime(2000),
              lastDate: DateTime(2100),
              initialDateRange: filters.from != null && filters.to != null
                  ? DateTimeRange(start: filters.from!, end: filters.to!)
                  : null,
            );
            if (range != null) onChanged(range.start, range.end);
          },
        ),
      ]),
    );
  }
}
