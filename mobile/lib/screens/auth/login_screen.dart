import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api.dart';
import '../../core/session.dart';
import 'signup_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_user.text.trim().isEmpty || _pass.text.isEmpty) {
      setState(() => _error = 'Enter your username and password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<Session>().login(_user.text.trim(), _pass.text);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Icon(Icons.account_balance_wallet_rounded, size: 56, color: t.colorScheme.primary),
                  const SizedBox(height: 12),
                  Text('Home Budget',
                      textAlign: TextAlign.center,
                      style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text('Sign in with your budget.hotone.co.tz account',
                      textAlign: TextAlign.center,
                      style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.outline)),
                  const SizedBox(height: 32),
                  if (_error != null) ...[
                    Text(_error!, style: TextStyle(color: t.colorScheme.error)),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    controller: _user,
                    autofillHints: const [AutofillHints.username],
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    decoration: const InputDecoration(
                        labelText: 'Username', prefixIcon: Icon(Icons.person_outline)),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _pass,
                    obscureText: _obscure,
                    autofillHints: const [AutofillHints.password],
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    child: _busy
                        ? const SizedBox(
                            width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Sign in'),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const SignupScreen())),
                    child: const Text("New here? Create an account"),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
