// Typed views over the /api/v1/ JSON (see budget_app/api/serializers.py).
// Money arrives as decimal strings and is parsed to double for display and
// charts only — values sent back to the server come from what the user typed.

double? _d(dynamic v) => v == null ? null : double.tryParse(v.toString());
double _d0(dynamic v) => _d(v) ?? 0;
DateTime? _date(dynamic v) => v == null ? null : DateTime.tryParse(v.toString());
List<T> _list<T>(dynamic v, T Function(Map<String, dynamic>) f) =>
    (v as List? ?? const []).map((e) => f(e as Map<String, dynamic>)).toList();
T? _opt<T>(dynamic v, T Function(Map<String, dynamic>) f) =>
    v == null ? null : f(v as Map<String, dynamic>);

class UserBrief {
  UserBrief({required this.id, required this.username});
  factory UserBrief.fromJson(Map<String, dynamic> j) =>
      UserBrief(id: j['id'] as int, username: j['username'] as String);
  final int id;
  final String username;
}

class Currency {
  Currency({required this.id, required this.code, required this.name, required this.symbol});
  factory Currency.fromJson(Map<String, dynamic> j) => Currency(
      id: j['id'] as int,
      code: j['code'] as String,
      name: j['name'] as String,
      symbol: j['symbol'] as String);
  final int id;
  final String code;
  final String name;
  final String symbol;
}

class CategoryBrief {
  CategoryBrief({
    required this.id,
    required this.name,
    required this.type,
    required this.color,
    required this.icon,
  });
  factory CategoryBrief.fromJson(Map<String, dynamic> j) => CategoryBrief(
      id: j['id'] as int,
      name: j['name'] as String,
      type: j['type'] as String,
      color: j['color'] as String,
      icon: j['icon'] as String);
  final int id;
  final String name;
  final String type; // income | expense
  final String color;
  final String icon;
}

class ProjectBrief {
  ProjectBrief({required this.id, required this.name, required this.color, required this.icon});
  factory ProjectBrief.fromJson(Map<String, dynamic> j) => ProjectBrief(
      id: j['id'] as int,
      name: j['name'] as String,
      color: j['color'] as String,
      icon: j['icon'] as String);
  final int id;
  final String name;
  final String color;
  final String icon;
}

class Household {
  Household({
    required this.id,
    required this.name,
    required this.baseCurrency,
    required this.currencySymbol,
    required this.currencyCode,
    required this.members,
  });
  factory Household.fromJson(Map<String, dynamic> j) => Household(
        id: j['id'] as int,
        name: j['name'] as String,
        baseCurrency: _opt(j['base_currency'], Currency.fromJson),
        currencySymbol: j['currency_symbol'] as String,
        currencyCode: j['currency_code'] as String,
        members: _list(j['members'], UserBrief.fromJson),
      );
  final int id;
  final String name;
  final Currency? baseCurrency;
  final String currencySymbol;
  final String currencyCode;
  final List<UserBrief> members;
}

class Invitation {
  Invitation.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        code = j['code'] as String,
        note = j['note'] as String? ?? '',
        status = j['status'] as String,
        isUsable = j['is_usable'] as bool,
        invitedBy = _opt(j['invited_by'], UserBrief.fromJson),
        acceptedBy = _opt(j['accepted_by'], UserBrief.fromJson),
        createdAt = _date(j['created_at']),
        expiresAt = _date(j['expires_at']),
        acceptedAt = _date(j['accepted_at']);
  final int id;
  final String code;
  final String note;
  final String status;
  final bool isUsable;
  final UserBrief? invitedBy;
  final UserBrief? acceptedBy;
  final DateTime? createdAt;
  final DateTime? expiresAt;
  final DateTime? acceptedAt;
}

