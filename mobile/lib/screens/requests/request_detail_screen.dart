import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../core/format.dart';
import '../../core/realtime.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import 'request_common.dart';

/// One money request with approve / reject / cancel actions.
class RequestDetailScreen extends StatefulWidget {
  const RequestDetailScreen({super.key, required this.id});
  final int id;

  @override
  State<RequestDetailScreen> createState() => _RequestDetailScreenState();
}

class _RequestDetailScreenState extends State<RequestDetailScreen> {
  final _loader = GlobalKey<LoadBuilderState<MoneyRequest>>();
  StreamSubscription<Map<String, dynamic>>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = context
        .read<Realtime>()
        .myEvents
        .where((e) => isRequestEvent(e) && e['request_id'] == widget.id)
        .listen(_onEvent);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _onEvent(Map<String, dynamic> e) {
    _loader.currentState?.reload();
    if (ModalRoute.of(context)?.isCurrent ?? true) {
      showOk(context, e['message'] as String? ?? 'This request was updated.');
    }
  }

  Future<MoneyRequest> _load() async {
    final api = context.read<Session>().api;
    return MoneyRequest.fromJson(await api.get('requests/${widget.id}/') as Map<String, dynamic>);
  }

  /// approve / reject / cancel, then refresh the screen and badges.
  Future<void> _act(String action, {String? note, required String done}) async {
    final session = context.read<Session>();
    final ok = await runAction(
      context,
      () => session.api.post('requests/${widget.id}/$action/', {'note': ?note}),
      success: done,
    );
    if (!ok) return;
    _loader.currentState?.reload();
    session.refreshBadges();
  }

  Future<void> _respond(MoneyRequest r, {required bool approve}) async {
    final note = await promptText(
      context,
      title: approve ? 'Approve request?' : 'Reject request?',
      label: 'Note (optional)',
      okLabel: approve ? 'Approve' : 'Reject',
    );
    if (note == null || !mounted) return;
    await _act(approve ? 'approve' : 'reject',
        note: note.isEmpty ? null : note,
        done: approve ? 'Request approved' : 'Request rejected');
  }

  Future<void> _cancel() async {
    final yes = await confirm(context,
        title: 'Cancel this request?',
        message: 'Your partner will no longer be able to approve it.',
        confirmLabel: 'Cancel request');
    if (yes && mounted) await _act('cancel', done: 'Request cancelled');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Money request')),
      body: LoadBuilder<MoneyRequest>(
        key: _loader,
        load: _load,
        builder: (context, r, reload) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(top: 8, bottom: 32),
          children: [
            _Header(request: r),
            _Details(request: r),
            _Actions(
              request: r,
              onApprove: () => _respond(r, approve: true),
              onReject: () => _respond(r, approve: false),
              onCancel: _cancel,
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.request});
  final MoneyRequest request;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final symbol = context.select<Session, String>((s) => s.currencySymbol);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(requestAmount(request, symbol),
                  style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            ),
            RequestStatusChip(request.status),
          ]),
          const SizedBox(height: 6),
          Text(request.purpose, style: t.titleMedium),
          const SizedBox(height: 4),
          Text('${request.requester.username} asked ${request.approver.username}',
              style: t.bodyMedium?.copyWith(color: AppColors.muted)),
        ]),
      ),
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.request});
  final MoneyRequest request;

  @override
  Widget build(BuildContext context) {
    final r = request;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(children: [
          _Row('Requester', r.requester.username),
          _Row('Approver', r.approver.username),
          _Row('Currency', r.currency == null ? '—' : '${r.currency!.code} (${r.currency!.symbol})'),
          _Row('Category', r.category?.name ?? '—'),
          _Row('Requested', fmtDateTime(r.createdAt)),
          if (r.resolvedAt != null) _Row(humanize(r.status), fmtDateTime(r.resolvedAt)),
          if (r.notes.isNotEmpty) _Row('Notes from requester', r.notes, block: true),
          if (r.responseNote.isNotEmpty) _Row('Response note', r.responseNote, block: true),
        ]),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.block = false});
  final String label;
  final String value;
  final bool block;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final labelText = Text(label, style: t.bodyMedium?.copyWith(color: AppColors.muted));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: block
          ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              labelText,
              const SizedBox(height: 2),
              Text(value, style: t.bodyMedium),
            ])
          : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              labelText,
              const SizedBox(width: 16),
              Expanded(
                child: Text(value,
                    textAlign: TextAlign.end,
                    style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
              ),
            ]),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.request,
    required this.onApprove,
    required this.onReject,
    required this.onCancel,
  });

  final MoneyRequest request;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final r = request;
    final symbol = context.select<Session, String>((s) => s.currencySymbol);
    final t = Theme.of(context).textTheme;
    final muted = t.bodyMedium?.copyWith(color: AppColors.muted);

    if (r.canRespond) {
      return _ActionCard(title: 'Your decision', children: [
        Text(
          'Approving records one expense of ${requestAmount(r, symbol)} for '
          '${r.requester.username}${r.category == null ? '' : ' under ${r.category!.name}'}.',
          style: muted,
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: AppColors.expense),
              onPressed: onReject,
              icon: const Icon(Icons.close),
              label: const Text('Reject'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: AppColors.income),
              onPressed: onApprove,
              icon: const Icon(Icons.check),
              label: const Text('Approve'),
            ),
          ),
        ]),
      ]);
    }
    if (r.canCancel) {
      return _ActionCard(title: 'Manage request', children: [
        Text("Waiting for ${r.approver.username}. You can cancel this request while it's pending.",
            style: muted),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: AppColors.expense),
          onPressed: onCancel,
          icon: const Icon(Icons.cancel_outlined),
          label: const Text('Cancel request'),
        ),
      ]);
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        r.status == 'pending'
            ? 'Waiting for ${r.approver.username} to respond.'
            : 'This request has been resolved. No further actions.',
        style: muted,
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          ...children,
        ]),
      ),
    );
  }
}
