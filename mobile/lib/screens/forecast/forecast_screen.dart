import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';

/// End-of-month projection from this month's pace plus known recurring items.
class ForecastScreen extends StatelessWidget {
  const ForecastScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final symbol = session.currencySymbol;
    return Scaffold(
      appBar: AppBar(title: const Text('Forecast')),
      body: LoadBuilder<Forecast>(
        load: () async =>
            Forecast.fromJson(await session.api.get('forecast/') as Map<String, dynamic>),
        builder: (context, f, reload) => ListView(
          padding: const EdgeInsets.only(top: 12, bottom: 32),
          children: [
            _BalanceCard(f: f, symbol: symbol),
            const SizedBox(height: 8),
            _MonthProgress(f: f),
            const SectionHeader('So far vs end of month'),
            _CompareRow(
                label: 'Income',
                current: f.incomeSoFar,
                projected: f.projectedIncome,
                color: AppColors.income,
                symbol: symbol),
            const SizedBox(height: 8),
            _CompareRow(
                label: 'Expenses',
                current: f.expenseSoFar,
                projected: f.projectedExpense,
                color: AppColors.expense,
                symbol: symbol),
            const SizedBox(height: 8),
            _CompareRow(
                label: 'Balance',
                current: f.currentBalance,
                projected: f.projectedBalance,
                color: Theme.of(context).colorScheme.primary,
                symbol: symbol),
            const SectionHeader('Chart'),
            _ForecastChart(f: f, symbol: symbol),
            const SectionHeader('Daily pace'),
            StatRow(children: [
              StatTile(
                  label: 'Daily spending',
                  value: fmtMoney(f.dailyBurn, symbol: symbol),
                  color: AppColors.expense,
                  icon: Icons.local_fire_department_outlined),
              StatTile(
                  label: 'Daily income',
                  value: fmtMoney(f.dailyInflow, symbol: symbol),
                  color: AppColors.income,
                  icon: Icons.water_drop_outlined),
            ]),
            const SizedBox(height: 16),
            const _HowItWorks(),
          ],
        ),
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.f, required this.symbol});
  final Forecast f;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final negative = f.projectedBalance < 0;
    final color = negative ? AppColors.expense : AppColors.income;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Projected end-of-month balance${f.monthLabel == null ? '' : ' · ${f.monthLabel}'}',
              style: t.labelLarge?.copyWith(color: AppColors.muted)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(fmtMoney(f.projectedBalance, symbol: symbol, signed: true),
                style: t.headlineMedium?.copyWith(fontWeight: FontWeight.w700, color: color)),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Icon(negative ? Icons.warning_amber_rounded : Icons.check_circle_outline,
                size: 18, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                negative
                    ? 'At this pace you will spend more than you earn this month.'
                    : 'At this pace you should end the month in the green.',
                style: t.bodySmall,
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _MonthProgress extends StatelessWidget {
  const _MonthProgress({required this.f});
  final Forecast f;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme.bodySmall;
    final pct = f.daysTotal == 0 ? 0.0 : f.daysElapsed / f.daysTotal * 100;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ProgressLine(percent: pct, color: Theme.of(context).colorScheme.primary, height: 6),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
              child: Text('Day ${f.daysElapsed} of ${f.daysTotal}',
                  style: t?.copyWith(color: AppColors.muted))),
          Text('${f.daysRemaining} day${f.daysRemaining == 1 ? '' : 's'} remaining',
              style: t?.copyWith(color: AppColors.muted)),
        ]),
      ]),
    );
  }
}

/// "So far → projected" for one measure.
class _CompareRow extends StatelessWidget {
  const _CompareRow({
    required this.label,
    required this.current,
    required this.projected,
    required this.color,
    required this.symbol,
  });
  final String label;
  final double current;
  final double projected;
  final Color color;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          Container(width: 4, height: 36, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: t.labelLarge),
              Text('So far ${fmtMoney(current, symbol: symbol)}',
                  style: t.bodySmall?.copyWith(color: AppColors.muted)),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('Projected', style: t.labelSmall?.copyWith(color: AppColors.muted)),
            Text(fmtMoney(projected, symbol: symbol),
                style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700, color: color)),
          ]),
        ]),
      ),
    );
  }
}

