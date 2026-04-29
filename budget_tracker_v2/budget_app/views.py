import csv
import io
from calendar import monthrange
from datetime import date, datetime, timedelta
from decimal import Decimal, InvalidOperation

from django.contrib import messages
from django.contrib.auth import login
from django.contrib.auth.decorators import login_required
from django.contrib.auth.models import User
from django.db import transaction as db_transaction
from django.db.models import Sum, Q
from django.http import HttpResponse, JsonResponse
from django.shortcuts import render, redirect, get_object_or_404
from django.urls import reverse
from django.utils import timezone

from .forms import (
    SignUpForm, HouseholdForm, TransactionForm, CategoryForm, BudgetForm,
    RecurringTransactionForm, CategoryRuleForm, AssetForm, LiabilityForm,
    MoneyRequestForm, MoneyRequestResponseForm, CSVImportForm,
    CurrencyForm, ExchangeRateForm,
)
from .models import (
    Household, Transaction, Category, Budget, RecurringTransaction,
    CategoryRule, Alert, MoneyRequest, Asset, Liability, NetWorthSnapshot,
    Currency, ExchangeRate,
)
from .services import (
    apply_category_rules, apply_due_recurring, upcoming_recurring,
    check_budget_alerts, forecast_end_of_month, compute_net_worth,
    bills_in_month, month_range,
)


# ============================================================
# HELPERS
# ============================================================

def get_user_household(user):
    return user.households.first()


def ensure_household(view):
    """Decorator: redirect to setup if user has no household."""
    def wrapper(request, *args, **kwargs):
        h = get_user_household(request.user)
        if not h:
            return redirect('household_setup')
        return view(request, *args, **kwargs)
    wrapper.__name__ = view.__name__
    return wrapper


def seed_household_defaults(household):
    """Seed default currencies, categories, and rules."""
    # Currencies
    defaults_cur = [
        ('USD', 'US Dollar', '$'),
        ('TZS', 'Tanzanian Shilling', 'TSh'),
        ('EUR', 'Euro', '€'),
        ('GBP', 'British Pound', '£'),
        ('KES', 'Kenyan Shilling', 'KSh'),
    ]
    for code, name, sym in defaults_cur:
        Currency.objects.get_or_create(code=code, defaults={'name': name, 'symbol': sym})

    if not household.base_currency:
        household.base_currency = Currency.objects.get(code='USD')
        household.save(update_fields=['base_currency'])

    # Categories
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


# ============================================================
# AUTH
# ============================================================

def signup_view(request):
    if request.method == 'POST':
        form = SignUpForm(request.POST)
        if form.is_valid():
            user = form.save()
            login(request, user)
            messages.success(request, "Account created. Now set up your household.")
            return redirect('household_setup')
    else:
        form = SignUpForm()
    return render(request, 'budget_app/signup.html', {'form': form})


# ============================================================
# HOUSEHOLD
# ============================================================

@login_required
def household_setup(request):
    # Make sure default currencies exist before showing the form
    Currency.objects.get_or_create(code='USD', defaults={'name': 'US Dollar', 'symbol': '$'})
    Currency.objects.get_or_create(code='TZS', defaults={'name': 'Tanzanian Shilling', 'symbol': 'TSh'})
    Currency.objects.get_or_create(code='EUR', defaults={'name': 'Euro', 'symbol': '€'})
    Currency.objects.get_or_create(code='GBP', defaults={'name': 'British Pound', 'symbol': '£'})
    Currency.objects.get_or_create(code='KES', defaults={'name': 'Kenyan Shilling', 'symbol': 'KSh'})

    if get_user_household(request.user):
        return redirect('dashboard')

    if request.method == 'POST':
        form = HouseholdForm(request.POST)
        if form.is_valid():
            household = form.save()
            household.members.add(request.user)
            partner_username = form.cleaned_data.get('partner_username')
            if partner_username:
                try:
                    partner = User.objects.get(username=partner_username)
                    household.members.add(partner)
                    messages.success(request, f"Partner {partner.username} added.")
                except User.DoesNotExist:
                    messages.warning(request, f"User '{partner_username}' not found. Add them later.")
            seed_household_defaults(household)
            messages.success(request, "Household created!")
            return redirect('dashboard')
    else:
        form = HouseholdForm()
    return render(request, 'budget_app/household_setup.html', {'form': form})


