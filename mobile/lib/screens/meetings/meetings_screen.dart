import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../../widgets/entity_form.dart';
import 'meeting_detail_screen.dart';
import 'meeting_forms.dart';

export 'meeting_detail_screen.dart' show MeetingDetailScreen;

class _MeetingsData {
  _MeetingsData.fromJson(Map<String, dynamic> j)
      : meetings = (j['results'] as List)
            .map((e) => Meeting.fromJson(e as Map<String, dynamic>))
            .toList(),
        openCount = j['open_count'] as int? ?? 0,
        overdueCount = j['overdue_count'] as int? ?? 0,
        suggestedDate = DateTime.tryParse(j['next_suggested_date'] as String? ?? ''),
        suggestedTitle = j['next_suggested_title'] as String? ?? '';

  final List<Meeting> meetings;
  final int openCount;
  final int overdueCount;
  final DateTime? suggestedDate;
  final String suggestedTitle;
}

/// Household finance meetings with their action-item progress.
class MeetingsScreen extends StatefulWidget {
  const MeetingsScreen({super.key});

  @override
  State<MeetingsScreen> createState() => _MeetingsScreenState();
}

class _MeetingsScreenState extends State<MeetingsScreen> {
  final _loader = GlobalKey<LoadBuilderState<_MeetingsData>>();
  _MeetingsData? _data;

  Future<_MeetingsData> _load() async {
    final api = context.read<Session>().api;
    final data = _MeetingsData.fromJson(await api.get('meetings/') as Map<String, dynamic>);
    _data = data;
    return data;
  }

  Future<void> _open(int id) async {
    await push(context, MeetingDetailScreen(id: id));
    if (!mounted) return;
    _loader.currentState?.reload();
    context.read<Session>().refreshBadges();
  }

  Future<void> _schedule() async {
    final session = context.read<Session>();
    final Meta meta;
    try {
      meta = await ensureMeta(session);
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (!mounted) return;
    Map<String, dynamic>? created;
    final saved = await openForm(
      context,
      meetingForm(
        session: session,
        meta: meta,
        suggestedDate: _data?.suggestedDate,
        suggestedTitle: _data?.suggestedTitle,
        hasPreviousMeetings: _data?.meetings.isNotEmpty ?? false,
        onSaved: (res) => created = res,
      ),
    );
    if (!saved || !mounted) return;
    final carried = created?['carried_over'] as int? ?? 0;
    showOk(context,
        carried > 0 ? 'Meeting scheduled · $carried open items carried over' : 'Meeting scheduled');
    _loader.currentState?.reload();
    final id = created?['id'] as int?;
    if (id != null) _open(id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Meetings')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'meetings-fab',
        onPressed: _schedule,
        icon: const Icon(Icons.event_available),
        label: const Text('Schedule'),
      ),
      body: LoadBuilder<_MeetingsData>(
        key: _loader,
        load: _load,
        builder: (context, data, reload) {
          if (data.meetings.isEmpty) {
            return EmptyState(
              icon: Icons.groups_outlined,
              title: 'No meetings yet',
              message: 'Sit down together regularly to review the budget and agree on next steps.'
                  '${data.suggestedTitle.isEmpty ? '' : ' Suggested: ${data.suggestedTitle}.'}',
              action: FilledButton.icon(
                onPressed: _schedule,
                icon: const Icon(Icons.event_available),
                label: const Text('Schedule the first one'),
              ),
            );
          }
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(top: 8, bottom: 96),
            children: [
              StatRow(children: [
                StatTile(
                    label: 'Meetings',
                    value: '${data.meetings.length}',
                    icon: Icons.groups_outlined),
                StatTile(
                    label: 'Open items',
                    value: '${data.openCount}',
                    icon: Icons.checklist,
                    color: data.openCount > 0 ? AppColors.info : null),
                StatTile(
                    label: 'Overdue',
                    value: '${data.overdueCount}',
                    icon: Icons.schedule,
                    color: data.overdueCount > 0 ? AppColors.expense : null),
              ]),
              if (data.suggestedDate != null)
                _SuggestionCard(
                    title: data.suggestedTitle, date: data.suggestedDate!, onTap: _schedule),
              const SectionHeader('All meetings'),
              for (final m in data.meetings) _MeetingCard(meeting: m, onTap: () => _open(m.id)),
            ],
          );
        },
      ),
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({required this.title, required this.date, required this.onTap});
  final String title;
  final DateTime date;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: ListTile(
        leading: const Icon(Icons.lightbulb_outline, color: AppColors.warning),
        title: Text('Next: $title'),
        subtitle: Text('Suggested for ${fmtDate(date)}'),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

class _MeetingCard extends StatelessWidget {
  const _MeetingCard({required this.meeting, required this.onTap});
  final Meeting meeting;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = meeting;
    final t = Theme.of(context).textTheme;
    final meta = context.select<Session, Meta?>((s) => s.meta);
    final hasItems = m.openCount + m.doneCount > 0;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(m.title,
                    style: t.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              StatusChip(choiceLabel(meta, 'meeting_status', m.status),
                  color: meetingStatusColor(m.status)),
            ]),
            const SizedBox(height: 4),
            Text(
              [
                fmtDate(m.meetingDate),
                if (m.participants.isNotEmpty) m.participants.map((p) => p.username).join(', '),
              ].join(' · '),
              style: t.bodySmall?.copyWith(color: AppColors.muted),
            ),
            if (hasItems) ...[
              const SizedBox(height: 10),
              ProgressLine(percent: m.progressPercent.toDouble(), color: AppColors.income, height: 6),
              const SizedBox(height: 4),
              Text('${m.doneCount} done · ${m.openCount} open · ${m.progressPercent}%',
                  style: t.labelSmall?.copyWith(color: AppColors.muted)),
            ] else ...[
              const SizedBox(height: 6),
              Text('No action items', style: t.labelSmall?.copyWith(color: AppColors.muted)),
            ],
          ]),
        ),
      ),
    );
  }
}
