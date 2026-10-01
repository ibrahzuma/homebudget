import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/format.dart';
import '../core/icons.dart';

/// Brand-ish semantic colours used across screens.
class AppColors {
  static const income = Color(0xFF198754);
  static const expense = Color(0xFFDC3545);
  static const warning = Color(0xFFE0A100);
  static const info = Color(0xFF0D6EFD);
  static const muted = Color(0xFF6C757D);

  static Color forLevel(String level) => switch (level) {
        'danger' => expense,
        'warning' => warning,
        'success' => income,
        _ => info,
      };
}

/// Loads data with [load], shows spinner / error-with-retry / content, and
/// wraps content in pull-to-refresh. Call `reload` from the builder after a
/// mutation.
class LoadBuilder<T> extends StatefulWidget {
  const LoadBuilder({super.key, required this.load, required this.builder});

  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data, Future<void> Function() reload) builder;

  @override
  State<LoadBuilder<T>> createState() => LoadBuilderState<T>();
}

class LoadBuilderState<T> extends State<LoadBuilder<T>> {
  T? _data;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    setState(() {
      _loading = _data == null;
      _error = null;
    });
    try {
      final d = await widget.load();
      if (!mounted) return;
      setState(() {
        _data = d;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
      if (_data != null) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _data == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_data == null) {
      return ErrorState(error: _error, onRetry: reload);
    }
    return RefreshIndicator(
      onRefresh: reload,
      child: widget.builder(context, _data as T, reload),
    );
  }
}

class ErrorState extends StatelessWidget {
  const ErrorState({super.key, this.error, required this.onRetry});
  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final offline = error is ApiException && (error as ApiException).isNetwork;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(offline ? Icons.wifi_off : Icons.error_outline, size: 48, color: AppColors.muted),
          const SizedBox(height: 12),
          Text(error?.toString() ?? 'Something went wrong.', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton.tonal(onPressed: onRetry, child: const Text('Try again')),
        ]),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    // Scrollable so pull-to-refresh still works on an empty list.
    return LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: c.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 56, color: AppColors.muted.withValues(alpha: 0.6)),
                const SizedBox(height: 12),
                Text(title, style: t.titleMedium, textAlign: TextAlign.center),
                if (message != null) ...[
                  const SizedBox(height: 6),
                  Text(message!, style: t.bodyMedium?.copyWith(color: AppColors.muted),
                      textAlign: TextAlign.center),
                ],
                if (action != null) ...[const SizedBox(height: 16), action!],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing, this.padding});
  final String title;
  final Widget? trailing;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(16, 20, 8, 8),
      child: Row(children: [
        Expanded(
          child: Text(title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600, letterSpacing: 0.2)),
        ),
        ?trailing,
      ]),
    );
  }
}

/// Small labelled number, used in summary rows.
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, this.color, this.icon});
  final String label;
  final String value;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: color ?? AppColors.muted),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(label,
                  style: t.labelMedium?.copyWith(color: AppColors.muted),
                  overflow: TextOverflow.ellipsis),
            ),
          ]),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value,
                style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: color)),
          ),
        ]),
      ),
    );
  }
}

/// Two or three StatTiles side by side.
class StatRow extends StatelessWidget {
  const StatRow({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(child: children[i]),
          ],
        ],
      ),
    );
  }
}

class ProgressLine extends StatelessWidget {
  const ProgressLine({super.key, required this.percent, this.color, this.height = 8});
  final double percent; // 0..100
  final Color? color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = color ??
        (percent >= 100
            ? AppColors.expense
            : percent >= 80
                ? AppColors.warning
                : Theme.of(context).colorScheme.primary);
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: LinearProgressIndicator(
        value: (percent / 100).clamp(0, 1).toDouble(),
        minHeight: height,
        color: c,
        backgroundColor: c.withValues(alpha: 0.15),
      ),
    );
  }
}

/// Round coloured icon for categories, goals and projects.
class IconBadge extends StatelessWidget {
  const IconBadge({super.key, this.icon, this.iconData, this.color, this.size = 40});
  final String? icon; // bootstrap name
  final IconData? iconData;
  final String? color; // hex
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = hexColor(color);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: c.withValues(alpha: 0.15), shape: BoxShape.circle),
      child: Icon(iconData ?? biIcon(icon), color: c, size: size * 0.5),
    );
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.label, {super.key, this.color});
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label,
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: c, fontWeight: FontWeight.w600)),
    );
  }
}

/// Badge count on an icon (nav bar, menu rows).
class CountBadge extends StatelessWidget {
  const CountBadge({super.key, required this.count, required this.child});
  final int count;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Badge(isLabelVisible: count > 0, label: Text('$count'), child: child);
}

void showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(error.toString()),
      backgroundColor: Theme.of(context).colorScheme.error,
    ));
}

void showOk(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  String? message,
  String confirmLabel = 'Delete',
  bool destructive = true,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: message == null ? null : Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error)
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Runs [action], shows [success] or the error. Returns whether it succeeded.
Future<bool> runAction(BuildContext context, Future<void> Function() action,
    {String? success}) async {
  try {
    await action();
    if (context.mounted && success != null) showOk(context, success);
    return true;
  } catch (e) {
    if (context.mounted) showError(context, e);
    return false;
  }
}

/// Prompt for a single line of text (notes, names). Null when cancelled.
Future<String?> promptText(BuildContext context,
    {required String title, String? label, String initial = '', String okLabel = 'OK'}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        maxLines: null,
        decoration: InputDecoration(labelText: label),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: Text(okLabel)),
      ],
    ),
  );
}

Future<T?> push<T>(BuildContext context, Widget screen) =>
    Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => screen));
