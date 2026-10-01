import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/realtime.dart';
import 'core/session.dart';
import 'screens/auth/login_screen.dart';
import 'screens/household/setup_screen.dart';
import 'screens/shell.dart';
import 'widgets/common.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final session = Session()..restore();
  runApp(HomeBudgetApp(session: session));
}

class HomeBudgetApp extends StatelessWidget {
  const HomeBudgetApp({super.key, required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: session),
        Provider<Realtime>(create: (_) => Realtime(session), dispose: (_, r) => r.dispose()),
      ],
      child: MaterialApp(
        title: 'Home Budget',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        home: const AuthGate(),
      ),
    );
  }
}

ThemeData _theme(Brightness b) {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF0F766E), brightness: b);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    cardTheme: CardThemeData(
      elevation: 0,
      color: b == Brightness.light ? Colors.white : scheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    ),
    scaffoldBackgroundColor: b == Brightness.light ? const Color(0xFFF6F7F9) : null,
    appBarTheme: AppBarTheme(
      centerTitle: false,
      backgroundColor: b == Brightness.light ? const Color(0xFFF6F7F9) : null,
      scrolledUnderElevation: 1,
    ),
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
  );
}

/// Routes between sign-in, household setup and the app, and keeps the
/// realtime socket connected only while signed in.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  SessionState? _last;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final rt = context.read<Realtime>();
    if (session.state != _last) {
      _last = session.state;
      if (session.state == SessionState.ready) {
        rt.connect();
      } else {
        rt.disconnect();
      }
    }

    switch (session.state) {
      case SessionState.loading:
        if (session.startupError != null) {
          return Scaffold(
            body: ErrorState(error: session.startupError, onRetry: session.restore),
          );
        }
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      case SessionState.signedOut:
        return const LoginScreen();
      case SessionState.needsHousehold:
        return const HouseholdSetupScreen();
      case SessionState.ready:
        return const AppShell();
    }
  }
}
