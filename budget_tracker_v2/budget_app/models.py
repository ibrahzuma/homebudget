from datetime import date, timedelta
from decimal import Decimal

from django.db import models
from django.contrib.auth.models import User
from django.utils import timezone


# ============================================================
# CURRENCIES
# ============================================================

class Currency(models.Model):
    """Supported currencies. Rate is relative to household's base currency."""
    code = models.CharField(max_length=5, unique=True, help_text="e.g. USD, TZS, EUR")
    name = models.CharField(max_length=50)
    symbol = models.CharField(max_length=5, default='$')

    class Meta:
        verbose_name_plural = 'Currencies'
        ordering = ['code']

    def __str__(self):
        return f"{self.code} ({self.symbol})"


class ExchangeRate(models.Model):
    """Exchange rate from `from_currency` to `to_currency`. 1 from = rate * to."""
    from_currency = models.ForeignKey(Currency, on_delete=models.CASCADE, related_name='rates_from')
    to_currency = models.ForeignKey(Currency, on_delete=models.CASCADE, related_name='rates_to')
    rate = models.DecimalField(max_digits=18, decimal_places=6)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        unique_together = ('from_currency', 'to_currency')

    def __str__(self):
        return f"1 {self.from_currency.code} = {self.rate} {self.to_currency.code}"


# ============================================================
# HOUSEHOLD
# ============================================================

class Household(models.Model):
    name = models.CharField(max_length=100)
    members = models.ManyToManyField(User, related_name='households')
    base_currency = models.ForeignKey(
        Currency, on_delete=models.PROTECT, null=True, blank=True,
        related_name='households_base'
    )
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return self.name

    @property
    def currency_symbol(self):
        return self.base_currency.symbol if self.base_currency else '$'

    @property
    def currency_code(self):
        return self.base_currency.code if self.base_currency else 'USD'


# ============================================================
# CATEGORIES
# ============================================================

class Category(models.Model):
    INCOME = 'income'
    EXPENSE = 'expense'
    TYPE_CHOICES = [(INCOME, 'Income'), (EXPENSE, 'Expense')]

    household = models.ForeignKey(Household, on_delete=models.CASCADE, related_name='categories')
    name = models.CharField(max_length=80)
    category_type = models.CharField(max_length=10, choices=TYPE_CHOICES)
    color = models.CharField(max_length=7, default='#6c757d')
    icon = models.CharField(max_length=50, default='bi-tag', help_text='Bootstrap icon class')

    class Meta:
        unique_together = ('household', 'name', 'category_type')
        ordering = ['category_type', 'name']
        verbose_name_plural = 'Categories'

    def __str__(self):
        return f"{self.name} ({self.get_category_type_display()})"


# ============================================================
# TRANSACTIONS
# ============================================================