@login_required
@ensure_household
def household_settings(request):
    household = get_user_household(request.user)
    if request.method == 'POST':
        action = request.POST.get('action')
        if action == 'add_member':
            username = request.POST.get('username', '').strip()
            try:
                user = User.objects.get(username=username)
                household.members.add(user)
                messages.success(request, f"{user.username} added.")
            except User.DoesNotExist:
                messages.error(request, f"User '{username}' not found.")
        elif action == 'remove_member':
            user_id = request.POST.get('user_id')
            user = get_object_or_404(User, pk=user_id)
            if user == request.user:
                messages.error(request, "You can't remove yourself.")
            else:
                household.members.remove(user)
                messages.success(request, f"{user.username} removed.")
        elif action == 'change_currency':
            cid = request.POST.get('currency_id')
            try:
                household.base_currency = Currency.objects.get(pk=cid)
                household.save()
                messages.success(request, f"Base currency updated to {household.base_currency.code}.")
            except Currency.DoesNotExist:
                pass
        return redirect('household_settings')

    return render(request, 'budget_app/household_settings.html', {
        'household': household,
        'currencies': Currency.objects.all(),
    })


# ============================================================
# DASHBOARD
# ============================================================

@login_required
@ensure_household
def dashboard(request):
    household = get_user_household(request.user)
    today = timezone.now().date()
    month_start, month_end = month_range(today)

    qs = Transaction.objects.filter(
        household=household, date__gte=month_start, date__lte=month_end
    )

    total_income = qs.filter(transaction_type=Transaction.INCOME).aggregate(
        s=Sum('amount_base'))['s'] or Decimal('0')
    total_expense = qs.filter(transaction_type=Transaction.EXPENSE).aggregate(
        s=Sum('amount_base'))['s'] or Decimal('0')
    balance = total_income - total_expense

    members_data = []
    for member in household.members.all():
        m_inc = qs.filter(user=member, transaction_type=Transaction.INCOME).aggregate(
            s=Sum('amount_base'))['s'] or Decimal('0')
        m_exp = qs.filter(user=member, transaction_type=Transaction.EXPENSE).aggregate(
            s=Sum('amount_base'))['s'] or Decimal('0')
        members_data.append({
            'user': member, 'income': m_inc, 'expense': m_exp, 'net': m_inc - m_exp
        })

    category_breakdown = list(
        qs.filter(transaction_type=Transaction.EXPENSE, category__isnull=False)
        .values('category__name', 'category__color')
        .annotate(total=Sum('amount_base'))
        .order_by('-total')
    )

    budgets = Budget.objects.filter(household=household, month=month_start)
    budget_progress = []
    for b in budgets:
        spent = qs.filter(
            transaction_type=Transaction.EXPENSE, category=b.category
        ).aggregate(s=Sum('amount_base'))['s'] or Decimal('0')
        pct = float(spent / b.monthly_limit * 100) if b.monthly_limit else 0
        budget_progress.append({
            'category': b.category, 'limit': b.monthly_limit, 'spent': spent,
            'pct': min(round(pct, 1), 100), 'over': spent > b.monthly_limit,
        })

    recent = qs.select_related('user', 'category')[:6]
    upcoming = upcoming_recurring(household, days=7)
    forecast = forecast_end_of_month(household)
    networth = compute_net_worth(household)

    pending_my_approvals = MoneyRequest.objects.filter(
        household=household, approver=request.user, status=MoneyRequest.STATUS_PENDING
    )

    context = {
        'household': household,
        'month_label': month_start.strftime('%B %Y'),
        'total_income': total_income,
        'total_expense': total_expense,
        'balance': balance,
        'members_data': members_data,
        'category_breakdown': category_breakdown,
        'budget_progress': budget_progress,
        'recent': recent,
        'upcoming': upcoming,
        'forecast': forecast,
        'networth': networth,
        'pending_my_approvals': pending_my_approvals,
    }
    return render(request, 'budget_app/dashboard.html', context)


# ============================================================
# TRANSACTIONS
# ============================================================

