import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/api.dart';
import '../../core/config.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';

/// Household name, base currency, members and partner invite links.
class HouseholdSettingsScreen extends StatefulWidget {
  const HouseholdSettingsScreen({super.key});

  @override
  State<HouseholdSettingsScreen> createState() => _HouseholdSettingsScreenState();
}

class _HouseholdSettingsScreenState extends State<HouseholdSettingsScreen> {
  final _loader = GlobalKey<LoadBuilderState<HouseholdSettings>>();

  Session get _session => context.read<Session>();

  Future<HouseholdSettings> _load() async =>
      HouseholdSettings.fromJson(await _session.api.get('household/') as Map<String, dynamic>);

  /// Reload this screen and, when membership/currency changed, the session.
  Future<void> _refresh({bool householdChanged = false}) async {
    await _loader.currentState?.reload();
    if (householdChanged) {
      try {
        await _session.householdChanged();
      } catch (_) {
        // The screen already shows fresh data; the session catches up later.
      }
    }
  }

  /// Field errors (e.g. `username`) read better than the generic message.
  void _showApiError(Object e) {
    if (!mounted) return;
    if (e is ApiException) {
      final first = e.fieldErrors.values.where((v) => v.isNotEmpty).firstOrNull;
      showError(context, first?.first ?? e.message);
    } else {
      showError(context, e);
    }
  }

  // ---- household ----

  Future<void> _rename(Household h) async {
    final name = await promptText(context,
        title: 'Rename household', label: 'Household name', initial: h.name, okLabel: 'Save');
    if (name == null || name.isEmpty || name == h.name || !mounted) return;
    try {
      await _session.api.patch('household/', {'name': name});
      if (mounted) showOk(context, 'Household renamed');
      await _refresh(householdChanged: true);
    } catch (e) {
      _showApiError(e);
    }
  }