/// Grouped bars: so far (light) vs projected (solid) for income, expenses, balance.
class _ForecastChart extends StatelessWidget {
  const _ForecastChart({required this.f, required this.symbol});
  final Forecast f;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final labelStyle = TextStyle(fontSize: 11, color: scheme.onSurfaceVariant);
    final groups = [
      ('Income', f.incomeSoFar, f.projectedIncome, AppColors.income),
      ('Expenses', f.expenseSoFar, f.projectedExpense, AppColors.expense),
      ('Balance', f.currentBalance, f.projectedBalance, scheme.primary),
    ];
    final all = [for (final g in groups) ...[g.$2, g.$3]];
    final maxY = math.max(1.0, all.reduce(math.max)) * 1.1;
    final minY = math.min(0.0, all.reduce(math.min)) * 1.1;

    BarChartRodData rod(double v, Color c) => BarChartRodData(
          toY: v,
          color: c,
          width: 18,
          borderRadius: BorderRadius.circular(4),
        );

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 20, 16, 12),
        child: Column(children: [
          SizedBox(
            height: 200,
            child: BarChart(BarChartData(
              minY: minY,
              maxY: maxY,
              alignment: BarChartAlignment.spaceAround,
              borderData: FlBorderData(show: false),
              gridData: FlGridData(
                drawVerticalLine: false,
                getDrawingHorizontalLine: (v) => FlLine(
                    color: v == 0
                        ? scheme.outline
                        : scheme.outlineVariant.withValues(alpha: 0.5),
                    strokeWidth: 1),
              ),
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(),
                rightTitles: const AxisTitles(),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 44,
                    getTitlesWidget: (v, meta) => SideTitleWidget(
                        meta: meta, child: Text(fmtCompact(v), style: labelStyle)),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 26,
                    getTitlesWidget: (v, meta) => SideTitleWidget(
                        meta: meta, child: Text(groups[v.toInt()].$1, style: labelStyle)),
                  ),
                ),
              ),
              barTouchData: BarTouchData(
                touchTooltipData: BarTouchTooltipData(
                  getTooltipColor: (_) => scheme.inverseSurface,
                  getTooltipItem: (group, gi, r, ri) => BarTooltipItem(
                    '${ri == 0 ? 'So far' : 'Projected'}\n${fmtMoney(r.toY, symbol: symbol)}',
                    TextStyle(color: scheme.onInverseSurface, fontSize: 12),
                  ),
                ),
              ),
              barGroups: [
                for (var i = 0; i < groups.length; i++)
                  BarChartGroupData(x: i, barsSpace: 6, barRods: [
                    rod(groups[i].$2, groups[i].$4.withValues(alpha: 0.35)),
                    rod(groups[i].$3, groups[i].$4),
                  ]),
              ],
            )),
          ),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _Legend(color: scheme.onSurfaceVariant.withValues(alpha: 0.35), label: 'So far'),
            const SizedBox(width: 20),
            _Legend(color: scheme.onSurfaceVariant, label: 'Projected end of month'),
          ]),
        ]),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
        ),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.labelMedium),
      ]);
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      color: scheme.secondaryContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.info_outline, size: 18, color: scheme.onSecondaryContainer),
            const SizedBox(width: 8),
            Text('How this is calculated',
                style: t.titleSmall?.copyWith(color: scheme.onSecondaryContainer)),
          ]),
          const SizedBox(height: 8),
          Text(
            'Expenses: what you have spent so far, plus your average daily spending for '
            'each remaining day, plus automatic recurring bills still due this month.\n\n'
            'Income is counted conservatively: only 30% of your average daily income '
            'is assumed for the remaining days, plus automatic recurring income still due. '
            'Irregular income is not assumed to repeat.',
            style: t.bodySmall?.copyWith(color: scheme.onSecondaryContainer),
          ),
        ]),
      ),
    );
  }
}
