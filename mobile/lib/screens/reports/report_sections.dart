import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/icons.dart';
import '../../core/models.dart';
import '../../widgets/common.dart';
import '../networth/finance_shared.dart';

/// Everything below the month switcher.
class ReportBody extends StatelessWidget {
  const ReportBody({super.key, required this.report, required this.symbol});
  final MonthlyReport report;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final r = report;
    return ListView(
      padding: const EdgeInsets.only(top: 4, bottom: 32),
      children: [
        _Summary(r: r, symbol: symbol),
        if (r.members.isNotEmpty) ...[
          const SectionHeader('By member'),
          _Members(members: r.members, symbol: symbol),
        ],
        const SectionHeader('Spending by category'),
        _Categories(rows: r.byCategory, symbol: symbol),
        const SectionHeader('Top payees'),
        _TopPayees(rows: r.topPayees, symbol: symbol),
        if (r.budgets.isNotEmpty) ...[
          const SectionHeader('Budget performance'),
          _Budgets(rows: r.budgets, symbol: symbol),
        ],
        const SectionHeader('Other activity'),
        _Activity(r: r, symbol: symbol),
        if (r.goalContributions.isNotEmpty) ...[
          SectionHeader('Saved toward goals · ${fmtMoney(r.goalTotal, symbol: symbol)}'),
          _GoalContributions(rows: r.goalContributions, symbol: symbol),
        ],
        if (r.projects.isNotEmpty) ...[
          const SectionHeader('Project spending'),
          _Projects(rows: r.projects, symbol: symbol),
        ],
        if (r.meetings.isNotEmpty) ...[
          const SectionHeader('Meetings'),
          _Meetings(rows: r.meetings),
        ],
        if (r.topTransactions.isNotEmpty) ...[
          const SectionHeader('Largest transactions'),
          _CardList(children: [
            for (final t in r.topTransactions) TxnTile(txn: t, symbol: symbol),
          ]),
        ],
      ],
    );
  }
}

/// A full-width card wrapping list rows.
class _CardList extends StatelessWidget {
  const _CardList({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(children: children),
      );
}

class _Muted extends StatelessWidget {
  const _Muted(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Text(text, style: const TextStyle(color: AppColors.muted)),
      );
}

// ---------------------------------------------------------------- summary

class _Summary extends StatelessWidget {
  const _Summary({required this.r, required this.symbol});
  final MonthlyReport r;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      StatRow(children: [
        _DeltaTile(
          label: 'Income',
          value: fmtMoney(r.income, symbol: symbol),
          color: AppColors.income,
          delta: r.incomeDeltaPct,
          upIsGood: true,
        ),
        _DeltaTile(
          label: 'Expenses',
          value: fmtMoney(r.expense, symbol: symbol),
          color: AppColors.expense,
          delta: r.expenseDeltaPct,
          upIsGood: false,
        ),
      ]),
      const SizedBox(height: 8),
      StatRow(children: [
        _DeltaTile(
          label: 'Net',
          value: fmtMoney(r.net, symbol: symbol, signed: true),
          color: r.net < 0 ? AppColors.expense : AppColors.income,
          caption: '${r.transactionCount} transaction${r.transactionCount == 1 ? '' : 's'}',
        ),
        _DeltaTile(
          label: 'Savings rate',
          value: fmtPct(r.savingsRate, digits: 1),
          color: (r.savingsRate ?? 0) < 0 ? AppColors.expense : null,
          caption: 'Net ÷ income',
        ),
      ]),
    ]);
  }
}

/// Stat tile with a "+12.5% vs last month" line underneath.
class _DeltaTile extends StatelessWidget {
  const _DeltaTile({
    required this.label,
    required this.value,
    this.color,
    this.delta,
    this.upIsGood = true,
    this.caption,
  });
  final String label;
  final String value;
  final Color? color;
  final double? delta;
  final bool upIsGood;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Widget sub;
    if (caption != null) {
      sub = Text(caption!, style: t.labelSmall?.copyWith(color: AppColors.muted));
    } else if (delta == null) {
      sub = Text('No prior month data', style: t.labelSmall?.copyWith(color: AppColors.muted));
    } else {
      final good = (delta! >= 0) == upIsGood;
      final c = good ? AppColors.income : AppColors.expense;
      sub = Row(children: [
        Icon(delta! >= 0 ? Icons.arrow_upward : Icons.arrow_downward, size: 12, color: c),
        Flexible(
          child: Text(
            '${delta! >= 0 ? '+' : ''}${delta!.toStringAsFixed(1)}% vs last month',
            style: t.labelSmall?.copyWith(color: c, fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ]);
    }
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: t.labelMedium?.copyWith(color: AppColors.muted)),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value,
                style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: color)),
          ),
          const SizedBox(height: 4),
          sub,
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- members

