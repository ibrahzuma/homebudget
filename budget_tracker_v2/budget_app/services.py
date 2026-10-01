"""Business logic: recurring auto-apply, alerts, forecasting, auto-categorize,
and the household actions shared by the web views and the JSON API."""
import csv
import io
from datetime import date, datetime, timedelta
from decimal import Decimal, InvalidOperation

from django.db import transaction as db_transaction
from django.db.models import Q, Sum
from django.utils import timezone


# ============================================================
# Real-time push (Django Channels)
# ============================================================

def push_to_household(household, payload):
    """Fan an event out to every WebSocket connected to this household.

    `payload` should be a JSON-serialisable dict with at minimum {'kind': '...'}
    so the JS client can route the message. Safe to call from any sync code —
    no-ops cleanly if Channels isn't configured.
    """
    try:
        from channels.layers import get_channel_layer
        from asgiref.sync import async_to_sync
        layer = get_channel_layer()
        if not layer or not household:
            return
        async_to_sync(layer.group_send)(
            f'household_{household.id}',
            {'type': 'notify', 'payload': payload},
        )
    except Exception:
        # Don't ever break a request because the push failed (e.g. dev without channels).
        pass

from .models import (
    Transaction, Budget, RecurringTransaction, Alert,
    CategoryRule, Liability, NetWorthSnapshot, ExchangeRate,
    Meeting, AgreementItem, Category, Currency, MoneyRequest, Goal,
    Receivable, ChatMessage, ChatReadState,
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


def check_upcoming_meeting_alerts(household, today=None, days_ahead=7):
    """Create an Alert when a planned meeting is within `days_ahead` days.

    Dedupes by link_url so a meeting only generates one upcoming-reminder Alert.
    """
    today = today or timezone.now().date()
    cutoff = today + timedelta(days=days_ahead)
    upcoming = household.meetings.filter(
        status=Meeting.STATUS_PLANNED,
        meeting_date__gte=today, meeting_date__lte=cutoff,
    )
    created = []
    for m in upcoming:
        link = f"/meetings/{m.pk}/"
        if Alert.objects.filter(household=household, link_url=link).exists():
            continue
        days = (m.meeting_date - today).days
        when = "today" if days == 0 else (
            "tomorrow" if days == 1 else f"in {days} days"
        )
        a = Alert.objects.create(
            household=household,
            title=f"Upcoming meeting: {m.title}",
            message=f"\"{m.title}\" is scheduled {when} ({m.meeting_date.strftime('%a, %b %d')}).",
            level=Alert.LEVEL_INFO,
            link_url=link,
        )
        created.append(a)
    return created


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
    base = household.base_currency
    for r in RecurringTransaction.objects.filter(
        household=household, is_active=True, auto_create=True,
        next_due_date__gt=today, next_due_date__lte=month_end,
    ):
        amt = Decimal(r.amount)
        if base and r.currency_id and r.currency_id != base.id:
            rate = ExchangeRate.objects.filter(
                from_currency=r.currency, to_currency=base
            ).first()
            if rate:
                amt = amt * rate.rate
            else:
                inverse = ExchangeRate.objects.filter(
                    from_currency=base, to_currency=r.currency
                ).first()
                if inverse and inverse.rate:
                    amt = amt / inverse.rate
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
    """Sum assets, receivables (money lent out), and liabilities (in base currency)."""
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

    # Receivables — money others owe us — are an asset on the balance sheet
    total_receivables = Decimal('0')
    for r in household.receivables.filter(status='active'):
        total_receivables += Decimal(to_base(r.balance, r.currency))

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
        'total_receivables': total_receivables.quantize(Decimal('0.01')),
        'total_liabilities': total_liab.quantize(Decimal('0.01')),
        'net_worth': (total_assets + total_receivables - total_liab).quantize(Decimal('0.01')),
        'assets_by_type': by_asset_type,
        'liabilities_by_type': by_liab_type,
    }


# -------- bill calendar --------

def bills_in_month(household, target_date):
    """Return dict mapping date -> list of recurring expense AND income items for the month.

    Used by the cash-flow calendar. Each item dict has a `kind`:
      'expense' for outflows, 'income' for inflows.
    """
    month_start, month_end = month_range(target_date)
    days = {}

    for r in household.recurring_transactions.filter(is_active=True):
        kind = 'income' if r.transaction_type == Transaction.INCOME else 'expense'
        cursor = r.next_due_date
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
                'kind': kind,
                'name': r.name,
                'amount': r.amount,
                'category': r.category,
                'payee': r.payee,
                'transaction_type': r.transaction_type,
            })
            cursor = r.advance_due_date(from_date=cursor)
            guard += 1

    return days


