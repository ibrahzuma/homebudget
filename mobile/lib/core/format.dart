import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'models.dart';

final _grouped = NumberFormat('#,##0.00');
final _groupedWhole = NumberFormat('#,##0');
final _compact = NumberFormat.compact();

/// `TSh 12,500.00`. Whole-number currencies (TZS, KES) drop the cents when
/// they're zero to keep big numbers readable.
String fmtMoney(num? value, {String symbol = '\$', bool signed = false}) {
  if (value == null) return '—';
  final abs = value.abs();
  final whole = abs == abs.roundToDouble() && abs >= 1000;
  final body = whole ? _groupedWhole.format(abs) : _grouped.format(abs);
  final sign = value < 0 ? '−' : (signed && value > 0 ? '+' : '');
  final sep = symbol.length > 1 ? ' ' : '';
  return '$sign$symbol$sep$body';
}

/// Money in an item's own currency, falling back to the household symbol.
String fmtIn(num? value, Currency? currency, String fallbackSymbol, {bool signed = false}) =>
    fmtMoney(value, symbol: currency?.symbol ?? fallbackSymbol, signed: signed);

String fmtCompact(num value) => _compact.format(value);

String fmtPct(num? v, {int digits = 0}) => v == null ? '—' : '${v.toStringAsFixed(digits)}%';

String fmtDate(DateTime? d) => d == null ? '—' : DateFormat('d MMM yyyy').format(d);
String fmtDateShort(DateTime? d) => d == null ? '—' : DateFormat('d MMM').format(d);
String fmtDateTime(DateTime? d) =>
    d == null ? '—' : DateFormat('d MMM, HH:mm').format(d.toLocal());

/// API date format (YYYY-MM-DD).
String apiDate(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

String fmtRelativeDays(int days) {
  if (days == 0) return 'today';
  if (days == 1) return 'tomorrow';
  if (days == -1) return 'yesterday';
  return days > 0 ? 'in $days days' : '${-days} days ago';
}

/// `#0d6efd` -> Color. Falls back to grey on anything unparsable.
Color hexColor(String? hex, [Color fallback = const Color(0xFF6C757D)]) {
  if (hex == null) return fallback;
  var h = hex.replaceFirst('#', '');
  if (h.length == 3) h = h.split('').map((c) => '$c$c').join();
  if (h.length != 6) return fallback;
  final v = int.tryParse(h, radix: 16);
  return v == null ? fallback : Color(0xFF000000 | v);
}

String colorToHex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

String capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// `in_progress` -> `In progress`
String humanize(String s) => capitalize(s.replaceAll('_', ' '));