class HouseholdSettings {
  HouseholdSettings.fromJson(Map<String, dynamic> j)
      : household = Household.fromJson(j),
        pendingInvites = _list(j['pending_invites'], Invitation.fromJson),
        pastInvites = _list(j['past_invites'], Invitation.fromJson);
  final Household household;
  final List<Invitation> pendingInvites;
  final List<Invitation> pastInvites;
}

class Badges {
  Badges({this.unreadAlerts = 0, this.pendingRequests = 0, this.unreadChat = 0});
  factory Badges.fromJson(Map<String, dynamic>? j) => Badges(
        unreadAlerts: j?['unread_alerts'] as int? ?? 0,
        pendingRequests: j?['pending_requests'] as int? ?? 0,
        unreadChat: j?['unread_chat'] as int? ?? 0,
      );
  final int unreadAlerts;
  final int pendingRequests;
  final int unreadChat;
}

class Choice {
  Choice(this.value, this.label);
  factory Choice.fromJson(Map<String, dynamic> j) =>
      Choice(j['value'] as String, j['label'] as String);
  final String value;
  final String label;
}

/// Pickers for forms, from GET meta/.
class Meta {
  Meta.fromJson(Map<String, dynamic> j)
      : currencies = _list(j['currencies'], Currency.fromJson),
        categories = _list(j['categories'], CategoryBrief.fromJson),
        members = _list(j['members'], UserBrief.fromJson),
        projects = _list(j['projects'], ProjectBrief.fromJson),
        choices = (j['choices'] as Map<String, dynamic>).map(
            (k, v) => MapEntry(k, _list(v, Choice.fromJson)));
  final List<Currency> currencies;
  final List<CategoryBrief> categories;
  final List<UserBrief> members;
  final List<ProjectBrief> projects;
  final Map<String, List<Choice>> choices;

  List<Choice> choicesFor(String key) => choices[key] ?? const [];

  String label(String key, String value) =>
      choicesFor(key).where((c) => c.value == value).map((c) => c.label).firstOrNull ?? value;

  List<CategoryBrief> categoriesOfType(String type) =>
      categories.where((c) => c.type == type).toList();
}

class Txn {
  Txn.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        type = j['type'] as String,
        amount = _d0(j['amount']),
        amountRaw = j['amount'] as String,
        currency = _opt(j['currency'], Currency.fromJson),
        amountBase = _d(j['amount_base']),
        description = j['description'] as String? ?? '',
        payee = j['payee'] as String? ?? '',
        date = _date(j['date'])!,
        source = j['source'] as String,
        user = UserBrief.fromJson(j['user'] as Map<String, dynamic>),
        category = _opt(j['category'], CategoryBrief.fromJson),
        project = _opt(j['project'], ProjectBrief.fromJson);
  final int id;
  final String type;
  final double amount;
  final String amountRaw;
  final Currency? currency;
  final double? amountBase;
  final String description;
  final String payee;
  final DateTime date;
  final String source;
  final UserBrief user;
  final CategoryBrief? category;
  final ProjectBrief? project;

  bool get isIncome => type == 'income';
  String get title => payee.isNotEmpty
      ? payee
      : (description.isNotEmpty ? description : (category?.name ?? 'Transaction'));
}

class Paged<T> {
  Paged.fromJson(Map<String, dynamic> j, T Function(Map<String, dynamic>) f)
      : count = j['count'] as int,
        page = j['page'] as int,
        hasNext = j['has_next'] as bool,
        results = _list(j['results'], f),
        extra = j;
  final int count;
  final int page;
  final bool hasNext;
  final List<T> results;
  final Map<String, dynamic> extra;
}

class BudgetRow {
  BudgetRow.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int?,
        category = CategoryBrief.fromJson(j['category'] as Map<String, dynamic>),
        limit = _d0(j['monthly_limit'] ?? j['limit']),
        month = _date(j['month']),
        isCurrent = j['is_current'] as bool? ?? true,
        spent = _d(j['spent']),
        remaining = _d(j['remaining']),
        pct = (j['pct'] as num?)?.toDouble(),
        over = j['over'] as bool? ?? false;
  final int? id;
  final CategoryBrief category;
  final double limit;
  final DateTime? month;
  final bool isCurrent;
  final double? spent;
  final double? remaining;
  final double? pct;
  final bool over;
}