class _Members extends StatelessWidget {
  const _Members({required this.members, required this.symbol});
  final List<MemberRow> members;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return _CardList(children: [
      for (final m in members)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CircleAvatar(
                  radius: 14,
                  child: Text(m.user.username[0].toUpperCase(),
                      style: const TextStyle(fontSize: 12))),
              const SizedBox(width: 10),
              Expanded(
                child: Text(m.user.username,
                    style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
              ),
              Text('Net ${fmtMoney(m.net, symbol: symbol, signed: true)}',
                  style: t.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: m.net < 0 ? AppColors.expense : AppColors.income)),
            ]),
            const SizedBox(height: 10),
            _ShareLine(
                label: 'Income',
                amount: fmtMoney(m.income, symbol: symbol),
                pct: m.incomeSharePct,
                color: AppColors.income),
            const SizedBox(height: 6),
            _ShareLine(
                label: 'Expenses',
                amount: fmtMoney(m.expense, symbol: symbol),
                pct: m.expenseSharePct,
                color: AppColors.expense),
          ]),
        ),
    ]);
  }
}

class _ShareLine extends StatelessWidget {
  const _ShareLine(
      {required this.label, required this.amount, required this.pct, required this.color});
  final String label;
  final String amount;
  final double pct;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme.bodySmall;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text('$label · $amount', style: t)),
        Text('${pct.toStringAsFixed(0)}% of total', style: t?.copyWith(color: AppColors.muted)),
      ]),
      const SizedBox(height: 4),
      ProgressLine(percent: pct, color: color, height: 6),
    ]);
  }
}

// ---------------------------------------------------------------- categories

class _Categories extends StatelessWidget {
  const _Categories({required this.rows, required this.symbol});
  final List<Map<String, dynamic>> rows;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const _Muted('No categorised expenses this month.');
    final t = Theme.of(context).textTheme;
    final total = rows.fold<double>(0, (s, c) => s + money(c['total']));
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(children: [
          SizedBox(
            height: 180,
            child: Stack(alignment: Alignment.center, children: [
              PieChart(PieChartData(
                centerSpaceRadius: 56,
                sectionsSpace: 2,
                sections: [
                  for (final c in rows)
                    PieChartSectionData(
                      value: money(c['total']),
                      color: hexColor(c['color'] as String?),
                      radius: 30,
                      showTitle: false,
                    ),
                ],
              )),
              Column(mainAxisSize: MainAxisSize.min, children: [
                Text('Spent', style: t.labelSmall?.copyWith(color: AppColors.muted)),
                Text(fmtCompact(total),
                    style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              ]),
            ]),
          ),
          const SizedBox(height: 8),
          for (final c in rows) _CategoryRow(row: c, symbol: symbol),
        ]),
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({required this.row, required this.symbol});
  final Map<String, dynamic> row;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final color = hexColor(row['color'] as String?);
    final pct = (row['pct'] as num? ?? 0).toDouble();
    final count = row['count'] as int? ?? 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Column(children: [
        Row(children: [
          Icon(biIcon(row['icon'] as String?), size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(TextSpan(children: [
              TextSpan(text: row['name'] as String? ?? 'Uncategorised'),
              TextSpan(
                  text: '  $count tx',
                  style: t.bodySmall?.copyWith(color: AppColors.muted)),
            ])),
          ),
          Text(fmtMoney(money(row['total']), symbol: symbol),
              style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          SizedBox(
            width: 52,
            child: Text('${pct.toStringAsFixed(1)}%',
                textAlign: TextAlign.end,
                style: t.bodySmall?.copyWith(color: AppColors.muted)),
          ),
        ]),
        const SizedBox(height: 4),
        ProgressLine(percent: pct, color: color, height: 5),
      ]),
    );
  }
}

// ---------------------------------------------------------------- payees