@login_required
@ensure_household
def transaction_list(request):
    household = get_user_household(request.user)
    transactions = household.transactions.select_related('user', 'category', 'currency').all()

    ttype = request.GET.get('type')
    if ttype in (Transaction.INCOME, Transaction.EXPENSE):
        transactions = transactions.filter(transaction_type=ttype)

    member_id = request.GET.get('member')
    if member_id:
        transactions = transactions.filter(user_id=member_id)

    cat_id = request.GET.get('category')
    if cat_id:
        transactions = transactions.filter(category_id=cat_id)

    q = request.GET.get('q')
    if q:
        transactions = transactions.filter(
            Q(description__icontains=q) | Q(payee__icontains=q)
        )

    return render(request, 'budget_app/transaction_list.html', {
        'transactions': transactions,
        'household': household,
        'current_type': ttype or '',
        'current_member': member_id or '',
        'current_category': cat_id or '',
        'q': q or '',
    })


@login_required
@ensure_household
def transaction_create(request):
    household = get_user_household(request.user)
    if request.method == 'POST':
        form = TransactionForm(request.POST, household=household)
        if form.is_valid():
            t = form.save(commit=False)
            t.household = household
            t.user = request.user
            t.save()
            apply_category_rules(t)
            check_budget_alerts(household)
            messages.success(request, "Transaction added.")
            return redirect('transaction_list')
    else:
        form = TransactionForm(household=household, initial={'date': timezone.now().date()})
    return render(request, 'budget_app/transaction_form.html', {
        'form': form, 'title': 'Add Transaction'
    })


@login_required
@ensure_household
def transaction_edit(request, pk):
    household = get_user_household(request.user)
    transaction = get_object_or_404(Transaction, pk=pk, household=household)
    if request.method == 'POST':
        form = TransactionForm(request.POST, instance=transaction, household=household)
        if form.is_valid():
            t = form.save(commit=False)
            t.amount_base = None  # force recompute
            t.save()
            check_budget_alerts(household)
            messages.success(request, "Transaction updated.")
            return redirect('transaction_list')
    else:
        form = TransactionForm(instance=transaction, household=household)
    return render(request, 'budget_app/transaction_form.html', {
        'form': form, 'title': 'Edit Transaction'
    })


@login_required
@ensure_household
def transaction_delete(request, pk):
    household = get_user_household(request.user)
    transaction = get_object_or_404(Transaction, pk=pk, household=household)
    if request.method == 'POST':
        transaction.delete()
        messages.success(request, "Transaction deleted.")
        return redirect('transaction_list')
    return render(request, 'budget_app/transaction_confirm_delete.html', {'transaction': transaction})


# ============================================================
# CATEGORIES
# ============================================================

@login_required
@ensure_household
def category_list(request):
    household = get_user_household(request.user)
    return render(request, 'budget_app/category_list.html', {
        'categories': household.categories.all()
    })


@login_required
@ensure_household
def category_create(request):
    household = get_user_household(request.user)
    if request.method == 'POST':
        form = CategoryForm(request.POST)
        if form.is_valid():
            c = form.save(commit=False)
            c.household = household
            c.save()
            messages.success(request, "Category created.")
            return redirect('category_list')
    else:
        form = CategoryForm()
    return render(request, 'budget_app/category_form.html', {
        'form': form, 'title': 'Add Category'
    })


@login_required
@ensure_household
def category_delete(request, pk):
    household = get_user_household(request.user)
    category = get_object_or_404(Category, pk=pk, household=household)
    if request.method == 'POST':
        category.delete()
        messages.success(request, "Category deleted.")
        return redirect('category_list')
    return render(request, 'budget_app/category_confirm_delete.html', {'category': category})


# ============================================================
# BUDGETS
# ============================================================

@login_required
@ensure_household
def budget_list(request):
    household = get_user_household(request.user)
    today = timezone.now().date()
    month_start, month_end = month_range(today)

    budgets = household.budgets.select_related('category').all()
    # Annotate with current-month spending
    rows = []
    for b in budgets:
        if b.month == month_start:
            spent = Transaction.objects.filter(
                household=household, transaction_type=Transaction.EXPENSE,
                category=b.category, date__gte=month_start, date__lte=month_end
            ).aggregate(s=Sum('amount_base'))['s'] or Decimal('0')
            pct = float(spent / b.monthly_limit * 100) if b.monthly_limit else 0
            rows.append({'budget': b, 'spent': spent, 'pct': min(round(pct, 1), 100),
                         'over': spent > b.monthly_limit, 'is_current': True})
        else:
            rows.append({'budget': b, 'spent': None, 'pct': None, 'over': False, 'is_current': False})

    return render(request, 'budget_app/budget_list.html', {'rows': rows})


