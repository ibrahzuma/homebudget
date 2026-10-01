import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../budgets/budgets_screen.dart';
import '../debts/debts_screen.dart';
import '../forecast/forecast_screen.dart';
import '../goals/goals_screen.dart';
import '../lent/lent_screen.dart';
import '../meetings/meetings_screen.dart';
import '../networth/networth_screen.dart';
import '../recurring/recurring_screen.dart';
import '../requests/requests_screen.dart';
import '../shell.dart';
import '../transactions/transaction_detail_screen.dart';
import '../transactions/transaction_tile.dart';

// Building blocks of the dashboard, top to bottom.

String _sym(BuildContext context) => context.watch<Session>().currencySymbol;

TextStyle? _muted(BuildContext context) =>
    Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.muted);

/// "See all"-style link for section headers.
class _HeaderLink extends StatelessWidget {
  const _HeaderLink(this.label, this.onTap);
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) =>
      TextButton(onPressed: onTap, child: Text(label));
}

/// A card whose rows are separated by thin dividers.
class _ListCard extends StatelessWidget {
  const _ListCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
            children[i],
          ],
        ]),
      );
}

/// Placeholder row for an empty section, with an optional call to action.
class _EmptyRow extends StatelessWidget {
  const _EmptyRow(this.text, {this.action, this.onAction});
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(children: [
            Expanded(child: Text(text, style: const TextStyle(color: AppColors.muted))),
            if (action != null) TextButton(onPressed: onAction, child: Text(action!)),
          ]),
        ),
      );
}

class MonthHeader extends StatelessWidget {
  const MonthHeader({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
        child: Text(label,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: AppColors.muted, fontWeight: FontWeight.w500)),
      );
}

// ---------------------------------------------------------------- approvals

class ApprovalsCard extends StatelessWidget {
  const ApprovalsCard({super.key, required this.requests, required this.onReturn});
  final List<MoneyRequest> requests;
  final VoidCallback onReturn;

  @override
  Widget build(BuildContext context) {
    final sym = _sym(context);
    final n = requests.length;
    return Card(
      color: AppColors.warning.withValues(alpha: 0.10),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(children: [
            const Icon(Icons.hourglass_top, color: AppColors.warning),
            const SizedBox(width: 10),
            Expanded(
              child: Text('$n request${n == 1 ? '' : 's'} waiting for your approval',
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            _HeaderLink('Review', () => AppShell.of(context)?.goTo(AppTab.requests)),
          ]),
        ),
        for (final r in requests)
          ListTile(
            leading: CircleAvatar(child: Text(r.requester.username.substring(0, 1).toUpperCase())),
            title: Text(r.purpose, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${r.requester.username} · ${fmtDateShort(r.createdAt)}'),
            trailing: Text(fmtIn(r.amount, r.currency, sym),
                style: const TextStyle(fontWeight: FontWeight.w700)),
            onTap: () async {
              await push(context, RequestDetailScreen(id: r.id));
              onReturn();
            },
          ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- totals

class MonthTotals extends StatelessWidget {
  const MonthTotals({super.key, required this.data});
  final Dashboard data;

  @override
  Widget build(BuildContext context) {
    final sym = _sym(context);
    final d = data;
    final spentPct = d.totalIncome > 0 ? d.totalExpense / d.totalIncome * 100 : null;
    return Column(children: [
      StatRow(children: [
        StatTile(
            label: 'Income',
            icon: Icons.south_west,
            value: fmtMoney(d.totalIncome, symbol: sym),
            color: AppColors.income),
        StatTile(
            label: 'Expenses',
            icon: Icons.north_east,
            value: fmtMoney(d.totalExpense, symbol: sym),
            color: AppColors.expense),
        StatTile(
            label: 'Balance',
            icon: Icons.account_balance_wallet_outlined,
            value: fmtMoney(d.balance, symbol: sym),
            color: d.balance < 0 ? AppColors.expense : AppColors.income),
      ]),
      if (spentPct != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Row(children: [
            Expanded(child: ProgressLine(percent: spentPct, height: 6)),
            const SizedBox(width: 10),
            Text('${fmtPct(spentPct)} of income spent', style: _muted(context)),
          ]),
        ),
    ]);
  }
}

// ---------------------------------------------------------------- members

const _memberColors = [Color(0xFF0F766E), Color(0xFFFD7E14), Color(0xFF6F42C1), Color(0xFF0D6EFD)];

class MemberSplitCard extends StatelessWidget {
  const MemberSplitCard({super.key, required this.members, required this.data});
  final List<MemberRow> members;
  final Dashboard data;

  @override
  Widget build(BuildContext context) {
    final sym = _sym(context);
    final byExpense = data.totalExpense > 0;
    final showChart = byExpense || data.totalIncome > 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionHeader('By member'),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            if (showChart) ...[
              _MemberDonut(members: members, byExpense: byExpense),
              const SizedBox(width: 16),
            ],
            Expanded(
              child: Column(children: [
                for (var i = 0; i < members.length; i++)
                  _MemberLine(
                    row: members[i],
                    color: _memberColors[i % _memberColors.length],
                    symbol: sym,
                  ),
              ]),
            ),
          ]),
        ),
      ),
    ]);
  }
}

