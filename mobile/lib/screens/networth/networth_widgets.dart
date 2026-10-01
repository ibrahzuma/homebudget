import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../widgets/common.dart';
import '../debts/debts_screen.dart' show liabilityIcon;
import 'finance_shared.dart';

/// The big net worth number.
class NetWorthHeadline extends StatelessWidget {
  const NetWorthHeadline({super.key, required this.data, required this.symbol});
  final NetWorth data;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final last = data.snapshots.isEmpty ? null : data.snapshots.last;
    final change = last == null ? null : data.netWorth - last.netWorth;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          HeadlineAmount(
            caption: 'Net worth',
            amount: fmtMoney(data.netWorth, symbol: symbol),
            color: data.netWorth < 0 ? AppColors.expense : AppColors.income,
          ),
          const SizedBox(height: 4),
          Text('Assets + money lent − liabilities, in your base currency.',
              style: t.bodySmall?.copyWith(color: AppColors.muted)),
          if (change != null && change != 0) ...[
            const SizedBox(height: 8),
            Row(children: [
              Icon(change > 0 ? Icons.trending_up : Icons.trending_down,
                  size: 18, color: change > 0 ? AppColors.income : AppColors.expense),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${fmtMoney(change, symbol: symbol, signed: true)} since snapshot on ${fmtDate(last!.date)}',
                  style: t.bodySmall,
                ),
              ),
            ]),
          ],
        ]),
      ),
    );
  }
}

/// Net worth, assets and liabilities across saved snapshots.
class SnapshotChartCard extends StatelessWidget {
  const SnapshotChartCard({super.key, required this.snapshots, required this.symbol});
  final List<Snapshot> snapshots;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    if (snapshots.isEmpty) {
      return const Card(
        margin: EdgeInsets.symmetric(horizontal: 16),
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'No snapshots yet. Save one now and then (say monthly) to see how your net worth changes.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.muted),
          ),
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 16, 16, 12),
        child: Column(children: [
          SizedBox(height: 220, child: _SnapshotChart(snapshots: snapshots, symbol: symbol)),
          const SizedBox(height: 12),
          Wrap(spacing: 16, runSpacing: 6, alignment: WrapAlignment.center, children: [
            LegendDot(color: scheme.primary, label: 'Net worth'),
            const LegendDot(color: AppColors.income, label: 'Assets', dashed: true),
            const LegendDot(color: AppColors.expense, label: 'Liabilities', dashed: true),
          ]),
        ]),
      ),
    );
  }
}

class _SnapshotChart extends StatelessWidget {
  const _SnapshotChart({required this.snapshots, required this.symbol});
  final List<Snapshot> snapshots;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final labelStyle = TextStyle(fontSize: 10, color: scheme.onSurfaceVariant);
    final values = [
      for (final s in snapshots) ...[s.netWorth, s.totalAssets, s.totalLiabilities],
    ];
    var minY = math.min(0.0, values.reduce(math.min));
    var maxY = values.reduce(math.max);
    if (maxY == minY) maxY = minY + 1;
    final pad = (maxY - minY) * 0.08;
    minY = minY < 0 ? minY - pad : minY;
    maxY += pad;

    LineChartBarData line(double Function(Snapshot) pick, Color color,
            {bool dashed = false, bool fill = false}) =>
        LineChartBarData(
          spots: [
            for (var i = 0; i < snapshots.length; i++) FlSpot(i.toDouble(), pick(snapshots[i])),
          ],
          isCurved: true,
          preventCurveOverShooting: true,
          color: color,
          barWidth: dashed ? 2 : 3,
          dashArray: dashed ? [6, 4] : null,
          dotData: FlDotData(show: snapshots.length < 2),
          belowBarData: BarAreaData(show: fill, color: color.withValues(alpha: 0.12)),
        );