@login_required
@ensure_household
def budget_create(request):
    household = get_user_household(request.user)
    if request.method == 'POST':
        form = BudgetForm(request.POST, household=household)
        if form.is_valid():
            b = form.save(commit=False)
            b.household = household
            b.month = b.month.replace(day=1)
            b.save()
            messages.success(request, "Budget set.")
            return redirect('budget_list')
    else:
        form = BudgetForm(household=household, initial={'month': date.today().replace(day=1)})
    return render(request, 'budget_app/budget_form.html', {
        'form': form, 'title': 'Set Monthly Budget'
    })


@login_required
@ensure_household
def budget_delete(request, pk):
    household = get_user_household(request.user)
    budget = get_object_or_404(Budget, pk=pk, household=household)
    if request.method == 'POST':
        budget.delete()
        messages.success(request, "Budget removed.")
        return redirect('budget_list')
    return render(request, 'budget_app/budget_confirm_delete.html', {'budget': budget})


# ============================================================
# RECURRING TRANSACTIONS
# ============================================================

@login_required
@ensure_household
def recurring_list(request):
    household = get_user_household(request.user)
    items = household.recurring_transactions.select_related('category', 'currency').all()
    return render(request, 'budget_app/recurring_list.html', {'items': items})


@login_required
@ensure_household
def recurring_create(request):
    household = get_user_household(request.user)
    if request.method == 'POST':
        form = RecurringTransactionForm(request.POST, household=household)
        if form.is_valid():
            r = form.save(commit=False)
            r.household = household
            r.user = request.user
            if not r.next_due_date:
                r.next_due_date = r.start_date
            r.save()
            messages.success(request, "Recurring transaction created.")
            return redirect('recurring_list')
    else:
        today = timezone.now().date()
        form = RecurringTransactionForm(household=household, initial={
            'start_date': today, 'next_due_date': today, 'auto_create': True
        })
    return render(request, 'budget_app/recurring_form.html', {
        'form': form, 'title': 'Add Recurring Transaction'
    })


@login_required
@ensure_household
def recurring_edit(request, pk):
    household = get_user_household(request.user)
    item = get_object_or_404(RecurringTransaction, pk=pk, household=household)
    if request.method == 'POST':
        form = RecurringTransactionForm(request.POST, instance=item, household=household)
        if form.is_valid():
            form.save()
            messages.success(request, "Updated.")
            return redirect('recurring_list')
    else:
        form = RecurringTransactionForm(instance=item, household=household)
    return render(request, 'budget_app/recurring_form.html', {
        'form': form, 'title': 'Edit Recurring Transaction'
    })


@login_required
@ensure_household
def recurring_delete(request, pk):
    household = get_user_household(request.user)
    item = get_object_or_404(RecurringTransaction, pk=pk, household=household)
    if request.method == 'POST':
        item.delete()
        messages.success(request, "Deleted.")
        return redirect('recurring_list')
    return render(request, 'budget_app/recurring_confirm_delete.html', {'item': item})


@login_required
@ensure_household
def recurring_run_now(request):
    """Manual trigger to apply due recurring transactions."""
    household = get_user_household(request.user)
    if request.method == 'POST':
        created = apply_due_recurring(household=household)
        messages.success(request, f"Applied {len(created)} recurring transaction(s).")
    return redirect('recurring_list')


# ============================================================
# BILL CALENDAR
# ============================================================