class Transaction(models.Model):
    INCOME = 'income'
    EXPENSE = 'expense'
    TYPE_CHOICES = [(INCOME, 'Income'), (EXPENSE, 'Expense')]

    household = models.ForeignKey(Household, on_delete=models.CASCADE, related_name='transactions')
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='transactions')
    category = models.ForeignKey(Category, on_delete=models.SET_NULL, null=True, blank=True, related_name='transactions')
    transaction_type = models.CharField(max_length=10, choices=TYPE_CHOICES)

    # Amount in the original currency
    amount = models.DecimalField(max_digits=14, decimal_places=2)
    currency = models.ForeignKey(Currency, on_delete=models.PROTECT, null=True, blank=True)
    # Amount converted to household base currency (for aggregation)
    amount_base = models.DecimalField(max_digits=14, decimal_places=2, null=True, blank=True)

    description = models.CharField(max_length=255, blank=True)
    payee = models.CharField(max_length=120, blank=True, help_text='Merchant or source, e.g. "TotalEnergies"')
    date = models.DateField(default=timezone.now)
    created_at = models.DateTimeField(auto_now_add=True)
    # Tag a transaction to a household project (e.g. "Trip to Spain", "Roof repair")
    project = models.ForeignKey('Project', on_delete=models.SET_NULL, null=True, blank=True,
                                related_name='transactions')

    # Source tracking
    SOURCE_MANUAL = 'manual'
    SOURCE_RECURRING = 'recurring'
    SOURCE_REQUEST = 'request'
    SOURCE_IMPORT = 'import'
    SOURCE_CHOICES = [
        (SOURCE_MANUAL, 'Manual'),
        (SOURCE_RECURRING, 'Recurring'),
        (SOURCE_REQUEST, 'Money Request'),
        (SOURCE_IMPORT, 'Imported'),
    ]
    source = models.CharField(max_length=20, choices=SOURCE_CHOICES, default=SOURCE_MANUAL)

    class Meta:
        ordering = ['-date', '-created_at']

    def __str__(self):
        return f"{self.get_transaction_type_display()} - {self.amount} ({self.user.username})"

    def save(self, *args, **kwargs):
        # Pop unconditionally so the kwarg never leaks to super().save()
        recompute = kwargs.pop('recompute_base', False)
        if self.amount_base is None or recompute:
            self.amount_base = self._compute_amount_base()
        super().save(*args, **kwargs)

    def _compute_amount_base(self):
        if not self.household_id:
            return self.amount
        base = self.household.base_currency
        if not base or not self.currency_id or self.currency_id == base.id:
            return self.amount
        rate = ExchangeRate.objects.filter(
            from_currency=self.currency, to_currency=base
        ).first()
        if rate:
            return (Decimal(self.amount) * rate.rate).quantize(Decimal('0.01'))
        # try inverse
        inverse = ExchangeRate.objects.filter(
            from_currency=base, to_currency=self.currency
        ).first()
        if inverse and inverse.rate:
            return (Decimal(self.amount) / inverse.rate).quantize(Decimal('0.01'))
        return self.amount


# ============================================================
# BUDGETS
# ============================================================

class Budget(models.Model):
    household = models.ForeignKey(Household, on_delete=models.CASCADE, related_name='budgets')
    category = models.ForeignKey(Category, on_delete=models.CASCADE, related_name='budgets')
    monthly_limit = models.DecimalField(max_digits=12, decimal_places=2)
    month = models.DateField(help_text='First day of month')
    # Alert state — to avoid spamming the same alert
    alert_80_sent = models.BooleanField(default=False)
    alert_100_sent = models.BooleanField(default=False)

    class Meta:
        unique_together = ('household', 'category', 'month')
        ordering = ['-month']

    def __str__(self):
        return f"{self.category.name} budget for {self.month.strftime('%B %Y')}"


# ============================================================
# RECURRING TRANSACTIONS
# ============================================================

class RecurringTransaction(models.Model):
    DAILY = 'daily'
    WEEKLY = 'weekly'
    BIWEEKLY = 'biweekly'
    MONTHLY = 'monthly'
    QUARTERLY = 'quarterly'
    YEARLY = 'yearly'
    FREQ_CHOICES = [
        (DAILY, 'Daily'), (WEEKLY, 'Weekly'), (BIWEEKLY, 'Bi-weekly'),
        (MONTHLY, 'Monthly'), (QUARTERLY, 'Quarterly'), (YEARLY, 'Yearly'),
    ]

    household = models.ForeignKey(Household, on_delete=models.CASCADE, related_name='recurring_transactions')
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='recurring_transactions')
    category = models.ForeignKey(Category, on_delete=models.SET_NULL, null=True, blank=True)
    transaction_type = models.CharField(max_length=10, choices=Transaction.TYPE_CHOICES)
    name = models.CharField(max_length=120, help_text='e.g. "Rent", "Netflix"')
    payee = models.CharField(max_length=120, blank=True)
    amount = models.DecimalField(max_digits=12, decimal_places=2)
    currency = models.ForeignKey(Currency, on_delete=models.PROTECT, null=True, blank=True)
    frequency = models.CharField(max_length=15, choices=FREQ_CHOICES, default=MONTHLY)
    start_date = models.DateField(default=timezone.now)
    end_date = models.DateField(null=True, blank=True)
    next_due_date = models.DateField()
    auto_create = models.BooleanField(default=True, help_text='Automatically create transactions when due')
    is_active = models.BooleanField(default=True)
    notes = models.TextField(blank=True)

    class Meta:
        ordering = ['next_due_date']

    def __str__(self):
        return f"{self.name} ({self.get_frequency_display()})"

    def advance_due_date(self, from_date=None):
        base = from_date or self.next_due_date
        if self.frequency == self.DAILY:
            return base + timedelta(days=1)
        if self.frequency == self.WEEKLY:
            return base + timedelta(weeks=1)
        if self.frequency == self.BIWEEKLY:
            return base + timedelta(weeks=2)
        if self.frequency == self.MONTHLY:
            return self._add_months(base, 1)
        if self.frequency == self.QUARTERLY:
            return self._add_months(base, 3)
        if self.frequency == self.YEARLY:
            try:
                return base.replace(year=base.year + 1)
            except ValueError:
                return base.replace(year=base.year + 1, day=28)
        return base

    @staticmethod
    def _add_months(d, months):
        m = d.month - 1 + months
        year = d.year + m // 12
        month = m % 12 + 1
        # clamp day to last valid day
        import calendar
        last = calendar.monthrange(year, month)[1]
        day = min(d.day, last)
        return d.replace(year=year, month=month, day=day)

    @property
    def days_until_due(self):
        return (self.next_due_date - timezone.now().date()).days