class Recurring {
  Recurring.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        name = j['name'] as String,
        type = j['type'] as String,
        category = _opt(j['category'], CategoryBrief.fromJson),
        amount = _d0(j['amount']),
        currency = _opt(j['currency'], Currency.fromJson),
        payee = j['payee'] as String? ?? '',
        frequency = j['frequency'] as String,
        startDate = _date(j['start_date']),
        endDate = _date(j['end_date']),
        nextDueDate = _date(j['next_due_date'])!,
        daysUntilDue = j['days_until_due'] as int,
        autoCreate = j['auto_create'] as bool,
        isActive = j['is_active'] as bool,
        notes = j['notes'] as String? ?? '',
        raw = j;
  final int id;
  final String name;
  final String type;
  final CategoryBrief? category;
  final double amount;
  final Currency? currency;
  final String payee;
  final String frequency;
  final DateTime? startDate;
  final DateTime? endDate;
  final DateTime nextDueDate;
  final int daysUntilDue;
  final bool autoCreate;
  final bool isActive;
  final String notes;
  final Map<String, dynamic> raw;
}

class Rule {
  Rule.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        pattern = j['pattern'] as String,
        matchType = j['match_type'] as String,
        caseSensitive = j['case_sensitive'] as bool,
        category = CategoryBrief.fromJson(j['category'] as Map<String, dynamic>),
        priority = j['priority'] as int,
        isActive = j['is_active'] as bool;
  final int id;
  final String pattern;
  final String matchType;
  final bool caseSensitive;
  final CategoryBrief category;
  final int priority;
  final bool isActive;
}

class AlertItem {
  AlertItem.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        title = j['title'] as String,
        message = j['message'] as String? ?? '',
        level = j['level'] as String,
        linkUrl = j['link_url'] as String? ?? '',
        isRead = j['is_read'] as bool,
        createdAt = _date(j['created_at'])!;
  final int id;
  final String title;
  final String message;
  final String level; // info | warning | danger
  final String linkUrl;
  final bool isRead;
  final DateTime createdAt;
}

class MoneyRequest {
  MoneyRequest.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        requester = UserBrief.fromJson(j['requester'] as Map<String, dynamic>),
        approver = UserBrief.fromJson(j['approver'] as Map<String, dynamic>),
        amount = _d0(j['amount']),
        currency = _opt(j['currency'], Currency.fromJson),
        purpose = j['purpose'] as String,
        notes = j['notes'] as String? ?? '',
        category = _opt(j['category'], CategoryBrief.fromJson),
        status = j['status'] as String,
        responseNote = j['response_note'] as String? ?? '',
        createdAt = _date(j['created_at'])!,
        resolvedAt = _date(j['resolved_at']),
        canRespond = j['can_respond'] as bool,
        canCancel = j['can_cancel'] as bool;
  final int id;
  final UserBrief requester;
  final UserBrief approver;
  final double amount;
  final Currency? currency;
  final String purpose;
  final String notes;
  final CategoryBrief? category;
  final String status; // pending | approved | rejected | cancelled
  final String responseNote;
  final DateTime createdAt;
  final DateTime? resolvedAt;
  final bool canRespond;
  final bool canCancel;
}