# ============================================================
# Household actions shared by the web views and the JSON API.
#
# Each function holds the side effects of one user action (linked
# transactions, balance updates, alerts, pushes) so both front ends behave
# identically. Callers validate; these assume valid input.
# ============================================================

DEFAULT_CURRENCIES = [
    ('USD', 'US Dollar', '$'),
    ('TZS', 'Tanzanian Shilling', 'TSh'),
    ('EUR', 'Euro', '€'),
    ('GBP', 'British Pound', '£'),
    ('KES', 'Kenyan Shilling', 'KSh'),
]


def ensure_default_currencies():
    for code, name, sym in DEFAULT_CURRENCIES:
        Currency.objects.get_or_create(code=code, defaults={'name': name, 'symbol': sym})


def seed_household_defaults(household):
    """Seed default currencies and categories for a new household."""
    ensure_default_currencies()

    if not household.base_currency:
        household.base_currency = Currency.objects.get(code='USD')
        household.save(update_fields=['base_currency'])

    cats = [
        ('Salary', Category.INCOME, '#198754', 'bi-cash-coin'),
        ('Freelance', Category.INCOME, '#20c997', 'bi-laptop'),
        ('Other Income', Category.INCOME, '#0dcaf0', 'bi-plus-circle'),
        ('Groceries', Category.EXPENSE, '#0d6efd', 'bi-cart3'),
        ('Rent / Mortgage', Category.EXPENSE, '#6f42c1', 'bi-house-door'),
        ('Utilities', Category.EXPENSE, '#fd7e14', 'bi-lightning'),
        ('Fuel', Category.EXPENSE, '#dc3545', 'bi-fuel-pump'),
        ('Transport', Category.EXPENSE, '#e83e8c', 'bi-bus-front'),
        ('Dining Out', Category.EXPENSE, '#d63384', 'bi-cup-hot'),
        ('Entertainment', Category.EXPENSE, '#ffc107', 'bi-film'),
        ('Subscriptions', Category.EXPENSE, '#6610f2', 'bi-broadcast'),
        ('Healthcare', Category.EXPENSE, '#198754', 'bi-heart-pulse'),
    ]
    for name, ctype, color, icon in cats:
        Category.objects.get_or_create(
            household=household, name=name, category_type=ctype,
            defaults={'color': color, 'icon': icon}
        )


def add_member_to_household(household, user):
    """Add ``user`` to ``household``, cleaning up the stub household they were
    forced to create at signup.

    Returns a ``(level, message)`` pair for ``messages.<level>``.

    Every new account is pushed through /household/setup/, so an invited partner
    almost always owns a throwaway solo household by the time they are added
    here. Left in place it competes with the shared household when resolving
    which one they see. If that leftover holds nothing the user authored it is
    just signup residue and is deleted; if it holds real data we keep it (and
    say so) rather than cascade-deleting the user's records.
    """
    if household.members.filter(pk=user.pk).exists():
        return 'info', f"{user.username} is already a member of this household."

    household.members.add(user)

    # Everything a user can author. Seeded categories/currencies don't count —
    # those exist in every brand-new household.
    user_data = ('transactions', 'budgets', 'recurring_transactions', 'assets',
                 'liabilities', 'goals', 'projects', 'meetings', 'receivables',
                 'chat_messages', 'money_requests')

    kept = []
    for other in user.households.exclude(pk=household.pk):
        is_empty_stub = (
            other.members.count() == 1
            and not any(getattr(other, rel).exists() for rel in user_data)
        )
        if is_empty_stub:
            other.delete()
        else:
            kept.append(other.name)

    if kept:
        return 'warning', (
            f"{user.username} added, but they still belong to: {', '.join(kept)}. "
            f"Those households hold data, so they were left alone — "
            f"{user.username} will now see '{household.name}'."
        )
    return 'success', f"{user.username} added to {household.name}."


def accept_invitation(invite, user):
    """Join ``user`` to the invite's household, burn the link, tell the sender."""
    level, msg = add_member_to_household(invite.household, user)
    invite.accept(user)
    Alert.objects.create(
        household=invite.household, user=invite.invited_by,
        title='Invite accepted',
        message=f"{user.username} joined {invite.household.name}.",
        level=Alert.LEVEL_INFO, link_url='/household/settings/',
    )
    return level, msg


