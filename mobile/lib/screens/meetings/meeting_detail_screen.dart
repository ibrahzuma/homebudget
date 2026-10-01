import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../../widgets/entity_form.dart';
import 'agreement_sheet.dart';
import 'meeting_forms.dart';

/// A meeting: agenda, minutes, snapshot figures and its action items.
class MeetingDetailScreen extends StatefulWidget {
  const MeetingDetailScreen({super.key, required this.id});
  final int id;

  @override
  State<MeetingDetailScreen> createState() => _MeetingDetailScreenState();
}

enum _MenuAction { edit, delete }

class _MeetingDetailScreenState extends State<MeetingDetailScreen> {
  final _loader = GlobalKey<LoadBuilderState<Meeting>>();
  Meeting? _meeting;

  Session get _session => context.read<Session>();
  String get _base => 'meetings/${widget.id}/';

  Future<Meeting> _load() async {
    final m = Meeting.fromJson(await _session.api.get(_base) as Map<String, dynamic>);
    if (mounted) setState(() => _meeting = m);
    return m;
  }

  Future<void> _reload() async {
    await _loader.currentState?.reload();
  }

  Future<Meta?> _meta() async {
    try {
      return await ensureMeta(_session);
    } catch (e) {
      if (mounted) showError(context, e);
      return null;
    }
  }

  // ---- meeting ----

  Future<void> _editMeeting(Meeting m) async {
    final meta = await _meta();
    if (meta == null || !mounted) return;
    final saved = await openForm(context, meetingForm(session: _session, meta: meta, meeting: m));
    if (saved && mounted) {
      showOk(context, 'Meeting updated');
      _reload();
    }
  }

  Future<void> _deleteMeeting(Meeting m) async {
    final yes = await confirm(context,
        title: 'Delete "${m.title}"?',
        message: m.items.isEmpty
            ? 'This cannot be undone.'
            : 'Its ${m.items.length} action items are deleted too. This cannot be undone.');
    if (!yes || !mounted) return;
    final ok = await runAction(context, () => _session.api.delete(_base));
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  // ---- items ----

  Future<void> _addItem() async {
    final meta = await _meta();
    if (meta == null || !mounted) return;
    final saved = await openForm(
        context, agreementForm(session: _session, meta: meta, meetingId: widget.id));
    if (saved && mounted) _changed('Action item added');
  }

  Future<void> _openItem(AgreementItem item) async {
    final meta = await _meta();
    if (!mounted) return;
    final r = await showAgreementSheet(context, item, meta);
    if (r == null || !mounted) return;
    switch (r.action) {
      case AgreementSheetAction.save:
        final ok = await runAction(
          context,
          () => _session.api.post('${_base}items/${item.id}/quick/', {
            'status': ?r.status,
            'progress': ?r.progress,
          }),
        );
        if (ok && mounted) _changed('Item updated');
      case AgreementSheetAction.edit:
        if (meta == null) return;
        final saved = await openForm(context,
            agreementForm(session: _session, meta: meta, meetingId: widget.id, item: item));
        if (saved && mounted) _changed('Item updated');
      case AgreementSheetAction.delete:
        final yes = await confirm(context, title: 'Delete "${item.title}"?');
        if (!yes || !mounted) return;
        final ok =
            await runAction(context, () => _session.api.delete('${_base}items/${item.id}/'));
        if (ok && mounted) _changed('Item deleted');
    }
  }

  /// Item changes can create or clear overdue alerts.
  void _changed(String message) {
    showOk(context, message);
    _reload();
    _session.refreshBadges();
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    final m = _meeting;
    return Scaffold(
      appBar: AppBar(
        title: Text(m?.title ?? 'Meeting'),
        actions: [
          if (m != null)
            PopupMenuButton<_MenuAction>(
              onSelected: (a) => a == _MenuAction.edit ? _editMeeting(m) : _deleteMeeting(m),
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: _MenuAction.edit,
                    child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Edit meeting'))),
                PopupMenuItem(
                    value: _MenuAction.delete,
                    child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Delete meeting'))),
              ],
            ),
        ],
      ),
      floatingActionButton: m == null
          ? null
          : FloatingActionButton.extended(
              heroTag: 'meeting-item-fab',
              onPressed: _addItem,
              icon: const Icon(Icons.add_task),
              label: const Text('Add item'),
            ),
      body: LoadBuilder<Meeting>(
        key: _loader,
        load: _load,
        builder: (context, m, reload) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(top: 8, bottom: 96),
          children: [
            _Header(meeting: m),
            if (m.items.isNotEmpty) _ProgressCard(meeting: m),
            if (m.incomeSnapshot != null || m.expenseSnapshot != null || m.netWorthSnapshot != null)
              _Snapshot(meeting: m),
            _TextSection(
                title: 'Agenda', icon: Icons.list_alt, text: m.agenda, empty: 'No agenda.'),
            _TextSection(
              title: 'Minutes',
              icon: Icons.edit_note,
              text: m.minutes,
              empty: 'No minutes yet. Use Edit meeting to record what was decided.',
            ),
            SectionHeader('Action items & agreements',
                trailing: TextButton.icon(
                    onPressed: _addItem, icon: const Icon(Icons.add), label: const Text('Add'))),
            ..._items(m),
          ],
        ),
      ),
    );
  }

