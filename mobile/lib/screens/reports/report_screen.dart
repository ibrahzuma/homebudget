import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import 'report_sections.dart';

/// Month-by-month summary of the household's money, with CSV export.
class MonthlyReportScreen extends StatefulWidget {
  const MonthlyReportScreen({super.key});

  @override
  State<MonthlyReportScreen> createState() => _MonthlyReportScreenState();
}

class _MonthlyReportScreenState extends State<MonthlyReportScreen> {
  late DateTime _month = _thisMonth();
  bool _exporting = false;

  static DateTime _thisMonth() => DateTime(DateTime.now().year, DateTime.now().month);

  bool get _canGoNext => _month.isBefore(_thisMonth());

  Future<MonthlyReport> _load() async {
    final res = await context.read<Session>().api.get('reports/monthly/',
        query: {'year': _month.year, 'month': _month.month});
    return MonthlyReport.fromJson(res as Map<String, dynamic>);
  }

  void _shift(int months) =>
      setState(() => _month = DateTime(_month.year, _month.month + months));

  Future<void> _export(BuildContext buttonContext) async {
    final api = context.read<Session>().api;
    final y = _month.year;
    final m = _month.month.toString().padLeft(2, '0');
    // iPad share sheets need an anchor rect.
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    setState(() => _exporting = true);
    await runAction(context, () async {
      final bytes = await api.download('reports/monthly/$y/${_month.month}/csv/');
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/report_$y-$m.csv');
      await file.writeAsBytes(bytes, flush: true);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, mimeType: 'text/csv')],
        subject: 'Monthly report ${DateFormat('MMMM yyyy').format(_month)}',
        sharePositionOrigin: origin,
      ));
    });
    if (mounted) setState(() => _exporting = false);
  }

  @override
  Widget build(BuildContext context) {
    final symbol = context.watch<Session>().currencySymbol;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Monthly report'),
        actions: [
          Builder(
            builder: (btnContext) => _exporting
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: SizedBox(
                        width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : IconButton(
                    tooltip: 'Export CSV',
                    icon: const Icon(Icons.ios_share),
                    onPressed: () => _export(btnContext),
                  ),
          ),
        ],
      ),
      body: Column(children: [
        _MonthNav(
          month: _month,
          onPrev: () => _shift(-1),
          onNext: _canGoNext ? () => _shift(1) : null,
        ),
        Expanded(
          child: LoadBuilder<MonthlyReport>(
            key: ValueKey(_month),
            load: _load,
            builder: (context, r, reload) => ReportBody(report: r, symbol: symbol),
          ),
        ),
      ]),
    );
  }
}

class _MonthNav extends StatelessWidget {
  const _MonthNav({required this.month, required this.onPrev, this.onNext});
  final DateTime month;
  final VoidCallback onPrev;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final current = month.year == now.year && month.month == now.month;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(children: [
        IconButton(
            tooltip: 'Previous month', icon: const Icon(Icons.chevron_left), onPressed: onPrev),
        Expanded(
          child: Column(children: [
            Text(DateFormat('MMMM yyyy').format(month),
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            if (current)
              Text('Month to date',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: AppColors.muted)),
          ]),
        ),
        IconButton(
            tooltip: 'Next month', icon: const Icon(Icons.chevron_right), onPressed: onNext),
      ]),
    );
  }
}