def run_daily_household_tasks(household):
    """Catch-up work run once per user per day (middleware and API)."""
    apply_due_recurring(household=household)
    check_budget_alerts(household)
    check_upcoming_meeting_alerts(household)


# -------- money requests --------

def notify_money_request_created(money_request):
    household = money_request.household
    requester = money_request.requester
    symbol = money_request.currency.symbol if money_request.currency else household.currency_symbol
    Alert.objects.create(
        household=household, user=money_request.approver,
        title=f"Money request from {requester.username}",
        message=f"{requester.username} requested {symbol}{money_request.amount} "
                f"for: {money_request.purpose}",
        level=Alert.LEVEL_INFO,
        link_url=f"/requests/{money_request.pk}/",
    )
    push_to_household(household, {
        'kind': 'request.created',
        'message': f"New money request from {requester.username} for {money_request.purpose}",
        'link': f'/requests/{money_request.pk}/',
        'level': 'info',
        'for_user_id': money_request.approver_id,
        'request_id': money_request.pk,
    })


def approve_money_request(money_request, note=''):
    """Approve a pending request.

    An approved money request is purely an internal transfer of household
    funds — it represents money the household is actually spending, not
    income. Record a single expense attributed to the requester (the spender),
    in the requested category, so the household total reflects the outflow once.
    """
    household = money_request.household
    approver = money_request.approver
    with db_transaction.atomic():
        cur = money_request.currency or household.base_currency
        expense_t = Transaction.objects.create(
            household=household, user=money_request.requester,
            category=money_request.category,
            transaction_type=Transaction.EXPENSE,
            amount=money_request.amount, currency=cur,
            description=f"Approved by {approver.username}: {money_request.purpose}",
            payee=money_request.purpose,
            date=timezone.now().date(),
            source=Transaction.SOURCE_REQUEST,
        )
        money_request.status = MoneyRequest.STATUS_APPROVED
        money_request.response_note = note
        money_request.resolved_at = timezone.now()
        money_request.income_transaction = None
        money_request.expense_transaction = expense_t
        money_request.save()
        Alert.objects.create(
            household=household, user=money_request.requester,
            title=f"Request approved by {approver.username}",
            message=f"Your request for {money_request.purpose} was approved.",
            level=Alert.LEVEL_INFO,
        )
        check_budget_alerts(household)
    push_to_household(household, {
        'kind': 'request.approved',
        'message': f"{approver.username} approved your request: {money_request.purpose}",
        'link': f'/requests/{money_request.pk}/',
        'level': 'success',
        'for_user_id': money_request.requester_id,
        'request_id': money_request.pk,
    })


def reject_money_request(money_request, note=''):
    household = money_request.household
    approver = money_request.approver
    money_request.status = MoneyRequest.STATUS_REJECTED
    money_request.response_note = note
    money_request.resolved_at = timezone.now()
    money_request.save()
    Alert.objects.create(
        household=household, user=money_request.requester,
        title=f"Request rejected by {approver.username}",
        message=f"Your request for {money_request.purpose} was rejected."
                + (f" Note: {note}" if note else ""),
        level=Alert.LEVEL_WARNING,
    )
    push_to_household(household, {
        'kind': 'request.rejected',
        'message': f"{approver.username} rejected your request: {money_request.purpose}",
        'link': f'/requests/{money_request.pk}/',
        'level': 'warning',
        'for_user_id': money_request.requester_id,
        'request_id': money_request.pk,
    })


def cancel_money_request(money_request):
    money_request.status = MoneyRequest.STATUS_CANCELLED
    money_request.resolved_at = timezone.now()
    money_request.save()


# -------- debts (liability payments) --------

def record_liability_payment(liability, payment, user, record_as_expense=False,
                             expense_category=None):
    """Save ``payment`` (unsaved) against ``liability`` and lower its balance."""
    household = liability.household
    with db_transaction.atomic():
        payment.liability = liability
        if not payment.currency:
            payment.currency = liability.currency or household.base_currency
        if record_as_expense:
            cat = expense_category
            if not cat:
                cat, _ = Category.objects.get_or_create(
                    household=household, name='Debt Payment',
                    category_type=Category.EXPENSE,
                    defaults={'color': '#dc3545', 'icon': 'bi-cash-stack'},
                )
            payment.transaction = Transaction.objects.create(
                household=household, user=user,
                category=cat, transaction_type=Transaction.EXPENSE,
                amount=payment.amount, currency=payment.currency,
                description=f"Payment toward {liability.name}",
                payee=liability.lender or liability.name,
                date=payment.date,
                source=Transaction.SOURCE_MANUAL,
            )
        payment.save()
        # Decrement the outstanding balance (clamp at 0)
        new_balance = max(Decimal('0'), Decimal(liability.balance) - Decimal(payment.amount))
        Liability.objects.filter(pk=liability.pk).update(balance=new_balance)
    return payment


