import 'package:flutter/material.dart';

import '../widgets/common.dart';
import 'alerts/alerts_screen.dart';
import 'budgets/budgets_screen.dart';
import 'categories/categories_screen.dart';
import 'forecast/forecast_screen.dart';
import 'goals/goals_screen.dart';
import 'networth/networth_screen.dart';
import 'recurring/recurring_screen.dart';
import 'shell.dart';
import 'household/household_settings_screen.dart';
import 'meetings/meetings_screen.dart';
import 'requests/requests_screen.dart';

/// Opens the in-app screen for a web path stored on alerts and push events
/// (`link_url` / `link`), e.g. `/requests/12/`, `/budgets/`, `/meetings/3/`.
/// Returns false when there's no matching screen.
bool openWebLink(BuildContext context, String? url) {
  if (url == null || url.isEmpty) return false;
  final parts = Uri.parse(url).pathSegments.where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return false;
  if (parts.first == 'transactions') {
    final shell = AppShell.of(context);
    if (shell == null) return false;
    Navigator.of(context).popUntil((r) => r.isFirst);
    shell.goTo(AppTab.transactions);
    return true;
  }
  final id = parts.length > 1 ? int.tryParse(parts[1]) : null;

  final Widget? screen = switch (parts.first) {
    'requests' when id != null => RequestDetailScreen(id: id),
    'requests' => const RequestsScreen(),
    'meetings' when id != null => MeetingDetailScreen(id: id),
    'meetings' => const MeetingsScreen(),
    'budgets' => const BudgetsScreen(),
    'goals' => const GoalsScreen(),
    'networth' => const NetWorthScreen(),
    'forecast' => const ForecastScreen(),
    'recurring' => const RecurringScreen(),
    'categories' => const CategoriesScreen(),
    'alerts' => const AlertsScreen(),
    'household' => const HouseholdSettingsScreen(),
    _ => null,
  };
  if (screen == null) return false;
  push(context, screen);
  return true;
}