class Asset {
  Asset.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        name = j['name'] as String,
        assetType = j['asset_type'] as String,
        assetTypeDisplay = j['asset_type_display'] as String,
        isMajor = j['is_major'] as bool,
        value = _d0(j['value']),
        currency = _opt(j['currency'], Currency.fromJson),
        acquisitionDate = _date(j['acquisition_date']),
        location = j['location'] as String? ?? '',
        size = j['size'] as String? ?? '',
        registrationNumber = j['registration_number'] as String? ?? '',
        notes = j['notes'] as String? ?? '',
        raw = j;
  final int id;
  final String name;
  final String assetType;
  final String assetTypeDisplay;
  final bool isMajor;
  final double value;
  final Currency? currency;
  final DateTime? acquisitionDate;
  final String location;
  final String size;
  final String registrationNumber;
  final String notes;
  final Map<String, dynamic> raw;
}

class Payment {
  Payment.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        date = _date(j['date'])!,
        amount = _d0(j['amount']),
        currency = _opt(j['currency'], Currency.fromJson),
        notes = j['notes'] as String? ?? '',
        transactionId = j['transaction_id'] as int?;
  final int id;
  final DateTime date;
  final double amount;
  final Currency? currency;
  final String notes;
  final int? transactionId;
}

class Liability {
  Liability.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        name = j['name'] as String,
        liabilityType = j['liability_type'] as String,
        liabilityTypeDisplay = j['liability_type_display'] as String,
        lender = j['lender'] as String? ?? '',
        balance = _d0(j['balance']),
        originalAmount = _d(j['original_amount']),
        currency = _opt(j['currency'], Currency.fromJson),
        interestRate = _d(j['interest_rate']),
        startDate = _date(j['start_date']),
        dueDate = _date(j['due_date']),
        notes = j['notes'] as String? ?? '',
        paid = _d0(j['paid']),
        original = _d0(j['original']),
        pct = (j['pct'] as num).toDouble(),
        paymentsCount = j['payments_count'] as int,
        payments = _list(j['payments'], Payment.fromJson),
        raw = j;
  final int id;
  final String name;
  final String liabilityType;
  final String liabilityTypeDisplay;
  final String lender;
  final double balance;
  final double? originalAmount;
  final Currency? currency;
  final double? interestRate;
  final DateTime? startDate;
  final DateTime? dueDate;
  final String notes;
  final double paid;
  final double original;
  final double pct;
  final int paymentsCount;
  final List<Payment> payments;
  final Map<String, dynamic> raw;
}

class Receivable {
  Receivable.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        debtorName = j['debtor_name'] as String,
        debtorContact = j['debtor_contact'] as String? ?? '',
        description = j['description'] as String? ?? '',
        balance = _d0(j['balance']),
        originalAmount = _d(j['original_amount']),
        currency = _opt(j['currency'], Currency.fromJson),
        interestRate = _d(j['interest_rate']),
        lentDate = _date(j['lent_date']),
        dueDate = _date(j['due_date']),
        status = j['status'] as String,
        notes = j['notes'] as String? ?? '',
        received = _d0(j['received']),
        original = _d0(j['original']),
        pct = (j['pct'] as num).toDouble(),
        isOverdue = j['is_overdue'] as bool,
        paymentsCount = j['payments_count'] as int,
        payments = _list(j['payments'], Payment.fromJson),
        raw = j;
  final int id;
  final String debtorName;
  final String debtorContact;
  final String description;
  final double balance;
  final double? originalAmount;
  final Currency? currency;
  final double? interestRate;
  final DateTime? lentDate;
  final DateTime? dueDate;
  final String status; // active | paid | written_off
  final String notes;
  final double received;
  final double original;
  final double pct;
  final bool isOverdue;
  final int paymentsCount;
  final List<Payment> payments;
  final Map<String, dynamic> raw;
}

class GoalContribution {
  GoalContribution.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        amount = _d0(j['amount']),
        date = _date(j['date'])!,
        notes = j['notes'] as String? ?? '',
        user = _opt(j['user'], UserBrief.fromJson),
        transactionId = j['transaction_id'] as int?;
  final int id;
  final double amount;
  final DateTime date;
  final String notes;
  final UserBrief? user;
  final int? transactionId;
}