def delete_liability_payment(liability, payment):
    """Remove a payment, restore the balance and drop its linked expense."""
    with db_transaction.atomic():
        Liability.objects.filter(pk=liability.pk).update(
            balance=Decimal(liability.balance) + Decimal(payment.amount)
        )
        if payment.transaction_id:
            payment.transaction.delete()
        payment.delete()


# -------- savings goals --------

def record_goal_contribution(goal, contribution, user, record_as_expense=False):
    """Save ``contribution`` (unsaved), bump the goal, auto-flip to achieved."""
    household = goal.household
    with db_transaction.atomic():
        contribution.goal = goal
        contribution.user = user
        if record_as_expense:
            cat, _ = Category.objects.get_or_create(
                household=household, name='Savings',
                category_type=Category.EXPENSE,
                defaults={'color': '#0d6efd', 'icon': 'bi-piggy-bank'},
            )
            contribution.transaction = Transaction.objects.create(
                household=household, user=user,
                category=cat, transaction_type=Transaction.EXPENSE,
                amount=contribution.amount,
                currency=goal.currency or household.base_currency,
                description=f"Contribution to {goal.name}",
                payee=goal.name, date=contribution.date,
                source=Transaction.SOURCE_MANUAL,
            )
        contribution.save()
        Goal.objects.filter(pk=goal.pk).update(
            current_amount=Decimal(goal.current_amount) + Decimal(contribution.amount)
        )
        goal.refresh_from_db()
        if goal.current_amount >= goal.target_amount and goal.status == Goal.STATUS_ACTIVE:
            goal.status = Goal.STATUS_ACHIEVED
            goal.save(update_fields=['status'])
    return contribution


def delete_goal_contribution(goal, contribution):
    with db_transaction.atomic():
        Goal.objects.filter(pk=goal.pk).update(
            current_amount=Decimal(goal.current_amount) - Decimal(contribution.amount)
        )
        if contribution.transaction_id:
            contribution.transaction.delete()
        contribution.delete()


# -------- receivables (money lent out) --------

def create_receivable(receivable, user, record_as_expense=False):
    """Save a new loan-out (unsaved, household set), optionally as an expense."""
    household = receivable.household
    with db_transaction.atomic():
        if not receivable.currency:
            receivable.currency = household.base_currency
        if not receivable.original_amount:
            receivable.original_amount = receivable.balance
        receivable.save()
        if record_as_expense:
            cat, _ = Category.objects.get_or_create(
                household=household, name='Lent to Others',
                category_type=Category.EXPENSE,
                defaults={'color': '#fd7e14', 'icon': 'bi-cash-stack'},
            )
            Transaction.objects.create(
                household=household, user=user,
                category=cat, transaction_type=Transaction.EXPENSE,
                amount=receivable.balance,
                currency=receivable.currency,
                description=f"Lent to {receivable.debtor_name}",
                payee=receivable.debtor_name,
                date=receivable.lent_date,
                source=Transaction.SOURCE_MANUAL,
            )
    return receivable


def record_receivable_payment(receivable, payment, user, record_as_income=False):
    """Save a repayment (unsaved), lower the balance, auto-mark paid."""
    household = receivable.household
    with db_transaction.atomic():
        payment.receivable = receivable
        if not payment.currency:
            payment.currency = receivable.currency or household.base_currency
        if record_as_income:
            cat, _ = Category.objects.get_or_create(
                household=household, name='Loan Repayments',
                category_type=Category.INCOME,
                defaults={'color': '#20c997', 'icon': 'bi-cash-stack'},
            )
            payment.transaction = Transaction.objects.create(
                household=household, user=user,
                category=cat, transaction_type=Transaction.INCOME,
                amount=payment.amount, currency=payment.currency,
                description=f"Repayment from {receivable.debtor_name}",
                payee=receivable.debtor_name,
                date=payment.date,
                source=Transaction.SOURCE_MANUAL,
            )
        payment.save()
        new_balance = max(Decimal('0'),
                          Decimal(receivable.balance) - Decimal(payment.amount))
        fields = {'balance': new_balance}
        if new_balance == 0 and receivable.status == Receivable.STATUS_ACTIVE:
            fields['status'] = Receivable.STATUS_PAID
        Receivable.objects.filter(pk=receivable.pk).update(**fields)
    return payment