# ============================================================
# AUTO-CATEGORIZATION RULES
# ============================================================

class CategoryRule(models.Model):
    """If a transaction's payee/description matches `pattern`, set category."""
    MATCH_CONTAINS = 'contains'
    MATCH_EQUALS = 'equals'
    MATCH_STARTS = 'starts_with'
    MATCH_CHOICES = [
        (MATCH_CONTAINS, 'Contains'),
        (MATCH_EQUALS, 'Equals'),
        (MATCH_STARTS, 'Starts with'),
    ]

    household = models.ForeignKey(Household, on_delete=models.CASCADE, related_name='rules')
    pattern = models.CharField(max_length=200, help_text='Text to match against payee/description')
    match_type = models.CharField(max_length=15, choices=MATCH_CHOICES, default=MATCH_CONTAINS)
    case_sensitive = models.BooleanField(default=False)
    category = models.ForeignKey(Category, on_delete=models.CASCADE, related_name='rules')
    priority = models.IntegerField(default=10, help_text='Lower numbers run first')
    is_active = models.BooleanField(default=True)

    class Meta:
        ordering = ['priority', 'pattern']

    def __str__(self):
        return f"{self.pattern} → {self.category.name}"

    def matches(self, text):
        if not text:
            return False
        haystack = text if self.case_sensitive else text.lower()
        needle = self.pattern if self.case_sensitive else self.pattern.lower()
        if self.match_type == self.MATCH_CONTAINS:
            return needle in haystack
        if self.match_type == self.MATCH_EQUALS:
            return haystack == needle
        if self.match_type == self.MATCH_STARTS:
            return haystack.startswith(needle)
        return False


# ============================================================
# ALERTS / NOTIFICATIONS
# ============================================================

class Alert(models.Model):
    LEVEL_INFO = 'info'
    LEVEL_WARNING = 'warning'
    LEVEL_DANGER = 'danger'
    LEVEL_CHOICES = [
        (LEVEL_INFO, 'Info'),
        (LEVEL_WARNING, 'Warning'),
        (LEVEL_DANGER, 'Danger'),
    ]

    household = models.ForeignKey(Household, on_delete=models.CASCADE, related_name='alerts')
    user = models.ForeignKey(User, on_delete=models.CASCADE, null=True, blank=True,
                             related_name='alerts',
                             help_text='If null, visible to all household members')
    title = models.CharField(max_length=200)
    message = models.TextField(blank=True)
    level = models.CharField(max_length=10, choices=LEVEL_CHOICES, default=LEVEL_INFO)
    link_url = models.CharField(max_length=300, blank=True)
    is_read = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        return self.title


