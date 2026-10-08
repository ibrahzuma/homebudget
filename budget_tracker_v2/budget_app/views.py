from datetime import date
from decimal import Decimal

from django.contrib import messages
from django.contrib.auth import login
from django.contrib.auth import views as auth_views
from django.contrib.auth.decorators import login_required
from django.contrib.auth.models import User
from django.db.models import Sum, Q
from django.http import FileResponse, Http404, HttpResponse, JsonResponse
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
    Currency, ExchangeRate,
    Meeting, AgreementItem, Goal, GoalContribution, Project,
    Receivable, ReceivablePayment,
    HouseholdInvitation, resolve_user_household,
)
from .services import (
    apply_category_rules, apply_due_recurring,
    check_budget_alerts, forecast_end_of_month, compute_net_worth,
    month_range,
    # Shared with the JSON API (budget_app/api/)
    seed_household_defaults, ensure_default_currencies, add_member_to_household,
    accept_invitation, notify_money_request_created, approve_money_request,
    reject_money_request, cancel_money_request, record_liability_payment,
    delete_liability_payment, record_goal_contribution, delete_goal_contribution,
    create_receivable, record_receivable_payment, delete_receivable_payment,
    save_networth_snapshot, save_exchange_rate, snapshot_meeting_state,
    carry_over_open_items, suggest_next_meeting_date, normalize_agreement_completion,
    quick_update_agreement, mark_chat_read, send_chat_message,
    mobile_app_release,
    write_transactions_csv, import_transactions_csv,
    dashboard_summary, calendar_month, monthly_report_data,
)


# ============================================================
# HELPERS
# ============================================================

def get_user_household(user):
    return resolve_user_household(user)


def ensure_household(view):
    """Decorator: redirect to setup if user has no household."""
    def wrapper(request, *args, **kwargs):
        h = get_user_household(request.user)
        if not h:
            return redirect('household_setup')
        return view(request, *args, **kwargs)
    wrapper.__name__ = view.__name__
    return wrapper


# ============================================================
# AUTH
# ============================================================

INVITE_SESSION_KEY = '_pending_invite_code'


def signup_view(request):
    # An invite code can ride along the signup URL (?invite=...) so a partner
    # who follows a link lands in the shared household instead of being sent to
    # /household/setup/ to create one of their own.
    invite_code = request.GET.get('invite') or request.POST.get('invite') or ''
    invite = None
    if invite_code:
        invite = HouseholdInvitation.objects.filter(code=invite_code).first()
        if invite and not invite.is_usable:
            invite = None

    if request.method == 'POST':
        form = SignUpForm(request.POST)
        if form.is_valid():
            user = form.save()
            login(request, user)
            if invite:
                # Remember it across the redirect; invite_accept does the work.
                request.session[INVITE_SESSION_KEY] = invite.code
                return redirect('invite_accept', code=invite.code)
            messages.success(request, "Account created. Now set up your household.")
            return redirect('household_setup')
    else:
        form = SignUpForm()
    return render(request, 'budget_app/signup.html', {
        'form': form, 'invite': invite, 'invite_code': invite.code if invite else '',
    })


# ============================================================
# HOUSEHOLD
# ============================================================