  Future<void> _changeCurrency(Household h) async {
    final Meta meta;
    try {
      meta = await _ensureMeta();
    } catch (e) {
      _showApiError(e);
      return;
    }
    if (!mounted) return;
    final picked = await showDialog<Currency>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Base currency'),
        children: [
          for (final c in meta.currencies)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, c),
              child: Row(children: [
                SizedBox(width: 56, child: Text(c.code, style: const TextStyle(fontWeight: FontWeight.w600))),
                Expanded(child: Text('${c.name} (${c.symbol})')),
                if (c.id == h.baseCurrency?.id) const Icon(Icons.check, size: 20),
              ]),
            ),
        ],
      ),
    );
    if (picked == null || picked.id == h.baseCurrency?.id || !mounted) return;
    try {
      await _session.api.patch('household/', {'base_currency': picked.id});
      if (mounted) showOk(context, 'Base currency updated to ${picked.code}');
      await _refresh(householdChanged: true);
    } catch (e) {
      _showApiError(e);
    }
  }

  Future<Meta> _ensureMeta() async {
    if (_session.meta == null) await _session.refreshMeta();
    return _session.meta!;
  }

  // ---- members ----

  Future<void> _addMember() async {
    final username = await promptText(context,
        title: 'Add by username', label: "Your partner's username", okLabel: 'Add');
    if (username == null || username.isEmpty || !mounted) return;
    try {
      final res = await _session.api.post('household/members/', {'username': username})
          as Map<String, dynamic>;
      final notice = res['notice'] as String? ?? '$username added.';
      if (!mounted) return;
      if (res['level'] == 'warning') {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Member added'),
            content: Text(notice),
            actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
          ),
        );
      } else {
        showOk(context, notice);
      }
      await _refresh(householdChanged: true);
    } catch (e) {
      _showApiError(e);
    }
  }

  Future<void> _removeMember(UserBrief u, Household h) async {
    final yes = await confirm(context,
        title: 'Remove ${u.username}?',
        message: "They'll lose access to ${h.name}. Their past transactions stay in the household.",
        confirmLabel: 'Remove');
    if (!yes || !mounted) return;
    try {
      await _session.api.delete('household/members/${u.id}/');
      if (mounted) showOk(context, '${u.username} removed');
      await _refresh(householdChanged: true);
    } catch (e) {
      _showApiError(e);
    }
  }

  // ---- invites ----

  Future<void> _createInvite(Household h) async {
    final note = await promptText(context,
        title: 'New invite link', label: 'Note (optional), e.g. "For Amina"', okLabel: 'Create');
    if (note == null || !mounted) return;
    try {
      final res = await _session.api.post('household/invites/', {'note': note})
          as Map<String, dynamic>;
      final invite = Invitation.fromJson(res);
      _refresh();
      if (mounted) await _showNewInvite(invite, h);
    } catch (e) {
      _showApiError(e);
    }
  }

  Future<void> _showNewInvite(Invitation invite, Household h) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Invite link ready'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Send this to your partner. They join as soon as they sign up or sign in with it.'),
          const SizedBox(height: 12),
          SelectableText(AppConfig.inviteUrl(invite.code),
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
        actions: [
          TextButton(
            onPressed: () {
              _copy(invite);
              Navigator.pop(ctx);
            },
            child: const Text('Copy'),
          ),
          Builder(
            builder: (btnCtx) => FilledButton.icon(
              onPressed: () {
                _share(invite, h, btnCtx);
                Navigator.pop(ctx);
              },
              icon: const Icon(Icons.share, size: 18),
              label: const Text('Share'),
            ),
          ),
        ],
      ),
    );
  }

  void _copy(Invitation i) {
    Clipboard.setData(ClipboardData(text: AppConfig.inviteUrl(i.code)));
    showOk(context, 'Invite link copied');
  }

  Future<void> _share(Invitation i, Household h, BuildContext origin) async {
    final box = origin.findRenderObject() as RenderBox?;
    final rect = (box != null && box.hasSize) ? box.localToGlobal(Offset.zero) & box.size : null;
    try {
      await SharePlus.instance.share(ShareParams(
        subject: 'Join our household on Home Budget',
        text: 'Join "${h.name}" on Home Budget so we can track our budget together:\n'
            '${AppConfig.inviteUrl(i.code)}\n\n'
            'Or enter this invite code in the app: ${i.code}',
        sharePositionOrigin: rect,
      ));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _revoke(Invitation i) async {
    final yes = await confirm(context,
        title: 'Revoke this invite link?',
        message: 'Anyone holding it will no longer be able to join.',
        confirmLabel: 'Revoke');
    if (!yes || !mounted) return;
    final ok = await runAction(context, () => _session.api.post('household/invites/${i.id}/revoke/'),
        success: 'Invite link revoked');
    if (ok) _refresh();
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    final myId = context.select<Session, int?>((s) => s.user?.id);
    return Scaffold(
      appBar: AppBar(title: const Text('Household settings')),
      body: LoadBuilder<HouseholdSettings>(
        key: _loader,
        load: _load,
        builder: (context, s, reload) {
          final h = s.household;
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(top: 8, bottom: 32),
            children: [
              _HouseholdCard(
                household: h,
                onRename: () => _rename(h),
                onCurrency: () => _changeCurrency(h),
              ),
              SectionHeader('Members (${h.members.length})',
                  trailing: TextButton.icon(
                    onPressed: _addMember,
                    icon: const Icon(Icons.person_add_alt),
                    label: const Text('Add'),
                  )),
              _MembersCard(
                members: h.members,
                myId: myId,
                onRemove: (u) => _removeMember(u, h),
              ),
              SectionHeader('Invite partner',
                  trailing: TextButton.icon(
                    onPressed: () => _createInvite(h),
                    icon: const Icon(Icons.add_link),
                    label: const Text('New link'),
                  )),
              _InviteIntro(hasActive: s.pendingInvites.isNotEmpty, onCreate: () => _createInvite(h)),
              for (final i in s.pendingInvites)
                _InviteCard(
                  invite: i,
                  onCopy: () => _copy(i),
                  onShare: (origin) => _share(i, h, origin),
                  onRevoke: () => _revoke(i),
                ),
              if (s.pastInvites.isNotEmpty) ...[
                const SectionHeader('Used & expired'),
                for (final i in s.pastInvites) _InviteCard(invite: i),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _HouseholdCard extends StatelessWidget {
  const _HouseholdCard({required this.household, required this.onRename, required this.onCurrency});
  final Household household;
  final VoidCallback onRename;
  final VoidCallback onCurrency;

  @override
  Widget build(BuildContext context) {
    final c = household.baseCurrency;
    return Card(
      child: Column(children: [
        ListTile(
          leading: const Icon(Icons.home_work_outlined),
          title: Text(household.name, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: const Text('Household name'),
          trailing: IconButton(
              tooltip: 'Rename', icon: const Icon(Icons.edit_outlined), onPressed: onRename),
          onTap: onRename,
        ),
        const Divider(height: 1, indent: 16, endIndent: 16),
        ListTile(
          leading: const Icon(Icons.currency_exchange),
          title: Text(c == null ? household.currencyCode : '${c.code} · ${c.name} (${c.symbol})'),
          subtitle: const Text('Base currency. All totals and charts are shown in it.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: onCurrency,
        ),
      ]),
    );
  }
}

class _MembersCard extends StatelessWidget {
  const _MembersCard({required this.members, required this.myId, required this.onRemove});
  final List<UserBrief> members;
  final int? myId;
  final void Function(UserBrief) onRemove;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(children: [
        for (final u in members)
          ListTile(
            leading: CircleAvatar(child: Text(u.username.isEmpty ? '?' : u.username[0].toUpperCase())),
            title: Text(u.username),
            trailing: u.id == myId
                ? const StatusChip('You', color: AppColors.info)
                : IconButton(
                    tooltip: 'Remove ${u.username}',
                    icon: const Icon(Icons.person_remove_outlined, color: AppColors.expense),
                    onPressed: () => onRemove(u),
                  ),
          ),
        if (members.length < 2)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              "It's just you so far. If your partner already has an account, add them by "
              'username; otherwise send them an invite link below.',
              style: TextStyle(color: AppColors.muted),
            ),
          ),
      ]),
    );
  }
}

class _InviteIntro extends StatelessWidget {
  const _InviteIntro({required this.hasActive, required this.onCreate});
  final bool hasActive;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.muted);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(
          'Create a link and send it to your partner. When they sign up or sign in '
          'with it, they join this household. Each link works once and expires.',
          style: muted,
        ),
        if (!hasActive) ...[
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: onCreate,
            icon: const Icon(Icons.add_link),
            label: const Text('Create invite link'),
          ),
        ],
      ]),
    );
  }
}

