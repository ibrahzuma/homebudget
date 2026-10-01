import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../../widgets/entity_form.dart';
import '../transactions/txn_events.dart';

/// Income and expense categories with add / edit / delete.
class CategoriesScreen extends StatefulWidget {
  const CategoriesScreen({super.key});

  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends State<CategoriesScreen> {
  final _loader = GlobalKey<LoadBuilderState<List<CategoryBrief>>>();

  Future<List<CategoryBrief>> _load() async {
    final res = await context.read<Session>().api.get('categories/') as List;
    return [for (final c in res) CategoryBrief.fromJson(c as Map<String, dynamic>)];
  }

  Future<void> _reload() async => _loader.currentState?.reload();

  Future<void> _openForm({CategoryBrief? existing, String type = 'expense'}) async {
    final session = context.read<Session>();
    final form = EntityFormScreen(
      title: existing == null ? 'New category' : 'Edit category',
      initial: {
        'name': existing?.name,
        'category_type': existing?.type ?? type,
        'color': existing?.color ?? '#0d6efd',
        'icon': existing?.icon ?? 'bi-tag',
      },
      fields: const [
        FieldSpec.text('name', 'Name', required: true, hint: 'e.g. Groceries'),
        FieldSpec.select('category_type', 'Type', required: true, options: [
          Option('expense', 'Expense'),
          Option('income', 'Income'),
        ]),
        FieldSpec.color('color', 'Colour'),
        FieldSpec.icon('icon', 'Icon'),
      ],
      onSubmit: (v) async {
        if (existing == null) {
          await session.api.post('categories/', v);
        } else {
          await session.api.patch('categories/${existing.id}/', v);
        }
      },
    );
    if (await openForm(context, form)) {
      await session.refreshMeta().catchError((_) {});
      if (existing != null) notifyTransactionsChanged(); // names/icons shown on rows
      await _reload();
    }
  }

  Future<void> _delete(CategoryBrief c) async {
    final ok = await confirm(context,
        title: 'Delete "${c.name}"?',
        message: 'Transactions in this category are kept, but they lose their category '
            'and show as uncategorized. Budgets and auto-categorize rules for it are '
            'deleted as well.');
    if (!ok || !mounted) return;
    final session = context.read<Session>();
    final done = await runAction(context, () => session.api.delete('categories/${c.id}/'),
        success: 'Category deleted');
    if (!done) return;
    await session.refreshMeta().catchError((_) {});
    notifyTransactionsChanged();
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Categories')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openForm(),
        icon: const Icon(Icons.add),
        label: const Text('Add category'),
      ),
      body: LoadBuilder<List<CategoryBrief>>(
        key: _loader,
        load: _load,
        builder: (context, cats, _) {
          if (cats.isEmpty) {
            return EmptyState(
              icon: Icons.sell_outlined,
              title: 'No categories yet',
              message: 'Categories group your income and spending for budgets and reports.',
              action: FilledButton.icon(
                onPressed: () => _openForm(),
                icon: const Icon(Icons.add),
                label: const Text('Add category'),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              for (final (type, label) in const [('income', 'Income'), ('expense', 'Expense')])
                _Section(
                  label: label,
                  categories: cats.where((c) => c.type == type).toList(),
                  onAdd: () => _openForm(type: type),
                  onEdit: (c) => _openForm(existing: c),
                  onDelete: _delete,
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.label,
    required this.categories,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });

  final String label;
  final List<CategoryBrief> categories;
  final VoidCallback onAdd;
  final ValueChanged<CategoryBrief> onEdit;
  final ValueChanged<CategoryBrief> onDelete;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader(
        '$label (${categories.length})',
        trailing: TextButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add'),
        ),
      ),
      Card(
        clipBehavior: Clip.antiAlias,
        child: categories.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(16),
                child: Text('No ${label.toLowerCase()} categories yet.',
                    style: const TextStyle(color: AppColors.muted)),
              )
            : Column(children: [
                for (var i = 0; i < categories.length; i++) ...[
                  if (i > 0) const Divider(height: 1, indent: 72),
                  _CategoryTile(
                    category: categories[i],
                    onEdit: () => onEdit(categories[i]),
                    onDelete: () => onDelete(categories[i]),
                  ),
                ],
              ]),
      ),
    ]);
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({required this.category, required this.onEdit, required this.onDelete});
  final CategoryBrief category;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: IconBadge(icon: category.icon, color: category.color),
      title: Text(category.name),
      onTap: onEdit,
      trailing: PopupMenuButton<String>(
        onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('Edit')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }
}