class _MemberDonut extends StatelessWidget {
  const _MemberDonut({required this.members, required this.byExpense});
  final List<MemberRow> members;
  final bool byExpense;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 96,
      height: 96,
      child: Stack(alignment: Alignment.center, children: [
        PieChart(PieChartData(
          sectionsSpace: 2,
          centerSpaceRadius: 30,
          startDegreeOffset: -90,
          sections: [
            for (var i = 0; i < members.length; i++)
              PieChartSectionData(
                value: byExpense ? members[i].expense : members[i].income,
                color: _memberColors[i % _memberColors.length],
                radius: 14,
                showTitle: false,
              ),
          ],
        )),
        Text(byExpense ? 'Spent' : 'Earned', style: _muted(context)),
      ]),
    );
  }
}

class _MemberLine extends StatelessWidget {
  const _MemberLine({required this.row, required this.color, required this.symbol});
  final MemberRow row;
  final Color color;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
              width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Expanded(child: Text(row.user.username, style: t.titleSmall)),
          Text(fmtMoney(row.net, symbol: symbol, signed: true),
              style: t.labelLarge?.copyWith(
                  color: row.net < 0 ? AppColors.expense : AppColors.income)),
        ]),
        const SizedBox(height: 2),
        Padding(
          padding: const EdgeInsets.only(left: 18),
          child: Text(
            'In ${fmtMoney(row.income, symbol: symbol)} (${fmtPct(row.incomeSharePct)}) · '
            'Out ${fmtMoney(row.expense, symbol: symbol)} (${fmtPct(row.expenseSharePct)})',
            style: _muted(context),
          ),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- forecast

class ForecastCard extends StatelessWidget {
  const ForecastCard({super.key, required this.forecast});
  final Forecast forecast;

  @override
  Widget build(BuildContext context) {
    final sym = _sym(context);
    final f = forecast;
    final t = Theme.of(context).textTheme;
    final elapsed = f.daysTotal == 0 ? 0.0 : f.daysElapsed / f.daysTotal * 100;

    Widget figure(String label, String value, [Color? color]) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: _muted(context)),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value,
                  style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700, color: color)),
            ),
          ]),
        );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionHeader('End-of-month forecast'),
      Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => push(context, const ForecastScreen()),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text('Based on your spending rate and upcoming recurring bills',
                      style: _muted(context)),
                ),
                const Icon(Icons.chevron_right, color: AppColors.muted),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                figure('Days left', '${f.daysRemaining} / ${f.daysTotal}'),
                figure('Daily burn', fmtMoney(f.dailyBurn, symbol: sym)),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                figure('Projected expenses', fmtMoney(f.projectedExpense, symbol: sym),
                    AppColors.expense),
                figure(
                    'Projected balance',
                    fmtMoney(f.projectedBalance, symbol: sym),
                    f.projectedBalance < 0 ? AppColors.expense : AppColors.income),
              ]),
              const SizedBox(height: 14),
              ProgressLine(
                  percent: elapsed,
                  height: 6,
                  color: Theme.of(context).colorScheme.primary),
            ]),
          ),
        ),
      ),
    ]);
  }
}

// ---------------------------------------------------------------- meeting

class NextMeetingCard extends StatelessWidget {
  const NextMeetingCard({super.key, required this.meeting});
  final Meeting meeting;

