import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/icons.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../../widgets/entity_form.dart';
import '../networth/finance_shared.dart';
import 'goal_detail_screen.dart';

/// Savings goals with progress towards each target.
class GoalsScreen extends StatefulWidget {
  const GoalsScreen({super.key});

  @override
  State<GoalsScreen> createState() => _GoalsScreenState();
}

class _GoalsScreenState extends State<GoalsScreen> {
  final _loader = GlobalKey<LoadBuilderState<List<Goal>>>();

  Future<List<Goal>> _load() async {
    final list = await context.read<Session>().api.get('goals/') as List;
    return list.map((e) => Goal.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> _reload() async => _loader.currentState?.reload();

  Future<void> _add() async {
    if (await openGoalForm(context)) _reload();
  }

  Future<void> _open(Goal g) async {
    await push(context, GoalDetailScreen(id: g.id));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final symbol = context.watch<Session>().currencySymbol;
    return Scaffold(
      appBar: AppBar(title: const Text('Savings goals')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('New goal'),
      ),
      body: LoadBuilder<List<Goal>>(
        key: _loader,
        load: _load,
        builder: (context, goals, reload) {
          if (goals.isEmpty) {
            return EmptyState(
              icon: Icons.savings_outlined,
              title: 'No savings goals yet',
              message: 'Set a target like an emergency fund or a trip, and track contributions.',
              action: FilledButton.icon(
                  onPressed: _add, icon: const Icon(Icons.add), label: const Text('New goal')),
            );
          }
          final active = goals.where((g) => g.status == 'active').length;
          final achieved = goals.where((g) => g.status == 'achieved').length;
          return ListView(
            padding: const EdgeInsets.only(top: 12, bottom: 96),
            children: [
              StatRow(children: [
                StatTile(label: 'Active', value: '$active', icon: Icons.flag_outlined),
                StatTile(
                    label: 'Achieved',
                    value: '$achieved',
                    color: AppColors.income,
                    icon: Icons.emoji_events_outlined),
                StatTile(
                    label: 'Paused',
                    value: '${goals.length - active - achieved}',
                    icon: Icons.pause_circle_outline),
              ]),
              const SizedBox(height: 12),
              for (final g in goals) _GoalCard(goal: g, symbol: symbol, onTap: () => _open(g)),
            ],
          );
        },
      ),
    );
  }
}

class _GoalCard extends StatelessWidget {
  const _GoalCard({required this.goal, required this.symbol, required this.onTap});
  final Goal goal;
  final String symbol;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final g = goal;
    final t = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            GoalRing(goal: g, size: 64),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(g.name,
                        style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
                  GoalStatusChip(status: g.status),
                ]),
                const SizedBox(height: 4),
                Text.rich(TextSpan(children: [
                  TextSpan(
                      text: fmtIn(g.currentAmount, g.currency, symbol),
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  TextSpan(
                      text: ' of ${fmtIn(g.targetAmount, g.currency, symbol)}',
                      style: const TextStyle(color: AppColors.muted)),
                ])),
                if (g.targetDate != null)
                  Text(
                    'By ${fmtDate(g.targetDate)}'
                    '${g.monthsRemaining != null && g.status == 'active' ? ' · ${g.monthsRemaining} mo left' : ''}',
                    style: t.bodySmall?.copyWith(color: AppColors.muted),
                  ),
                if (g.status == 'active') ...[
                  const SizedBox(height: 6),
                  GoalPaceLine(goal: g, symbol: symbol),
                ],
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Circular progress in the goal's colour with its icon in the middle.
class GoalRing extends StatelessWidget {
  const GoalRing({super.key, required this.goal, this.size = 64});
  final Goal goal;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = hexColor(goal.color);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(alignment: Alignment.center, children: [
        SizedBox.expand(
          child: CircularProgressIndicator(
            value: (goal.progressPercent / 100).clamp(0, 1).toDouble(),
            strokeWidth: size / 10,
            color: c,
            backgroundColor: c.withValues(alpha: 0.15),
            strokeCap: StrokeCap.round,
          ),
        ),
        Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(biIcon(goal.icon), color: c, size: size * 0.3),
          Text(fmtPct(goal.progressPercent),
              style: TextStyle(fontSize: size * 0.17, fontWeight: FontWeight.w700)),
        ]),
      ]),
    );
  }
}

class GoalStatusChip extends StatelessWidget {
  const GoalStatusChip({super.key, required this.status});
  final String status;

  @override
  Widget build(BuildContext context) => switch (status) {
        'achieved' => const StatusChip('Achieved', color: AppColors.income),
        'paused' => const StatusChip('Paused'),
        _ => const StatusChip('Active', color: AppColors.info),
      };
}

/// "Need X/mo · planning Y/mo" with an on-track indicator.
class GoalPaceLine extends StatelessWidget {
  const GoalPaceLine({super.key, required this.goal, required this.symbol});
  final Goal goal;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final g = goal;
    final t = Theme.of(context).textTheme.bodySmall;
    final parts = [
      if (g.monthlyNeeded != null) 'Need ${fmtIn(g.monthlyNeeded, g.currency, symbol)}/mo',
      if (g.monthlyContribution != null)
        'planned ${fmtIn(g.monthlyContribution, g.currency, symbol)}/mo',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    final onTrack = g.onTrack;
    return Row(children: [
      if (onTrack != null) ...[
        Icon(onTrack ? Icons.check_circle : Icons.error_outline,
            size: 16, color: onTrack ? AppColors.income : AppColors.warning),
        const SizedBox(width: 4),
      ],
      Expanded(
        child: Text(
          '${onTrack == null ? '' : (onTrack ? 'On track · ' : 'Behind · ')}${parts.join(', ')}',
          style: t?.copyWith(
              color: onTrack == null
                  ? AppColors.muted
                  : (onTrack ? AppColors.income : AppColors.warning)),
        ),
      ),
    ]);
  }
}

/// Create ([existing] null) or edit a goal. Resolves true when saved.
Future<bool> openGoalForm(BuildContext context, {Goal? existing}) {
  return openMetaForm(context, (meta, session) {
    final r = existing?.raw;
    return EntityFormScreen(
      title: existing == null ? 'New savings goal' : 'Edit goal',
      initial: r == null
          ? {
              'currency': session.household?.baseCurrency?.id,
              'status': 'active',
              'icon': 'bi-piggy-bank',
              'color': '#0d6efd',
            }
          : {
              'name': r['name'],
              'target_amount': r['target_amount'],
              'currency': existing!.currency?.id,
              'target_date': r['target_date'],
              'monthly_contribution': r['monthly_contribution'],
              'icon': r['icon'],
              'color': r['color'],
              'status': r['status'],
              'notes': r['notes'],
            },
      fields: [
        const FieldSpec.text('name', 'Name', required: true, hint: 'e.g. Emergency fund'),
        const FieldSpec.money('target_amount', 'Target amount', required: true),
        FieldSpec.select('currency', 'Currency', options: currencyOptions(meta)),
        const FieldSpec.date('target_date', 'Target date',
            help: 'Optional. Used to work out how much to save each month.'),
        const FieldSpec.money('monthly_contribution', 'Planned monthly contribution'),
        const FieldSpec.color('color', 'Colour'),
        const FieldSpec.icon('icon', 'Icon'),
        FieldSpec.select('status', 'Status',
            options: choiceOptions(meta, 'goal_status'), required: true),
        const FieldSpec.multiline('notes', 'Notes'),
      ],
      onSubmit: (v) => existing == null
          ? session.api.post('goals/', v)
          : session.api.patch('goals/${existing.id}/', v),
    );
  });
}
