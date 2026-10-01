import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../../widgets/entity_form.dart';

Color meetingStatusColor(String s) => switch (s) {
      'planned' => AppColors.info,
      'held' => AppColors.income,
      _ => AppColors.muted,
    };

Color agreementStatusColor(String s) => switch (s) {
      'open' => AppColors.info,
      'in_progress' => AppColors.warning,
      'done' => AppColors.income,
      _ => AppColors.muted,
    };

Color priorityColor(String p) => switch (p) {
      'high' => AppColors.expense,
      'low' => AppColors.muted,
      _ => AppColors.info,
    };

/// Status order used to group action items.
const agreementStatusOrder = ['open', 'in_progress', 'done', 'cancelled'];

/// Label for an enum value from meta choices, falling back to humanize().
String choiceLabel(Meta? meta, String key, String value) {
  final label = meta?.label(key, value);
  return (label == null || label == value) ? humanize(value) : label;
}

List<Option> _options(Meta meta, String key) =>
    [for (final c in meta.choicesFor(key)) Option(c.value, c.label)];

Future<Meta> ensureMeta(Session session) async {
  if (session.meta == null) await session.refreshMeta();
  return session.meta!;
}

/// Create (when [meeting] is null) or edit a meeting. [onSaved] receives the
/// server response, e.g. to read `id` and `carried_over` after creating.
EntityFormScreen meetingForm({
  required Session session,
  required Meta meta,
  Meeting? meeting,
  DateTime? suggestedDate,
  String? suggestedTitle,
  bool hasPreviousMeetings = false,
  void Function(Map<String, dynamic> response)? onSaved,
}) {
  final creating = meeting == null;
  return EntityFormScreen(
    title: creating ? 'Schedule meeting' : 'Edit meeting',
    submitLabel: creating ? 'Schedule' : 'Save',
    initial: creating
        ? {
            'title': suggestedTitle ?? '',
            'meeting_date': suggestedDate ?? DateTime.now(),
            'participants': [for (final m in meta.members) m.id],
            'status': 'planned',
            'carry_over_open_items': true,
          }
        : {
            'title': meeting.title,
            'meeting_date': meeting.meetingDate,
            'participants': [for (final p in meeting.participants) p.id],
            'agenda': meeting.agenda,
            'minutes': meeting.minutes,
            'status': meeting.status,
          },
    fields: [
      const FieldSpec.text('title', 'Title', required: true, hint: 'e.g. Q2 2026 Review'),
      const FieldSpec.date('meeting_date', 'Date', required: true),
      FieldSpec.multiSelect('participants', 'Participants',
          options: [for (final m in meta.members) Option(m.id, m.username)]),
      const FieldSpec.multiline('agenda', 'Agenda',
          hint: 'Topics to cover, e.g. budget review, savings, upcoming expenses'),
      const FieldSpec.multiline('minutes', 'Minutes', hint: 'What was discussed and decided'),
      FieldSpec.select('status', 'Status', required: true, options: _options(meta, 'meeting_status')),
      if (creating && hasPreviousMeetings)
        const FieldSpec.toggle('carry_over_open_items', 'Carry over open action items',
            help: 'Copies unfinished items from the previous meeting into this one.'),
    ],
    onSubmit: (values) async {
      final res = creating
          ? await session.api.post('meetings/', values)
          : await session.api.patch('meetings/${meeting.id}/', values);
      if (res is Map<String, dynamic>) onSaved?.call(res);
    },
  );
}

/// Create or edit an agreement / action item on [meetingId].
EntityFormScreen agreementForm({
  required Session session,
  required Meta meta,
  required int meetingId,
  AgreementItem? item,
}) {
  final creating = item == null;
  return EntityFormScreen(
    title: creating ? 'Add action item' : 'Edit action item',
    initial: creating
        ? {'status': 'open', 'progress': 0, 'priority': 'normal'}
        : {
            'title': item.title,
            'description': item.description,
            'owner': item.owner?.id,
            'target_date': item.targetDate,
            'status': item.status,
            'progress': item.progress,
            'priority': item.priority,
            'notes': item.notes,
          },
    fields: [
      const FieldSpec.text('title', 'Title', required: true, hint: 'e.g. Build a 3-month emergency fund'),
      const FieldSpec.multiline('description', 'Description'),
      FieldSpec.select('owner', 'Owner',
          options: [for (final m in meta.members) Option(m.id, m.username)]),
      const FieldSpec.date('target_date', 'Target date', help: 'When this should be done by'),
      FieldSpec.select('status', 'Status',
          required: true, options: _options(meta, 'agreement_status')),
      const FieldSpec.integer('progress', 'Progress (%)',
          required: true, help: '0 to 100. Marking an item done sets it to 100.'),
      FieldSpec.select('priority', 'Priority',
          required: true, options: _options(meta, 'agreement_priority')),
      const FieldSpec.multiline('notes', 'Notes'),
    ],
    onSubmit: (values) async {
      final p = int.tryParse('${values['progress']}');
      final body = {...values, 'progress': (p ?? 0).clamp(0, 100)};
      if (creating) {
        await session.api.post('meetings/$meetingId/items/', body);
      } else {
        await session.api.patch('meetings/$meetingId/items/${item.id}/', body);
      }
    },
  );
}
