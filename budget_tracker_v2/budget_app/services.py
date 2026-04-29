"""Business logic: recurring auto-apply, alerts, forecasting, auto-categorize."""
from datetime import date, timedelta
from decimal import Decimal

from django.db.models import Sum
from django.utils import timezone

from .models import (
    Transaction, Budget, RecurringTransaction, Alert,
    CategoryRule, Asset, Liability, NetWorthSnapshot, ExchangeRate,
)


# -------- helpers --------

def month_range(target_date):
    first = target_date.replace(day=1)
    if first.month == 12:
        last = first.replace(year=first.year + 1, month=1) - timedelta(days=1)
    else:
        last = first.replace(month=first.month + 1) - timedelta(days=1)
    return first, last


def days_in_current_month(today=None):
    today = today or timezone.now().date()
    first, last = month_range(today)
    elapsed = (today - first).days + 1
    total = (last - first).days + 1
    return elapsed, total


# -------- auto-categorize --------

def apply_category_rules(transaction):
    """Apply matching rule to a transaction (only if no category set)."""
    if transaction.category:
        return False
    rules = CategoryRule.objects.filter(
        household=transaction.household, is_active=True
    ).order_by('priority')
    haystack = f"{transaction.payee} {transaction.description}".strip()
    for rule in rules:
        if rule.matches(haystack):
            # Only apply if rule's category type matches the transaction type
            if rule.category.category_type == transaction.transaction_type:
                transaction.category = rule.category
                transaction.save(update_fields=['category'])
                return True
    return False


# -------- recurring transactions --------

def apply_due_recurring(household=None, today=None):
    """Create transactions for all recurring entries that are due.
    Returns the list of created Transaction objects.
    """
    today = today or timezone.now().date()
    qs = RecurringTransaction.objects.filter(
        is_active=True, auto_create=True, next_due_date__lte=today
    )
    if household:
        qs = qs.filter(household=household)

    created = []
    for r in qs:
        # Avoid runaway loops: limit catch-up to ~24 occurrences
        guard = 0
        while r.next_due_date <= today and guard < 24:
            if r.end_date and r.next_due_date > r.end_date:
                r.is_active = False
                r.save(update_fields=['is_active'])
                break
            t = Transaction.objects.create(
                household=r.household,
                user=r.user,
                category=r.category,
                transaction_type=r.transaction_type,
                amount=r.amount,
                currency=r.currency or r.household.base_currency,
                description=r.name + (f" — {r.notes}" if r.notes else ""),
                payee=r.payee,
                date=r.next_due_date,
                source=Transaction.SOURCE_RECURRING,
            )
            apply_category_rules(t)
            created.append(t)
            r.next_due_date = r.advance_due_date()
            guard += 1
        r.save(update_fields=['next_due_date', 'is_active'])

    return created


def upcoming_recurring(household, days=7, today=None):
    today = today or timezone.now().date()
    cutoff = today + timedelta(days=days)
    return RecurringTransaction.objects.filter(
        household=household, is_active=True,
        next_due_date__gte=today, next_due_date__lte=cutoff
    ).order_by('next_due_date')


# -------- budget alerts --------

def check_budget_alerts(household, today=None):
    """Generate Alert rows when categories cross 80% or 100% of budget."""
    today = today or timezone.now().date()
    month_start, month_end = month_range(today)
    budgets = Budget.objects.filter(household=household, month=month_start)
    new_alerts = []

    for b in budgets:
        spent = Transaction.objects.filter(
            household=household, transaction_type=Transaction.EXPENSE,
            category=b.category, date__gte=month_start, date__lte=month_end,
        ).aggregate(s=Sum('amount_base'))['s'] or Decimal('0')
        if b.monthly_limit <= 0:
            continue
        pct = float(spent / b.monthly_limit * 100)

        if pct >= 100 and not b.alert_100_sent:
            a = Alert.objects.create(
                household=household,
                title=f"Budget exceeded: {b.category.name}",
                message=f"You've spent {household.currency_symbol}{spent:.2f} of "
                        f"{household.currency_symbol}{b.monthly_limit:.2f} ({pct:.0f}%) this month.",
                level=Alert.LEVEL_DANGER,
                link_url='/budgets/',
            )
            new_alerts.append(a)
            b.alert_100_sent = True
            b.alert_80_sent = True
            b.save(update_fields=['alert_100_sent', 'alert_80_sent'])
        elif pct >= 80 and not b.alert_80_sent:
            a = Alert.objects.create(
                household=household,
                title=f"Approaching budget: {b.category.name}",
                message=f"You've used {pct:.0f}% of your {b.category.name} budget "
                        f"({household.currency_symbol}{spent:.2f} of "
                        f"{household.currency_symbol}{b.monthly_limit:.2f}).",
                level=Alert.LEVEL_WARNING,
                link_url='/budgets/',
            )
            new_alerts.append(a)
            b.alert_80_sent = True
            b.save(update_fields=['alert_80_sent'])

    return new_alerts


def reset_monthly_budget_alerts(household, today=None):
    """Reset alert flags at start of each month."""
    today = today or timezone.now().date()
    month_start, _ = month_range(today)
    Budget.objects.filter(household=household, month=month_start).update(
        alert_80_sent=False, alert_100_sent=False
    )


