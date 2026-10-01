import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api.dart';
import '../core/format.dart';
import '../core/icons.dart';
import 'common.dart';

enum FieldKind { text, multiline, money, integer, date, select, multiSelect, toggle, color, icon }

class Option {
  const Option(this.value, this.label);
  final Object? value;
  final String label;
}

/// One form field. [name] is the API/Django form field name; server-side
/// validation errors for that name are shown under the field.
class FieldSpec {
  const FieldSpec._(
    this.kind,
    this.name,
    this.label, {
    this.required = false,
    this.hint,
    this.help,
    this.options,
    this.optionsBuilder,
    this.visibleWhen,
    this.keyboard,
    this.obscure = false,
  });

  const FieldSpec.text(String name, String label,
      {bool required = false, String? hint, String? help, TextInputType? keyboard,
      bool obscure = false, bool Function(Map<String, dynamic>)? visibleWhen})
      : this._(FieldKind.text, name, label,
            required: required, hint: hint, help: help, keyboard: keyboard,
            obscure: obscure, visibleWhen: visibleWhen);

  const FieldSpec.multiline(String name, String label,
      {bool required = false, String? hint, bool Function(Map<String, dynamic>)? visibleWhen})
      : this._(FieldKind.multiline, name, label,
            required: required, hint: hint, visibleWhen: visibleWhen);

  const FieldSpec.money(String name, String label,
      {bool required = false, String? help, bool Function(Map<String, dynamic>)? visibleWhen})
      : this._(FieldKind.money, name, label,
            required: required, help: help, visibleWhen: visibleWhen);

  const FieldSpec.integer(String name, String label,
      {bool required = false, String? help, bool Function(Map<String, dynamic>)? visibleWhen})
      : this._(FieldKind.integer, name, label,
            required: required, help: help, visibleWhen: visibleWhen);

  const FieldSpec.date(String name, String label,
      {bool required = false, String? help, bool Function(Map<String, dynamic>)? visibleWhen})
      : this._(FieldKind.date, name, label,
            required: required, help: help, visibleWhen: visibleWhen);

  /// Single choice. Use [optionsBuilder] when options depend on other values
  /// (e.g. categories filtered by the chosen transaction type).
  const FieldSpec.select(String name, String label,
      {List<Option>? options,
      List<Option> Function(Map<String, dynamic> values)? optionsBuilder,
      bool required = false,
      String? help,
      bool Function(Map<String, dynamic>)? visibleWhen})
      : this._(FieldKind.select, name, label,
            options: options, optionsBuilder: optionsBuilder, required: required,
            help: help, visibleWhen: visibleWhen);

  const FieldSpec.multiSelect(String name, String label,
      {required List<Option> options, String? help})
      : this._(FieldKind.multiSelect, name, label, options: options, help: help);

  const FieldSpec.toggle(String name, String label,
      {String? help, bool Function(Map<String, dynamic>)? visibleWhen})
      : this._(FieldKind.toggle, name, label, help: help, visibleWhen: visibleWhen);

  const FieldSpec.color(String name, String label) : this._(FieldKind.color, name, label);

  const FieldSpec.icon(String name, String label) : this._(FieldKind.icon, name, label);

  final FieldKind kind;
  final String name;
  final String label;
  final bool required;
  final String? hint;
  final String? help;
  final List<Option>? options;
  final List<Option> Function(Map<String, dynamic>)? optionsBuilder;
  final bool Function(Map<String, dynamic>)? visibleWhen;
  final TextInputType? keyboard;
  final bool obscure;
}

/// Full-screen create/edit form driven by [fields].
///
/// [initial] holds API-shaped values: ids for selects, `YYYY-MM-DD` or
/// DateTime for dates, strings/nums for money, bools for toggles. [onSubmit]
/// receives the same shape (dates as `YYYY-MM-DD`, empty optional
/// selects/dates as null) and should call the API; throwing [ApiException]
/// shows its field errors inline. On success the screen pops with `true`.
class EntityFormScreen extends StatefulWidget {
  const EntityFormScreen({
    super.key,
    required this.title,
    required this.fields,
    required this.onSubmit,
    this.initial = const {},
    this.submitLabel = 'Save',
    this.intro,
  });

  final String title;
  final List<FieldSpec> fields;
  final Map<String, dynamic> initial;
  final Future<void> Function(Map<String, dynamic> values) onSubmit;
  final String submitLabel;
  final Widget? intro;

  @override
  State<EntityFormScreen> createState() => _EntityFormScreenState();
}