def delete_receivable_payment(receivable, payment):
    with db_transaction.atomic():
        Receivable.objects.filter(pk=receivable.pk).update(
            balance=Decimal(receivable.balance) + Decimal(payment.amount),
            status=Receivable.STATUS_ACTIVE,
        )
        if payment.transaction_id:
            payment.transaction.delete()
        payment.delete()


# -------- net worth / currencies --------

def save_networth_snapshot(household):
    data = compute_net_worth(household)
    snap, _ = NetWorthSnapshot.objects.update_or_create(
        household=household, snapshot_date=timezone.now().date(),
        defaults={
            'total_assets': data['total_assets'],
            'total_liabilities': data['total_liabilities'],
            'net_worth': data['net_worth'],
        }
    )
    return snap


def save_exchange_rate(household, from_currency, to_currency, rate):
    """Upsert a rate, then recompute base amounts on this household's
    transactions in ``from_currency``."""
    obj, _ = ExchangeRate.objects.update_or_create(
        from_currency=from_currency, to_currency=to_currency,
        defaults={'rate': rate},
    )
    for t in household.transactions.filter(currency=from_currency):
        t.amount_base = t._compute_amount_base()
        t.save(update_fields=['amount_base'])
    return obj


# -------- meetings --------

def snapshot_meeting_state(meeting):
    """Fill the meeting's income/expense/net-worth snapshot (doesn't save)."""
    household = meeting.household
    today = timezone.now().date()
    month_start, _ = month_range(today)
    qs = Transaction.objects.filter(household=household, date__gte=month_start, date__lte=today)
    meeting.income_snapshot = qs.filter(transaction_type=Transaction.INCOME).aggregate(
        s=Sum('amount_base'))['s'] or Decimal('0')
    meeting.expense_snapshot = qs.filter(transaction_type=Transaction.EXPENSE).aggregate(
        s=Sum('amount_base'))['s'] or Decimal('0')
    meeting.net_worth_snapshot = compute_net_worth(household)['net_worth']


def carry_over_open_items(previous_meeting, meeting):
    """Copy unfinished agreement items into ``meeting``; returns the count."""
    open_items = previous_meeting.agreements.exclude(
        status__in=[AgreementItem.STATUS_DONE, AgreementItem.STATUS_CANCELLED]
    )
    carried = 0
    for src in open_items:
        AgreementItem.objects.create(
            meeting=meeting, title=src.title, description=src.description,
            owner=src.owner, target_date=src.target_date, status=src.status,
            progress=src.progress, priority=src.priority, notes=src.notes,
        )
        carried += 1
    return carried


def suggest_next_meeting_date(household):
    """Default next meeting date: 3 months after the last one, else today."""
    last = household.meetings.order_by('-meeting_date').first()
    if not last:
        return timezone.now().date()
    return RecurringTransaction._add_months(last.meeting_date, 3)


def normalize_agreement_completion(item):
    """Done items get progress 100 and a completed date; others lose the date."""
    if item.status == AgreementItem.STATUS_DONE:
        if not item.completed_date:
            item.completed_date = timezone.now().date()
        item.progress = 100
    else:
        item.completed_date = None


def quick_update_agreement(item, status=None, progress=None):
    """Inline status/progress change. Unknown status / bad progress are ignored."""
    if status in dict(AgreementItem.STATUS_CHOICES):
        item.status = status
    if progress is not None:
        try:
            p = max(0, min(100, int(progress)))
            item.progress = p
            if p == 100 and item.status != AgreementItem.STATUS_DONE:
                item.status = AgreementItem.STATUS_DONE
        except (TypeError, ValueError):
            pass
    normalize_agreement_completion(item)
    item.save()
    return item


# -------- chat --------

def mark_chat_read(household, user, when=None):
    ChatReadState.objects.update_or_create(
        user=user, household=household,
        defaults={'last_read_at': when or timezone.now()},
    )


def send_chat_message(household, user, body):
    msg = ChatMessage.objects.create(household=household, sender=user, body=body[:4000])
    # Mark sender's last-read up to (and including) this message
    mark_chat_read(household, user, msg.created_at)
    push_to_household(household, {
        'kind': 'chat.new',
        'id': msg.id,
        'sender_id': msg.sender_id,
        'sender_name': msg.sender.username,
        'body': msg.body,
        'created_at': msg.created_at.isoformat(),
        'created_at_display': timezone.localtime(msg.created_at).strftime('%b %d, %H:%M'),
    })
    return msg