class Goal {
  Goal.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        name = j['name'] as String,
        targetAmount = _d0(j['target_amount']),
        currentAmount = _d0(j['current_amount']),
        amountRemaining = _d0(j['amount_remaining']),
        targetDate = _date(j['target_date']),
        monthlyContribution = _d(j['monthly_contribution']),
        monthlyNeeded = _d(j['monthly_needed']),
        monthsRemaining = j['months_remaining'] as int?,
        onTrack = j['on_track'] as bool?,
        progressPercent = (j['progress_percent'] as num).toDouble(),
        currency = _opt(j['currency'], Currency.fromJson),
        icon = j['icon'] as String,
        color = j['color'] as String,
        status = j['status'] as String,
        notes = j['notes'] as String? ?? '',
        contributions = _list(j['contributions'], GoalContribution.fromJson),
        raw = j;
  final int id;
  final String name;
  final double targetAmount;
  final double currentAmount;
  final double amountRemaining;
  final DateTime? targetDate;
  final double? monthlyContribution;
  final double? monthlyNeeded;
  final int? monthsRemaining;
  final bool? onTrack;
  final double progressPercent;
  final Currency? currency;
  final String icon;
  final String color;
  final String status; // active | achieved | paused
  final String notes;
  final List<GoalContribution> contributions;
  final Map<String, dynamic> raw;
}

class Project {
  Project.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        name = j['name'] as String,
        description = j['description'] as String? ?? '',
        budget = _d0(j['budget']),
        currency = _opt(j['currency'], Currency.fromJson),
        startDate = _date(j['start_date']),
        endDate = _date(j['end_date']),
        status = j['status'] as String,
        color = j['color'] as String,
        icon = j['icon'] as String,
        spent = _d0(j['spent']),
        incomeReceived = _d0(j['income_received']),
        progressPercent = (j['progress_percent'] as num).toDouble(),
        isOverBudget = j['is_over_budget'] as bool,
        transactions = _list(j['transactions'], Txn.fromJson),
        raw = j;
  final int id;
  final String name;
  final String description;
  final double budget;
  final Currency? currency;
  final DateTime? startDate;
  final DateTime? endDate;
  final String status;
  final String color;
  final String icon;
  final double spent;
  final double incomeReceived;
  final double progressPercent;
  final bool isOverBudget;
  final List<Txn> transactions;
  final Map<String, dynamic> raw;
}

class AgreementItem {
  AgreementItem.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        meetingId = j['meeting_id'] as int,
        title = j['title'] as String,
        description = j['description'] as String? ?? '',
        owner = _opt(j['owner'], UserBrief.fromJson),
        targetDate = _date(j['target_date']),
        status = j['status'] as String,
        progress = j['progress'] as int,
        priority = j['priority'] as String,
        completedDate = _date(j['completed_date']),
        notes = j['notes'] as String? ?? '',
        isOverdue = j['is_overdue'] as bool,
        raw = j;
  final int id;
  final int meetingId;
  final String title;
  final String description;
  final UserBrief? owner;
  final DateTime? targetDate;
  final String status; // open | in_progress | done | cancelled
  final int progress;
  final String priority; // low | normal | high
  final DateTime? completedDate;
  final String notes;
  final bool isOverdue;
  final Map<String, dynamic> raw;
}

class Meeting {
  Meeting.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        title = j['title'] as String,
        meetingDate = _date(j['meeting_date'])!,
        participants = _list(j['participants'], UserBrief.fromJson),
        agenda = j['agenda'] as String? ?? '',
        minutes = j['minutes'] as String? ?? '',
        status = j['status'] as String,
        incomeSnapshot = _d(j['income_snapshot']),
        expenseSnapshot = _d(j['expense_snapshot']),
        netWorthSnapshot = _d(j['net_worth_snapshot']),
        progressPercent = j['progress_percent'] as int,
        openCount = j['open_count'] as int,
        doneCount = j['done_count'] as int,
        items = _list(j['items'], AgreementItem.fromJson),
        raw = j;
  final int id;
  final String title;
  final DateTime meetingDate;
  final List<UserBrief> participants;
  final String agenda;
  final String minutes;
  final String status; // planned | held | cancelled
  final double? incomeSnapshot;
  final double? expenseSnapshot;
  final double? netWorthSnapshot;
  final int progressPercent;
  final int openCount;
  final int doneCount;
  final List<AgreementItem> items;
  final Map<String, dynamic> raw;
}