@login_required
@ensure_household
def bill_calendar(request):
    household = get_user_household(request.user)
    today = timezone.now().date()
    try:
        year = int(request.GET.get('year', today.year))
        month = int(request.GET.get('month', today.month))
    except ValueError:
        year, month = today.year, today.month

    target = date(year, month, 1)
    days_with_bills = bills_in_month(household, target)

    # Build calendar grid (Mon-Sun)
    first_day = target
    _, last_day_num = monthrange(year, month)
    last_day = date(year, month, last_day_num)
    # Find Monday of week containing first day
    grid_start = first_day - timedelta(days=first_day.weekday())
    # Find Sunday of week containing last day
    grid_end = last_day + timedelta(days=6 - last_day.weekday())

    weeks = []
    d = grid_start
    week = []
    while d <= grid_end:
        bills = days_with_bills.get(d, [])
        total = sum(b['amount'] for b in bills) if bills else 0
        week.append({
            'date': d,
            'in_month': d.month == month,
            'is_today': d == today,
            'bills': bills,
            'total': total,
        })
        if len(week) == 7:
            weeks.append(week)
            week = []
        d += timedelta(days=1)

    # Prev / next month
    prev_month = (target - timedelta(days=1)).replace(day=1)
    if month == 12:
        next_month = date(year + 1, 1, 1)
    else:
        next_month = date(year, month + 1, 1)

    month_total = sum(
        sum(b['amount'] for b in days) for days in days_with_bills.values()
    )

    return render(request, 'budget_app/bill_calendar.html', {
        'year': year, 'month': month,
        'month_label': target.strftime('%B %Y'),
        'weeks': weeks,
        'prev_month': prev_month,
        'next_month': next_month,
        'month_total': month_total,
        'today': today,
    })


# ============================================================
# AUTO-CATEGORIZATION RULES
# ============================================================

@login_required
@ensure_household
def rule_list(request):
    household = get_user_household(request.user)
    rules = household.rules.select_related('category').all()
    return render(request, 'budget_app/rule_list.html', {'rules': rules})


@login_required
@ensure_household
def rule_create(request):
    household = get_user_household(request.user)
    if request.method == 'POST':
        form = CategoryRuleForm(request.POST, household=household)
        if form.is_valid():
            r = form.save(commit=False)
            r.household = household
            r.save()
            messages.success(request, "Rule created.")
            return redirect('rule_list')
    else:
        form = CategoryRuleForm(household=household)
    return render(request, 'budget_app/rule_form.html', {
        'form': form, 'title': 'Add Auto-Categorization Rule'
    })


@login_required
@ensure_household
def rule_delete(request, pk):
    household = get_user_household(request.user)
    rule = get_object_or_404(CategoryRule, pk=pk, household=household)
    if request.method == 'POST':
        rule.delete()
        messages.success(request, "Rule deleted.")
        return redirect('rule_list')
    return render(request, 'budget_app/rule_confirm_delete.html', {'rule': rule})


@login_required
@ensure_household
def rules_apply_existing(request):
    """Apply current rules to all uncategorized transactions."""
    household = get_user_household(request.user)
    if request.method == 'POST':
        count = 0
        for t in household.transactions.filter(category__isnull=True):
            if apply_category_rules(t):
                count += 1
        messages.success(request, f"Categorized {count} transaction(s).")
    return redirect('rule_list')


# ============================================================
# ALERTS
# ============================================================

@login_required
@ensure_household
def alert_list(request):
    household = get_user_household(request.user)
    alerts = household.alerts.all()
    return render(request, 'budget_app/alert_list.html', {'alerts': alerts})


@login_required
@ensure_household
def alert_mark_read(request, pk):
    household = get_user_household(request.user)
    alert = get_object_or_404(Alert, pk=pk, household=household)
    alert.is_read = True
    alert.save(update_fields=['is_read'])
    return redirect(request.GET.get('next') or 'alert_list')


@login_required
@ensure_household
def alert_mark_all_read(request):
    household = get_user_household(request.user)
    if request.method == 'POST':
        household.alerts.filter(is_read=False).update(is_read=True)
        messages.success(request, "All alerts marked as read.")
    return redirect('alert_list')


# ============================================================
# MONEY REQUESTS
# ============================================================

@login_required
@ensure_household
def request_list(request):
    household = get_user_household(request.user)
    incoming = household.money_requests.filter(approver=request.user).select_related(
        'requester', 'currency', 'category'
    )
    outgoing = household.money_requests.filter(requester=request.user).select_related(
        'approver', 'currency', 'category'
    )
    return render(request, 'budget_app/request_list.html', {
        'incoming': incoming, 'outgoing': outgoing
    })