  List<Widget> _items(Meeting m) {
    if (m.items.isEmpty) {
      return [
        const Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text('No action items yet. Add the first thing you agreed on.',
                style: TextStyle(color: AppColors.muted)),
          ),
        ),
      ];
    }
    final meta = context.read<Session>().meta;
    final out = <Widget>[];
    for (final status in agreementStatusOrder) {
      final group = m.items.where((i) => i.status == status).toList();
      if (group.isEmpty) continue;
      out.add(_GroupLabel(
          label: choiceLabel(meta, 'agreement_status', status),
          count: group.length,
          color: agreementStatusColor(status)));
      out.addAll(group.map((i) => _ItemCard(item: i, onTap: () => _openItem(i))));
    }
    // Anything with a status we don't know about.
    final rest = m.items.where((i) => !agreementStatusOrder.contains(i.status));
    out.addAll(rest.map((i) => _ItemCard(item: i, onTap: () => _openItem(i))));
    return out;
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.meeting});
  final Meeting meeting;

  @override
  Widget build(BuildContext context) {
    final m = meeting;
    final t = Theme.of(context).textTheme;
    final meta = context.select<Session, Meta?>((s) => s.meta);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(m.title, style: t.titleLarge)),
            StatusChip(choiceLabel(meta, 'meeting_status', m.status),
                color: meetingStatusColor(m.status)),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            const Icon(Icons.event, size: 16, color: AppColors.muted),
            const SizedBox(width: 6),
            Text(fmtDate(m.meetingDate), style: t.bodyMedium?.copyWith(color: AppColors.muted)),
          ]),
          if (m.participants.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final p in m.participants)
                Chip(
                  avatar: CircleAvatar(child: Text(p.username[0].toUpperCase())),
                  label: Text(p.username),
                  visualDensity: VisualDensity.compact,
                ),
            ]),
          ],
        ]),
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.meeting});
  final Meeting meeting;

  @override
  Widget build(BuildContext context) {
    final m = meeting;
    final t = Theme.of(context).textTheme;
    final overdue = m.items.where((i) => i.isOverdue).length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('Agreement progress', style: t.titleSmall)),
            Text('${m.progressPercent}%', style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 8),
          ProgressLine(percent: m.progressPercent.toDouble(), color: AppColors.income),
          const SizedBox(height: 8),
          Text(
            [
              '${m.items.length} items',
              '${m.doneCount} done',
              '${m.openCount} open',
              if (overdue > 0) '$overdue overdue',
            ].join(' · '),
            style: t.bodySmall?.copyWith(color: overdue > 0 ? AppColors.expense : AppColors.muted),
          ),
        ]),
      ),
    );
  }
}

class _Snapshot extends StatelessWidget {
  const _Snapshot({required this.meeting});
  final Meeting meeting;

  @override
  Widget build(BuildContext context) {
    final symbol = context.select<Session, String>((s) => s.currencySymbol);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionHeader('Snapshot at meeting time'),
      StatRow(children: [
        StatTile(
            label: 'Income (MTD)',
            value: fmtMoney(meeting.incomeSnapshot, symbol: symbol),
            color: AppColors.income),
        StatTile(
            label: 'Expense (MTD)',
            value: fmtMoney(meeting.expenseSnapshot, symbol: symbol),
            color: AppColors.expense),
        StatTile(label: 'Net worth', value: fmtMoney(meeting.netWorthSnapshot, symbol: symbol)),
      ]),
    ]);
  }
}

class _TextSection extends StatelessWidget {
  const _TextSection(
      {required this.title, required this.icon, required this.text, required this.empty});
  final String title;
  final IconData icon;
  final String text;
  final String empty;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 18, color: AppColors.muted),
            const SizedBox(width: 8),
            Text(title, style: t.titleSmall),
          ]),
          const SizedBox(height: 8),
          text.isEmpty
              ? Text(empty, style: t.bodyMedium?.copyWith(color: AppColors.muted))
              : SelectableText(text, style: t.bodyMedium),
        ]),
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel({required this.label, required this.count, required this.color});
  final String label;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 16, 2),
      child: Row(children: [
        Container(
            width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Text('$label ($count)',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(color: color)),
      ]),
    );
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({required this.item, required this.onTap});
  final AgreementItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final i = item;
    final t = Theme.of(context).textTheme;
    final meta = context.select<Session, Meta?>((s) => s.meta);
    final finished = i.status == 'done' || i.status == 'cancelled';

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Text(i.title,
                    style: t.titleSmall?.copyWith(
                        decoration: i.status == 'cancelled' ? TextDecoration.lineThrough : null)),
              ),
              if (i.priority != 'normal') ...[
                const SizedBox(width: 6),
                StatusChip(choiceLabel(meta, 'agreement_priority', i.priority),
                    color: priorityColor(i.priority)),
              ],
              if (i.isOverdue) ...[
                const SizedBox(width: 6),
                const StatusChip('Overdue', color: AppColors.expense),
              ],
            ]),
            const SizedBox(height: 4),
            Text(
              [
                i.owner?.username ?? 'No owner',
                if (i.targetDate != null) 'by ${fmtDate(i.targetDate)}',
                if (i.completedDate != null) 'done ${fmtDate(i.completedDate)}',
              ].join(' · '),
              style: t.bodySmall?.copyWith(color: i.isOverdue ? AppColors.expense : AppColors.muted),
            ),
            if (!finished || i.progress > 0) ...[
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: ProgressLine(
                      percent: i.progress.toDouble(),
                      color: agreementStatusColor(i.status),
                      height: 6),
                ),
                const SizedBox(width: 8),
                Text('${i.progress}%', style: t.labelSmall),
              ]),
            ],
          ]),
        ),
      ),
    );
  }
}
