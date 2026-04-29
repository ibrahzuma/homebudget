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
        # Always compute base amount for aggregation
        if self.amount_base is None or kwargs.pop('recompute_base', False):
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
    TYPE_VEHICLE = 'vehicle'
    TYPE_OTHER = 'other'
    TYPE_CHOICES = [
        (TYPE_CASH, 'Cash'),
        (TYPE_BANK, 'Bank Account'),
        (TYPE_INVESTMENT, 'Investment'),
        (TYPE_PROPERTY, 'Property/Real Estate'),
        (TYPE_VEHICLE, 'Vehicle'),
        (TYPE_OTHER, 'Other'),
    ]

    household = models.ForeignKey(Household, on_delete=models.CASCADE, related_name='assets')
    name = models.CharField(max_length=120)
    asset_type = models.CharField(max_length=20, choices=TYPE_CHOICES, default=TYPE_BANK)
    value = models.DecimalField(max_digits=14, decimal_places=2)
    currency = models.ForeignKey(Currency, on_delete=models.PROTECT, null=True, blank=True)
    notes = models.TextField(blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-value']

    def __str__(self):
        return f"{self.name}: {self.value}"


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
    balance = models.DecimalField(max_digits=14, decimal_places=2)
    currency = models.ForeignKey(Currency, on_delete=models.PROTECT, null=True, blank=True)
    interest_rate = models.DecimalField(max_digits=5, decimal_places=2, null=True, blank=True,
                                         help_text='Annual %')
    notes = models.TextField(blank=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ['-balance']
        verbose_name_plural = 'Liabilities'

    def __str__(self):
        return f"{self.name}: {self.balance}"


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