def badge_counts(household, user):
    """Unread alerts, pending approvals and unread chat for ``user``."""
    unread_alerts = Alert.objects.filter(
        household=household, is_read=False
    ).filter(Q(user__isnull=True) | Q(user=user)).count()
    pending_requests = MoneyRequest.objects.filter(
        household=household, approver=user, status=MoneyRequest.STATUS_PENDING
    ).count()
    read_state = ChatReadState.objects.filter(user=user, household=household).first()
    chat_qs = ChatMessage.objects.filter(household=household).exclude(sender=user)
    if read_state:
        chat_qs = chat_qs.filter(created_at__gt=read_state.last_read_at)
    return {
        'unread_alerts': unread_alerts,
        'pending_requests': pending_requests,
        'unread_chat': chat_qs.count(),
    }


# -------- CSV import / export --------

def write_transactions_csv(fileobj, transactions, include_project=False):
    writer = csv.writer(fileobj)
    header = ['date', 'type', 'amount', 'currency', 'amount_base',
              'category', 'payee', 'description', 'member', 'source']
    writer.writerow(header + (['project'] if include_project else []))
    for t in transactions:
        row = [
            t.date.isoformat(), t.transaction_type, t.amount,
            t.currency.code if t.currency else '',
            t.amount_base or '',
            t.category.name if t.category else '',
            t.payee, t.description, t.user.username, t.source,
        ]
        if include_project:
            row.append(t.project.name if t.project else '')
        writer.writerow(row)


def import_transactions_csv(household, user, raw_bytes):
    """Create transactions from CSV bytes. Returns {'created': n, 'errors': [...]}."""
    try:
        decoded = raw_bytes.decode('utf-8-sig')
    except UnicodeDecodeError:
        decoded = raw_bytes.decode('latin-1')
    reader = csv.DictReader(io.StringIO(decoded))

    created = 0
    errors = []
    base_cur = household.base_currency
    for i, row in enumerate(reader, start=2):
        try:
            raw_date = (row.get('date') or '').strip()
            if not raw_date:
                errors.append(f"Row {i}: missing date")
                continue
            try:
                d = datetime.strptime(raw_date, '%Y-%m-%d').date()
            except ValueError:
                d = datetime.strptime(raw_date, '%m/%d/%Y').date()

            ttype = (row.get('type') or '').strip().lower()
            if ttype not in ('income', 'expense'):
                errors.append(f"Row {i}: type must be income or expense")
                continue

            amount = Decimal(str(row.get('amount') or '0').replace(',', ''))

            cat_name = (row.get('category') or '').strip()
            cat = None
            if cat_name:
                cat, _ = Category.objects.get_or_create(
                    household=household, name=cat_name, category_type=ttype,
                    defaults={'color': '#6c757d', 'icon': 'bi-tag'},
                )

            cur_code = (row.get('currency') or '').strip().upper()
            cur = Currency.objects.filter(code=cur_code).first() if cur_code else None
            if not cur:
                cur = base_cur

            t = Transaction.objects.create(
                household=household, user=user, category=cat,
                transaction_type=ttype, amount=amount, currency=cur,
                payee=(row.get('payee') or '').strip(),
                description=(row.get('description') or '').strip(),
                date=d, source=Transaction.SOURCE_IMPORT,
            )
            apply_category_rules(t)
            created += 1
        except (ValueError, InvalidOperation) as e:
            errors.append(f"Row {i}: {e}")
    check_budget_alerts(household)
    return {'created': created, 'errors': errors}


# -------- page summaries (dashboard, calendar, monthly report) --------

def _sum_base(qs):
    return qs.aggregate(s=Sum('amount_base'))['s'] or Decimal('0')


def member_breakdown(household, qs, total_income, total_expense):
    """Per-member income/expense/net and share of the household totals."""
    rows = []
    for member in household.members.all():
        m_inc = _sum_base(qs.filter(user=member, transaction_type=Transaction.INCOME))
        m_exp = _sum_base(qs.filter(user=member, transaction_type=Transaction.EXPENSE))
        exp_share = float(m_exp / total_expense * 100) if total_expense else 0
        inc_share = float(m_inc / total_income * 100) if total_income else 0
        rows.append({
            'user': member, 'income': m_inc, 'expense': m_exp,
            'net': m_inc - m_exp,
            'expense_share_pct': round(exp_share, 1),
            'income_share_pct': round(inc_share, 1),
        })
    return rows


