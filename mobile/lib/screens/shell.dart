import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/session.dart';
import '../widgets/common.dart';
import 'chat/chat_screen.dart';
import 'dashboard/dashboard_screen.dart';
import 'more_screen.dart';
import 'requests/requests_screen.dart';
import 'transactions/transactions_screen.dart';

/// Bottom-tab shell: Home, Transactions, Requests, Chat, More.
/// Each tab is its own Scaffold; tabs stay alive in an IndexedStack.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  /// Switch tabs from anywhere below the shell, e.g.
  /// `AppShell.of(context)?.goTo(AppTab.requests)`.
  static AppShellState? of(BuildContext context) => context.findAncestorStateOfType<AppShellState>();

  @override
  State<AppShell> createState() => AppShellState();
}

enum AppTab { home, transactions, requests, chat, more }

class AppShellState extends State<AppShell> {
  AppTab _tab = AppTab.home;

  void goTo(AppTab tab) => setState(() => _tab = tab);

  @override
  Widget build(BuildContext context) {
    final badges = context.watch<Session>().badges;
    return Scaffold(
      body: IndexedStack(
        index: _tab.index,
        children: const [
          DashboardScreen(),
          TransactionsScreen(),
          RequestsScreen(),
          ChatScreen(),
          MoreScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab.index,
        onDestinationSelected: (i) => goTo(AppTab.values[i]),
        destinations: [
          const NavigationDestination(
              icon: Icon(Icons.dashboard_outlined),
              selectedIcon: Icon(Icons.dashboard),
              label: 'Home'),
          const NavigationDestination(
              icon: Icon(Icons.receipt_long_outlined),
              selectedIcon: Icon(Icons.receipt_long),
              label: 'Transactions'),
          NavigationDestination(
              icon: CountBadge(
                  count: badges.pendingRequests, child: const Icon(Icons.swap_horiz_outlined)),
              selectedIcon:
                  CountBadge(count: badges.pendingRequests, child: const Icon(Icons.swap_horiz)),
              label: 'Requests'),
          NavigationDestination(
              icon: CountBadge(
                  count: badges.unreadChat, child: const Icon(Icons.chat_bubble_outline)),
              selectedIcon: CountBadge(count: badges.unreadChat, child: const Icon(Icons.chat_bubble)),
              label: 'Chat'),
          NavigationDestination(
              icon: CountBadge(count: badges.unreadAlerts, child: const Icon(Icons.menu)),
              label: 'More'),
        ],
      ),
    );
  }
}