@login_required
def household_setup(request):
    # Make sure default currencies exist before showing the form
    ensure_default_currencies()

    if get_user_household(request.user):
        return redirect('dashboard')

    # Followed an invite link before signing in? Go straight to the join page
    # rather than making them create a household they don't want.
    pending_code = request.session.get(INVITE_SESSION_KEY)
    if pending_code:
        pending = HouseholdInvitation.objects.filter(code=pending_code).first()
        if pending and pending.is_usable:
            return redirect('invite_accept', code=pending.code)
        request.session.pop(INVITE_SESSION_KEY, None)

    if request.method == 'POST' and request.POST.get('action') == 'join':
        code = request.POST.get('code', '').strip()
        # Accept either a bare code or a pasted full invite URL.
        code = code.rstrip('/').rsplit('/', 1)[-1]
        invite = HouseholdInvitation.objects.filter(code=code).first() if code else None
        if invite is None:
            messages.error(request, "That invite code is not valid.")
        elif not invite.is_usable:
            messages.error(request, invite.unusable_reason())
        else:
            return redirect('invite_accept', code=invite.code)
        return redirect('household_setup')

    if request.method == 'POST':
        form = HouseholdForm(request.POST)
        if form.is_valid():
            household = form.save()
            household.members.add(request.user)
            partner_username = form.cleaned_data.get('partner_username')
            if partner_username:
                try:
                    partner = User.objects.get(username=partner_username)
                    level, msg = add_member_to_household(household, partner)
                    getattr(messages, level)(request, msg)
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
                level, msg = add_member_to_household(household, user)
                getattr(messages, level)(request, msg)
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
        elif action == 'create_invite':
            invite = HouseholdInvitation.objects.create(
                household=household,
                code=HouseholdInvitation.generate_code(),
                invited_by=request.user,
                note=request.POST.get('note', '').strip()[:200],
            )
            messages.success(request, "Invite link created — send it to your partner.")
            return redirect(f"{reverse('household_settings')}?new_invite={invite.code}")
        elif action == 'revoke_invite':
            invite = get_object_or_404(
                HouseholdInvitation, pk=request.POST.get('invite_id'), household=household
            )
            if invite.status == HouseholdInvitation.STATUS_PENDING:
                invite.status = HouseholdInvitation.STATUS_REVOKED
                invite.save(update_fields=['status'])
                messages.success(request, "Invite link cancelled.")
        elif action == 'change_currency':
            cid = request.POST.get('currency_id')
            try:
                household.base_currency = Currency.objects.get(pk=cid)
                household.save()
                messages.success(request, f"Base currency updated to {household.base_currency.code}.")
            except Currency.DoesNotExist:
                pass
        return redirect('household_settings')

    invites = household.invitations.select_related('invited_by', 'accepted_by')
    return render(request, 'budget_app/household_settings.html', {
        'household': household,
        'currencies': Currency.objects.all(),
        'pending_invites': [i for i in invites if i.is_usable],
        'past_invites': [i for i in invites if not i.is_usable][:10],
        'new_invite_code': request.GET.get('new_invite', ''),
    })


def invite_accept(request, code):
    """Landing page for an invite link. Works logged-out, logged-in, and for
    brand-new accounts coming back from signup."""
    invite = HouseholdInvitation.objects.filter(code=code).select_related(
        'household', 'invited_by'
    ).first()

    if invite is None:
        return render(request, 'budget_app/invite_accept.html',
                      {'error': 'That invite link is not valid.'}, status=404)

    reason = invite.unusable_reason()
    if reason:
        # An already-accepted link is not an error for the person who used it.
        if (request.user.is_authenticated
                and invite.household.members.filter(pk=request.user.pk).exists()):
            request.session.pop(INVITE_SESSION_KEY, None)
            return redirect('dashboard')
        return render(request, 'budget_app/invite_accept.html',
                      {'invite': invite, 'error': reason}, status=410)

    if not request.user.is_authenticated:
        # Stash it so /household/setup/ can offer the join instead of a create,
        # then show sign-up / sign-in options that carry the code through.
        request.session[INVITE_SESSION_KEY] = invite.code
        return render(request, 'budget_app/invite_accept.html', {'invite': invite})

    if invite.household.members.filter(pk=request.user.pk).exists():
        # Usually the sender checking their own link — don't burn it on them.
        messages.info(request, f"You're already a member of {invite.household.name}. "
                               f"This link is still active for your partner.")
        return redirect('household_settings')

    if request.method == 'POST':
        level, msg = accept_invitation(invite, request.user)
        request.session.pop(INVITE_SESSION_KEY, None)
        getattr(messages, level)(request, msg)
        return redirect('dashboard')

    return render(request, 'budget_app/invite_accept.html', {'invite': invite})


# ============================================================
# DASHBOARD
# ============================================================

