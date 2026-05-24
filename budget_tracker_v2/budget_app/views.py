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
    LiabilityPaymentForm,
    MoneyRequestForm, MoneyRequestResponseForm, CSVImportForm,
    CurrencyForm, ExchangeRateForm,
    MeetingForm, AgreementItemForm,
    GoalForm, GoalContributionForm, ProjectForm,
    ReceivableForm, ReceivablePaymentForm,
)
from .models import (
    Household, Transaction, Category, Budget, RecurringTransaction,
    CategoryRule, Alert, MoneyRequest, Asset, Liability, LiabilityPayment,
    NetWorthSnapshot, Currency, ExchangeRate,
    Meeting, AgreementItem, Goal, GoalContribution, Project,
    Receivable, ReceivablePayment,
)
from .services import (
    apply_category_rules, apply_due_recurring, upcoming_recurring,
    check_budget_alerts, forecast_end_of_month, compute_net_worth,
    bills_in_month, month_range, push_to_household,
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
        exp_share = float(m_exp / total_expense * 100) if total_expense else 0
        inc_share = float(m_inc / total_income * 100) if total_income else 0
        members_data.append({
            'user': member, 'income': m_inc, 'expense': m_exp,
            'net': m_inc - m_exp,
            'expense_share_pct': round(exp_share, 1),
            'income_share_pct': round(inc_share, 1),
        })

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

    # Active goals (top 4 by progress remaining)
    active_goals = household.goals.filter(status=Goal.STATUS_ACTIVE).order_by('-target_amount')[:4]

    recent = qs.select_related('user', 'category')[:6]
    upcoming = upcoming_recurring(household, days=7)
    forecast = forecast_end_of_month(household)
    networth = compute_net_worth(household)

    # Credit (owed to us) and debit (we owe)
    total_lent_out = sum(
        (Decimal(r.balance) for r in household.receivables.filter(status=Receivable.STATUS_ACTIVE)),
        Decimal('0')
    )
    total_owed = sum(
        (Decimal(l.balance) for l in household.liabilities.all()),
        Decimal('0')
    )
    overdue_lent = household.receivables.filter(
        status=Receivable.STATUS_ACTIVE, due_date__lt=today
    ).count()

    pending_my_approvals = MoneyRequest.objects.filter(
        household=household, approver=request.user, status=MoneyRequest.STATUS_PENDING
    )

    # Next upcoming meeting
    next_meeting = household.meetings.filter(
        status=Meeting.STATUS_PLANNED, meeting_date__gte=today
    ).order_by('meeting_date').first()

    context = {
        'household': household,
        'month_label': month_start.strftime('%B %Y'),
        'total_income': total_income,
        'total_expense': total_expense,
        'balance': balance,
        'members_data': members_data,
        'budget_progress': budget_progress,
        'recent': recent,
        'upcoming': upcoming,
        'forecast': forecast,
        'networth': networth,
        'pending_my_approvals': pending_my_approvals,
        'active_goals': active_goals,
        'next_meeting': next_meeting,
        'total_lent_out': total_lent_out,
        'total_owed': total_owed,
        'overdue_lent': overdue_lent,
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
        income = sum((b['amount'] for b in bills if b.get('kind') == 'income'), Decimal('0'))
        expense = sum((b['amount'] for b in bills if b.get('kind') != 'income'), Decimal('0'))
        net = income - expense
        week.append({
            'date': d,
            'in_month': d.month == month,
            'is_today': d == today,
            'bills': bills,
            'total': expense,           # back-compat: expense total of the day
            'income': income,
            'expense': expense,
            'net': net,
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

    month_expense = sum(
        (b['amount'] for items in days_with_bills.values() for b in items
         if b.get('kind') != 'income'), Decimal('0')
    )
    month_income = sum(
        (b['amount'] for items in days_with_bills.values() for b in items
         if b.get('kind') == 'income'), Decimal('0')
    )

    return render(request, 'budget_app/bill_calendar.html', {
        'year': year, 'month': month,
        'month_label': target.strftime('%B %Y'),
        'weeks': weeks,
        'prev_month': prev_month,
        'next_month': next_month,
        'month_total': month_expense,   # back-compat
        'month_expense': month_expense,
        'month_income': month_income,
        'month_net': month_income - month_expense,
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
            push_to_household(household, {
                'kind': 'request.created',
                'message': f"New money request from {request.user.username} for {r.purpose}",
                'link': f'/requests/{r.pk}/',
                'level': 'info',
                'for_user_id': r.approver_id,
            })
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
                # An approved money request is purely an internal transfer of
                # household funds — it represents money the household is
                # actually spending, not income. Record a single expense
                # attributed to the requester (the spender), in the requested
                # category, so the household total reflects the outflow once.
                cur = money_request.currency or household.base_currency
                expense_t = Transaction.objects.create(
                    household=household, user=money_request.requester,
                    category=money_request.category,
                    transaction_type=Transaction.EXPENSE,
                    amount=money_request.amount, currency=cur,
                    description=f"Approved by {money_request.approver.username}: {money_request.purpose}",
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
                    title=f"Request approved by {request.user.username}",
                    message=f"Your request for {money_request.purpose} was approved.",
                    level=Alert.LEVEL_INFO,
                )
                check_budget_alerts(household)
            push_to_household(household, {
                'kind': 'request.approved',
                'message': f"{request.user.username} approved your request: {money_request.purpose}",
                'link': f'/requests/{money_request.pk}/',
                'level': 'success',
                'for_user_id': money_request.requester_id,
            })
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
            push_to_household(household, {
                'kind': 'request.rejected',
                'message': f"{request.user.username} rejected your request: {money_request.purpose}",
                'link': f'/requests/{money_request.pk}/',
                'level': 'warning',
                'for_user_id': money_request.requester_id,
            })
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
            messages.success(request, "Debt added.")
            return redirect('debt_list')
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
            return redirect('debt_detail', pk=liab.pk)
    else:
        form = LiabilityForm(instance=liab)
    return render(request, 'budget_app/liability_form.html', {
        'form': form, 'title': 'Edit Debt'
    })


@login_required
@ensure_household
def liability_delete(request, pk):
    household = get_user_household(request.user)
    liab = get_object_or_404(Liability, pk=pk, household=household)
    if request.method == 'POST':
        liab.delete()
        return redirect('debt_list')
    return render(request, 'budget_app/liability_confirm_delete.html', {'liability': liab})


# ============================================================
# DEBTS (Liability list/detail and payments)
# ============================================================

@login_required
@ensure_household
def debt_list(request):
    household = get_user_household(request.user)
    liabilities = household.liabilities.select_related('currency').all()
    rows = []
    total_balance = Decimal('0')
    total_paid = Decimal('0')
    for l in liabilities:
        paid = l.total_paid
        original = l.original_amount or (l.balance + paid)
        pct = float(paid / original * 100) if original else 0
        rows.append({
            'liability': l, 'paid': paid, 'original': original,
            'pct': min(round(pct, 1), 100),
            'payments_count': l.payments.count(),
        })
        total_balance += l.balance
        total_paid += paid
    return render(request, 'budget_app/debt_list.html', {
        'rows': rows,
        'total_balance': total_balance,
        'total_paid': total_paid,
    })


@login_required
@ensure_household
def debt_detail(request, pk):
    household = get_user_household(request.user)
    liab = get_object_or_404(Liability, pk=pk, household=household)
    payments = liab.payments.select_related('currency', 'transaction').all()
    paid = liab.total_paid
    original = liab.original_amount or (liab.balance + paid)
    pct = float(paid / original * 100) if original else 0
    return render(request, 'budget_app/debt_detail.html', {
        'liability': liab,
        'payments': payments,
        'paid': paid,
        'original': original,
        'pct': min(round(pct, 1), 100),
    })


@login_required
@ensure_household
def payment_create(request, pk):
    household = get_user_household(request.user)
    liab = get_object_or_404(Liability, pk=pk, household=household)
    if request.method == 'POST':
        form = LiabilityPaymentForm(request.POST, household=household, liability=liab)
        if form.is_valid():
            with db_transaction.atomic():
                payment = form.save(commit=False)
                payment.liability = liab
                if not payment.currency:
                    payment.currency = liab.currency or household.base_currency
                # Optionally record an expense transaction
                if form.cleaned_data.get('record_as_expense'):
                    cat = form.cleaned_data.get('expense_category')
                    if not cat:
                        cat, _ = Category.objects.get_or_create(
                            household=household, name='Debt Payment',
                            category_type=Category.EXPENSE,
                            defaults={'color': '#dc3545', 'icon': 'bi-cash-stack'},
                        )
                    tx = Transaction.objects.create(
                        household=household, user=request.user,
                        category=cat, transaction_type=Transaction.EXPENSE,
                        amount=payment.amount, currency=payment.currency,
                        description=f"Payment toward {liab.name}",
                        payee=liab.lender or liab.name,
                        date=payment.date,
                        source=Transaction.SOURCE_MANUAL,
                    )
                    payment.transaction = tx
                payment.save()
                # Decrement the outstanding balance (clamp at 0)
                new_balance = max(Decimal('0'), Decimal(liab.balance) - Decimal(payment.amount))
                Liability.objects.filter(pk=liab.pk).update(balance=new_balance)
            messages.success(request, f"Payment of {payment.amount} recorded.")
            return redirect('debt_detail', pk=liab.pk)
    else:
        form = LiabilityPaymentForm(household=household, liability=liab,
                                    initial={'date': timezone.now().date(),
                                             'amount': liab.balance})
    return render(request, 'budget_app/payment_form.html', {
        'form': form, 'liability': liab,
    })


@login_required
@ensure_household
def payment_delete(request, pk, payment_pk):
    household = get_user_household(request.user)
    liab = get_object_or_404(Liability, pk=pk, household=household)
    payment = get_object_or_404(LiabilityPayment, pk=payment_pk, liability=liab)
    if request.method == 'POST':
        with db_transaction.atomic():
            # Restore the liability balance and delete the linked expense, if any
            Liability.objects.filter(pk=liab.pk).update(
                balance=Decimal(liab.balance) + Decimal(payment.amount)
            )
            if payment.transaction_id:
                payment.transaction.delete()
            payment.delete()
        messages.info(request, "Payment removed and balance restored.")
        return redirect('debt_detail', pk=liab.pk)
    return render(request, 'budget_app/payment_confirm_delete.html', {
        'liability': liab, 'payment': payment,
    })


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
    return render(request, 'budget_app/forecast.html', {
        'forecast': f,
        'month_label': month_start.strftime('%B %Y'),
    })


# ============================================================
# MEETINGS & AGREEMENTS
# ============================================================

def _suggest_next_meeting_date(household):
    """Default next meeting date: 3 months after the last one, else today."""
    last = household.meetings.order_by('-meeting_date').first()
    today = timezone.now().date()
    if not last:
        return today
    # add 3 months
    m = last.meeting_date.month - 1 + 3
    year = last.meeting_date.year + m // 12
    month = m % 12 + 1
    from calendar import monthrange as _mr
    day = min(last.meeting_date.day, _mr(year, month)[1])
    return date(year, month, day)


@login_required
@ensure_household
def meeting_list(request):
    household = get_user_household(request.user)
    meetings = household.meetings.prefetch_related('agreements', 'participants').all()
    today = timezone.now().date()

    # Aggregate open / overdue across all meetings
    all_open = AgreementItem.objects.filter(
        meeting__household=household
    ).exclude(status__in=[AgreementItem.STATUS_DONE, AgreementItem.STATUS_CANCELLED])
    overdue = all_open.filter(target_date__lt=today)

    return render(request, 'budget_app/meeting_list.html', {
        'meetings': meetings,
        'open_count': all_open.count(),
        'overdue_count': overdue.count(),
        'next_suggested': _suggest_next_meeting_date(household),
        'today': today,
    })


@login_required
@ensure_household
def meeting_create(request):
    household = get_user_household(request.user)
    if request.method == 'POST':
        form = MeetingForm(request.POST, household=household)
        if form.is_valid():
            m = form.save(commit=False)
            m.household = household
            # Snapshot household state for context
            today = timezone.now().date()
            month_start, _ = month_range(today)
            inc = Transaction.objects.filter(
                household=household, transaction_type=Transaction.INCOME,
                date__gte=month_start, date__lte=today
            ).aggregate(s=Sum('amount_base'))['s'] or Decimal('0')
            exp = Transaction.objects.filter(
                household=household, transaction_type=Transaction.EXPENSE,
                date__gte=month_start, date__lte=today
            ).aggregate(s=Sum('amount_base'))['s'] or Decimal('0')
            nw = compute_net_worth(household)
            m.income_snapshot = inc
            m.expense_snapshot = exp
            m.net_worth_snapshot = nw['net_worth']
            m.save()
            form.save_m2m()
            # Carry over open agreement items from the previous meeting, if asked
            carried = 0
            if form.cleaned_data.get('carry_over_open_items') and form._previous_meeting:
                open_items = form._previous_meeting.agreements.exclude(
                    status__in=[AgreementItem.STATUS_DONE, AgreementItem.STATUS_CANCELLED]
                )
                for src in open_items:
                    AgreementItem.objects.create(
                        meeting=m,
                        title=src.title,
                        description=src.description,
                        owner=src.owner,
                        target_date=src.target_date,
                        status=src.status,
                        progress=src.progress,
                        priority=src.priority,
                        notes=src.notes,
                    )
                    carried += 1
            if carried:
                messages.success(request, f"Meeting created. Carried over {carried} open item(s) from the previous meeting.")
            else:
                messages.success(request, "Meeting created.")
            return redirect('meeting_detail', pk=m.pk)
    else:
        form = MeetingForm(household=household, initial={
            'meeting_date': _suggest_next_meeting_date(household),
            'title': f"Q{((_suggest_next_meeting_date(household).month - 1) // 3) + 1} "
                     f"{_suggest_next_meeting_date(household).year} Review",
        })
    return render(request, 'budget_app/meeting_form.html', {
        'form': form, 'title': 'Schedule a Meeting',
    })


@login_required
@ensure_household
def meeting_detail(request, pk):
    household = get_user_household(request.user)
    meeting = get_object_or_404(Meeting, pk=pk, household=household)
    agreements = meeting.agreements.select_related('owner').all()
    return render(request, 'budget_app/meeting_detail.html', {
        'meeting': meeting,
        'agreements': agreements,
        'agreement_form': AgreementItemForm(household=household),
        'today': timezone.now().date(),
    })


@login_required
@ensure_household
def meeting_edit(request, pk):
    household = get_user_household(request.user)
    meeting = get_object_or_404(Meeting, pk=pk, household=household)
    if request.method == 'POST':
        form = MeetingForm(request.POST, instance=meeting, household=household)
        if form.is_valid():
            form.save()
            messages.success(request, "Meeting updated.")
            return redirect('meeting_detail', pk=meeting.pk)
    else:
        form = MeetingForm(instance=meeting, household=household)
    return render(request, 'budget_app/meeting_form.html', {
        'form': form, 'title': 'Edit Meeting',
    })


@login_required
@ensure_household
def meeting_delete(request, pk):
    household = get_user_household(request.user)
    meeting = get_object_or_404(Meeting, pk=pk, household=household)
    if request.method == 'POST':
        meeting.delete()
        messages.success(request, "Meeting deleted.")
        return redirect('meeting_list')
    return render(request, 'budget_app/meeting_confirm_delete.html', {'meeting': meeting})


@login_required
@ensure_household
def agreement_create(request, pk):
    household = get_user_household(request.user)
    meeting = get_object_or_404(Meeting, pk=pk, household=household)
    if request.method == 'POST':
        form = AgreementItemForm(request.POST, household=household)
        if form.is_valid():
            item = form.save(commit=False)
            item.meeting = meeting
            if item.status == AgreementItem.STATUS_DONE and not item.completed_date:
                item.completed_date = timezone.now().date()
                item.progress = 100
            item.save()
            messages.success(request, "Agreement item added.")
            return redirect('meeting_detail', pk=meeting.pk)
    else:
        form = AgreementItemForm(household=household)
    return render(request, 'budget_app/agreement_form.html', {
        'form': form, 'meeting': meeting, 'title': 'Add Action Item',
    })


@login_required
@ensure_household
def agreement_edit(request, pk, item_pk):
    household = get_user_household(request.user)
    meeting = get_object_or_404(Meeting, pk=pk, household=household)
    item = get_object_or_404(AgreementItem, pk=item_pk, meeting=meeting)
    if request.method == 'POST':
        form = AgreementItemForm(request.POST, instance=item, household=household)
        if form.is_valid():
            saved = form.save(commit=False)
            if saved.status == AgreementItem.STATUS_DONE and not saved.completed_date:
                saved.completed_date = timezone.now().date()
                saved.progress = 100
            elif saved.status != AgreementItem.STATUS_DONE:
                saved.completed_date = None
            saved.save()
            messages.success(request, "Agreement item updated.")
            return redirect('meeting_detail', pk=meeting.pk)
    else:
        form = AgreementItemForm(instance=item, household=household)
    return render(request, 'budget_app/agreement_form.html', {
        'form': form, 'meeting': meeting, 'item': item, 'title': 'Edit Action Item',
    })


@login_required
@ensure_household
def agreement_delete(request, pk, item_pk):
    household = get_user_household(request.user)
    meeting = get_object_or_404(Meeting, pk=pk, household=household)
    item = get_object_or_404(AgreementItem, pk=item_pk, meeting=meeting)
    if request.method == 'POST':
        item.delete()
        messages.info(request, "Agreement item removed.")
    return redirect('meeting_detail', pk=meeting.pk)


@login_required
@ensure_household
def agreement_quick_update(request, pk, item_pk):
    """Inline status/progress update from the detail page."""
    household = get_user_household(request.user)
    meeting = get_object_or_404(Meeting, pk=pk, household=household)
    item = get_object_or_404(AgreementItem, pk=item_pk, meeting=meeting)
    if request.method == 'POST':
        new_status = request.POST.get('status')
        new_progress = request.POST.get('progress')
        if new_status in dict(AgreementItem.STATUS_CHOICES):
            item.status = new_status
        if new_progress is not None:
            try:
                p = max(0, min(100, int(new_progress)))
                item.progress = p
                if p == 100 and item.status != AgreementItem.STATUS_DONE:
                    item.status = AgreementItem.STATUS_DONE
            except (TypeError, ValueError):
                pass
        if item.status == AgreementItem.STATUS_DONE:
            if not item.completed_date:
                item.completed_date = timezone.now().date()
            item.progress = 100
        else:
            item.completed_date = None
        item.save()
    return redirect('meeting_detail', pk=meeting.pk)


# ============================================================
# SAVINGS GOALS
# ============================================================

@login_required
@ensure_household
def goal_list(request):
    household = get_user_household(request.user)
    goals = household.goals.select_related('currency').all()
    return render(request, 'budget_app/goal_list.html', {'goals': goals})


@login_required
@ensure_household
def goal_create(request):
    household = get_user_household(request.user)
    if request.method == 'POST':
        form = GoalForm(request.POST, household=household)
        if form.is_valid():
            g = form.save(commit=False)
            g.household = household
            if not g.currency:
                g.currency = household.base_currency
            g.save()
            messages.success(request, "Goal created.")
            return redirect('goal_detail', pk=g.pk)
    else:
        form = GoalForm(household=household,
                        initial={'currency': household.base_currency})
    return render(request, 'budget_app/goal_form.html', {
        'form': form, 'title': 'New Savings Goal',
    })


@login_required
@ensure_household
def goal_detail(request, pk):
    household = get_user_household(request.user)
    goal = get_object_or_404(Goal, pk=pk, household=household)
    contributions = goal.contributions.select_related('user').all()
    return render(request, 'budget_app/goal_detail.html', {
        'goal': goal, 'contributions': contributions,
    })


@login_required
@ensure_household
def goal_edit(request, pk):
    household = get_user_household(request.user)
    goal = get_object_or_404(Goal, pk=pk, household=household)
    if request.method == 'POST':
        form = GoalForm(request.POST, instance=goal, household=household)
        if form.is_valid():
            form.save()
            messages.success(request, "Goal updated.")
            return redirect('goal_detail', pk=goal.pk)
    else:
        form = GoalForm(instance=goal, household=household)
    return render(request, 'budget_app/goal_form.html', {
        'form': form, 'title': 'Edit Goal',
    })


@login_required
@ensure_household
def goal_delete(request, pk):
    household = get_user_household(request.user)
    goal = get_object_or_404(Goal, pk=pk, household=household)
    if request.method == 'POST':
        goal.delete()
        messages.info(request, "Goal removed.")
        return redirect('goal_list')
    return render(request, 'budget_app/goal_confirm_delete.html', {'goal': goal})


@login_required
@ensure_household
def goal_contribute(request, pk):
    household = get_user_household(request.user)
    goal = get_object_or_404(Goal, pk=pk, household=household)
    if request.method == 'POST':
        form = GoalContributionForm(request.POST)
        if form.is_valid():
            with db_transaction.atomic():
                contrib = form.save(commit=False)
                contrib.goal = goal
                contrib.user = request.user
                if form.cleaned_data.get('record_as_expense'):
                    cat, _ = Category.objects.get_or_create(
                        household=household, name='Savings',
                        category_type=Category.EXPENSE,
                        defaults={'color': '#0d6efd', 'icon': 'bi-piggy-bank'},
                    )
                    tx = Transaction.objects.create(
                        household=household, user=request.user,
                        category=cat, transaction_type=Transaction.EXPENSE,
                        amount=contrib.amount,
                        currency=goal.currency or household.base_currency,
                        description=f"Contribution to {goal.name}",
                        payee=goal.name, date=contrib.date,
                        source=Transaction.SOURCE_MANUAL,
                    )
                    contrib.transaction = tx
                contrib.save()
                # Bump goal's current_amount
                Goal.objects.filter(pk=goal.pk).update(
                    current_amount=Decimal(goal.current_amount) + Decimal(contrib.amount)
                )
                goal.refresh_from_db()
                # Auto-flip to achieved
                if goal.current_amount >= goal.target_amount and goal.status == Goal.STATUS_ACTIVE:
                    goal.status = Goal.STATUS_ACHIEVED
                    goal.save(update_fields=['status'])
            messages.success(request, f"Added {contrib.amount} to {goal.name}.")
            return redirect('goal_detail', pk=goal.pk)
    else:
        form = GoalContributionForm(initial={'date': timezone.now().date()})
    return render(request, 'budget_app/goal_contribute_form.html', {
        'form': form, 'goal': goal,
    })


@login_required
@ensure_household
def goal_contribution_delete(request, pk, contrib_pk):
    household = get_user_household(request.user)
    goal = get_object_or_404(Goal, pk=pk, household=household)
    contrib = get_object_or_404(GoalContribution, pk=contrib_pk, goal=goal)
    if request.method == 'POST':
        with db_transaction.atomic():
            Goal.objects.filter(pk=goal.pk).update(
                current_amount=Decimal(goal.current_amount) - Decimal(contrib.amount)
            )
            if contrib.transaction_id:
                contrib.transaction.delete()
            contrib.delete()
        messages.info(request, "Contribution removed.")
    return redirect('goal_detail', pk=goal.pk)


# ============================================================
# PROJECTS
# ============================================================

@login_required
@ensure_household
def project_list(request):
    household = get_user_household(request.user)
    projects = household.projects.select_related('currency').all()
    return render(request, 'budget_app/project_list.html', {'projects': projects})


@login_required
@ensure_household
def project_create(request):
    household = get_user_household(request.user)
    if request.method == 'POST':
        form = ProjectForm(request.POST, household=household)
        if form.is_valid():
            p = form.save(commit=False)
            p.household = household
            if not p.currency:
                p.currency = household.base_currency
            p.save()
            messages.success(request, "Project created.")
            return redirect('project_detail', pk=p.pk)
    else:
        form = ProjectForm(household=household,
                           initial={'currency': household.base_currency})
    return render(request, 'budget_app/project_form.html', {
        'form': form, 'title': 'New Project',
    })


@login_required
@ensure_household
def project_detail(request, pk):
    household = get_user_household(request.user)
    project = get_object_or_404(Project, pk=pk, household=household)
    transactions = project.transactions.select_related('user', 'category', 'currency')[:200]
    return render(request, 'budget_app/project_detail.html', {
        'project': project, 'transactions': transactions,
    })


@login_required
@ensure_household
def project_edit(request, pk):
    household = get_user_household(request.user)
    project = get_object_or_404(Project, pk=pk, household=household)
    if request.method == 'POST':
        form = ProjectForm(request.POST, instance=project, household=household)
        if form.is_valid():
            form.save()
            messages.success(request, "Project updated.")
            return redirect('project_detail', pk=project.pk)
    else:
        form = ProjectForm(instance=project, household=household)
    return render(request, 'budget_app/project_form.html', {
        'form': form, 'title': 'Edit Project',
    })


@login_required
@ensure_household
def project_delete(request, pk):
    household = get_user_household(request.user)
    project = get_object_or_404(Project, pk=pk, household=household)
    if request.method == 'POST':
        project.delete()
        messages.info(request, "Project removed.")
        return redirect('project_list')
    return render(request, 'budget_app/project_confirm_delete.html', {'project': project})


# ============================================================
# RECEIVABLES (people who borrowed from us)
# ============================================================

@login_required
@ensure_household
def receivable_list(request):
    household = get_user_household(request.user)
    receivables = household.receivables.select_related('currency').all()
    rows = []
    total_outstanding = Decimal('0')
    total_received = Decimal('0')
    overdue_count = 0
    today = timezone.now().date()
    for r in receivables:
        received = r.total_received
        original = r.original_amount or (r.balance + received)
        rows.append({
            'receivable': r, 'received': received, 'original': original,
            'pct': r.progress_percent,
            'payments_count': r.payments.count(),
            'is_overdue': r.is_overdue,
        })
        if r.status == Receivable.STATUS_ACTIVE:
            total_outstanding += r.balance
        total_received += received
        if r.is_overdue:
            overdue_count += 1
    return render(request, 'budget_app/receivable_list.html', {
        'rows': rows,
        'total_outstanding': total_outstanding,
        'total_received': total_received,
        'overdue_count': overdue_count,
    })


@login_required
@ensure_household
def receivable_create(request):
    household = get_user_household(request.user)
    if request.method == 'POST':
        form = ReceivableForm(request.POST, household=household)
        if form.is_valid():
            with db_transaction.atomic():
                r = form.save(commit=False)
                r.household = household
                if not r.currency:
                    r.currency = household.base_currency
                if not r.original_amount:
                    r.original_amount = r.balance
                r.save()
                # Optionally record the lending as a one-off expense
                if form.cleaned_data.get('record_as_expense'):
                    cat, _ = Category.objects.get_or_create(
                        household=household, name='Lent to Others',
                        category_type=Category.EXPENSE,
                        defaults={'color': '#fd7e14', 'icon': 'bi-cash-stack'},
                    )
                    Transaction.objects.create(
                        household=household, user=request.user,
                        category=cat, transaction_type=Transaction.EXPENSE,
                        amount=r.balance,
                        currency=r.currency,
                        description=f"Lent to {r.debtor_name}",
                        payee=r.debtor_name,
                        date=r.lent_date,
                        source=Transaction.SOURCE_MANUAL,
                    )
            messages.success(request, f"Recorded loan to {r.debtor_name}.")
            return redirect('receivable_detail', pk=r.pk)
    else:
        form = ReceivableForm(household=household,
                              initial={'currency': household.base_currency,
                                       'lent_date': timezone.now().date()})
    return render(request, 'budget_app/receivable_form.html', {
        'form': form, 'title': 'Record a Loan Out',
    })


@login_required
@ensure_household
def receivable_detail(request, pk):
    household = get_user_household(request.user)
    receivable = get_object_or_404(Receivable, pk=pk, household=household)
    payments = receivable.payments.select_related('currency', 'transaction').all()
    received = receivable.total_received
    original = receivable.original_amount or (receivable.balance + received)
    return render(request, 'budget_app/receivable_detail.html', {
        'receivable': receivable,
        'payments': payments,
        'received': received,
        'original': original,
        'pct': receivable.progress_percent,
    })


@login_required
@ensure_household
def receivable_edit(request, pk):
    household = get_user_household(request.user)
    receivable = get_object_or_404(Receivable, pk=pk, household=household)
    if request.method == 'POST':
        form = ReceivableForm(request.POST, instance=receivable, household=household)
        if form.is_valid():
            form.save()
            messages.success(request, "Loan updated.")
            return redirect('receivable_detail', pk=receivable.pk)
    else:
        form = ReceivableForm(instance=receivable, household=household)
    return render(request, 'budget_app/receivable_form.html', {
        'form': form, 'title': 'Edit Loan',
    })


@login_required
@ensure_household
def receivable_delete(request, pk):
    household = get_user_household(request.user)
    receivable = get_object_or_404(Receivable, pk=pk, household=household)
    if request.method == 'POST':
        receivable.delete()
        messages.info(request, "Loan removed.")
        return redirect('receivable_list')
    return render(request, 'budget_app/receivable_confirm_delete.html', {'receivable': receivable})


@login_required
@ensure_household
def receivable_payment_create(request, pk):
    household = get_user_household(request.user)
    receivable = get_object_or_404(Receivable, pk=pk, household=household)
    if request.method == 'POST':
        form = ReceivablePaymentForm(request.POST, household=household, receivable=receivable)
        if form.is_valid():
            with db_transaction.atomic():
                payment = form.save(commit=False)
                payment.receivable = receivable
                if not payment.currency:
                    payment.currency = receivable.currency or household.base_currency
                if form.cleaned_data.get('record_as_income'):
                    cat, _ = Category.objects.get_or_create(
                        household=household, name='Loan Repayments',
                        category_type=Category.INCOME,
                        defaults={'color': '#20c997', 'icon': 'bi-cash-stack'},
                    )
                    tx = Transaction.objects.create(
                        household=household, user=request.user,
                        category=cat, transaction_type=Transaction.INCOME,
                        amount=payment.amount, currency=payment.currency,
                        description=f"Repayment from {receivable.debtor_name}",
                        payee=receivable.debtor_name,
                        date=payment.date,
                        source=Transaction.SOURCE_MANUAL,
                    )
                    payment.transaction = tx
                payment.save()
                # Decrement outstanding balance, clamped at 0
                new_balance = max(Decimal('0'),
                                  Decimal(receivable.balance) - Decimal(payment.amount))
                fields = {'balance': new_balance}
                # Auto-mark fully paid
                if new_balance == 0 and receivable.status == Receivable.STATUS_ACTIVE:
                    fields['status'] = Receivable.STATUS_PAID
                Receivable.objects.filter(pk=receivable.pk).update(**fields)
            messages.success(request, f"Recorded repayment of {payment.amount}.")
            return redirect('receivable_detail', pk=receivable.pk)
    else:
        form = ReceivablePaymentForm(household=household, receivable=receivable,
                                     initial={'date': timezone.now().date(),
                                              'amount': receivable.balance})
    return render(request, 'budget_app/receivable_payment_form.html', {
        'form': form, 'receivable': receivable,
    })


@login_required
@ensure_household
def receivable_payment_delete(request, pk, payment_pk):
    household = get_user_household(request.user)
    receivable = get_object_or_404(Receivable, pk=pk, household=household)
    payment = get_object_or_404(ReceivablePayment, pk=payment_pk, receivable=receivable)
    if request.method == 'POST':
        with db_transaction.atomic():
            Receivable.objects.filter(pk=receivable.pk).update(
                balance=Decimal(receivable.balance) + Decimal(payment.amount),
                status=Receivable.STATUS_ACTIVE,
            )
            if payment.transaction_id:
                payment.transaction.delete()
            payment.delete()
        messages.info(request, "Repayment removed and balance restored.")
        return redirect('receivable_detail', pk=receivable.pk)
    return render(request, 'budget_app/receivable_payment_confirm_delete.html', {
        'receivable': receivable, 'payment': payment,
    })