@login_required
@ensure_household
def request_create(request):
    household = get_user_household(request.user)
    if household.members.count() < 2:
        messages.warning(request, "Add a partner to your household before requesting money.")
        return redirect('household_settings')

    if request.method == 'POST':
        form = MoneyRequestForm(request.POST, household=household, requester=request.user)
        if form.is_valid():
            r = form.save(commit=False)
            r.household = household
            r.requester = request.user
            r.save()
            # Notify approver via Alert
            Alert.objects.create(
                household=household, user=r.approver,
                title=f"Money request from {request.user.username}",
                message=f"{request.user.username} requested "
                        f"{r.currency.symbol if r.currency else household.currency_symbol}"
                        f"{r.amount} for: {r.purpose}",
                level=Alert.LEVEL_INFO,
                link_url=f"/requests/{r.pk}/",
            )
            messages.success(request, "Request sent.")
            return redirect('request_list')
    else:
        form = MoneyRequestForm(household=household, requester=request.user)
    return render(request, 'budget_app/request_form.html', {
        'form': form, 'title': 'Request Money'
    })


@login_required
@ensure_household
def request_detail(request, pk):
    household = get_user_household(request.user)
    money_request = get_object_or_404(MoneyRequest, pk=pk, household=household)

    can_respond = (
        request.user == money_request.approver
        and money_request.status == MoneyRequest.STATUS_PENDING
    )
    can_cancel = (
        request.user == money_request.requester
        and money_request.status == MoneyRequest.STATUS_PENDING
    )

    if request.method == 'POST':
        action = request.POST.get('action')
        form = MoneyRequestResponseForm(request.POST)
        note = ''
        if form.is_valid():
            note = form.cleaned_data.get('response_note', '')

        if action == 'approve' and can_respond:
            with db_transaction.atomic():
                # Income for requester (deducted from approver in spirit, but the
                # request "transfers" budgeted money → recorded as income for the
                # requester and as an expense from the approver).
                cur = money_request.currency or household.base_currency
                # Find or create a simple "Transfer" income category
                transfer_cat, _ = Category.objects.get_or_create(
                    household=household, name='Transfer (Approved)',
                    category_type=Category.INCOME,
                    defaults={'color': '#0dcaf0', 'icon': 'bi-arrow-left-right'},
                )
                income_t = Transaction.objects.create(
                    household=household, user=money_request.requester,
                    category=transfer_cat,
                    transaction_type=Transaction.INCOME,
                    amount=money_request.amount, currency=cur,
                    description=f"Approved request: {money_request.purpose}",
                    payee=money_request.approver.username,
                    date=timezone.now().date(),
                    source=Transaction.SOURCE_REQUEST,
                )
                expense_cat = money_request.category
                expense_t = Transaction.objects.create(
                    household=household, user=money_request.approver,
                    category=expense_cat,
                    transaction_type=Transaction.EXPENSE,
                    amount=money_request.amount, currency=cur,
                    description=f"Granted to {money_request.requester.username}: {money_request.purpose}",
                    payee=money_request.requester.username,
                    date=timezone.now().date(),
                    source=Transaction.SOURCE_REQUEST,
                )
                money_request.status = MoneyRequest.STATUS_APPROVED
                money_request.response_note = note
                money_request.resolved_at = timezone.now()
                money_request.income_transaction = income_t
                money_request.expense_transaction = expense_t
                money_request.save()
                Alert.objects.create(
                    household=household, user=money_request.requester,
                    title=f"Request approved by {request.user.username}",
                    message=f"Your request for {money_request.purpose} was approved.",
                    level=Alert.LEVEL_INFO,
                )
                check_budget_alerts(household)
            messages.success(request, "Request approved and transactions recorded.")
            return redirect('request_detail', pk=pk)

        elif action == 'reject' and can_respond:
            money_request.status = MoneyRequest.STATUS_REJECTED
            money_request.response_note = note
            money_request.resolved_at = timezone.now()
            money_request.save()
            Alert.objects.create(
                household=household, user=money_request.requester,
                title=f"Request rejected by {request.user.username}",
                message=f"Your request for {money_request.purpose} was rejected."
                        + (f" Note: {note}" if note else ""),
                level=Alert.LEVEL_WARNING,
            )
            messages.info(request, "Request rejected.")
            return redirect('request_detail', pk=pk)

        elif action == 'cancel' and can_cancel:
            money_request.status = MoneyRequest.STATUS_CANCELLED
            money_request.resolved_at = timezone.now()
            money_request.save()
            messages.info(request, "Request cancelled.")
            return redirect('request_detail', pk=pk)

    return render(request, 'budget_app/request_detail.html', {
        'money_request': money_request,
        'can_respond': can_respond,
        'can_cancel': can_cancel,
        'response_form': MoneyRequestResponseForm(),
    })