  @override
  Widget build(BuildContext context) {
    final m = meeting;
    final days = DateUtils.dateOnly(m.meetingDate)
        .difference(DateUtils.dateOnly(DateTime.now()))
        .inDays;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      color: AppColors.info.withValues(alpha: 0.07),
      child: ListTile(
        leading: const Icon(Icons.groups_outlined, color: AppColors.info),
        title: Text('Next meeting: ${m.title}', maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
            '${DateFormat('EEEE, d MMM').format(m.meetingDate)} · ${fmtRelativeDays(days)}'
            '${m.openCount > 0 ? ' · ${m.openCount} open item${m.openCount == 1 ? '' : 's'}' : ''}'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => push(context, MeetingDetailScreen(id: m.id)),
      ),
    );
  }
}

// ---------------------------------------------------------------- net worth

class NetWorthCard extends StatelessWidget {
  const NetWorthCard({super.key, required this.data});
  final Dashboard data;

  @override
  Widget build(BuildContext context) {
    final sym = _sym(context);
    final nw = data.networth;
    final t = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionHeader('Net worth'),
      Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => push(context, const NetWorthScreen()),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(fmtMoney(nw.netWorth, symbol: sym),
                        style: t.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: nw.netWorth < 0 ? AppColors.expense : null)),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Assets ${fmtMoney(nw.totalAssets + nw.totalReceivables, symbol: sym)} · '
                    'Liabilities ${fmtMoney(nw.totalLiabilities, symbol: sym)}',
                    style: _muted(context),
                  ),
                ]),
              ),
              const Icon(Icons.chevron_right, color: AppColors.muted),
            ]),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
        child: Row(children: [
          Expanded(
            child: _MiniLinkTile(
              label: 'Lent out (owed to us)',
              value: fmtMoney(data.totalLentOut, symbol: sym),
              color: AppColors.income,
              note: data.overdueLent > 0 ? '${data.overdueLent} overdue' : null,
              onTap: () => push(context, const LentScreen()),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _MiniLinkTile(
              label: 'Owed (we owe)',
              value: fmtMoney(data.totalOwed, symbol: sym),
              color: AppColors.expense,
              onTap: () => push(context, const DebtsScreen()),
            ),
          ),
        ]),
      ),
    ]);
  }
}

class _MiniLinkTile extends StatelessWidget {
  const _MiniLinkTile({
    required this.label,
    required this.value,
    required this.color,
    required this.onTap,
    this.note,
  });
  final String label;
  final String value;
  final Color color;
  final VoidCallback onTap;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: _muted(context), maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value,
                  style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700, color: color)),
            ),
            if (note != null) ...[
              const SizedBox(height: 4),
              StatusChip(note!, color: AppColors.warning),
            ],
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- budgets

class BudgetsSection extends StatelessWidget {
  const BudgetsSection({super.key, required this.budgets});
  final List<BudgetRow> budgets;

  @override
  Widget build(BuildContext context) {
    final sym = _sym(context);
    void open() => push(context, const BudgetsScreen());
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader('Budget progress', trailing: _HeaderLink('Manage', open)),
      if (budgets.isEmpty)
        _EmptyRow('No budgets for this month.', action: 'Create one', onAction: open)
      else
        _ListCard(children: [
          for (final b in budgets) _BudgetLine(budget: b, symbol: sym, onTap: open),
        ]),
    ]);
  }
}

class _BudgetLine extends StatelessWidget {
  const _BudgetLine({required this.budget, required this.symbol, required this.onTap});
  final BudgetRow budget;
  final String symbol;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final b = budget;
    final t = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Column(children: [
          Row(children: [
            IconBadge(icon: b.category.icon, color: b.category.color, size: 28),
            const SizedBox(width: 10),
            Expanded(child: Text(b.category.name, style: t.bodyMedium)),
            Text(
              '${fmtMoney(b.spent, symbol: symbol)} / ${fmtMoney(b.limit, symbol: symbol)}',
              style: t.bodySmall?.copyWith(
                color: b.over ? AppColors.expense : AppColors.muted,
                fontWeight: b.over ? FontWeight.w700 : null,
              ),
            ),
          ]),
          const SizedBox(height: 8),
          ProgressLine(percent: b.pct ?? 0, height: 6, color: b.over ? AppColors.expense : null),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- goals

class GoalsSection extends StatelessWidget {
  const GoalsSection({super.key, required this.goals});
  final List<Goal> goals;

  @override
  Widget build(BuildContext context) {
    void open() => push(context, const GoalsScreen());
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader('Savings goals', trailing: _HeaderLink('All', open)),
      if (goals.isEmpty)
        _EmptyRow('No active goals.', action: 'Add one', onAction: open)
      else
        _ListCard(children: [for (final g in goals) _GoalLine(goal: g, onTap: open)]),
    ]);
  }
}

class _GoalLine extends StatelessWidget {
  const _GoalLine({required this.goal, required this.onTap});
  final Goal goal;
  final VoidCallback onTap;

