import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/format.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../transactions/txn_events.dart';

const _sampleCsv = 'date,type,amount,currency,category,payee,description\n'
    '2025-04-15,expense,45.50,USD,Groceries,Supermarket,Weekly shop\n'
    '2025-04-15,income,3000.00,USD,Salary,Employer,April salary\n'
    '04/16/2025,expense,80.00,USD,Fuel,TotalEnergies,Filled tank';

/// Export every transaction to CSV (shared via the system sheet) and import
/// transactions from a CSV file.
class ImportExportScreen extends StatefulWidget {
  const ImportExportScreen({super.key});

  @override
  State<ImportExportScreen> createState() => _ImportExportScreenState();
}

class _ImportExportScreenState extends State<ImportExportScreen> {
  bool _exporting = false;
  bool _importing = false;
  String? _importedName;
  _ImportResult? _result;

  Future<void> _export(Rect? shareOrigin) async {
    final api = context.read<Session>().api;
    setState(() => _exporting = true);
    try {
      final bytes = await api.download('transactions/export/');
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/transactions_${apiDate(DateTime.now())}.csv');
      await file.writeAsBytes(bytes, flush: true);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, mimeType: 'text/csv')],
        subject: 'Home Budget transactions',
        sharePositionOrigin: shareOrigin,
      ));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _import() async {
    final api = context.read<Session>().api;
    final PlatformFile? picked;
    try {
      picked = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['csv']);
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (picked == null || !mounted) return;

    setState(() {
      _importing = true;
      _importedName = picked!.name;
      _result = null;
    });
    try {
      final path = await _localPath(picked);
      final res = await api.upload('transactions/import/', 'file', path) as Map<String, dynamic>;
      final result = _ImportResult(
        created: res['created'] as int? ?? 0,
        errors: [for (final e in res['errors'] as List? ?? const []) e.toString()],
      );
      if (result.created > 0) notifyTransactionsChanged();
      if (!mounted) return;
      setState(() => _result = result);
      context.read<Session>()
        ..refreshMeta().ignore() // the import can create categories
        ..refreshBadges(); // and trigger budget alerts
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// Uploads need a file on disk; content-URI picks are copied to temp first.
  Future<String> _localPath(PlatformFile f) async {
    final path = f.path;
    if (path != null) return path;
    final dir = await getTemporaryDirectory();
    final copy = File('${dir.path}/import_${DateTime.now().millisecondsSinceEpoch}.csv');
    await copy.writeAsBytes(await f.readAsBytes(), flush: true);
    return copy.path;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Import / export')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _ExportCard(busy: _exporting, onExport: _export),
          _ImportCard(busy: _importing, onImport: _import),
          if (_importing || _result != null)
            _ResultCard(fileName: _importedName, result: _result),
          const _FormatCard(),
        ],
      ),
    );
  }
}

class _ImportResult {
  _ImportResult({required this.created, required this.errors});
  final int created;
  final List<String> errors;
}

class _ExportCard extends StatelessWidget {
  const _ExportCard({required this.busy, required this.onExport});
  final bool busy;
  final ValueChanged<Rect?> onExport;

  @override
  Widget build(BuildContext context) {
    return _ActionCard(
      icon: Icons.file_download_outlined,
      title: 'Export transactions',
      body: 'Download every transaction as a CSV file for spreadsheets, tax '
          'preparation or backup, then save or send it from the share sheet.',
      button: Builder(
        builder: (ctx) => FilledButton.icon(
          onPressed: busy
              ? null
              : () {
                  // iPad share popovers need an anchor rectangle.
                  final box = ctx.findRenderObject() as RenderBox?;
                  onExport(box == null ? null : box.localToGlobal(Offset.zero) & box.size);
                },
          icon: busy ? const _Spinner() : const Icon(Icons.ios_share),
          label: Text(busy ? 'Preparing…' : 'Export CSV'),
        ),
      ),
    );
  }
}

class _ImportCard extends StatelessWidget {
  const _ImportCard({required this.busy, required this.onImport});
  final bool busy;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return _ActionCard(
      icon: Icons.file_upload_outlined,
      title: 'Import from CSV',
      body: 'Add transactions in bulk from a CSV file (up to 5 MB). Imported rows are '
          'added under your name and run through your auto-categorize rules.',
      button: FilledButton.tonalIcon(
        onPressed: busy ? null : onImport,
        icon: busy ? const _Spinner() : const Icon(Icons.upload_file),
        label: Text(busy ? 'Importing…' : 'Choose CSV file'),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({required this.icon, required this.title, required this.body, required this.button});
  final IconData icon;
  final String title;
  final String body;
  final Widget button;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 10),
            Text(title, style: t.titleMedium),
          ]),
          const SizedBox(height: 8),
          Text(body, style: t.bodyMedium?.copyWith(color: AppColors.muted)),
          const SizedBox(height: 14),
          SizedBox(width: double.infinity, child: button),
        ]),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.fileName, required this.result});
  final String? fileName;
  final _ImportResult? result;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final r = result;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Import result', style: t.titleMedium),
          if (fileName != null)
            Text(fileName!, style: t.bodySmall?.copyWith(color: AppColors.muted)),
          const SizedBox(height: 12),
          if (r == null)
            const LinearProgressIndicator()
          else ...[
            Row(children: [
              Icon(r.created > 0 ? Icons.check_circle : Icons.info_outline,
                  color: r.created > 0 ? AppColors.income : AppColors.muted),
              const SizedBox(width: 8),
              Text('Created ${r.created} transaction${r.created == 1 ? '' : 's'}.',
                  style: t.bodyLarge),
            ]),
            if (r.errors.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(children: [
                const Icon(Icons.warning_amber, color: AppColors.warning),
                const SizedBox(width: 8),
                Text('${r.errors.length} row${r.errors.length == 1 ? '' : 's'} skipped',
                    style: t.bodyLarge),
              ]),
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(maxHeight: 240),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.all(10),
                  children: [
                    for (final e in r.errors)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(e, style: t.bodySmall),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ]),
      ),
    );
  }
}

class _FormatCard extends StatelessWidget {
  const _FormatCard();

  static const _columns = [
    ('date', 'YYYY-MM-DD or MM/DD/YYYY'),
    ('type', 'income or expense'),
    ('amount', 'e.g. 45.50 (commas are ignored)'),
    ('currency', 'Code such as USD or TZS; blank uses the household currency'),
    ('category', 'Name; created automatically if it doesn\'t exist'),
    ('payee', 'Optional'),
    ('description', 'Optional'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final mono = t.bodySmall?.copyWith(fontFamily: 'monospace');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('CSV format', style: t.titleMedium),
          const SizedBox(height: 4),
          Text('The first row must be a header with these column names (any order):',
              style: t.bodyMedium?.copyWith(color: AppColors.muted)),
          const SizedBox(height: 8),
          for (final (name, help) in _columns)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                  width: 96,
                  child: Text(name, style: mono?.copyWith(fontWeight: FontWeight.w700)),
                ),
                Expanded(child: Text(help, style: t.bodySmall)),
              ]),
            ),
          const SizedBox(height: 12),
          Text('Example', style: t.labelLarge),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(_sampleCsv, style: mono),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) =>
      const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2));
}
