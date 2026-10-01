import 'package:flutter/foundation.dart';

/// Bumped after anything that can create, change or delete transactions, so
/// screens kept alive in the tab shell (Home, Transactions) reload without a
/// manual pull-to-refresh. [ApiClient] bumps it automatically for successful
/// writes to [_transactionWrites]; screens can also call it directly.
final ValueNotifier<int> transactionsChanged = ValueNotifier(0);

void notifyTransactionsChanged() => transactionsChanged.value++;

/// Write endpoints whose server-side effects add or remove transactions
/// (approvals, payments, contributions, recurring runs, imports, rules).
final _transactionWrites = RegExp(
  r'^(transactions/|requests/\d+/approve/|recurring/run-now/|rules/apply/'
  r'|goals/\d+/contributions/|debts/\d+/payments/|lent/(\d+/repayments/)?'
  r'|currencies/rates/|categories/\d+/)',
);

void noteWrite(String path) {
  if (_transactionWrites.hasMatch(path)) notifyTransactionsChanged();
}
