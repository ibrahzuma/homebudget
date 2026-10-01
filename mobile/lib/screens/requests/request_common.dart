import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../widgets/common.dart';

/// Colour for a money-request status.
Color requestStatusColor(String status) => switch (status) {
      'pending' => AppColors.warning,
      'approved' => AppColors.income,
      'rejected' => AppColors.expense,
      _ => AppColors.muted,
    };

class RequestStatusChip extends StatelessWidget {
  const RequestStatusChip(this.status, {super.key});
  final String status;

  @override
  Widget build(BuildContext context) =>
      StatusChip(humanize(status), color: requestStatusColor(status));
}

/// Formats a request amount in its own currency.
String requestAmount(MoneyRequest r, String fallbackSymbol) =>
    fmtIn(r.amount, r.currency, fallbackSymbol);

/// True for the realtime events this feature cares about.
bool isRequestEvent(Map<String, dynamic> e) =>
    (e['kind'] as String? ?? '').startsWith('request.');
