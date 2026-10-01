import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../widgets/common.dart';
import 'meeting_forms.dart';

enum AgreementSheetAction { save, edit, delete }

class AgreementSheetResult {
  const AgreementSheetResult(this.action, {this.status, this.progress});
  final AgreementSheetAction action;

  /// Only set when changed, so the server's own rules apply to the rest.
  final String? status;
  final int? progress;
}

/// Bottom sheet with an item's details, a quick status/progress update and
/// edit/delete shortcuts.
Future<AgreementSheetResult?> showAgreementSheet(
    BuildContext context, AgreementItem item, Meta? meta) {
  return showModalBottomSheet<AgreementSheetResult>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _AgreementSheet(item: item, meta: meta),
  );
}

class _AgreementSheet extends StatefulWidget {
  const _AgreementSheet({required this.item, required this.meta});
  final AgreementItem item;
  final Meta? meta;

  @override
  State<_AgreementSheet> createState() => _AgreementSheetState();
}

class _AgreementSheetState extends State<_AgreementSheet> {
  late String _status = widget.item.status;
  late double _progress = widget.item.progress.toDouble();

  bool get _dirty => _status != widget.item.status || _progress.round() != widget.item.progress;

  void _setStatus(String s) => setState(() {
        _status = s;
        if (s == 'done') _progress = 100;
      });

  void _setProgress(double p) => setState(() {
        _progress = p;
        if (p >= 100) _status = 'done';
      });

  void _save() {
    final i = widget.item;
    Navigator.pop(
      context,
      AgreementSheetResult(
        AgreementSheetAction.save,
        status: _status != i.status ? _status : null,
        progress: _progress.round() != i.progress ? _progress.round() : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.item;
    final t = Theme.of(context).textTheme;
    final muted = t.bodyMedium?.copyWith(color: AppColors.muted);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(i.title, style: t.titleLarge),
          const SizedBox(height: 4),
          Text(_facts(i), style: muted),
          if (i.description.isNotEmpty) ...[const SizedBox(height: 8), Text(i.description)],
          if (i.notes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Notes', style: t.labelMedium?.copyWith(color: AppColors.muted)),
            Text(i.notes),
          ],
          const SizedBox(height: 16),
          Text('Status', style: t.titleSmall),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final s in agreementStatusOrder)
              ChoiceChip(
                label: Text(choiceLabel(widget.meta, 'agreement_status', s)),
                selected: _status == s,
                onSelected: (_) => _setStatus(s),
              ),
          ]),
          const SizedBox(height: 16),
          Text('Progress: ${_progress.round()}%', style: t.titleSmall),
          Slider(
            value: _progress,
            max: 100,
            divisions: 20,
            label: '${_progress.round()}%',
            onChanged: _setProgress,
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _dirty ? _save : null,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: const Text('Update'),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => Navigator.pop(
                    context, const AgreementSheetResult(AgreementSheetAction.edit)),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: AppColors.expense),
                onPressed: () => Navigator.pop(
                    context, const AgreementSheetResult(AgreementSheetAction.delete)),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete'),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  String _facts(AgreementItem i) => [
        'Owner: ${i.owner?.username ?? '—'}',
        if (i.targetDate != null) 'Target ${fmtDate(i.targetDate)}',
        '${choiceLabel(widget.meta, 'agreement_priority', i.priority)} priority',
        if (i.completedDate != null) 'Completed ${fmtDate(i.completedDate)}',
      ].join(' · ');
}