class ChatMessage {
  ChatMessage({required this.id, required this.sender, required this.body, required this.createdAt});
  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: j['id'] as int,
        sender: UserBrief.fromJson(j['sender'] as Map<String, dynamic>),
        body: j['body'] as String,
        createdAt: _date(j['created_at'])!,
      );

  /// From a WebSocket `chat.new` event.
  factory ChatMessage.fromEvent(Map<String, dynamic> e) => ChatMessage(
        id: e['id'] as int,
        sender: UserBrief(id: e['sender_id'] as int, username: e['sender_name'] as String),
        body: e['body'] as String,
        createdAt: _date(e['created_at']) ?? DateTime.now(),
      );
  final int id;
  final UserBrief sender;
  final String body;
  final DateTime createdAt;
}

class Snapshot {
  Snapshot.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        date = _date(j['snapshot_date'])!,
        totalAssets = _d0(j['total_assets']),
        totalLiabilities = _d0(j['total_liabilities']),
        netWorth = _d0(j['net_worth']);
  final int id;
  final DateTime date;
  final double totalAssets;
  final double totalLiabilities;
  final double netWorth;
}

class ExchangeRate {
  ExchangeRate.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int,
        from = Currency.fromJson(j['from_currency'] as Map<String, dynamic>),
        to = Currency.fromJson(j['to_currency'] as Map<String, dynamic>),
        rate = _d0(j['rate']),
        rateRaw = j['rate'] as String,
        updatedAt = _date(j['updated_at']);
  final int id;
  final Currency from;
  final Currency to;
  final double rate;
  final String rateRaw;
  final DateTime? updatedAt;
}

class NetWorth {
  NetWorth.fromJson(Map<String, dynamic> j)
      : totalAssets = _d0(j['total_assets']),
        totalReceivables = _d0(j['total_receivables']),
        totalLiabilities = _d0(j['total_liabilities']),
        netWorth = _d0(j['net_worth']),
        assetsByType = (j['assets_by_type'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, _d0(v))),
        liabilitiesByType = (j['liabilities_by_type'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, _d0(v))),
        assets = _list(j['assets'], Asset.fromJson),
        liabilities = _list(j['liabilities'], Liability.fromJson),
        snapshots = _list(j['snapshots'], Snapshot.fromJson);
  final double totalAssets;
  final double totalReceivables;
  final double totalLiabilities;
  final double netWorth;
  final Map<String, double> assetsByType;
  final Map<String, double> liabilitiesByType;
  final List<Asset> assets; // only from GET networth/
  final List<Liability> liabilities;
  final List<Snapshot> snapshots;
}

class Forecast {
  Forecast.fromJson(Map<String, dynamic> j)
      : monthLabel = j['month_label'] as String?,
        incomeSoFar = _d0(j['income_so_far']),
        expenseSoFar = _d0(j['expense_so_far']),
        daysElapsed = j['days_elapsed'] as int,
        daysTotal = j['days_total'] as int,
        daysRemaining = j['days_remaining'] as int,
        dailyBurn = _d0(j['daily_burn']),
        dailyInflow = _d0(j['daily_inflow']),
        projectedIncome = _d0(j['projected_income']),
        projectedExpense = _d0(j['projected_expense']),
        projectedBalance = _d0(j['projected_balance']),
        currentBalance = _d0(j['current_balance']);
  final String? monthLabel;
  final double incomeSoFar;
  final double expenseSoFar;
  final int daysElapsed;
  final int daysTotal;
  final int daysRemaining;
  final double dailyBurn;
  final double dailyInflow;
  final double projectedIncome;
  final double projectedExpense;
  final double projectedBalance;
  final double currentBalance;
}

