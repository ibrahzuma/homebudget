import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/push.dart';
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
  StreamSubscription<PushTap>? _taps;

  void goTo(AppTab tab) => setState(() => _tab = tab);

  @override
  void initState() {
    super.initState();
    final push = context.read<PushService>();
    _taps = push.taps.listen(_open);
    // A notification the user tapped to launch the app, held until now.
    final launch = push.takeLaunchTap();
    if (launch != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _open(launch));
    }
  }

  @override
  void dispose() {
    _taps?.cancel();
    super.dispose();
  }

  /// Show whatever a tapped notification was about.
  Future<void> _open(PushTap tap) async {
    if (!mounted) return;
    if (tap.isChat) {
      goTo(AppTab.chat);
      return;
    }
    if (!tap.isRequest) return;
    goTo(AppTab.requests);
    final id = tap.requestId;
    if (id == null) return;
    await push(context, RequestDetailScreen(id: id));
    if (!mounted) return;
    context.read<Session>().refreshBadges();
  }

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