    final step = math.max(1, (snapshots.length / 4).ceil());
    final dateFmt = DateFormat('MMM d');
    return LineChart(LineChartData(
      minY: minY,
      maxY: maxY,
      minX: 0,
      maxX: math.max(1, snapshots.length - 1).toDouble(),
      gridData: FlGridData(
        drawVerticalLine: false,
        getDrawingHorizontalLine: (_) =>
            FlLine(color: scheme.outlineVariant.withValues(alpha: 0.5), strokeWidth: 1),
      ),
      borderData: FlBorderData(show: false),
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
            interval: 1,
            reservedSize: 24,
            getTitlesWidget: (v, meta) {
              final i = v.round();
              if (v != i || i < 0 || i >= snapshots.length || i % step != 0) {
                return const SizedBox.shrink();
              }
              return SideTitleWidget(
                  meta: meta, child: Text(dateFmt.format(snapshots[i].date), style: labelStyle));
            },
          ),
        ),
      ),
      lineTouchData: LineTouchData(
        touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => scheme.inverseSurface,
          fitInsideHorizontally: true,
          getTooltipItems: (spots) => [
            for (final s in spots)
              LineTooltipItem(
                '${const ['Net worth', 'Assets', 'Liabilities'][s.barIndex]}: '
                '${fmtMoney(s.y, symbol: symbol)}'
                '${s.barIndex == 0 ? '\n${fmtDate(snapshots[s.x.round()].date)}' : ''}',
                TextStyle(color: scheme.onInverseSurface, fontSize: 12),
              ),
          ],
        ),
      ),
      lineBarsData: [
        line((s) => s.netWorth, scheme.primary, fill: true),
        line((s) => s.totalAssets, AppColors.income, dashed: true),
        line((s) => s.totalLiabilities, AppColors.expense, dashed: true),
      ],
    ));
  }
}

/// Horizontal share bars for a {label: amount} breakdown.
class BreakdownCard extends StatelessWidget {
  const BreakdownCard({
    super.key,
    required this.values,
    required this.color,
    required this.symbol,
  });
  final Map<String, double> values;
  final Color color;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final entries = values.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final total = entries.fold<double>(0, (s, e) => s + e.value);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(children: [
          for (final e in entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(e.key, style: t.bodyMedium)),
                  Text(fmtMoney(e.value, symbol: symbol),
                      style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                  SizedBox(
                    width: 48,
                    child: Text(fmtPct(total == 0 ? 0 : e.value / total * 100),
                        textAlign: TextAlign.end,
                        style: t.bodySmall?.copyWith(color: AppColors.muted)),
                  ),
                ]),
                const SizedBox(height: 4),
                ProgressLine(
                    percent: total == 0 ? 0 : e.value / total * 100, color: color, height: 6),
              ]),
            ),
        ]),
      ),
    );
  }
}

/// Liabilities total, by type, and the largest few; links to the debts screen.
class LiabilitySummaryCard extends StatelessWidget {
  const LiabilitySummaryCard({
    super.key,
    required this.data,
    required this.symbol,
    required this.onOpen,
  });
  final NetWorth data;
  final String symbol;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final top = [...data.liabilities]..sort((a, b) => b.balance.compareTo(a.balance));
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(children: [
            if (top.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('No debts recorded.', style: TextStyle(color: AppColors.muted)),
              ),
            for (final e in data.liabilitiesByType.entries)
              ListTile(
                dense: true,
                title: Text(e.key),
                trailing: Text(fmtMoney(e.value, symbol: symbol),
                    style: t.bodyMedium?.copyWith(
                        color: AppColors.expense, fontWeight: FontWeight.w600)),
              ),
            if (top.isNotEmpty) const Divider(height: 8),
            for (final l in top.take(3))
              ListTile(
                leading: Icon(liabilityIcon(l.liabilityType), color: AppColors.expense),
                title: Text(l.name),
                subtitle: Text([
                  l.liabilityTypeDisplay,
                  if (l.lender.isNotEmpty) l.lender,
                  if (l.interestRate != null && l.interestRate! > 0) '${l.interestRate}% APR',
                ].join(' · ')),
                trailing: Text(fmtIn(l.balance, l.currency, symbol),
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(children: [
                Text(
                    top.length > 3
                        ? 'View all ${top.length} debts and payments'
                        : 'View debts and payments',
                    style: t.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary)),
                const Spacer(),
                Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.primary),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