class _EntityFormScreenState extends State<EntityFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final Map<String, dynamic> _values;
  final Map<String, TextEditingController> _text = {};
  Map<String, List<String>> _serverErrors = {};
  String? _banner;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _values = {};
    for (final f in widget.fields) {
      var v = widget.initial[f.name];
      switch (f.kind) {
        case FieldKind.text:
        case FieldKind.multiline:
        case FieldKind.money:
        case FieldKind.integer:
          _text[f.name] = TextEditingController(text: v?.toString() ?? '');
        case FieldKind.date:
          if (v is String) v = DateTime.tryParse(v);
          _values[f.name] = v;
        case FieldKind.toggle:
          _values[f.name] = v == true;
        case FieldKind.multiSelect:
          _values[f.name] = List<Object?>.from(v as List? ?? const []);
        case FieldKind.color:
          _values[f.name] = v ?? '#0d6efd';
        case FieldKind.icon:
          _values[f.name] = v ?? 'bi-tag';
        case FieldKind.select:
          _values[f.name] = v;
      }
    }
  }

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic> get _current {
    final out = <String, dynamic>{..._values};
    final secret = widget.fields.where((f) => f.obscure).map((f) => f.name).toSet();
    // Never trim passwords — spaces may be part of them.
    _text.forEach((k, c) => out[k] = secret.contains(k) ? c.text : c.text.trim());
    return out;
  }

  Map<String, dynamic> _payload() {
    final out = <String, dynamic>{};
    final cur = _current;
    for (final f in widget.fields) {
      if (f.visibleWhen != null && !f.visibleWhen!(cur)) continue;
      final v = cur[f.name];
      switch (f.kind) {
        case FieldKind.date:
          out[f.name] = v is DateTime ? apiDate(v) : null;
        case FieldKind.money:
        case FieldKind.integer:
          final s = (v as String).replaceAll(',', '');
          out[f.name] = s.isEmpty ? null : s;
        default:
          out[f.name] = v;
      }
    }
    return out;
  }

  Future<void> _submit() async {
    setState(() {
      _serverErrors = {};
      _banner = null;
    });
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await widget.onSubmit(_payload());
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      final known = widget.fields.map((f) => f.name).toSet();
      final unknown = e.fieldErrors.entries
          .where((x) => !known.contains(x.key))
          .map((x) => x.key == 'non_field_errors' ? x.value.join(' ') : '${humanize(x.key)}: ${x.value.join(' ')}')
          .toList();
      setState(() {
        _serverErrors = e.fieldErrors;
        _banner = unknown.isNotEmpty ? unknown.join('\n') : (e.fieldErrors.isEmpty ? e.message : null);
      });
      _formKey.currentState!.validate();
    } catch (e) {
      setState(() => _banner = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _err(FieldSpec f) {
    final e = _serverErrors[f.name];
    return (e == null || e.isEmpty) ? null : e.join(' ');
  }

  String? _requiredCheck(FieldSpec f, Object? v) {
    if (!f.required) return null;
    if (v == null || (v is String && v.trim().isEmpty)) return 'Required';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final cur = _current;
    final visible =
        widget.fields.where((f) => f.visibleWhen == null || f.visibleWhen!(cur)).toList();
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            if (widget.intro != null) widget.intro!,
            if (_banner != null)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_banner!,
                      style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
                ),
              ),
            for (final f in visible)
              Padding(padding: const EdgeInsets.only(top: 12), child: _field(f)),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _submit,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              child: _saving
                  ? const SizedBox(
                      width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(widget.submitLabel),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _deco(FieldSpec f) => InputDecoration(
        labelText: f.required ? '${f.label} *' : f.label,
        hintText: f.hint,
        helperText: f.help,
        helperMaxLines: 3,
        errorText: _err(f),
        errorMaxLines: 3,
        border: const OutlineInputBorder(),
      );

  Widget _field(FieldSpec f) {
    switch (f.kind) {
      case FieldKind.text:
      case FieldKind.multiline:
        return TextFormField(
          controller: _text[f.name],
          decoration: _deco(f),
          keyboardType: f.kind == FieldKind.multiline ? TextInputType.multiline : f.keyboard,
          minLines: f.kind == FieldKind.multiline ? 2 : 1,
          maxLines: f.kind == FieldKind.multiline ? 6 : 1,
          obscureText: f.obscure,
          autocorrect: !f.obscure,
          textCapitalization: f.obscure || f.keyboard == TextInputType.emailAddress
              ? TextCapitalization.none
              : TextCapitalization.sentences,
          validator: (v) => _requiredCheck(f, v) ?? _err(f),
          onChanged: (_) => setState(() {}),
        );
      case FieldKind.money:
      case FieldKind.integer:
        final isInt = f.kind == FieldKind.integer;
        return TextFormField(
          controller: _text[f.name],
          decoration: _deco(f),
          keyboardType: TextInputType.numberWithOptions(decimal: !isInt, signed: false),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(isInt ? r'[0-9]' : r'[0-9.,]')),
          ],
          validator: (v) {
            final r = _requiredCheck(f, v);
            if (r != null) return r;
            if (v != null && v.isNotEmpty && double.tryParse(v.replaceAll(',', '')) == null) {
              return 'Enter a number';
            }
            return _err(f);
          },
          onChanged: (_) => setState(() {}),
        );
      case FieldKind.date:
        final d = _values[f.name] as DateTime?;
        return FormField<DateTime>(
          initialValue: d,
          validator: (_) => _requiredCheck(f, _values[f.name]) ?? _err(f),
          builder: (state) => InkWell(
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _values[f.name] as DateTime? ?? DateTime.now(),
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
              );
              if (picked != null) setState(() => _values[f.name] = picked);
            },
            child: InputDecorator(
              decoration: _deco(f).copyWith(
                errorText: state.errorText,
                suffixIcon: (!f.required && _values[f.name] != null)
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(() => _values[f.name] = null),
                      )
                    : const Icon(Icons.calendar_today_outlined),
              ),
              child: Text(_values[f.name] == null ? '' : fmtDate(_values[f.name] as DateTime)),
            ),
          ),
        );
      case FieldKind.select:
        final opts = f.optionsBuilder?.call(_current) ?? f.options ?? const [];
        var value = _values[f.name];
        if (value != null && !opts.any((o) => o.value == value)) value = null;
        return DropdownButtonFormField<Object?>(
          // Re-key when the option set changes so a dependent select resets.
          key: ValueKey('${f.name}|${opts.map((o) => o.value).join(',')}|$value'),
          initialValue: value,
          isExpanded: true,
          decoration: _deco(f),
          items: [
            if (!f.required) const DropdownMenuItem(value: null, child: Text('— None —')),
            for (final o in opts)
              DropdownMenuItem(value: o.value, child: Text(o.label, overflow: TextOverflow.ellipsis)),
          ],
          validator: (v) => _requiredCheck(f, v) ?? _err(f),
          onChanged: (v) => setState(() => _values[f.name] = v),
        );
      case FieldKind.multiSelect:
        final selected = _values[f.name] as List<Object?>;
        return InputDecorator(
          decoration: _deco(f),
          child: Wrap(spacing: 8, runSpacing: 4, children: [
            for (final o in f.options ?? const <Option>[])
              FilterChip(
                label: Text(o.label),
                selected: selected.contains(o.value),
                onSelected: (on) => setState(() {
                  on ? selected.add(o.value) : selected.remove(o.value);
                }),
              ),
          ]),
        );
      case FieldKind.toggle:
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(f.label),
          subtitle: (f.help ?? _err(f)) == null
              ? null
              : Text(_err(f) ?? f.help!,
                  style: _err(f) == null ? null : TextStyle(color: Theme.of(context).colorScheme.error)),
          value: _values[f.name] as bool,
          onChanged: (v) => setState(() => _values[f.name] = v),
        );
      case FieldKind.color:
        return _ColorPicker(
          label: f.label,
          value: _values[f.name] as String,
          error: _err(f),
          onChanged: (v) => setState(() => _values[f.name] = v),
        );
      case FieldKind.icon:
        return _IconPicker(
          label: f.label,
          value: _values[f.name] as String,
          color: _values['color'] as String?,
          onChanged: (v) => setState(() => _values[f.name] = v),
        );
    }
  }
}