def dashboard_summary(household, user, today=None):
    today = today or timezone.now().date()
    month_start, month_end = month_range(today)

    qs = Transaction.objects.filter(
        household=household, date__gte=month_start, date__lte=month_end
    )
    total_income = _sum_base(qs.filter(transaction_type=Transaction.INCOME))
    total_expense = _sum_base(qs.filter(transaction_type=Transaction.EXPENSE))

    budget_progress = []
    for b in Budget.objects.filter(household=household, month=month_start).select_related('category'):
        spent = _sum_base(qs.filter(transaction_type=Transaction.EXPENSE, category=b.category))
        pct = float(spent / b.monthly_limit * 100) if b.monthly_limit else 0
        budget_progress.append({
            'category': b.category, 'limit': b.monthly_limit, 'spent': spent,
            'pct': min(round(pct, 1), 100), 'over': spent > b.monthly_limit,
        })

    # Credit (owed to us) and debit (we owe)
    total_lent_out = sum(
        (Decimal(r.balance) for r in household.receivables.filter(status=Receivable.STATUS_ACTIVE)),
        Decimal('0')
    )
    total_owed = sum((Decimal(l.balance) for l in household.liabilities.all()), Decimal('0'))

    return {
        'month_label': month_start.strftime('%B %Y'),
        'total_income': total_income,
        'total_expense': total_expense,
        'balance': total_income - total_expense,
        'members_data': member_breakdown(household, qs, total_income, total_expense),
        'budget_progress': budget_progress,
        'recent': qs.select_related('user', 'category', 'currency', 'project')[:6],
        'upcoming': upcoming_recurring(household, days=7),
        'forecast': forecast_end_of_month(household),
        'networth': compute_net_worth(household),
        'pending_my_approvals': MoneyRequest.objects.filter(
            household=household, approver=user, status=MoneyRequest.STATUS_PENDING
        ),
        'active_goals': household.goals.filter(
            status=Goal.STATUS_ACTIVE).order_by('-target_amount')[:4],
        'next_meeting': household.meetings.filter(
            status=Meeting.STATUS_PLANNED, meeting_date__gte=today
        ).order_by('meeting_date').first(),
        'total_lent_out': total_lent_out,
        'total_owed': total_owed,
        'overdue_lent': household.receivables.filter(
            status=Receivable.STATUS_ACTIVE, due_date__lt=today
        ).count(),
    }


def calendar_month(household, year, month, today=None):
    """Mon–Sun week grid of projected recurring income/expense for a month."""
    import calendar
    today = today or timezone.now().date()
    target = date(year, month, 1)
    days_with_bills = bills_in_month(household, target)

    last_day = date(year, month, calendar.monthrange(year, month)[1])
    grid_start = target - timedelta(days=target.weekday())
    grid_end = last_day + timedelta(days=6 - last_day.weekday())

    weeks, week = [], []
    d = grid_start
    while d <= grid_end:
        bills = days_with_bills.get(d, [])
        income = sum((b['amount'] for b in bills if b.get('kind') == 'income'), Decimal('0'))
        expense = sum((b['amount'] for b in bills if b.get('kind') != 'income'), Decimal('0'))
        week.append({
            'date': d,
            'in_month': d.month == month,
            'is_today': d == today,
            'bills': bills,
            'total': expense,           # back-compat: expense total of the day
            'income': income,
            'expense': expense,
            'net': income - expense,
        })
        if len(week) == 7:
            weeks.append(week)
            week = []
        d += timedelta(days=1)

    month_expense = sum(
        (b['amount'] for items in days_with_bills.values() for b in items
         if b.get('kind') != 'income'), Decimal('0')
    )
    month_income = sum(
        (b['amount'] for items in days_with_bills.values() for b in items
         if b.get('kind') == 'income'), Decimal('0')
    )
    return {
        'target': target,
        'weeks': weeks,
        'prev_month': (target - timedelta(days=1)).replace(day=1),
        'next_month': RecurringTransaction._add_months(target, 1),
        'month_expense': month_expense,
        'month_income': month_income,
        'month_net': month_income - month_expense,
    }


def _pct_change(now_val, prev_val):
    """Return percentage change (now - prev) / prev * 100, or None if undefined."""
    if not prev_val:
        return None
    return float(((now_val - prev_val) / prev_val) * 100)