# ============================================================
# NET WORTH
# ============================================================

@login_required
@ensure_household
def networth_view(request):
    household = get_user_household(request.user)
    data = compute_net_worth(household)
    assets = household.assets.select_related('currency').all()
    liabilities = household.liabilities.select_related('currency').all()
    snapshots = household.snapshots.all()[:24]
    return render(request, 'budget_app/networth.html', {
        'data': data,
        'assets': assets,
        'liabilities': liabilities,
        'snapshots': list(reversed(snapshots)),
    })


@login_required
@ensure_household
def asset_create(request):
    household = get_user_household(request.user)
    if request.method == 'POST':
        form = AssetForm(request.POST)
        if form.is_valid():
            a = form.save(commit=False)
            a.household = household
            if not a.currency:
                a.currency = household.base_currency
            a.save()
            messages.success(request, "Asset added.")
            return redirect('networth')
    else:
        form = AssetForm(initial={'currency': household.base_currency})
    return render(request, 'budget_app/asset_form.html', {
        'form': form, 'title': 'Add Asset'
    })


@login_required
@ensure_household
def asset_edit(request, pk):
    household = get_user_household(request.user)
    asset = get_object_or_404(Asset, pk=pk, household=household)
    if request.method == 'POST':
        form = AssetForm(request.POST, instance=asset)
        if form.is_valid():
            form.save()
            return redirect('networth')
    else:
        form = AssetForm(instance=asset)
    return render(request, 'budget_app/asset_form.html', {
        'form': form, 'title': 'Edit Asset'
    })


@login_required
@ensure_household
def asset_delete(request, pk):
    household = get_user_household(request.user)
    asset = get_object_or_404(Asset, pk=pk, household=household)
    if request.method == 'POST':
        asset.delete()
        return redirect('networth')
    return render(request, 'budget_app/asset_confirm_delete.html', {'asset': asset})


@login_required
@ensure_household
def liability_create(request):
    household = get_user_household(request.user)
    if request.method == 'POST':
        form = LiabilityForm(request.POST)
        if form.is_valid():
            l = form.save(commit=False)
            l.household = household
            if not l.currency:
                l.currency = household.base_currency
            l.save()
            messages.success(request, "Liability added.")
            return redirect('networth')
    else:
        form = LiabilityForm(initial={'currency': household.base_currency})
    return render(request, 'budget_app/liability_form.html', {
        'form': form, 'title': 'Add Liability'
    })


@login_required
@ensure_household
def liability_edit(request, pk):
    household = get_user_household(request.user)
    liab = get_object_or_404(Liability, pk=pk, household=household)
    if request.method == 'POST':
        form = LiabilityForm(request.POST, instance=liab)
        if form.is_valid():
            form.save()
            return redirect('networth')
    else:
        form = LiabilityForm(instance=liab)
    return render(request, 'budget_app/liability_form.html', {
        'form': form, 'title': 'Edit Liability'
    })


@login_required
@ensure_household
def liability_delete(request, pk):
    household = get_user_household(request.user)
    liab = get_object_or_404(Liability, pk=pk, household=household)
    if request.method == 'POST':
        liab.delete()
        return redirect('networth')
    return render(request, 'budget_app/liability_confirm_delete.html', {'liability': liab})


@login_required
@ensure_household
def networth_snapshot(request):
    """Save a point-in-time snapshot."""
    household = get_user_household(request.user)
    if request.method == 'POST':
        data = compute_net_worth(household)
        NetWorthSnapshot.objects.update_or_create(
            household=household, snapshot_date=timezone.now().date(),
            defaults={
                'total_assets': data['total_assets'],
                'total_liabilities': data['total_liabilities'],
                'net_worth': data['net_worth'],
            }
        )
        messages.success(request, "Snapshot saved.")
    return redirect('networth')


# ============================================================
# CURRENCIES & EXCHANGE RATES
# ============================================================

@login_required
@ensure_household
def currency_list(request):
    return render(request, 'budget_app/currency_list.html', {
        'currencies': Currency.objects.all(),
        'rates': ExchangeRate.objects.select_related('from_currency', 'to_currency').all(),
    })


@login_required
@ensure_household
def currency_create(request):
    if request.method == 'POST':
        form = CurrencyForm(request.POST)
        if form.is_valid():
            form.save()
            messages.success(request, "Currency added.")
            return redirect('currency_list')
    else:
        form = CurrencyForm()
    return render(request, 'budget_app/currency_form.html', {
        'form': form, 'title': 'Add Currency'
    })


