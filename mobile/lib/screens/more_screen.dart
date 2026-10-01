import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/config.dart';
import '../core/session.dart';
import '../widgets/common.dart';
import 'alerts/alerts_screen.dart';
import 'budgets/budgets_screen.dart';
import 'calendar/calendar_screen.dart';
import 'categories/categories_screen.dart';
import 'currencies/currencies_screen.dart';
import 'debts/debts_screen.dart';
import 'forecast/forecast_screen.dart';
import 'goals/goals_screen.dart';
import 'household/household_settings_screen.dart';
import 'import_export/import_export_screen.dart';
import 'lent/lent_screen.dart';
import 'meetings/meetings_screen.dart';
import 'networth/networth_screen.dart';
import 'projects/projects_screen.dart';
import 'recurring/recurring_screen.dart';
import 'reports/report_screen.dart';
import 'rules/rules_screen.dart';

/// Every section that isn't a bottom tab, grouped like the web sidebar.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final h = session.household;

    Widget item(IconData icon, String label, Widget screen, {int badge = 0}) => ListTile(
          leading: CountBadge(count: badge, child: Icon(icon)),
          title: Text(label),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => push(context, screen),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(
        children: [
          Card(
            child: ListTile(
              leading: CircleAvatar(
                  child: Text((session.user?.username ?? '?').substring(0, 1).toUpperCase())),
              title: Text(session.user?.username ?? ''),
              subtitle: Text('${h?.name ?? ''} · ${h?.currencyCode ?? ''}'
                  '${(h?.members.length ?? 0) > 1 ? ' · ${h!.members.length} members' : ''}'),
              trailing: const Icon(Icons.settings_outlined),
              onTap: () => push(context, const HouseholdSettingsScreen()),
            ),
          ),
          item(Icons.notifications_outlined, 'Alerts', const AlertsScreen(),
              badge: session.badges.unreadAlerts),
          const SectionHeader('Plan'),
          item(Icons.pie_chart_outline, 'Budgets', const BudgetsScreen()),
          item(Icons.repeat, 'Recurring', const RecurringScreen()),
          item(Icons.calendar_month_outlined, 'Cash-flow calendar', const CalendarScreen()),
          item(Icons.trending_up, 'Forecast', const ForecastScreen()),
          item(Icons.savings_outlined, 'Savings goals', const GoalsScreen()),
          item(Icons.bookmark_outline, 'Projects', const ProjectsScreen()),
          const SectionHeader('Wealth'),
          item(Icons.account_balance_outlined, 'Net worth & assets', const NetWorthScreen()),
          item(Icons.credit_card, 'Debts', const DebtsScreen()),
          item(Icons.handshake_outlined, 'Money lent', const LentScreen()),
          const SectionHeader('Household'),
          item(Icons.groups_outlined, 'Meetings', const MeetingsScreen()),
          item(Icons.bar_chart, 'Monthly report', const MonthlyReportScreen()),
          const SectionHeader('Setup'),
          item(Icons.sell_outlined, 'Categories', const CategoriesScreen()),
          item(Icons.auto_fix_high, 'Auto-categorize rules', const RulesScreen()),
          item(Icons.currency_exchange, 'Currencies & rates', const CurrenciesScreen()),
          item(Icons.import_export, 'Import / export CSV', const ImportExportScreen()),
          item(Icons.home_work_outlined, 'Household settings', const HouseholdSettingsScreen()),
          const Divider(height: 32),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sign out'),
            onTap: () async {
              if (await confirm(context,
                  title: 'Sign out?', confirmLabel: 'Sign out', destructive: false)) {
                await session.logout();
              }
            },
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Connected to ${Uri.parse(AppConfig.origin).host}',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.muted)),
          ),
        ],
      ),
    );
  }
}
