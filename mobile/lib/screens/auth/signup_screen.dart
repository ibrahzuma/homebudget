import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/session.dart';
import '../../widgets/entity_form.dart';

/// Account creation. An invite code (or a pasted invite link) joins the
/// partner's household directly instead of creating a new one.
class SignupScreen extends StatelessWidget {
  const SignupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.read<Session>();
    return EntityFormScreen(
      title: 'Create account',
      submitLabel: 'Create account',
      intro: const Padding(
        padding: EdgeInsets.only(bottom: 4),
        child: Text('Got an invite from your partner? Paste the code or link below and '
            "you'll join their household straight away."),
      ),
      fields: const [
        FieldSpec.text('username', 'Username', required: true,
            keyboard: TextInputType.emailAddress),
        FieldSpec.text('email', 'Email', required: true, keyboard: TextInputType.emailAddress),
        FieldSpec.text('password1', 'Password', required: true,
            obscure: true),
        FieldSpec.text('password2', 'Confirm password', required: true,
            obscure: true),
        FieldSpec.text('invite', 'Invite code or link (optional)'),
      ],
      onSubmit: (v) async {
        final invite = (v['invite'] as String? ?? '').trim();
        await session.signup(
          username: v['username'] as String,
          email: v['email'] as String,
          password1: v['password1'] as String,
          password2: v['password2'] as String,
          invite: invite.isEmpty ? null : invite.replaceAll(RegExp(r'/+$'), '').split('/').last,
        );
      },
    );
  }
}