class _TopPayees extends StatelessWidget {
  const _TopPayees({required this.rows, required this.symbol});
  final List<Map<String, dynamic>> rows;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const _Muted('No payees recorded this month.');
    return _CardList(children: [
      for (var i = 0; i < rows.length; i++)
        ListTile(
          dense: true,
          leading: CircleAvatar(radius: 14, child: Text('${i + 1}', style: const TextStyle(fontSize: 12))),
          title: Text(rows[i]['payee'] as String? ?? ''),
          subtitle: Text('${rows[i]['count']} transaction${rows[i]['count'] == 1 ? '' : 's'}'),
          trailing: Text(fmtMoney(money(rows[i]['total']), symbol: symbol),
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
    ]);
  }
}

// ---------------------------------------------------------------- budgets

class _Budgets extends StatelessWidget {
  const _Budgets({required this.rows, required this.symbol});
  final List<BudgetRow> rows;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return _CardList(children: [
      for (final b in rows)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              IconBadge(icon: b.category.icon, color: b.category.color, size: 28),
              const SizedBox(width: 10),
              Expanded(child: Text(b.category.name, style: t.bodyMedium)),
              Text(
                  '${fmtMoney(b.spent ?? 0, symbol: symbol)} / ${fmtMoney(b.limit, symbol: symbol)}',
                  style: t.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 6),
            ProgressLine(percent: b.pct ?? 0),
            const SizedBox(height: 4),
            Text(
              b.over
                  ? 'Over by ${fmtMoney((b.spent ?? 0) - b.limit, symbol: symbol)} · ${fmtPct(b.pct)} used'
                  : '${fmtPct(b.pct)} used · ${fmtMoney(b.remaining ?? 0, symbol: symbol)} left',
              style: t.bodySmall?.copyWith(color: b.over ? AppColors.expense : AppColors.muted),
            ),
          ]),
        ),
    ]);
  }
}

// ---------------------------------------------------------------- activity

class _Activity extends StatelessWidget {
  const _Activity({required this.r, required this.symbol});
  final MonthlyReport r;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final approved = r.requests['approved'] ?? 0;
    final rejected = r.requests['rejected'] ?? 0;
    final cancelled = r.requests['cancelled'] ?? 0;
    return _CardList(children: [
      _ActivityTile(
        icon: Icons.swap_horiz,
        title: 'Money requests resolved',
        value: '${approved + rejected + cancelled}',
        subtitle: '$approved approved · $rejected rejected · $cancelled cancelled',
      ),
      _ActivityTile(
        icon: Icons.savings_outlined,
        title: 'Saved toward goals',
        value: fmtMoney(r.goalTotal, symbol: symbol),
        subtitle:
            '${r.goalContributions.length} contribution${r.goalContributions.length == 1 ? '' : 's'}',
      ),
      _ActivityTile(
        icon: Icons.credit_card,
        title: 'Debt paid',
        value: fmtMoney(r.debtPaid, symbol: symbol),
        subtitle: '${r.debtPaidCount} payment${r.debtPaidCount == 1 ? '' : 's'}',
      ),
      _ActivityTile(
        icon: Icons.handshake_outlined,
        title: 'Repaid to us',
        value: fmtMoney(r.receivableReceived, symbol: symbol),
        subtitle: 'From money lent out',
      ),
    ]);
  }
}

class _ActivityTile extends StatelessWidget {
  const _ActivityTile(
      {required this.icon, required this.title, required this.value, required this.subtitle});
  final IconData icon;
  final String title;
  final String value;
  final String subtitle;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
      );
}

// ---------------------------------------------------------------- goals / projects / meetings

class _GoalContributions extends StatelessWidget {
  const _GoalContributions({required this.rows, required this.symbol});
  final List<Map<String, dynamic>> rows;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    return _CardList(children: [
      for (final c in rows)
        ListTile(
          dense: true,
          leading: const Icon(Icons.savings_outlined),
          title: Text((c['goal'] as Map?)?['name'] as String? ?? 'Goal'),
          subtitle: Text([
            fmtDateShort(DateTime.tryParse(c['date'] as String? ?? '')),
            if (c['user'] is Map) (c['user'] as Map)['username'] as String,
          ].join(' · ')),
          trailing: Text(fmtMoney(money(c['amount']), symbol: symbol),
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
    ]);
  }
}

class _Projects extends StatelessWidget {
  const _Projects({required this.rows, required this.symbol});
  final List<Map<String, dynamic>> rows;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    return _CardList(children: [
      for (final p in rows)
        ListTile(
          dense: true,
          leading: IconBadge(icon: p['icon'] as String?, color: p['color'] as String?, size: 32),
          title: Text(p['name'] as String? ?? ''),
          trailing: Text(fmtMoney(money(p['month_spent']), symbol: symbol),
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
    ]);
  }
}

class _Meetings extends StatelessWidget {
  const _Meetings({required this.rows});
  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    return _CardList(children: [
      for (final m in rows)
        ListTile(
          dense: true,
          leading: const Icon(Icons.groups_outlined),
          title: Text(m['title'] as String? ?? ''),
          subtitle: Text(fmtDate(DateTime.tryParse(m['meeting_date'] as String? ?? ''))),
          trailing: StatusChip(humanize(m['status'] as String? ?? ''),
              color: m['status'] == 'held' ? AppColors.income : null),
        ),
    ]);
  }
}