# ============================================================
# MONEY REQUESTS (between household members)
# ============================================================

class MoneyRequest(models.Model):
    STATUS_PENDING = 'pending'
    STATUS_APPROVED = 'approved'
    STATUS_REJECTED = 'rejected'
    STATUS_CANCELLED = 'cancelled'
    STATUS_CHOICES = [
        (STATUS_PENDING, 'Pending'),
        (STATUS_APPROVED, 'Approved'),
        (STATUS_REJECTED, 'Rejected'),
        (STATUS_CANCELLED, 'Cancelled'),
    ]

    household = models.ForeignKey(Household, on_delete=models.CASCADE, related_name='money_requests')
    requester = models.ForeignKey(User, on_delete=models.CASCADE, related_name='requests_made')
    approver = models.ForeignKey(User, on_delete=models.CASCADE, related_name='requests_to_approve')
    amount = models.DecimalField(max_digits=12, decimal_places=2)
    currency = models.ForeignKey(Currency, on_delete=models.PROTECT, null=True, blank=True)
    purpose = models.CharField(max_length=200, help_text='What is this money for?')
    notes = models.TextField(blank=True)
    category = models.ForeignKey(Category, on_delete=models.SET_NULL, null=True, blank=True,
                                  help_text='Expense category once approved')
    status = models.CharField(max_length=15, choices=STATUS_CHOICES, default=STATUS_PENDING)
    response_note = models.TextField(blank=True, help_text='Approver/rejecter note')
    created_at = models.DateTimeField(auto_now_add=True)
    resolved_at = models.DateTimeField(null=True, blank=True)
    # Linked transactions when approved
    income_transaction = models.ForeignKey(
        Transaction, on_delete=models.SET_NULL, null=True, blank=True,
        related_name='request_income_for'
    )
    expense_transaction = models.ForeignKey(
        Transaction, on_delete=models.SET_NULL, null=True, blank=True,
        related_name='request_expense_for'
    )

    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        return f"Request: {self.amount} for {self.purpose} ({self.status})"


# ============================================================
# NET WORTH: ASSETS & LIABILITIES
# ============================================================

class Asset(models.Model):
    TYPE_CASH = 'cash'
    TYPE_BANK = 'bank'
    TYPE_INVESTMENT = 'investment'
    TYPE_PROPERTY = 'property'
    TYPE_LAND = 'land'
    TYPE_HOUSE = 'house'
    TYPE_BUSINESS = 'business'
    TYPE_VEHICLE = 'vehicle'
    TYPE_OTHER = 'other'
    TYPE_CHOICES = [
        (TYPE_CASH, 'Cash'),
        (TYPE_BANK, 'Bank Account'),
        (TYPE_INVESTMENT, 'Investment'),
        (TYPE_PROPERTY, 'Property/Real Estate'),
        (TYPE_LAND, 'Land'),
        (TYPE_HOUSE, 'House'),
        (TYPE_BUSINESS, 'Business'),
        (TYPE_VEHICLE, 'Vehicle'),
        (TYPE_OTHER, 'Other'),
    ]
    # Asset types that benefit from the extended detail fields below
    MAJOR_TYPES = {TYPE_PROPERTY, TYPE_LAND, TYPE_HOUSE, TYPE_BUSINESS, TYPE_VEHICLE}

    household = models.ForeignKey(Household, on_delete=models.CASCADE, related_name='assets')
    name = models.CharField(max_length=120)
    asset_type = models.CharField(max_length=20, choices=TYPE_CHOICES, default=TYPE_BANK)
    value = models.DecimalField(max_digits=14, decimal_places=2)
    currency = models.ForeignKey(Currency, on_delete=models.PROTECT, null=True, blank=True)
    notes = models.TextField(blank=True)
    # Optional descriptive fields used by major assets (land/house/business/vehicle).
    acquisition_date = models.DateField(null=True, blank=True,
                                        help_text='When the asset was acquired')
    location = models.CharField(max_length=200, blank=True,
                                help_text='Address, plot, or business location')
    size = models.CharField(max_length=60, blank=True,
                            help_text='e.g. 120 m², 0.5 acre, 3 bed / 2 bath')
    registration_number = models.CharField(max_length=100, blank=True,
                                            help_text='Title deed, plate, or registration #')
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-value']

    def __str__(self):
        return f"{self.name}: {self.value}"

    @property
    def is_major(self):
        return self.asset_type in self.MAJOR_TYPES