# -------- forecasting --------

def forecast_end_of_month(household, today=None):
    """Predict end-of-month balance based on current spending rate.

    Returns dict with: income_so_far, expense_so_far, days_elapsed, days_total,
    projected_income, projected_expense, projected_balance, daily_burn.
    """
    today = today or timezone.now().date()
    month_start, month_end = month_range(today)
    elapsed, total = days_in_current_month(today)

    income = Transaction.objects.filter(
        household=household, transaction_type=Transaction.INCOME,
        date__gte=month_start, date__lte=today
    ).aggregate(s=Sum('amount_base'))['s'] or Decimal('0')

    expense = Transaction.objects.filter(
        household=household, transaction_type=Transaction.EXPENSE,
        date__gte=month_start, date__lte=today
    ).aggregate(s=Sum('amount_base'))['s'] or Decimal('0')

    daily_burn = (expense / elapsed) if elapsed else Decimal('0')
    daily_inflow = (income / elapsed) if elapsed else Decimal('0')

    # Add upcoming recurring transactions for the rest of the month
    upcoming_expense = Decimal('0')
    upcoming_income = Decimal('0')
    for r in RecurringTransaction.objects.filter(
        household=household, is_active=True, auto_create=True,
        next_due_date__gt=today, next_due_date__lte=month_end,
    ):
        # Convert amount to base currency roughly
        amt = r.amount  # simple: assume base currency unless rate exists
        if r.transaction_type == Transaction.EXPENSE:
            upcoming_expense += amt
        else:
            upcoming_income += amt

    # Projection: actual + (daily rate * remaining days) + known recurring
    remaining = total - elapsed
    projected_income = income + upcoming_income + (daily_inflow * remaining * Decimal('0.3'))
    projected_expense = expense + upcoming_expense + (daily_burn * remaining)

    return {
        'income_so_far': income,
        'expense_so_far': expense,
        'days_elapsed': elapsed,
        'days_total': total,
        'days_remaining': remaining,
        'daily_burn': daily_burn.quantize(Decimal('0.01')),
        'daily_inflow': daily_inflow.quantize(Decimal('0.01')),
        'projected_income': projected_income.quantize(Decimal('0.01')),
        'projected_expense': projected_expense.quantize(Decimal('0.01')),
        'projected_balance': (projected_income - projected_expense).quantize(Decimal('0.01')),
        'current_balance': (income - expense).quantize(Decimal('0.01')),
    }


# -------- net worth --------

def compute_net_worth(household):
    """Sum assets and liabilities (in base currency)."""
    base = household.base_currency

    def to_base(amount, currency):
        if not currency or not base or currency.id == base.id:
            return amount
        rate = ExchangeRate.objects.filter(from_currency=currency, to_currency=base).first()
        if rate:
            return Decimal(amount) * rate.rate
        inverse = ExchangeRate.objects.filter(from_currency=base, to_currency=currency).first()
        if inverse and inverse.rate:
            return Decimal(amount) / inverse.rate
        return amount

    total_assets = Decimal('0')
    by_asset_type = {}
    for a in household.assets.all():
        v = Decimal(to_base(a.value, a.currency))
        total_assets += v
        by_asset_type[a.get_asset_type_display()] = by_asset_type.get(
            a.get_asset_type_display(), Decimal('0')
        ) + v

    total_liab = Decimal('0')
    by_liab_type = {}
    for l in household.liabilities.all():
        v = Decimal(to_base(l.balance, l.currency))
        total_liab += v
        by_liab_type[l.get_liability_type_display()] = by_liab_type.get(
            l.get_liability_type_display(), Decimal('0')
        ) + v

    return {
        'total_assets': total_assets.quantize(Decimal('0.01')),
        'total_liabilities': total_liab.quantize(Decimal('0.01')),
        'net_worth': (total_assets - total_liab).quantize(Decimal('0.01')),
        'assets_by_type': by_asset_type,
        'liabilities_by_type': by_liab_type,
    }


# -------- bill calendar --------

def bills_in_month(household, target_date):
    """Return dict mapping date -> list of (recurring or one-off bill) items for the month.

    Combines RecurringTransaction occurrences and existing expense Transactions.
    """
    month_start, month_end = month_range(target_date)
    days = {}

    # Project recurring expenses across the month
    for r in household.recurring_transactions.filter(
        is_active=True, transaction_type=Transaction.EXPENSE
    ):
        cursor = r.next_due_date
        # Walk back to start of month if needed
        guard = 0
        # Move cursor forward into the month
        while cursor < month_start and guard < 60:
            cursor = r.advance_due_date(from_date=cursor)
            guard += 1
        guard = 0
        while cursor <= month_end and guard < 60:
            if r.end_date and cursor > r.end_date:
                break
            days.setdefault(cursor, []).append({
                'kind': 'recurring',
                'name': r.name,
                'amount': r.amount,
                'category': r.category,
                'payee': r.payee,
            })
            cursor = r.advance_due_date(from_date=cursor)
            guard += 1

    return days
