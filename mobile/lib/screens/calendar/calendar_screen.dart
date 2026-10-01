import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';

/// Month grid of projected recurring income and bills.
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  late DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);

  Future<CalendarMonth> _load() async {
    final res = await context.read<Session>().api.get('calendar/',
        query: {'year': _month.year, 'month': _month.month});
    return CalendarMonth.fromJson(res as Map<String, dynamic>);
  }

  void _shift(int months) =>
      setState(() => _month = DateTime(_month.year, _month.month + months));

  bool get _isThisMonth {
    final now = DateTime.now();
    return _month.year == now.year && _month.month == now.month;
  }

  @override
  Widget build(BuildContext context) {
    final symbol = context.watch<Session>().currencySymbol;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cash-flow calendar'),
        actions: [
          if (!_isThisMonth)
            TextButton(
              onPressed: () => setState(() =>
                  _month = DateTime(DateTime.now().year, DateTime.now().month)),
              child: const Text('Today'),
            ),
        ],
      ),
      body: Column(children: [
        _MonthNav(
          label: DateFormat('MMMM yyyy').format(_month),
          onPrev: () => _shift(-1),
          onNext: () => _shift(1),
        ),
        Expanded(
          child: LoadBuilder<CalendarMonth>(
            // A new key per month makes the loader fetch again.
            key: ValueKey(_month),
            load: _load,
            builder: (context, cal, reload) => _CalendarBody(cal: cal, symbol: symbol),
          ),
        ),
      ]),
    );
  }
}

class _MonthNav extends StatelessWidget {
  const _MonthNav({required this.label, required this.onPrev, required this.onNext});
  final String label;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(children: [
        IconButton(
            tooltip: 'Previous month', icon: const Icon(Icons.chevron_left), onPressed: onPrev),
        Expanded(
          child: Text(label,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        ),
        IconButton(
            tooltip: 'Next month', icon: const Icon(Icons.chevron_right), onPressed: onNext),
      ]),
    );
  }
}

class _CalendarBody extends StatelessWidget {
  const _CalendarBody({required this.cal, required this.symbol});
  final CalendarMonth cal;
  final String symbol;

  void _showDay(BuildContext context, CalendarDay day) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _DaySheet(day: day, symbol: symbol),
    );
  }

  @override
  Widget build(BuildContext context) {
    final billDays = [
      for (final w in cal.weeks)
        for (final d in w)
          if (d.inMonth && d.bills.isNotEmpty) d,
    ];
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        StatRow(children: [
          StatTile(
              label: 'Income',
              value: fmtMoney(cal.monthIncome, symbol: symbol),
              color: AppColors.income),
          StatTile(
              label: 'Bills',
              value: fmtMoney(cal.monthExpense, symbol: symbol),
              color: AppColors.expense),
          StatTile(
              label: 'Net',
              value: fmtMoney(cal.monthNet, symbol: symbol, signed: true),
              color: cal.monthNet < 0 ? AppColors.expense : AppColors.income),
        ]),
        const SizedBox(height: 12),
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 8),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Column(children: [
              const _WeekdayHeader(),
              for (final week in cal.weeks)
                Row(children: [
                  for (final day in week)
                    Expanded(
                      child: _DayCell(
                        day: day,
                        onTap: day.bills.isEmpty ? null : () => _showDay(context, day),
                      ),
                    ),
                ]),
            ]),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text('Projected from your active recurring items. Tap a day to see its bills.',
              style: TextStyle(color: AppColors.muted, fontSize: 12)),
        ),
        SectionHeader('Scheduled this month (${billDays.fold<int>(0, (n, d) => n + d.bills.length)})'),
        if (billDays.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('Nothing scheduled.', style: TextStyle(color: AppColors.muted)),
          )
        else
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(children: [
              for (final d in billDays)
                for (final b in d.bills) _BillTile(bill: b, date: d.date, symbol: symbol),
            ]),
          ),
      ],
    );
  }
}

class _WeekdayHeader extends StatelessWidget {
  const _WeekdayHeader();

  @override
  Widget build(BuildContext context) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final style = Theme.of(context)
        .textTheme
        .labelSmall
        ?.copyWith(color: AppColors.muted, fontWeight: FontWeight.w600);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        for (final n in names)
          Expanded(child: Text(n, textAlign: TextAlign.center, style: style)),
      ]),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({required this.day, this.onTap});
  final CalendarDay day;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.labelSmall;
    return Opacity(
      opacity: day.inMonth ? 1 : 0.35,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 64,
          margin: const EdgeInsets.all(1.5),
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: day.bills.isNotEmpty && day.inMonth
                ? scheme.surfaceContainerHighest.withValues(alpha: 0.6)
                : null,
            border: day.isToday ? Border.all(color: scheme.primary, width: 2) : null,
          ),
          child: Column(children: [
            Text(
              '${day.date.day}',
              style: small?.copyWith(
                fontWeight: day.isToday ? FontWeight.w800 : FontWeight.w600,
                color: day.isToday ? scheme.primary : null,
              ),
            ),
            const Spacer(),
            if (day.income > 0) _Marker(value: day.income, color: AppColors.income, sign: '+'),
            if (day.expense > 0) _Marker(value: day.expense, color: AppColors.expense, sign: '−'),
          ]),
        ),
      ),
    );
  }
}

class _Marker extends StatelessWidget {
  const _Marker({required this.value, required this.color, required this.sign});
  final double value;
  final Color color;
  final String sign;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Text('$sign${fmtCompact(value)}',
          style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w700)),
    );
  }
}

class _DaySheet extends StatelessWidget {
  const _DaySheet({required this.day, required this.symbol});
  final CalendarDay day;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(children: [
              Expanded(
                child: Text(DateFormat('EEEE, d MMMM').format(day.date),
                    style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              ),
              Text(fmtMoney(day.net, symbol: symbol, signed: true),
                  style: t.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: day.net < 0 ? AppColors.expense : AppColors.income)),
            ]),
          ),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final b in day.bills) _BillTile(bill: b, symbol: symbol),
            ]),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}

class _BillTile extends StatelessWidget {
  const _BillTile({required this.bill, required this.symbol, this.date});
  final CalendarBill bill;
  final String symbol;
  final DateTime? date;

  @override
  Widget build(BuildContext context) {
    final income = bill.kind == 'income';
    final color = income ? AppColors.income : AppColors.expense;
    final sub = [
      if (date != null) fmtDateShort(date),
      income ? 'Income' : 'Bill',
      if (bill.category != null) bill.category!.name,
      if (bill.payee.isNotEmpty) bill.payee,
    ].join(' · ');
    return ListTile(
      leading: bill.category == null
          ? IconBadge(
              iconData: income ? Icons.south_west : Icons.north_east,
              color: income ? '#198754' : '#dc3545',
              size: 36)
          : IconBadge(icon: bill.category!.icon, color: bill.category!.color, size: 36),
      title: Text(bill.name),
      subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(
        fmtMoney(income ? bill.amount : -bill.amount, symbol: symbol, signed: true),
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}