  (String, Color)? _status(String sym) {
    final g = goal;
    if (g.targetDate == null) return null;
    final month = DateFormat('MMM yyyy').format(g.targetDate!);
    return switch (g.onTrack) {
      true => ('On track for $month', AppColors.income),
      false => (
          'Need ${fmtIn(g.monthlyNeeded, g.currency, sym)}/mo to hit target',
          AppColors.warning
        ),
      null => ('Target $month', AppColors.muted),
    };
  }

  @override
  Widget build(BuildContext context) {
    final sym = _sym(context);
    final g = goal;
    final t = Theme.of(context).textTheme;
    final status = _status(sym);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            IconBadge(icon: g.icon, color: g.color, size: 28),
            const SizedBox(width: 10),
            Expanded(child: Text(g.name, style: t.bodyMedium)),
            Text(
              '${fmtIn(g.currentAmount, g.currency, sym)} / ${fmtIn(g.targetAmount, g.currency, sym)}',
              style: _muted(context),
            ),
          ]),
          const SizedBox(height: 8),
          ProgressLine(percent: g.progressPercent, height: 6, color: hexColor(g.color)),
          if (status != null) ...[
            const SizedBox(height: 6),
            Text(status.$1, style: t.bodySmall?.copyWith(color: status.$2)),
          ],
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- upcoming

class UpcomingSection extends StatelessWidget {
  const UpcomingSection({super.key, required this.items});
  final List<Recurring> items;

  @override
  Widget build(BuildContext context) {
    void open() => push(context, const RecurringScreen());
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader('Upcoming · next 7 days', trailing: _HeaderLink('Recurring', open)),
      if (items.isEmpty)
        const _EmptyRow('Nothing due in the next 7 days.')
      else
        _ListCard(children: [for (final r in items) _UpcomingTile(item: r, onTap: open)]),
    ]);
  }
}

class _UpcomingTile extends StatelessWidget {
  const _UpcomingTile({required this.item, required this.onTap});
  final Recurring item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final r = item;
    final income = r.type == 'income';
    final due = switch (r.daysUntilDue) {
      0 => 'Today',
      1 => 'Tomorrow',
      final n when n < 0 => 'Overdue',
      final n => 'In $n days',
    };
    return ListTile(
      onTap: onTap,
      leading: IconBadge(
        icon: r.category?.icon,
        iconData: r.category == null ? Icons.repeat : null,
        color: r.category?.color,
        size: 36,
      ),
      title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('$due · ${fmtDateShort(r.nextDueDate)}',
          style: TextStyle(color: r.daysUntilDue <= 0 ? AppColors.warning : null)),
      trailing: Text(
        fmtIn(income ? r.amount : -r.amount, r.currency, _sym(context), signed: true),
        style: TextStyle(
            fontWeight: FontWeight.w700, color: income ? AppColors.income : AppColors.expense),
      ),
    );
  }
}

// ---------------------------------------------------------------- recent

class RecentSection extends StatelessWidget {
  const RecentSection({super.key, required this.items});
  final List<Txn> items;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader('Recent activity',
          trailing: _HeaderLink('All', () => AppShell.of(context)?.goTo(AppTab.transactions))),
      if (items.isEmpty)
        const _EmptyRow('No transactions this month yet.')
      else
        _ListCard(children: [
          for (final t in items)
            TransactionTile(
              txn: t,
              showDate: true,
              onTap: () => push(context, TransactionDetailScreen(id: t.id)),
            ),
        ]),
    ]);
  }
}