const _palette = [
  '#0d6efd', '#6610f2', '#6f42c1', '#d63384', '#dc3545', '#fd7e14',
  '#ffc107', '#198754', '#20c997', '#0dcaf0', '#6c757d', '#343a40',
];

class _ColorPicker extends StatelessWidget {
  const _ColorPicker({required this.label, required this.value, required this.onChanged, this.error});
  final String label;
  final String value;
  final String? error;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
          labelText: label, errorText: error, border: const OutlineInputBorder()),
      child: Wrap(spacing: 10, runSpacing: 10, children: [
        for (final hex in _palette)
          GestureDetector(
            onTap: () => onChanged(hex),
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: hexColor(hex),
                shape: BoxShape.circle,
                border: Border.all(
                  width: 3,
                  color: hex.toLowerCase() == value.toLowerCase()
                      ? Theme.of(context).colorScheme.onSurface
                      : Colors.transparent,
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

class _IconPicker extends StatelessWidget {
  const _IconPicker({required this.label, required this.value, required this.onChanged, this.color});
  final String label;
  final String value;
  final String? color;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = hexColor(color, Theme.of(context).colorScheme.primary);
    return InputDecorator(
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      child: Wrap(spacing: 4, runSpacing: 4, children: [
        for (final e in biIcons.entries)
          InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => onChanged(e.key),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: e.key == value ? c.withValues(alpha: 0.2) : null,
              ),
              child: Icon(e.value, size: 22, color: e.key == value ? c : AppColors.muted),
            ),
          ),
      ]),
    );
  }
}

/// Push a form; resolves true when it saved.
Future<bool> openForm(BuildContext context, EntityFormScreen form) async {
  final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => form));
  return saved == true;
}
