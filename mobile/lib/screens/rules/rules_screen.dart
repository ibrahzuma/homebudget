import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../../widgets/entity_form.dart';
import '../transactions/transaction_form.dart';
import '../transactions/txn_events.dart';

/// Auto-categorization rules: match payee/description text to a category.
class RulesScreen extends StatefulWidget {
  const RulesScreen({super.key});

  @override
  State<RulesScreen> createState() => _RulesScreenState();
}

class _RulesScreenState extends State<RulesScreen> {
  final _loader = GlobalKey<LoadBuilderState<List<Rule>>>();
  bool _applying = false;

  Future<List<Rule>> _load() async {
    final session = context.read<Session>();
    // Match-type labels come from meta; fetch it alongside if missing.
    final res = await session.api.get('rules/') as List;
    try {
      await ensureMeta(session);
    } catch (_) {
      // Labels fall back to the raw match type.
    }
    return [for (final r in res) Rule.fromJson(r as Map<String, dynamic>)];
  }

  Future<void> _reload() async => _loader.currentState?.reload();

  Future<void> _openForm([Rule? existing]) async {
    final meta = await metaForForm(context);
    if (meta == null || !mounted) return;
    if (meta.categories.isEmpty) {
      showError(context, 'Add a category first.');
      return;
    }
    final api = context.read<Session>().api;
    final matchTypes = meta.choicesFor('match_type');
    final form = EntityFormScreen(
      title: existing == null ? 'New rule' : 'Edit rule',
      initial: {
        'pattern': existing?.pattern,
        'match_type': existing?.matchType ?? 'contains',
        'case_sensitive': existing?.caseSensitive ?? false,
        'category': existing?.category.id,
        'priority': existing?.priority ?? 10,
        'is_active': existing?.isActive ?? true,
      },
      fields: [
        const FieldSpec.text('pattern', 'Pattern',
            required: true,
            hint: 'e.g. TotalEnergies',
            help: 'Matched against the payee and description.'),
        FieldSpec.select('match_type', 'Match type', required: true, options: [
          if (matchTypes.isEmpty) ...const [
            Option('contains', 'Contains'),
            Option('equals', 'Equals'),
            Option('starts_with', 'Starts with'),
          ],
          for (final c in matchTypes) Option(c.value, c.label),
        ]),
        const FieldSpec.toggle('case_sensitive', 'Case sensitive'),
        FieldSpec.select('category', 'Assign category', required: true, options: [
          for (final c in meta.categories) Option(c.id, '${c.name} (${capitalize(c.type)})'),
        ], help: 'Only applies to transactions of the same type as the category.'),
        const FieldSpec.integer('priority', 'Priority',
            required: true, help: 'Lower numbers run first; the first matching rule wins.'),
        const FieldSpec.toggle('is_active', 'Active'),
      ],
      onSubmit: (v) async {
        if (existing == null) {
          await api.post('rules/', v);
        } else {
          await api.patch('rules/${existing.id}/', v);
        }
      },
    );
    if (await openForm(context, form)) await _reload();
  }

  Future<void> _toggle(Rule r, bool active) async {
    final api = context.read<Session>().api;
    if (await runAction(context, () => api.patch('rules/${r.id}/', {'is_active': active}))) {
      await _reload();
    }
  }

  Future<void> _delete(Rule r) async {
    final ok = await confirm(context,
        title: 'Delete rule?',
        message: '"${r.pattern}" → ${r.category.name}. '
            'Transactions it already categorized keep their category.');
    if (!ok || !mounted) return;
    final api = context.read<Session>().api;
    if (await runAction(context, () => api.delete('rules/${r.id}/'), success: 'Rule deleted')) {
      await _reload();
    }
  }

  Future<void> _applyToExisting() async {
    final api = context.read<Session>().api;
    setState(() => _applying = true);
    try {
      final res = await api.post('rules/apply/') as Map<String, dynamic>;
      final n = res['categorized'] as int? ?? 0;
      if (n > 0) notifyTransactionsChanged();
      if (mounted) {
        showOk(context,
            n == 0 ? 'No uncategorized transactions matched a rule.' : 'Categorized $n transaction${n == 1 ? '' : 's'}.');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Auto-categorize rules')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(),
        icon: const Icon(Icons.add),
        label: const Text('Add rule'),
      ),
      body: LoadBuilder<List<Rule>>(
        key: _loader,
        load: _load,
        builder: (context, rules, _) => ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            _IntroCard(
              applying: _applying,
              onApply: rules.any((r) => r.isActive) ? _applyToExisting : null,
            ),
            if (rules.isEmpty)
              SizedBox(
                height: 320,
                child: EmptyState(
                  icon: Icons.auto_fix_high,
                  title: 'No rules yet',
                  message: 'New transactions without a category are tagged automatically '
                      'when their payee or description matches a rule.',
                  action: FilledButton.icon(
                    onPressed: () => _openForm(),
                    icon: const Icon(Icons.add),
                    label: const Text('Add rule'),
                  ),
                ),
              )
            else ...[
              SectionHeader('${rules.length} rule${rules.length == 1 ? '' : 's'} · by priority'),
              for (final r in rules)
                _RuleCard(
                  rule: r,
                  onTap: () => _openForm(r),
                  onToggle: (v) => _toggle(r, v),
                  onDelete: () => _delete(r),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard({required this.applying, required this.onApply});
  final bool applying;
  final VoidCallback? onApply;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Categorize automatically', style: t.titleSmall),
          const SizedBox(height: 6),
          Text(
            'Example: "TotalEnergies" contains → Fuel tags any transaction with '
            'TotalEnergies in the payee or description as Fuel.',
            style: t.bodySmall?.copyWith(color: AppColors.muted),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: applying ? null : onApply,
            icon: applying
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.playlist_add_check),
            label: const Text('Apply to uncategorized transactions'),
          ),
        ]),
      ),
    );
  }
}

class _RuleCard extends StatelessWidget {
  const _RuleCard({
    required this.rule,
    required this.onTap,
    required this.onToggle,
    required this.onDelete,
  });
  final Rule rule;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final meta = context.watch<Session>().meta;
    final t = Theme.of(context).textTheme;
    final matchLabel = meta?.label('match_type', rule.matchType) ?? humanize(rule.matchType);
    final muted = !rule.isActive;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onDelete,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(children: [
            CircleAvatar(
              radius: 16,
              child: Text('${rule.priority}', style: t.labelMedium),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Opacity(
                opacity: muted ? 0.55 : 1,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('"${rule.pattern}"',
                      style: t.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    '${matchLabel.toLowerCase()}${rule.caseSensitive ? ' · case sensitive' : ''}',
                    style: t.bodySmall?.copyWith(color: AppColors.muted),
                  ),
                  const SizedBox(height: 6),
                  Row(children: [
                    const Icon(Icons.arrow_forward, size: 14, color: AppColors.muted),
                    const SizedBox(width: 4),
                    IconBadge(icon: rule.category.icon, color: rule.category.color, size: 22),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(rule.category.name,
                          style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis),
                    ),
                  ]),
                ]),
              ),
            ),
            Switch(value: rule.isActive, onChanged: onToggle),
            PopupMenuButton<String>(
              onSelected: (v) => v == 'edit' ? onTap() : onDelete(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Edit')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ]),
        ),
      ),
    );
  }
}