@login_required
@ensure_household
def rate_create(request):
    if request.method == 'POST':
        form = ExchangeRateForm(request.POST)
        if form.is_valid():
            ExchangeRate.objects.update_or_create(
                from_currency=form.cleaned_data['from_currency'],
                to_currency=form.cleaned_data['to_currency'],
                defaults={'rate': form.cleaned_data['rate']},
            )
            # Recompute base amounts on transactions in this currency
            household = get_user_household(request.user)
            for t in household.transactions.filter(currency=form.cleaned_data['from_currency']):
                t.amount_base = t._compute_amount_base()
                t.save(update_fields=['amount_base'])
            messages.success(request, "Exchange rate saved.")
            return redirect('currency_list')
    else:
        form = ExchangeRateForm()
    return render(request, 'budget_app/currency_form.html', {
        'form': form, 'title': 'Set Exchange Rate'
    })


# ============================================================
# IMPORT / EXPORT
# ============================================================

@login_required
@ensure_household
def export_csv(request):
    household = get_user_household(request.user)
    response = HttpResponse(content_type='text/csv')
    today = timezone.now().date().isoformat()
    response['Content-Disposition'] = f'attachment; filename="transactions_{today}.csv"'

    writer = csv.writer(response)
    writer.writerow(['date', 'type', 'amount', 'currency', 'amount_base',
                     'category', 'payee', 'description', 'member', 'source'])
    for t in household.transactions.select_related('user', 'category', 'currency').all():
        writer.writerow([
            t.date.isoformat(),
            t.transaction_type,
            t.amount,
            t.currency.code if t.currency else '',
            t.amount_base or '',
            t.category.name if t.category else '',
            t.payee,
            t.description,
            t.user.username,
            t.source,
        ])
    return response


@login_required
@ensure_household
def import_csv(request):
    household = get_user_household(request.user)
    result = None
    if request.method == 'POST':
        form = CSVImportForm(request.POST, request.FILES)
        if form.is_valid():
            f = form.cleaned_data['file']
            try:
                decoded = f.read().decode('utf-8-sig')
            except UnicodeDecodeError:
                decoded = f.read().decode('latin-1')
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
                            household=household, name=cat_name,
                            category_type=ttype,
                            defaults={'color': '#6c757d', 'icon': 'bi-tag'},
                        )

                    cur_code = (row.get('currency') or '').strip().upper()
                    cur = None
                    if cur_code:
                        cur = Currency.objects.filter(code=cur_code).first()
                    if not cur:
                        cur = base_cur

                    t = Transaction.objects.create(
                        household=household,
                        user=request.user,
                        category=cat,
                        transaction_type=ttype,
                        amount=amount,
                        currency=cur,
                        payee=(row.get('payee') or '').strip(),
                        description=(row.get('description') or '').strip(),
                        date=d,
                        source=Transaction.SOURCE_IMPORT,
                    )
                    apply_category_rules(t)
                    created += 1
                except (ValueError, InvalidOperation) as e:
                    errors.append(f"Row {i}: {e}")
            check_budget_alerts(household)
            result = {'created': created, 'errors': errors}
    else:
        form = CSVImportForm()

    return render(request, 'budget_app/import_csv.html', {
        'form': form, 'result': result
    })


# ============================================================
# FORECAST DETAIL
# ============================================================

@login_required
@ensure_household
def forecast_view(request):
    household = get_user_household(request.user)
    f = forecast_end_of_month(household)

    today = timezone.now().date()
    month_start, _ = month_range(today)

    # Per-day cumulative spending so far this month
    daily_spending = []
    cumulative = Decimal('0')
    d = month_start
    while d <= today:
        day_total = Transaction.objects.filter(
            household=household, transaction_type=Transaction.EXPENSE, date=d
        ).aggregate(s=Sum('amount_base'))['s'] or Decimal('0')
        cumulative += day_total
        daily_spending.append({'date': d, 'cumulative': cumulative})
        d += timedelta(days=1)

    return render(request, 'budget_app/forecast.html', {
        'forecast': f,
        'daily_spending': daily_spending,
        'month_label': month_start.strftime('%B %Y'),
    })