class _InviteCard extends StatelessWidget {
  const _InviteCard({required this.invite, this.onCopy, this.onShare, this.onRevoke});
  final Invitation invite;
  final VoidCallback? onCopy;
  final void Function(BuildContext origin)? onShare;
  final VoidCallback? onRevoke;

  bool get _expired => invite.status == 'pending' && !invite.isUsable;

  String get _statusLabel => _expired ? 'Expired' : humanize(invite.status);

  Color get _statusColor => _expired
      ? AppColors.muted
      : switch (invite.status) {
          'pending' => AppColors.info,
          'accepted' => AppColors.income,
          'revoked' => AppColors.expense,
          _ => AppColors.muted,
        };

  @override
  Widget build(BuildContext context) {
    final i = invite;
    final t = Theme.of(context).textTheme;
    final muted = t.bodySmall?.copyWith(color: AppColors.muted);
    final details = [
      if (i.invitedBy != null) 'By ${i.invitedBy!.username}',
      if (i.createdAt != null) 'created ${fmtDateTime(i.createdAt)}',
      if (i.acceptedBy != null) 'joined by ${i.acceptedBy!.username}',
      if (i.acceptedAt != null) fmtDateTime(i.acceptedAt),
      if (i.status == 'pending' && i.expiresAt != null)
        '${_expired ? 'expired' : 'expires'} ${fmtDateTime(i.expiresAt)}',
    ].join(' · ');

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(i.note.isEmpty ? 'Invite link' : i.note,
                  style: t.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            StatusChip(_statusLabel, color: _statusColor),
            const SizedBox(width: 8),
          ]),
          const SizedBox(height: 4),
          SelectableText('Code: ${i.code}',
              style: t.bodySmall?.copyWith(fontFamily: 'monospace')),
          const SizedBox(height: 2),
          Text(details, style: muted),
          if (onCopy != null || onShare != null || onRevoke != null)
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              if (onRevoke != null)
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: AppColors.expense),
                  onPressed: onRevoke,
                  child: const Text('Revoke'),
                ),
              if (onCopy != null)
                TextButton.icon(
                  onPressed: onCopy,
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy link'),
                ),
              if (onShare != null)
                Builder(
                  builder: (btnCtx) => TextButton.icon(
                    onPressed: () => onShare!(btnCtx),
                    icon: const Icon(Icons.share, size: 18),
                    label: const Text('Share'),
                  ),
                ),
            ]),
        ]),
      ),
    );
  }
}