class MemberRow {
  MemberRow.fromJson(Map<String, dynamic> j)
      : user = UserBrief.fromJson(j['user'] as Map<String, dynamic>),
        income = _d0(j['income']),
        expense = _d0(j['expense']),
        net = _d0(j['net']),
        incomeSharePct = (j['income_share_pct'] as num).toDouble(),
        expenseSharePct = (j['expense_share_pct'] as num).toDouble();
  final UserBrief user;
  final double income;
  final double expense;
  final double net;
  final double incomeSharePct;
  final double expenseSharePct;
}

class Dashboard {
  Dashboard.fromJson(Map<String, dynamic> j)
      : monthLabel = j['month_label'] as String,
        totalIncome = _d0(j['total_income']),
        totalExpense = _d0(j['total_expense']),
        balance = _d0(j['balance']),
        members = _list(j['members'], MemberRow.fromJson),
        budgets = _list(j['budgets'], BudgetRow.fromJson),
        recent = _list(j['recent'], Txn.fromJson),
        upcoming = _list(j['upcoming'], Recurring.fromJson),
        forecast = Forecast.fromJson(j['forecast'] as Map<String, dynamic>),
        networth = NetWorth.fromJson(j['networth'] as Map<String, dynamic>),
        pendingMyApprovals = _list(j['pending_my_approvals'], MoneyRequest.fromJson),
        activeGoals = _list(j['active_goals'], Goal.fromJson),
        nextMeeting = _opt(j['next_meeting'], Meeting.fromJson),
        totalLentOut = _d0(j['total_lent_out']),
        totalOwed = _d0(j['total_owed']),
        overdueLent = j['overdue_lent'] as int;
  final String monthLabel;
  final double totalIncome;
  final double totalExpense;
  final double balance;
  final List<MemberRow> members;
  final List<BudgetRow> budgets;
  final List<Txn> recent;
  final List<Recurring> upcoming;
  final Forecast forecast;
  final NetWorth networth;
  final List<MoneyRequest> pendingMyApprovals;
  final List<Goal> activeGoals;
  final Meeting? nextMeeting;
  final double totalLentOut;
  final double totalOwed;
  final int overdueLent;
}

class CalendarBill {
  CalendarBill.fromJson(Map<String, dynamic> j)
      : kind = j['kind'] as String,
        name = j['name'] as String,
        amount = _d0(j['amount']),
        payee = j['payee'] as String? ?? '',
        category = _opt(j['category'], CategoryBrief.fromJson);
  final String kind; // income | expense
  final String name;
  final double amount;
  final String payee;
  final CategoryBrief? category;
}

class CalendarDay {
  CalendarDay.fromJson(Map<String, dynamic> j)
      : date = _date(j['date'])!,
        inMonth = j['in_month'] as bool,
        isToday = j['is_today'] as bool,
        income = _d0(j['income']),
        expense = _d0(j['expense']),
        net = _d0(j['net']),
        bills = _list(j['bills'], CalendarBill.fromJson);
  final DateTime date;
  final bool inMonth;
  final bool isToday;
  final double income;
  final double expense;
  final double net;
  final List<CalendarBill> bills;
}

class YearMonth {
  YearMonth(this.year, this.month);
  factory YearMonth.fromJson(Map<String, dynamic> j) =>
      YearMonth(j['year'] as int, j['month'] as int);
  final int year;
  final int month;
}