class Liability(models.Model):
    TYPE_LOAN = 'loan'
    TYPE_MORTGAGE = 'mortgage'
    TYPE_CREDIT_CARD = 'credit_card'
    TYPE_OTHER = 'other'
    TYPE_CHOICES = [
        (TYPE_LOAN, 'Loan'),
        (TYPE_MORTGAGE, 'Mortgage'),
        (TYPE_CREDIT_CARD, 'Credit Card'),
        (TYPE_OTHER, 'Other'),
    ]

    household = models.ForeignKey(Household, on_delete=models.CASCADE, related_name='liabilities')
    name = models.CharField(max_length=120)
    liability_type = models.CharField(max_length=20, choices=TYPE_CHOICES, default=TYPE_LOAN)
    balance = models.DecimalField(max_digits=14, decimal_places=2,
                                  help_text='Current outstanding balance')
    original_amount = models.DecimalField(max_digits=14, decimal_places=2, null=True, blank=True,
                                          help_text='Original loan / debt amount, if known')
    currency = models.ForeignKey(Currency, on_delete=models.PROTECT, null=True, blank=True)
    interest_rate = models.DecimalField(max_digits=5, decimal_places=2, null=True, blank=True,
                                         help_text='Annual %')
    lender = models.CharField(max_length=200, blank=True,
                              help_text='Bank, person, or institution holding the debt')
    start_date = models.DateField(null=True, blank=True)
    due_date = models.DateField(null=True, blank=True,
                                help_text='Final repayment date')
    notes = models.TextField(blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-balance']
        verbose_name_plural = 'Liabilities'

    def __str__(self):
        return f"{self.name}: {self.balance}"

    @property
    def total_paid(self):
        from decimal import Decimal as D
        return self.payments.aggregate(s=models.Sum('amount'))['s'] or D('0')


class LiabilityPayment(models.Model):
    """A payment made against a debt — decrements the liability balance."""
    liability = models.ForeignKey(Liability, on_delete=models.CASCADE, related_name='payments')
    date = models.DateField(default=timezone.now)
    amount = models.DecimalField(max_digits=14, decimal_places=2)
    currency = models.ForeignKey(Currency, on_delete=models.PROTECT, null=True, blank=True)
    notes = models.TextField(blank=True)
    # When the payment is also recorded as a household expense, link to it so
    # deleting the payment can clean up the corresponding transaction.
    transaction = models.ForeignKey(
        Transaction, on_delete=models.SET_NULL, null=True, blank=True,
        related_name='debt_payment_for'
    )
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-date', '-created_at']

    def __str__(self):
        return f"Payment of {self.amount} on {self.date} for {self.liability.name}"


# ============================================================
# SAVINGS GOALS
# ============================================================

class Goal(models.Model):
    STATUS_ACTIVE = 'active'
    STATUS_ACHIEVED = 'achieved'
    STATUS_PAUSED = 'paused'
    STATUS_CHOICES = [
        (STATUS_ACTIVE, 'Active'),
        (STATUS_ACHIEVED, 'Achieved'),
        (STATUS_PAUSED, 'Paused'),
    ]

    household = models.ForeignKey(Household, on_delete=models.CASCADE, related_name='goals')
    name = models.CharField(max_length=120, help_text='e.g. "Emergency Fund", "Trip to Spain"')
    target_amount = models.DecimalField(max_digits=14, decimal_places=2)
    current_amount = models.DecimalField(max_digits=14, decimal_places=2, default=0)
    target_date = models.DateField(null=True, blank=True)
    monthly_contribution = models.DecimalField(
        max_digits=12, decimal_places=2, null=True, blank=True,
        help_text='How much you plan to add each month'
    )
    currency = models.ForeignKey(Currency, on_delete=models.PROTECT, null=True, blank=True)
    icon = models.CharField(max_length=50, default='bi-piggy-bank', help_text='Bootstrap icon class')
    color = models.CharField(max_length=7, default='#0d6efd')
    status = models.CharField(max_length=15, choices=STATUS_CHOICES, default=STATUS_ACTIVE)
    notes = models.TextField(blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        return f"{self.name} ({self.current_amount}/{self.target_amount})"

    @property
    def progress_percent(self):
        if not self.target_amount:
            return 0
        pct = float(self.current_amount) / float(self.target_amount) * 100
        return min(round(pct, 1), 100)

    @property
    def amount_remaining(self):
        from decimal import Decimal as D
        return max(D('0'), D(self.target_amount) - D(self.current_amount))

    @property
    def months_remaining(self):
        if not self.target_date:
            return None
        today = timezone.now().date()
        if self.target_date <= today:
            return 0
        delta_days = (self.target_date - today).days
        return max(1, delta_days // 30)

    @property
    def monthly_needed(self):
        """Amount per month to hit target by target_date."""
        m = self.months_remaining
        if not m:
            return None
        from decimal import Decimal as D
        return (D(self.amount_remaining) / D(m)).quantize(D('0.01'))

    @property
    def on_track(self):
        """True when the planned monthly contribution is enough to hit the target."""
        if self.monthly_contribution is None or self.monthly_needed is None:
            return None
        return self.monthly_contribution >= self.monthly_needed


class GoalContribution(models.Model):
    """A deposit toward a savings goal."""
    goal = models.ForeignKey(Goal, on_delete=models.CASCADE, related_name='contributions')
    user = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True,
                             related_name='goal_contributions')
    amount = models.DecimalField(max_digits=14, decimal_places=2)
    date = models.DateField(default=timezone.now)
    notes = models.TextField(blank=True)
    transaction = models.ForeignKey(
        Transaction, on_delete=models.SET_NULL, null=True, blank=True,
        related_name='goal_contribution_for'
    )
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-date', '-created_at']

    def __str__(self):
        return f"{self.amount} -> {self.goal.name} on {self.date}"


# ============================================================
# PROJECTS (budget envelopes spanning categories)
# ============================================================

class Project(models.Model):
    STATUS_PLANNING = 'planning'
    STATUS_ACTIVE = 'active'
    STATUS_COMPLETED = 'completed'
    STATUS_CANCELLED = 'cancelled'
    STATUS_CHOICES = [
        (STATUS_PLANNING, 'Planning'),
        (STATUS_ACTIVE, 'Active'),
        (STATUS_COMPLETED, 'Completed'),
        (STATUS_CANCELLED, 'Cancelled'),
    ]

    household = models.ForeignKey(Household, on_delete=models.CASCADE, related_name='projects')
    name = models.CharField(max_length=160)
    description = models.TextField(blank=True)
    budget = models.DecimalField(max_digits=14, decimal_places=2, default=0,
                                  help_text='Total envelope; 0 if untracked')
    currency = models.ForeignKey(Currency, on_delete=models.PROTECT, null=True, blank=True)
    start_date = models.DateField(null=True, blank=True)
    end_date = models.DateField(null=True, blank=True)
    status = models.CharField(max_length=15, choices=STATUS_CHOICES, default=STATUS_PLANNING)
    color = models.CharField(max_length=7, default='#6610f2')
    icon = models.CharField(max_length=50, default='bi-bookmark-star')
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-created_at']

    def __str__(self):
        return self.name

    @property
    def spent(self):
        from decimal import Decimal as D
        return self.transactions.filter(transaction_type=Transaction.EXPENSE).aggregate(
            s=models.Sum('amount_base')
        )['s'] or D('0')

    @property
    def income_received(self):
        from decimal import Decimal as D
        return self.transactions.filter(transaction_type=Transaction.INCOME).aggregate(
            s=models.Sum('amount_base')
        )['s'] or D('0')

    @property
    def progress_percent(self):
        if not self.budget:
            return 0
        pct = float(self.spent) / float(self.budget) * 100
        return min(round(pct, 1), 100)

    @property
    def is_over_budget(self):
        return bool(self.budget) and self.spent > self.budget


# ============================================================
# HOUSEHOLD MEETINGS & AGREEMENTS
# ============================================================

class Meeting(models.Model):
    """A scheduled or held household meeting (typically quarterly)."""
    STATUS_PLANNED = 'planned'
    STATUS_HELD = 'held'
    STATUS_CANCELLED = 'cancelled'
    STATUS_CHOICES = [
        (STATUS_PLANNED, 'Planned'),
        (STATUS_HELD, 'Held'),
        (STATUS_CANCELLED, 'Cancelled'),
    ]

    household = models.ForeignKey(Household, on_delete=models.CASCADE, related_name='meetings')
    title = models.CharField(max_length=160, help_text='e.g. "Q2 2026 Review"')
    meeting_date = models.DateField(default=timezone.now)
    participants = models.ManyToManyField(User, related_name='meetings_attended', blank=True)
    agenda = models.TextField(blank=True, help_text='What you plan to discuss')
    minutes = models.TextField(blank=True, help_text='Summary / minutes of the meeting')
    status = models.CharField(max_length=15, choices=STATUS_CHOICES, default=STATUS_PLANNED)
    # Optional snapshot of household state at meeting time
    income_snapshot = models.DecimalField(max_digits=14, decimal_places=2, null=True, blank=True)
    expense_snapshot = models.DecimalField(max_digits=14, decimal_places=2, null=True, blank=True)
    net_worth_snapshot = models.DecimalField(max_digits=14, decimal_places=2, null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-meeting_date', '-created_at']

    def __str__(self):
        return f"{self.title} ({self.meeting_date})"

    @property
    def progress_percent(self):
        items = self.agreements.all()
        if not items:
            return 0
        total = sum(i.progress for i in items)
        return int(total / items.count())

    @property
    def open_count(self):
        return self.agreements.exclude(
            status__in=[AgreementItem.STATUS_DONE, AgreementItem.STATUS_CANCELLED]
        ).count()

    @property
    def done_count(self):
        return self.agreements.filter(status=AgreementItem.STATUS_DONE).count()


class AgreementItem(models.Model):
    """An action item or decision agreed at a household meeting."""
    STATUS_OPEN = 'open'
    STATUS_IN_PROGRESS = 'in_progress'
    STATUS_DONE = 'done'
    STATUS_CANCELLED = 'cancelled'
    STATUS_CHOICES = [
        (STATUS_OPEN, 'Open'),
        (STATUS_IN_PROGRESS, 'In progress'),
        (STATUS_DONE, 'Done'),
        (STATUS_CANCELLED, 'Cancelled'),
    ]

    PRIORITY_LOW = 'low'
    PRIORITY_NORMAL = 'normal'
    PRIORITY_HIGH = 'high'
    PRIORITY_CHOICES = [
        (PRIORITY_LOW, 'Low'),
        (PRIORITY_NORMAL, 'Normal'),
        (PRIORITY_HIGH, 'High'),
    ]

    meeting = models.ForeignKey(Meeting, on_delete=models.CASCADE, related_name='agreements')
    title = models.CharField(max_length=200)
    description = models.TextField(blank=True)
    owner = models.ForeignKey(User, on_delete=models.SET_NULL, null=True, blank=True,
                              related_name='owned_agreements')
    target_date = models.DateField(null=True, blank=True, help_text='When this should be done by')
    status = models.CharField(max_length=15, choices=STATUS_CHOICES, default=STATUS_OPEN)
    progress = models.IntegerField(default=0, help_text='0 to 100')
    priority = models.CharField(max_length=10, choices=PRIORITY_CHOICES, default=PRIORITY_NORMAL)
    completed_date = models.DateField(null=True, blank=True)
    notes = models.TextField(blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['status', '-priority', 'target_date']

    def __str__(self):
        return f"{self.title} [{self.get_status_display()}]"

    @property
    def is_overdue(self):
        if not self.target_date or self.status in (self.STATUS_DONE, self.STATUS_CANCELLED):
            return False
        return self.target_date < timezone.now().date()


# ============================================================
# RECEIVABLES (people who borrowed from the household)
# ============================================================

class Receivable(models.Model):
    """Money the household has lent out — an asset for net worth purposes."""
    STATUS_ACTIVE = 'active'
    STATUS_PAID = 'paid'
    STATUS_WRITTEN_OFF = 'written_off'
    STATUS_CHOICES = [
        (STATUS_ACTIVE, 'Active'),
        (STATUS_PAID, 'Paid in full'),
        (STATUS_WRITTEN_OFF, 'Written off'),
    ]

    household = models.ForeignKey(Household, on_delete=models.CASCADE, related_name='receivables')
    debtor_name = models.CharField(max_length=160, help_text='Who borrowed from you')
    debtor_contact = models.CharField(max_length=200, blank=True,
                                       help_text='Phone, email, etc. (optional)')
    description = models.CharField(max_length=255, blank=True,
                                    help_text='What was the money for')
    balance = models.DecimalField(max_digits=14, decimal_places=2,
                                  help_text='Current outstanding amount')
    original_amount = models.DecimalField(max_digits=14, decimal_places=2, null=True, blank=True,
                                           help_text='Original amount lent (if different from balance)')
    currency = models.ForeignKey(Currency, on_delete=models.PROTECT, null=True, blank=True)
    interest_rate = models.DecimalField(max_digits=5, decimal_places=2, null=True, blank=True,
                                         help_text='Annual %')
    lent_date = models.DateField(default=timezone.now)
    due_date = models.DateField(null=True, blank=True, help_text='When you expect repayment')
    status = models.CharField(max_length=20, choices=STATUS_CHOICES, default=STATUS_ACTIVE)
    notes = models.TextField(blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-balance']

    def __str__(self):
        return f"{self.debtor_name}: {self.balance}"

    @property
    def total_received(self):
        from decimal import Decimal as D
        return self.payments.aggregate(s=models.Sum('amount'))['s'] or D('0')

    @property
    def progress_percent(self):
        original = self.original_amount or (self.balance + self.total_received)
        if not original:
            return 0
        pct = float(self.total_received) / float(original) * 100
        return min(round(pct, 1), 100)

    @property
    def is_overdue(self):
        if not self.due_date or self.status != self.STATUS_ACTIVE:
            return False
        return self.due_date < timezone.now().date()


class ReceivablePayment(models.Model):
    """A repayment received from the borrower — bumps household income, lowers receivable balance."""
    receivable = models.ForeignKey(Receivable, on_delete=models.CASCADE, related_name='payments')
    date = models.DateField(default=timezone.now)
    amount = models.DecimalField(max_digits=14, decimal_places=2)
    currency = models.ForeignKey(Currency, on_delete=models.PROTECT, null=True, blank=True)
    notes = models.TextField(blank=True)
    # Link to the optional income transaction recorded for this repayment
    transaction = models.ForeignKey(
        Transaction, on_delete=models.SET_NULL, null=True, blank=True,
        related_name='receivable_payment_for'
    )
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-date', '-created_at']

    def __str__(self):
        return f"Repayment of {self.amount} on {self.date} from {self.receivable.debtor_name}"


class NetWorthSnapshot(models.Model):
    """Optional periodic snapshots for tracking net worth over time."""
    household = models.ForeignKey(Household, on_delete=models.CASCADE, related_name='snapshots')
    snapshot_date = models.DateField(default=timezone.now)
    total_assets = models.DecimalField(max_digits=14, decimal_places=2)
    total_liabilities = models.DecimalField(max_digits=14, decimal_places=2)
    net_worth = models.DecimalField(max_digits=14, decimal_places=2)

    class Meta:
        ordering = ['-snapshot_date']
        unique_together = ('household', 'snapshot_date')

    def __str__(self):
        return f"Snapshot {self.snapshot_date}: {self.net_worth}"
