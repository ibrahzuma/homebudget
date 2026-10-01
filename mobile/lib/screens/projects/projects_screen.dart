import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../../widgets/entity_form.dart';
import '../networth/finance_shared.dart';
import 'project_detail_screen.dart';

/// Projects: budget envelopes that transactions can be tagged with.
class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({super.key});

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  final _loader = GlobalKey<LoadBuilderState<List<Project>>>();

  Future<List<Project>> _load() async {
    final list = await context.read<Session>().api.get('projects/') as List;
    return list.map((e) => Project.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> _reload() async => _loader.currentState?.reload();

  Future<void> _add() async {
    if (await openProjectForm(context)) _reload();
  }

  Future<void> _open(Project p) async {
    await push(context, ProjectDetailScreen(id: p.id));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final symbol = context.watch<Session>().currencySymbol;
    return Scaffold(
      appBar: AppBar(title: const Text('Projects')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('New project'),
      ),
      body: LoadBuilder<List<Project>>(
        key: _loader,
        load: _load,
        builder: (context, projects, reload) {
          if (projects.isEmpty) {
            return EmptyState(
              icon: Icons.bookmark_outline,
              title: 'No projects yet',
              message: 'Give a renovation, wedding or trip its own budget, then tag '
                  'transactions with it to see what it really cost.',
              action: FilledButton.icon(
                  onPressed: _add, icon: const Icon(Icons.add), label: const Text('New project')),
            );
          }
          return ListView(
            padding: const EdgeInsets.only(top: 12, bottom: 96),
            children: [
              for (final p in projects)
                _ProjectCard(project: p, symbol: symbol, onTap: () => _open(p)),
            ],
          );
        },
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({required this.project, required this.symbol, required this.onTap});
  final Project project;
  final String symbol;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = project;
    final t = Theme.of(context).textTheme;
    final dates = projectDates(p);
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              IconBadge(icon: p.icon, color: p.color, size: 38),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p.name,
                      style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  if (dates.isNotEmpty)
                    Text(dates, style: t.bodySmall?.copyWith(color: AppColors.muted)),
                ]),
              ),
              ProjectStatusChip(status: p.status),
            ]),
            const SizedBox(height: 12),
            ProjectSpendBar(project: p, symbol: symbol),
          ]),
        ),
      ),
    );
  }
}

/// "Spent X of Y" with a progress bar; red with a flag when over budget.
class ProjectSpendBar extends StatelessWidget {
  const ProjectSpendBar({super.key, required this.project, required this.symbol});
  final Project project;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final p = project;
    final t = Theme.of(context).textTheme.bodySmall;
    final spent = fmtIn(p.spent, p.currency, symbol);
    if (p.budget <= 0) {
      return Text('Spent $spent · no budget set', style: t?.copyWith(color: AppColors.muted));
    }
    final color = p.isOverBudget ? AppColors.expense : hexColor(p.color);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ProgressLine(percent: p.progressPercent, color: color),
      const SizedBox(height: 6),
      Row(children: [
        Expanded(
          child: Text('Spent $spent of ${fmtIn(p.budget, p.currency, symbol)}',
              style: t?.copyWith(color: AppColors.muted)),
        ),
        if (p.isOverBudget)
          Text('Over by ${fmtIn(p.spent - p.budget, p.currency, symbol)}',
              style: t?.copyWith(color: AppColors.expense, fontWeight: FontWeight.w600))
        else
          Text(fmtPct(p.progressPercent), style: t?.copyWith(fontWeight: FontWeight.w600)),
      ]),
    ]);
  }
}

class ProjectStatusChip extends StatelessWidget {
  const ProjectStatusChip({super.key, required this.status});
  final String status;

  @override
  Widget build(BuildContext context) => switch (status) {
        'active' => const StatusChip('Active', color: AppColors.info),
        'completed' => const StatusChip('Completed', color: AppColors.income),
        'cancelled' => const StatusChip('Cancelled'),
        _ => const StatusChip('Planning', color: AppColors.warning),
      };
}

String projectDates(Project p) {
  if (p.startDate == null && p.endDate == null) return '';
  if (p.endDate == null) return 'From ${fmtDate(p.startDate)}';
  if (p.startDate == null) return 'Until ${fmtDate(p.endDate)}';
  return '${fmtDate(p.startDate)} – ${fmtDate(p.endDate)}';
}

/// Create ([existing] null) or edit a project. Resolves true when saved.
/// Refreshes the session pickers, since projects are a transaction field.
Future<bool> openProjectForm(BuildContext context, {Project? existing}) async {
  final saved = await openMetaForm(context, (meta, session) {
    final r = existing?.raw;
    return EntityFormScreen(
      title: existing == null ? 'New project' : 'Edit project',
      initial: r == null
          ? {
              'budget': '0',
              'currency': session.household?.baseCurrency?.id,
              'status': 'planning',
              'color': '#6610f2',
              'icon': 'bi-bookmark-star',
            }
          : {
              'name': r['name'],
              'description': r['description'],
              'budget': r['budget'],
              'currency': existing!.currency?.id,
              'start_date': r['start_date'],
              'end_date': r['end_date'],
              'status': r['status'],
              'color': r['color'],
              'icon': r['icon'],
            },
      fields: [
        const FieldSpec.text('name', 'Name', required: true, hint: 'e.g. Kitchen renovation'),
        const FieldSpec.multiline('description', 'Description'),
        const FieldSpec.money('budget', 'Budget', required: true,
            help: 'Enter 0 if this project has no budget cap.'),
        FieldSpec.select('currency', 'Currency', options: currencyOptions(meta)),
        const FieldSpec.date('start_date', 'Start date'),
        const FieldSpec.date('end_date', 'End date'),
        FieldSpec.select('status', 'Status',
            options: choiceOptions(meta, 'project_status'), required: true),
        const FieldSpec.color('color', 'Colour'),
        const FieldSpec.icon('icon', 'Icon'),
      ],
      onSubmit: (v) => existing == null
          ? session.api.post('projects/', v)
          : session.api.patch('projects/${existing.id}/', v),
    );
  });
  if (saved && context.mounted) refreshProjectPickers(context.read<Session>());
  return saved;
}

/// Projects appear in the transaction form's picker; keep the cached meta current.
void refreshProjectPickers(Session session) {
  session.refreshMeta().catchError((_) {});
}