@login_required
@ensure_household
def dashboard(request):
    household = get_user_household(request.user)
    context = dashboard_summary(household, request.user)
    context['household'] = household
    context['apk'] = mobile_app_release()
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
        date(year, month, 1)
    except ValueError:
        year, month = today.year, today.month

    cal = calendar_month(household, year, month, today)
    return render(request, 'budget_app/bill_calendar.html', {
        'year': year, 'month': month,
        'month_label': cal['target'].strftime('%B %Y'),
        'weeks': cal['weeks'],
        'prev_month': cal['prev_month'],
        'next_month': cal['next_month'],
        'month_total': cal['month_expense'],   # back-compat
        'month_expense': cal['month_expense'],
        'month_income': cal['month_income'],
        'month_net': cal['month_net'],
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
            notify_money_request_created(r)
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
            approve_money_request(money_request, note)
            messages.success(request, "Request approved and transactions recorded.")
            return redirect('request_detail', pk=pk)

        elif action == 'reject' and can_respond:
            reject_money_request(money_request, note)
            messages.info(request, "Request rejected.")
            return redirect('request_detail', pk=pk)

        elif action == 'cancel' and can_cancel:
            cancel_money_request(money_request)
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
            payment = record_liability_payment(
                liab, form.save(commit=False), request.user,
                record_as_expense=form.cleaned_data.get('record_as_expense'),
                expense_category=form.cleaned_data.get('expense_category'),
            )
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
        delete_liability_payment(liab, payment)
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
        save_networth_snapshot(household)
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
            save_exchange_rate(
                get_user_household(request.user),
                form.cleaned_data['from_currency'],
                form.cleaned_data['to_currency'],
                form.cleaned_data['rate'],
            )
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

    write_transactions_csv(
        response, household.transactions.select_related('user', 'category', 'currency').all()
    )
    return response


@login_required
@ensure_household
def import_csv(request):
    household = get_user_household(request.user)
    result = None
    if request.method == 'POST':
        form = CSVImportForm(request.POST, request.FILES)
        if form.is_valid():
            result = import_transactions_csv(
                household, request.user, form.cleaned_data['file'].read()
            )
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
        'next_suggested': suggest_next_meeting_date(household),
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
            snapshot_meeting_state(m)
            m.save()
            form.save_m2m()
            # Carry over open agreement items from the previous meeting, if asked
            carried = 0
            if form.cleaned_data.get('carry_over_open_items') and form._previous_meeting:
                carried = carry_over_open_items(form._previous_meeting, m)
            if carried:
                messages.success(request, f"Meeting created. Carried over {carried} open item(s) from the previous meeting.")
            else:
                messages.success(request, "Meeting created.")
            return redirect('meeting_detail', pk=m.pk)
    else:
        suggested = suggest_next_meeting_date(household)
        form = MeetingForm(household=household, initial={
            'meeting_date': suggested,
            'title': f"Q{((suggested.month - 1) // 3) + 1} {suggested.year} Review",
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
            normalize_agreement_completion(item)
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
            normalize_agreement_completion(saved)
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
        quick_update_agreement(item, request.POST.get('status'), request.POST.get('progress'))
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
            contrib = record_goal_contribution(
                goal, form.save(commit=False), request.user,
                record_as_expense=form.cleaned_data.get('record_as_expense'),
            )
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
        delete_goal_contribution(goal, contrib)
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
            r = form.save(commit=False)
            r.household = household
            create_receivable(r, request.user,
                              record_as_expense=form.cleaned_data.get('record_as_expense'))
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
            payment = record_receivable_payment(
                receivable, form.save(commit=False), request.user,
                record_as_income=form.cleaned_data.get('record_as_income'),
            )
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
        delete_receivable_payment(receivable, payment)
        messages.info(request, "Repayment removed and balance restored.")
        return redirect('receivable_detail', pk=receivable.pk)
    return render(request, 'budget_app/receivable_payment_confirm_delete.html', {
        'receivable': receivable, 'payment': payment,
    })


# ============================================================
# HOUSEHOLD CHAT
# ============================================================

@login_required
@ensure_household
def chat_view(request):
    household = get_user_household(request.user)
    messages_qs = household.chat_messages.select_related('sender').all()
    # Mark all chat as read for this user
    mark_chat_read(household, request.user)
    return render(request, 'budget_app/chat.html', {
        'chat_messages': messages_qs,
        'members': household.members.all(),
    })


@login_required
@ensure_household
def chat_recent(request):
    """JSON feed of the last N chat messages — used by the floating widget on open."""
    household = get_user_household(request.user)
    limit = min(int(request.GET.get('limit', 50)), 200)
    qs = household.chat_messages.select_related('sender').order_by('-created_at')[:limit]
    # Reverse so the JS gets them oldest-first (so it can append without sorting)
    messages_list = list(reversed(list(qs)))
    # Mark as read when the widget loads them
    mark_chat_read(household, request.user)
    return JsonResponse({
        'messages': [
            {
                'id': m.id,
                'sender_id': m.sender_id,
                'sender_name': m.sender.username,
                'body': m.body,
                'created_at_display': timezone.localtime(m.created_at).strftime('%b %d, %H:%M'),
            }
            for m in messages_list
        ]
    })


@login_required
@ensure_household
def chat_send(request):
    household = get_user_household(request.user)
    if request.method != 'POST':
        return redirect('chat')
    body = (request.POST.get('body') or '').strip()
    if not body:
        if request.headers.get('X-Requested-With') == 'XMLHttpRequest':
            return JsonResponse({'ok': False, 'error': 'empty'}, status=400)
        return redirect('chat')
    msg = send_chat_message(household, request.user, body)
    if request.headers.get('X-Requested-With') == 'XMLHttpRequest':
        return JsonResponse({'ok': True, 'id': msg.id})
    return redirect('chat')


# ============================================================
# MONTHLY REPORT
# ============================================================

@login_required
@ensure_household
def monthly_report(request):
    household = get_user_household(request.user)
    today = timezone.now().date()
    try:
        year = int(request.GET.get('year', today.year))
        month = int(request.GET.get('month', today.month))
        date(year, month, 1)
    except (TypeError, ValueError):
        year, month = today.year, today.month
    context = monthly_report_data(household, year, month)
    context['is_current_month'] = year == today.year and month == today.month
    return render(request, 'budget_app/monthly_report.html', context)


@login_required
@ensure_household
def monthly_report_csv(request, year, month):
    """CSV export of all transactions in a single month."""
    household = get_user_household(request.user)
    try:
        target = date(year, month, 1)
    except ValueError:
        return redirect('monthly_report')
    month_start, month_end = month_range(target)

    response = HttpResponse(content_type='text/csv')
    response['Content-Disposition'] = (
        f'attachment; filename="report_{year}-{month:02d}.csv"'
    )
    qs = household.transactions.filter(
        date__gte=month_start, date__lte=month_end
    ).select_related('user', 'category', 'currency', 'project').order_by('date')
    write_transactions_csv(response, qs, include_project=True)
    return response


# ============================================================
# ANDROID APP DOWNLOAD (public)
# ============================================================

class AppLoginView(auth_views.LoginView):
    """Django's login view plus the published APK, so the sign-in page can
    offer the Android download. Looked up per request, not at import time, so
    uploading a build is picked up without a restart."""
    template_name = 'budget_app/login.html'

    def get_context_data(self, **kwargs):
        return super().get_context_data(**kwargs) | {'apk': mobile_app_release()}


def app_download(request):
    """Public landing page for the Android app.

    Deliberately outside @login_required: the point is that someone who has
    just been invited can install the app before they have an account.
    """
    return render(request, 'budget_app/app_download.html', {
        'release': mobile_app_release(),
    })


def app_download_file(request):
    """Serve the APK itself.

    Streams from disk via FileResponse. If the file ever grows enough for that
    to matter, nginx can take the route over with an `alias` — see the README.
    """
    release = mobile_app_release()
    if not release['available']:
        raise Http404('No build has been uploaded yet.')
    version = release['version'].split()[0] if release['version'] else ''
    name = f"home-budget-{version}.apk" if version else 'home-budget.apk'
    return FileResponse(
        open(release['path'], 'rb'),
        as_attachment=True,
        filename=name,
        content_type='application/vnd.android.package-archive',
    )