class CalendarMonth {
  CalendarMonth.fromJson(Map<String, dynamic> j)
      : year = j['year'] as int,
        month = j['month'] as int,
        monthLabel = j['month_label'] as String,
        prev = YearMonth.fromJson(j['prev'] as Map<String, dynamic>),
        next = YearMonth.fromJson(j['next'] as Map<String, dynamic>),
        monthIncome = _d0(j['month_income']),
        monthExpense = _d0(j['month_expense']),
        monthNet = _d0(j['month_net']),
        weeks = (j['weeks'] as List)
            .map((w) => _list(w, CalendarDay.fromJson))
            .toList();
  final int year;
  final int month;
  final String monthLabel;
  final YearMonth prev;
  final YearMonth next;
  final double monthIncome;
  final double monthExpense;
  final double monthNet;
  final List<List<CalendarDay>> weeks;
}

class MonthlyReport {
  MonthlyReport.fromJson(Map<String, dynamic> j)
      : year = j['year'] as int,
        month = j['month'] as int,
        monthLabel = j['month_label'] as String,
        prev = YearMonth.fromJson(j['prev'] as Map<String, dynamic>),
        next = YearMonth.fromJson(j['next'] as Map<String, dynamic>),
        isCurrentMonth = j['is_current_month'] as bool? ?? false,
        income = _d0(j['income']),
        expense = _d0(j['expense']),
        net = _d0(j['net']),
        savingsRate = (j['savings_rate'] as num?)?.toDouble(),
        incomeDeltaPct = (j['income_delta_pct'] as num?)?.toDouble(),
        expenseDeltaPct = (j['expense_delta_pct'] as num?)?.toDouble(),
        prevIncome = _d0(j['prev_income']),
        prevExpense = _d0(j['prev_expense']),
        members = _list(j['members'], MemberRow.fromJson),
        byCategory = (j['by_category'] as List).cast<Map<String, dynamic>>(),
        topPayees = (j['top_payees'] as List).cast<Map<String, dynamic>>(),
        topTransactions = _list(j['top_transactions'], Txn.fromJson),
        budgets = _list(j['budgets'], BudgetRow.fromJson),
        requests = (j['requests'] as Map<String, dynamic>).cast<String, int>(),
        goalContributions = (j['goal_contributions'] as List).cast<Map<String, dynamic>>(),
        goalTotal = _d0(j['goal_total']),
        projects = (j['projects'] as List).cast<Map<String, dynamic>>(),
        meetings = (j['meetings'] as List).cast<Map<String, dynamic>>(),
        debtPaid = _d0(j['debt_paid']),
        debtPaidCount = j['debt_paid_count'] as int,
        receivableReceived = _d0(j['receivable_received']),
        transactionCount = j['transaction_count'] as int;
  final int year;
  final int month;
  final String monthLabel;
  final YearMonth prev;
  final YearMonth next;
  final bool isCurrentMonth;
  final double income;
  final double expense;
  final double net;
  final double? savingsRate;
  final double? incomeDeltaPct;
  final double? expenseDeltaPct;
  final double prevIncome;
  final double prevExpense;
  final List<MemberRow> members;

  /// {name, color, icon, total, count, pct}
  final List<Map<String, dynamic>> byCategory;

  /// {payee, total, count}
  final List<Map<String, dynamic>> topPayees;
  final List<Txn> topTransactions;
  final List<BudgetRow> budgets;

  /// {approved, rejected, cancelled}
  final Map<String, int> requests;

  /// {goal: {id, name}, amount, date, user}
  final List<Map<String, dynamic>> goalContributions;
  final double goalTotal;

  /// {id, name, color, icon, month_spent}
  final List<Map<String, dynamic>> projects;

  /// {id, title, meeting_date, status}
  final List<Map<String, dynamic>> meetings;
  final double debtPaid;
  final int debtPaidCount;
  final double receivableReceived;
  final int transactionCount;
}

/// Parses a decimal string from a nested JSON map (for MonthlyReport maps).
double money(dynamic v) => _d0(v);