def monthly_report_data(household, year, month):
    from django.db.models import Count
    from .models import GoalContribution, LiabilityPayment, Project, ReceivablePayment
    target = date(year, month, 1)
    month_start, month_end = month_range(target)
    prev_target = (target - timedelta(days=1)).replace(day=1)

    qs = household.transactions.filter(date__gte=month_start, date__lte=month_end)
    inc = _sum_base(qs.filter(transaction_type=Transaction.INCOME))
    exp = _sum_base(qs.filter(transaction_type=Transaction.EXPENSE))
    net = inc - exp

    prev_start, prev_end = month_range(prev_target)
    prev_qs = household.transactions.filter(date__gte=prev_start, date__lte=prev_end)
    prev_inc = _sum_base(prev_qs.filter(transaction_type=Transaction.INCOME))
    prev_exp = _sum_base(prev_qs.filter(transaction_type=Transaction.EXPENSE))

    by_category = list(
        qs.filter(transaction_type=Transaction.EXPENSE, category__isnull=False)
        .values('category__name', 'category__color', 'category__icon')
        .annotate(total=Sum('amount_base'), n=Count('id'))
        .order_by('-total')
    )
    for c in by_category:
        c['pct'] = float(c['total'] / exp * 100) if exp else 0

    top_payees = list(
        qs.filter(transaction_type=Transaction.EXPENSE).exclude(payee='')
        .values('payee')
        .annotate(total=Sum('amount_base'), n=Count('id'))
        .order_by('-total')[:10]
    )

    budget_perf = []
    for b in Budget.objects.filter(household=household, month=month_start).select_related('category'):
        spent = _sum_base(qs.filter(transaction_type=Transaction.EXPENSE, category=b.category))
        pct = float(spent / b.monthly_limit * 100) if b.monthly_limit else 0
        budget_perf.append({
            'category': b.category, 'limit': b.monthly_limit, 'spent': spent,
            'pct': min(round(pct, 1), 999),
            'over': spent > b.monthly_limit,
            'remaining': max(Decimal('0'), b.monthly_limit - spent),
        })

    resolved_qs = household.money_requests.filter(
        resolved_at__gte=month_start, resolved_at__lte=month_end + timedelta(days=1)
    )
    goal_contribs = GoalContribution.objects.filter(
        goal__household=household, date__gte=month_start, date__lte=month_end,
    ).select_related('goal', 'user')
    debt_payments = LiabilityPayment.objects.filter(
        liability__household=household, date__gte=month_start, date__lte=month_end
    )

    return {
        'target': target,
        'month_label': target.strftime('%B %Y'),
        'prev_target': prev_target,
        'next_target': RecurringTransaction._add_months(target, 1),
        'income': inc, 'expense': exp, 'net': net,
        'savings_rate': float(net / inc * 100) if inc else None,
        'inc_delta': _pct_change(inc, prev_inc), 'exp_delta': _pct_change(exp, prev_exp),
        'prev_income': prev_inc, 'prev_expense': prev_exp,
        'members_data': member_breakdown(household, qs, inc, exp),
        'by_category': by_category,
        'top_payees': top_payees,
        'top_transactions': list(
            qs.order_by('-amount_base').select_related('user', 'category', 'currency')[:10]),
        'budget_perf': budget_perf,
        'requests_stats': {
            'approved': resolved_qs.filter(status=MoneyRequest.STATUS_APPROVED).count(),
            'rejected': resolved_qs.filter(status=MoneyRequest.STATUS_REJECTED).count(),
            'cancelled': resolved_qs.filter(status=MoneyRequest.STATUS_CANCELLED).count(),
        },
        'goal_contribs': list(goal_contribs)[:10],
        'goal_total': sum((Decimal(c.amount) for c in goal_contribs), Decimal('0')),
        'project_spending': list(
            Project.objects.filter(household=household).annotate(
                month_spent=Sum('transactions__amount_base',
                                filter=Q(transactions__date__gte=month_start)
                                & Q(transactions__date__lte=month_end)
                                & Q(transactions__transaction_type=Transaction.EXPENSE))
            ).filter(month_spent__gt=0).order_by('-month_spent')
        ),
        'meetings': household.meetings.filter(
            meeting_date__gte=month_start, meeting_date__lte=month_end),
        'debt_paid': debt_payments.aggregate(s=Sum('amount'))['s'] or Decimal('0'),
        'debt_paid_count': debt_payments.count(),
        'receivable_received': ReceivablePayment.objects.filter(
            receivable__household=household, date__gte=month_start, date__lte=month_end
        ).aggregate(s=Sum('amount'))['s'] or Decimal('0'),
        'tx_count': qs.count(),
    }
