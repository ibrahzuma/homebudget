"""JSON API for the mobile app (mounted at /api/v1/).

Every endpoint is token-authenticated and scoped to the caller's household
via ``resolve_user_household``. Input goes through the same Django forms as
the web UI, and side effects go through ``services`` — so a transaction,
approval or payment made from the phone is indistinguishable from one made
in the browser.
"""
from datetime import date

from django.contrib.auth import authenticate
from django.contrib.auth.models import User
from django.core.exceptions import ValidationError as DjangoValidationError
from django.db.models import Q, Sum
from django.http import HttpResponse
from django.utils import timezone
from rest_framework import status
from rest_framework.authtoken.models import Token
from rest_framework.exceptions import NotFound, PermissionDenied, ValidationError
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from .. import services
from ..forms import (
    AgreementItemForm, AssetForm, BudgetForm, CategoryForm, CategoryRuleForm,
    CurrencyForm, ExchangeRateForm, GoalContributionForm, GoalForm, HouseholdForm,
    LiabilityForm, LiabilityPaymentForm, MeetingForm, MoneyRequestForm,
    ProjectForm, ReceivableForm, ReceivablePaymentForm, RecurringTransactionForm,
    SignUpForm, TransactionForm,
)
from ..models import (
    AgreementItem, Alert, Asset, Budget, Category, CategoryRule, Currency,
    ExchangeRate, Goal, GoalContribution, HouseholdInvitation, Liability,
    LiabilityPayment, Meeting, MoneyRequest, Project, Receivable,
    ReceivablePayment, RecurringTransaction, Transaction,
)
from . import serializers as s
from .base import (
    HouseholdAPIView, NoHousehold, bind_form, created, form_error, no_content, paginate,
    validated_form,
)


def _month_param(request):
    today = timezone.now().date()
    try:
        year = int(request.query_params.get('year', today.year))
        month = int(request.query_params.get('month', today.month))
        date(year, month, 1)
    except ValueError:
        raise ValidationError({'month': ['Invalid year/month.']})
    return year, month


def _data(request):
    """Mutable plain-dict copy of the request body."""
    d = request.data
    return d.dict() if hasattr(d, 'dict') else dict(d)


def _token_response(user, http_status=status.HTTP_200_OK):
    token, _ = Token.objects.get_or_create(user=user)
    return Response({'token': token.key, 'user': s.user_brief(user)}, status=http_status)


# ============================================================
# AUTH
# ============================================================

class LoginView(APIView):
    authentication_classes = []
    permission_classes = [AllowAny]
    throttle_scope = 'auth'

    def post(self, request):
        user = authenticate(request, username=request.data.get('username', ''),
                            password=request.data.get('password', ''))
        if user is None or not user.is_active:
            raise ValidationError({'non_field_errors': ['Wrong username or password.']})
        return _token_response(user)


class SignupView(APIView):
    """Create an account. With ``invite`` the new user joins that household
    straight away instead of having to create one."""
    authentication_classes = []
    permission_classes = [AllowAny]
    throttle_scope = 'auth'

    def post(self, request):
        invite = None
        code = (request.data.get('invite') or '').strip()
        if code:
            invite = HouseholdInvitation.objects.filter(code=code).first()
            if invite is None:
                raise ValidationError({'invite': ['That invite code is not valid.']})
            if not invite.is_usable:
                raise ValidationError({'invite': [invite.unusable_reason()]})
        form = validated_form(SignUpForm, request.data)
        user = form.save()
        if invite:
            services.accept_invitation(invite, user)
        return _token_response(user, status.HTTP_201_CREATED)


class LogoutView(APIView):
    def post(self, request):
        Token.objects.filter(user=request.user).delete()
        return no_content()


# ============================================================
# ME / META / HOUSEHOLD
# ============================================================

class MeView(HouseholdAPIView):
    requires_household = False

    def get(self, request):
        u = request.user
        h = self.household
        return Response({
            'user': {**s.user_brief(u), 'email': u.email},
            'household': s.household(h) if h else None,
            'badges': services.badge_counts(h, u) if h else None,
        })


class MetaView(HouseholdAPIView):
    """Everything a form needs to render pickers, in one round trip."""

    def get(self, request):
        h = self.household

        def choices(pairs):
            return [{'value': v, 'label': str(l)} for v, l in pairs]

        return Response({
            'currencies': [s.currency(c) for c in Currency.objects.all()],
            'categories': [s.category(c) for c in h.categories.all()],
            'members': [s.user_brief(u) for u in h.members.order_by('username')],
            'projects': [s.project_brief(p) for p in h.projects.exclude(
                status__in=[Project.STATUS_COMPLETED, Project.STATUS_CANCELLED])],
            'choices': {
                'transaction_type': choices(Transaction.TYPE_CHOICES),
                'transaction_source': choices(Transaction.SOURCE_CHOICES),
                'frequency': choices(RecurringTransaction.FREQ_CHOICES),
                'match_type': choices(CategoryRule.MATCH_CHOICES),
                'alert_level': choices(Alert.LEVEL_CHOICES),
                'request_status': choices(MoneyRequest.STATUS_CHOICES),
                'asset_type': choices(Asset.TYPE_CHOICES),
                'liability_type': choices(Liability.TYPE_CHOICES),
                'goal_status': choices(Goal.STATUS_CHOICES),
                'project_status': choices(Project.STATUS_CHOICES),
                'meeting_status': choices(Meeting.STATUS_CHOICES),
                'agreement_status': choices(AgreementItem.STATUS_CHOICES),
                'agreement_priority': choices(AgreementItem.PRIORITY_CHOICES),
                'receivable_status': choices(Receivable.STATUS_CHOICES),
            },
        })


class HouseholdView(HouseholdAPIView):
    requires_household = False

    def _settings(self):
        h = self.household
        invites = list(h.invitations.select_related('invited_by', 'accepted_by'))
        return {
            **s.household(h),
            'pending_invites': [s.invitation(i) for i in invites if i.is_usable],
            'past_invites': [s.invitation(i) for i in invites if not i.is_usable][:10],
        }

    def get(self, request):
        if not self.household:
            raise NotFound('You are not in a household yet.')
        return Response(self._settings())

    def post(self, request):
        """Create a household (the /household/setup/ flow)."""
        if self.household:
            raise ValidationError({'non_field_errors': ['You already belong to a household.']})
        services.ensure_default_currencies()
        form = validated_form(HouseholdForm, request.data)
        h = form.save()
        h.members.add(request.user)
        notice = None
        partner = form.cleaned_data.get('partner_username')
        if partner:
            try:
                _, notice = services.add_member_to_household(h, User.objects.get(username=partner))
            except User.DoesNotExist:
                notice = f"User '{partner}' not found. Add them later."
        services.seed_household_defaults(h)
        self.household = h
        return created({**self._settings(), 'notice': notice})

    def patch(self, request):
        h = self.household
        if not h:
            raise NotFound('You are not in a household yet.')
        if 'name' in request.data:
            name = (request.data.get('name') or '').strip()
            if not name:
                raise ValidationError({'name': ['This field is required.']})
            h.name = name[:100]
        if 'base_currency' in request.data:
            try:
                h.base_currency = Currency.objects.get(pk=request.data.get('base_currency'))
            except (Currency.DoesNotExist, ValueError, TypeError):
                raise ValidationError({'base_currency': ['Unknown currency.']})
        h.save()
        return Response(self._settings())


class HouseholdJoinView(HouseholdAPIView):
    requires_household = False

    def post(self, request):
        code = (request.data.get('code') or '').strip()
        # Accept either a bare code or a pasted full invite URL.
        code = code.rstrip('/').rsplit('/', 1)[-1]
        invite = HouseholdInvitation.objects.filter(code=code).select_related(
            'household').first() if code else None
        if invite is None:
            raise ValidationError({'code': ['That invite code is not valid.']})
        if invite.household.members.filter(pk=request.user.pk).exists():
            raise ValidationError({'code': ["You're already a member of this household."]})
        if not invite.is_usable:
            raise ValidationError({'code': [invite.unusable_reason()]})
        level, msg = services.accept_invitation(invite, request.user)
        return Response({'household': s.household(invite.household), 'notice': msg})


class HouseholdMembersView(HouseholdAPIView):
    def post(self, request):
        username = (request.data.get('username') or '').strip()
        try:
            user = User.objects.get(username=username)
        except User.DoesNotExist:
            raise ValidationError({'username': [f"User '{username}' not found."]})
        level, msg = services.add_member_to_household(self.household, user)
        return Response({'level': level, 'notice': msg,
                         'household': s.household(self.household)})


class HouseholdMemberDetailView(HouseholdAPIView):
    def delete(self, request, user_id):
        user = self.household.members.filter(pk=user_id).first()
        if user is None:
            raise NotFound('Not a member of this household.')
        if user == request.user:
            raise ValidationError({'non_field_errors': ["You can't remove yourself."]})
        self.household.members.remove(user)
        return no_content()


class InvitesView(HouseholdAPIView):
    def post(self, request):
        invite = HouseholdInvitation.objects.create(
            household=self.household,
            code=HouseholdInvitation.generate_code(),
            invited_by=request.user,
            note=(request.data.get('note') or '').strip()[:200],
        )
        return created(s.invitation(invite))


class InviteRevokeView(HouseholdAPIView):
    def post(self, request, pk):
        invite = self.get_owned(HouseholdInvitation, pk)
        if invite.status == HouseholdInvitation.STATUS_PENDING:
            invite.status = HouseholdInvitation.STATUS_REVOKED
            invite.save(update_fields=['status'])
        return Response(s.invitation(invite))


# ============================================================
# Generic household-scoped CRUD
# ============================================================

class CrudListView(HouseholdAPIView):
    model = None
    form_class = None
    serialize = None
    pass_household_to_form = True

    def get_queryset(self):
        return self.model.objects.filter(household=self.household)

    def form_kwargs(self):
        return {'household': self.household} if self.pass_household_to_form else {}

    def perform_create(self, form):
        obj = form.save(commit=False)
        obj.household = self.household
        obj.save()
        form.save_m2m()
        return obj

    def serialize_list(self, qs):
        return [type(self).serialize(o) for o in qs]

    def get(self, request):
        return Response(self.serialize_list(self.get_queryset()))

    def post(self, request):
        form = validated_form(self.form_class, request.data, **self.form_kwargs())
        obj = self.perform_create(form)
        return created(type(self).serialize(self.get_queryset().get(pk=obj.pk)))


class CrudDetailView(HouseholdAPIView):
    model = None
    form_class = None
    serialize = None
    pass_household_to_form = True

    def get_object(self, pk):
        return self.get_owned(self.model, pk)

    def form_kwargs(self):
        return {'household': self.household} if self.pass_household_to_form else {}

    def perform_update(self, form):
        return form.save()

    def get(self, request, pk):
        return Response(type(self).serialize(self.get_object(pk)))

    def patch(self, request, pk):
        obj = self.get_object(pk)
        form = bind_form(self.form_class, request.data, instance=obj, **self.form_kwargs())
        if not form.is_valid():
            form_error(form)
        self.perform_update(form)
        return Response(type(self).serialize(self.get_object(pk)))

    put = patch

    def delete(self, request, pk):
        self.get_object(pk).delete()
        return no_content()


# ============================================================
# DASHBOARD
# ============================================================

class DashboardView(HouseholdAPIView):
    def get(self, request):
        data = services.dashboard_summary(self.household, request.user)
        return Response(s.dashboard(data, request.user))


# ============================================================
# TRANSACTIONS
# ============================================================

class TransactionListView(CrudListView):
    model = Transaction
    form_class = TransactionForm
    serialize = staticmethod(s.transaction)

    def get_queryset(self):
        qs = self.household.transactions.select_related('user', 'category', 'currency', 'project')
        p = self.request.query_params
        if p.get('type') in (Transaction.INCOME, Transaction.EXPENSE):
            qs = qs.filter(transaction_type=p['type'])
        for param, field in (('member', 'user_id'), ('category', 'category_id'),
                             ('project', 'project_id')):
            if p.get(param):
                qs = qs.filter(**{field: p[param]})
        if p.get('uncategorized') in ('1', 'true'):
            qs = qs.filter(category__isnull=True)
        if p.get('date_from'):
            qs = qs.filter(date__gte=p['date_from'])
        if p.get('date_to'):
            qs = qs.filter(date__lte=p['date_to'])
        if p.get('q'):
            qs = qs.filter(Q(description__icontains=p['q']) | Q(payee__icontains=p['q']))
        return qs

    def get(self, request):
        try:
            qs = self.get_queryset()
            data = paginate(request, qs, s.transaction)
        except (ValueError, DjangoValidationError):  # bad ids / dates in filters
            raise ValidationError({'non_field_errors': ['Invalid filter value.']})
        totals = qs.values('transaction_type').annotate(t=Sum('amount_base'))
        data['totals'] = {row['transaction_type']: s.money(row['t']) for row in totals}
        return Response(data)

    def perform_create(self, form):
        t = form.save(commit=False)
        t.household = self.household
        t.user = self.request.user
        t.save()
        services.apply_category_rules(t)
        services.check_budget_alerts(self.household)
        return t


class TransactionDetailView(CrudDetailView):
    model = Transaction
    form_class = TransactionForm
    serialize = staticmethod(s.transaction)

    def perform_update(self, form):
        t = form.save(commit=False)
        t.amount_base = None  # force recompute
        t.save()
        services.check_budget_alerts(self.household)
        return t


class TransactionExportView(HouseholdAPIView):
    def get(self, request):
        response = HttpResponse(content_type='text/csv')
        today = timezone.now().date().isoformat()
        response['Content-Disposition'] = f'attachment; filename="transactions_{today}.csv"'
        services.write_transactions_csv(
            response,
            self.household.transactions.select_related('user', 'category', 'currency').all(),
        )
        return response


class TransactionImportView(HouseholdAPIView):
    def post(self, request):
        f = request.FILES.get('file')
        if f is None:
            raise ValidationError({'file': ['Attach a CSV file as "file".']})
        if f.size > 5 * 1024 * 1024:
            raise ValidationError({'file': ['CSV must be under 5 MB.']})
        return Response(services.import_transactions_csv(self.household, request.user, f.read()))


# ============================================================
# CATEGORIES / BUDGETS / RULES
# ============================================================

def _check_category_unique(household, obj):
    # CategoryForm doesn't carry `household`, so the form can't enforce
    # unique_together itself.
    clash = household.categories.filter(name=obj.name, category_type=obj.category_type)
    if obj.pk:
        clash = clash.exclude(pk=obj.pk)
    if clash.exists():
        raise ValidationError({'name': ['A category with this name and type already exists.']})


class CategoryListView(CrudListView):
    model = Category
    form_class = CategoryForm
    serialize = staticmethod(s.category)
    pass_household_to_form = False

    def perform_create(self, form):
        c = form.save(commit=False)
        c.household = self.household
        _check_category_unique(self.household, c)
        c.save()
        return c


class CategoryDetailView(CrudDetailView):
    model = Category
    form_class = CategoryForm
    serialize = staticmethod(s.category)
    pass_household_to_form = False

    def perform_update(self, form):
        c = form.save(commit=False)
        _check_category_unique(self.household, c)
        c.save()
        return c


def _budget_rows(household, qs):
    month_start, month_end = services.month_range(timezone.now().date())
    rows = []
    for b in qs:
        if b.month == month_start:
            spent = Transaction.objects.filter(
                household=household, transaction_type=Transaction.EXPENSE,
                category=b.category, date__gte=month_start, date__lte=month_end,
            ).aggregate(t=Sum('amount_base'))['t'] or 0
            rows.append(s.budget(b, spent=spent, is_current=True))
        else:
            rows.append(s.budget(b))
    return rows


class BudgetListView(CrudListView):
    model = Budget
    form_class = BudgetForm

    def get_queryset(self):
        return self.household.budgets.select_related('category')

    def get(self, request):
        return Response(_budget_rows(self.household, self.get_queryset()))

    def perform_create(self, form):
        b = form.save(commit=False)
        b.household = self.household
        b.month = b.month.replace(day=1)
        b.save()
        return b

    def post(self, request):
        form = validated_form(self.form_class, request.data, household=self.household)
        month = form.cleaned_data['month'].replace(day=1)
        if self.household.budgets.filter(category=form.cleaned_data['category'],
                                         month=month).exists():
            raise ValidationError({'category': ['A budget for this category and month already exists.']})
        b = self.perform_create(form)
        return created(_budget_rows(self.household, [b])[0])


class BudgetDetailView(CrudDetailView):
    model = Budget
    form_class = BudgetForm

    def get(self, request, pk):
        return Response(_budget_rows(self.household, [self.get_object(pk)])[0])

    def patch(self, request, pk):
        b = self.get_object(pk)
        form = bind_form(BudgetForm, request.data, instance=b, household=self.household)
        if not form.is_valid():
            form_error(form)
        b = form.save(commit=False)
        b.month = b.month.replace(day=1)
        if self.household.budgets.filter(category=b.category, month=b.month).exclude(pk=b.pk).exists():
            raise ValidationError({'category': ['A budget for this category and month already exists.']})
        b.save()
        return Response(_budget_rows(self.household, [b])[0])


class RuleListView(CrudListView):
    model = CategoryRule
    form_class = CategoryRuleForm
    serialize = staticmethod(s.rule)

    def get_queryset(self):
        return self.household.rules.select_related('category')


class RuleDetailView(CrudDetailView):
    model = CategoryRule
    form_class = CategoryRuleForm
    serialize = staticmethod(s.rule)


class RulesApplyView(HouseholdAPIView):
    def post(self, request):
        count = sum(1 for t in self.household.transactions.filter(category__isnull=True)
                    if services.apply_category_rules(t))
        return Response({'categorized': count})


# ============================================================
# RECURRING / CALENDAR / FORECAST
# ============================================================

class RecurringListView(CrudListView):
    model = RecurringTransaction
    form_class = RecurringTransactionForm
    serialize = staticmethod(s.recurring)

    def get_queryset(self):
        return self.household.recurring_transactions.select_related('category', 'currency', 'user')

    def post(self, request):
        data = _data(request)
        # next_due_date defaults to the start date, as on the web form
        if not data.get('next_due_date') and data.get('start_date'):
            data['next_due_date'] = data['start_date']
        form = validated_form(self.form_class, data, household=self.household)
        r = form.save(commit=False)
        r.household = self.household
        r.user = request.user
        r.save()
        return created(s.recurring(r))


class RecurringDetailView(CrudDetailView):
    model = RecurringTransaction
    form_class = RecurringTransactionForm
    serialize = staticmethod(s.recurring)


class RecurringRunNowView(HouseholdAPIView):
    def post(self, request):
        made = services.apply_due_recurring(household=self.household)
        return Response({'created': len(made),
                         'transactions': [s.transaction(t) for t in made]})


class CalendarView(HouseholdAPIView):
    def get(self, request):
        year, month = _month_param(request)
        return Response(s.calendar(services.calendar_month(self.household, year, month)))


class ForecastView(HouseholdAPIView):
    def get(self, request):
        month_start, _ = services.month_range(timezone.now().date())
        return Response({
            'month_label': month_start.strftime('%B %Y'),
            **s.forecast(services.forecast_end_of_month(self.household)),
        })


# ============================================================
# ALERTS
# ============================================================

def _visible_alerts(household, user):
    return household.alerts.filter(Q(user__isnull=True) | Q(user=user)).select_related('user')


class AlertListView(HouseholdAPIView):
    def get(self, request):
        qs = _visible_alerts(self.household, request.user)
        if request.query_params.get('unread') in ('1', 'true'):
            qs = qs.filter(is_read=False)
        return Response(paginate(request, qs, s.alert))


class AlertReadView(HouseholdAPIView):
    def post(self, request, pk):
        a = _visible_alerts(self.household, request.user).filter(pk=pk).first()
        if a is None:
            raise NotFound()
        a.is_read = True
        a.save(update_fields=['is_read'])
        return Response(s.alert(a))


class AlertReadAllView(HouseholdAPIView):
    def post(self, request):
        n = _visible_alerts(self.household, request.user).filter(is_read=False).update(is_read=True)
        return Response({'marked': n})


# ============================================================
# MONEY REQUESTS
# ============================================================

def _requests_qs(household):
    return household.money_requests.select_related('requester', 'approver', 'currency', 'category')


class MoneyRequestListView(HouseholdAPIView):
    def get(self, request):
        qs = _requests_qs(self.household)
        u = request.user
        return Response({
            'incoming': [s.money_request(r, u) for r in qs.filter(approver=u)],
            'outgoing': [s.money_request(r, u) for r in qs.filter(requester=u)],
        })

    def post(self, request):
        if self.household.members.count() < 2:
            raise ValidationError({'non_field_errors': [
                'Add a partner to your household before requesting money.']})
        form = validated_form(MoneyRequestForm, request.data,
                              household=self.household, requester=request.user)
        r = form.save(commit=False)
        r.household = self.household
        r.requester = request.user
        r.save()
        services.notify_money_request_created(r)
        return created(s.money_request(r, request.user))


class MoneyRequestDetailView(HouseholdAPIView):
    def get_object(self, pk):
        r = _requests_qs(self.household).filter(pk=pk).first()
        if r is None:
            raise NotFound()
        return r

    def get(self, request, pk):
        return Response(s.money_request(self.get_object(pk), request.user))


class MoneyRequestActionView(MoneyRequestDetailView):
    action = None  # 'approve' | 'reject' | 'cancel'

    def post(self, request, pk):
        r = self.get_object(pk)
        if r.status != MoneyRequest.STATUS_PENDING:
            raise ValidationError({'non_field_errors': [f'This request is already {r.status}.']})
        note = (request.data.get('note') or '').strip()
        if self.action in ('approve', 'reject'):
            if request.user.id != r.approver_id:
                raise PermissionDenied('Only the approver can respond to this request.')
            if self.action == 'approve':
                services.approve_money_request(r, note)
            else:
                services.reject_money_request(r, note)
        else:
            if request.user.id != r.requester_id:
                raise PermissionDenied('Only the requester can cancel this request.')
            services.cancel_money_request(r)
        return Response(s.money_request(self.get_object(pk), request.user))


# ============================================================
# NET WORTH / ASSETS
# ============================================================

class NetWorthView(HouseholdAPIView):
    def get(self, request):
        h = self.household
        return Response({
            **s.networth(services.compute_net_worth(h)),
            'assets': [s.asset(a) for a in h.assets.select_related('currency')],
            'liabilities': [s.liability(l) for l in h.liabilities.select_related('currency')],
            'snapshots': [s.snapshot(x) for x in reversed(list(h.snapshots.all()[:24]))],
        })


class NetWorthSnapshotView(HouseholdAPIView):
    def post(self, request):
        return created(s.snapshot(services.save_networth_snapshot(self.household)))


class _DefaultCurrencyMixin:
    """Fill a blank currency with the household base currency on create."""

    def perform_create(self, form):
        obj = form.save(commit=False)
        obj.household = self.household
        if not obj.currency:
            obj.currency = self.household.base_currency
        obj.save()
        form.save_m2m()
        return obj


class AssetListView(_DefaultCurrencyMixin, CrudListView):
    model = Asset
    form_class = AssetForm
    serialize = staticmethod(s.asset)
    pass_household_to_form = False


class AssetDetailView(CrudDetailView):
    model = Asset
    form_class = AssetForm
    serialize = staticmethod(s.asset)
    pass_household_to_form = False


# ============================================================
# DEBTS (liabilities) + payments
# ============================================================

class DebtListView(_DefaultCurrencyMixin, CrudListView):
    model = Liability
    form_class = LiabilityForm
    serialize = staticmethod(s.liability)
    pass_household_to_form = False

    def get(self, request):
        rows = [s.liability(l) for l in self.get_queryset().select_related('currency')]
        total_balance = sum((l.balance for l in self.get_queryset()), 0)
        total_paid = LiabilityPayment.objects.filter(
            liability__household=self.household).aggregate(t=Sum('amount'))['t'] or 0
        return Response({'results': rows, 'total_balance': s.money(total_balance),
                         'total_paid': s.money(total_paid)})


class DebtDetailView(CrudDetailView):
    model = Liability
    form_class = LiabilityForm
    serialize = staticmethod(lambda l: s.liability(l, with_payments=True))
    pass_household_to_form = False


class DebtPaymentCreateView(HouseholdAPIView):
    def post(self, request, pk):
        liab = self.get_owned(Liability, pk)
        form = validated_form(LiabilityPaymentForm, request.data,
                              household=self.household, liability=liab)
        services.record_liability_payment(
            liab, form.save(commit=False), request.user,
            record_as_expense=form.cleaned_data.get('record_as_expense'),
            expense_category=form.cleaned_data.get('expense_category'),
        )
        liab.refresh_from_db()
        return created(s.liability(liab, with_payments=True))


class DebtPaymentDeleteView(HouseholdAPIView):
    def delete(self, request, pk, payment_pk):
        liab = self.get_owned(Liability, pk)
        payment = LiabilityPayment.objects.filter(pk=payment_pk, liability=liab).first()
        if payment is None:
            raise NotFound()
        services.delete_liability_payment(liab, payment)
        liab.refresh_from_db()
        return Response(s.liability(liab, with_payments=True))


# ============================================================
# LENT (receivables) + repayments
# ============================================================

class LentListView(CrudListView):
    model = Receivable
    form_class = ReceivableForm
    serialize = staticmethod(s.receivable)

    def get(self, request):
        items = list(self.get_queryset().select_related('currency'))
        received = ReceivablePayment.objects.filter(
            receivable__household=self.household).aggregate(t=Sum('amount'))['t'] or 0
        return Response({
            'results': [s.receivable(r) for r in items],
            'total_outstanding': s.money(sum((r.balance for r in items
                                              if r.status == Receivable.STATUS_ACTIVE), 0)),
            'total_received': s.money(received),
            'overdue_count': sum(1 for r in items if r.is_overdue),
        })

    def perform_create(self, form):
        r = form.save(commit=False)
        r.household = self.household
        return services.create_receivable(
            r, self.request.user, record_as_expense=form.cleaned_data.get('record_as_expense'))


class LentDetailView(CrudDetailView):
    model = Receivable
    form_class = ReceivableForm
    serialize = staticmethod(lambda r: s.receivable(r, with_payments=True))


class LentPaymentCreateView(HouseholdAPIView):
    def post(self, request, pk):
        rec = self.get_owned(Receivable, pk)
        form = validated_form(ReceivablePaymentForm, request.data,
                              household=self.household, receivable=rec)
        services.record_receivable_payment(
            rec, form.save(commit=False), request.user,
            record_as_income=form.cleaned_data.get('record_as_income'),
        )
        rec.refresh_from_db()
        return created(s.receivable(rec, with_payments=True))


class LentPaymentDeleteView(HouseholdAPIView):
    def delete(self, request, pk, payment_pk):
        rec = self.get_owned(Receivable, pk)
        payment = ReceivablePayment.objects.filter(pk=payment_pk, receivable=rec).first()
        if payment is None:
            raise NotFound()
        services.delete_receivable_payment(rec, payment)
        rec.refresh_from_db()
        return Response(s.receivable(rec, with_payments=True))


# ============================================================
# GOALS
# ============================================================

class GoalListView(_DefaultCurrencyMixin, CrudListView):
    model = Goal
    form_class = GoalForm
    serialize = staticmethod(s.goal)

    def get_queryset(self):
        return self.household.goals.select_related('currency')


class GoalDetailView(CrudDetailView):
    model = Goal
    form_class = GoalForm
    serialize = staticmethod(lambda g: s.goal(g, with_contributions=True))


class GoalContributionCreateView(HouseholdAPIView):
    def post(self, request, pk):
        goal = self.get_owned(Goal, pk)
        form = validated_form(GoalContributionForm, request.data)
        services.record_goal_contribution(
            goal, form.save(commit=False), request.user,
            record_as_expense=form.cleaned_data.get('record_as_expense'),
        )
        goal.refresh_from_db()
        return created(s.goal(goal, with_contributions=True))


class GoalContributionDeleteView(HouseholdAPIView):
    def delete(self, request, pk, contrib_pk):
        goal = self.get_owned(Goal, pk)
        contrib = GoalContribution.objects.filter(pk=contrib_pk, goal=goal).first()
        if contrib is None:
            raise NotFound()
        services.delete_goal_contribution(goal, contrib)
        goal.refresh_from_db()
        return Response(s.goal(goal, with_contributions=True))


# ============================================================
# PROJECTS
# ============================================================

class ProjectListView(_DefaultCurrencyMixin, CrudListView):
    model = Project
    form_class = ProjectForm
    serialize = staticmethod(s.project)

    def get_queryset(self):
        return self.household.projects.select_related('currency')


class ProjectDetailView(CrudDetailView):
    model = Project
    form_class = ProjectForm
    serialize = staticmethod(lambda p: s.project(p, with_transactions=True))


# ============================================================
# CURRENCIES & RATES
# ============================================================

class CurrencyListView(HouseholdAPIView):
    # Readable before joining a household so setup can offer a base currency.
    requires_household = False

    def get(self, request):
        services.ensure_default_currencies()
        return Response({
            'currencies': [s.currency(c) for c in Currency.objects.all()],
            'rates': [s.exchange_rate(r) for r in
                      ExchangeRate.objects.select_related('from_currency', 'to_currency')],
        })

    def post(self, request):
        if self.household is None:
            raise NoHousehold()
        form = validated_form(CurrencyForm, request.data)
        return created(s.currency(form.save()))


class ExchangeRateCreateView(HouseholdAPIView):
    def post(self, request):
        form = validated_form(ExchangeRateForm, request.data)
        cd = form.cleaned_data
        if cd['from_currency'] == cd['to_currency']:
            raise ValidationError({'to_currency': ['Pick two different currencies.']})
        rate = services.save_exchange_rate(self.household, cd['from_currency'],
                                           cd['to_currency'], cd['rate'])
        return created(s.exchange_rate(rate))


# ============================================================
# REPORTS
# ============================================================

class MonthlyReportView(HouseholdAPIView):
    def get(self, request):
        year, month = _month_param(request)
        today = timezone.now().date()
        data = s.monthly_report(services.monthly_report_data(self.household, year, month))
        data['is_current_month'] = (year, month) == (today.year, today.month)
        return Response(data)


class MonthlyReportCSVView(HouseholdAPIView):
    def get(self, request, year, month):
        try:
            target = date(year, month, 1)
        except ValueError:
            raise NotFound()
        month_start, month_end = services.month_range(target)
        response = HttpResponse(content_type='text/csv')
        response['Content-Disposition'] = f'attachment; filename="report_{year}-{month:02d}.csv"'
        qs = self.household.transactions.filter(
            date__gte=month_start, date__lte=month_end
        ).select_related('user', 'category', 'currency', 'project').order_by('date')
        services.write_transactions_csv(response, qs, include_project=True)
        return response


# ============================================================
# CHAT
# ============================================================

class ChatView(HouseholdAPIView):
    def get(self, request):
        """Newest ``limit`` messages (oldest-first). ``before=<id>`` pages back,
        ``after=<id>`` fetches only newer ones (for catching up after a
        reconnect). Fetching the latest page marks the chat read."""
        qs = self.household.chat_messages.select_related('sender')
        try:
            limit = max(1, min(int(request.query_params.get('limit', 50)), 200))
            before = request.query_params.get('before')
            after = request.query_params.get('after')
            if before:
                qs = qs.filter(id__lt=int(before))
            if after:
                qs = qs.filter(id__gt=int(after))
        except ValueError:
            raise ValidationError({'non_field_errors': ['Invalid paging parameter.']})
        page = list(qs.order_by('-id')[:limit + 1])
        has_more = len(page) > limit
        page = list(reversed(page[:limit]))
        if not before:
            services.mark_chat_read(self.household, request.user)
        return Response({'results': [s.chat_message(m) for m in page], 'has_more': has_more})

    def post(self, request):
        body = (request.data.get('body') or '').strip()
        if not body:
            raise ValidationError({'body': ['Message is empty.']})
        msg = services.send_chat_message(self.household, request.user, body)
        return created(s.chat_message(msg))


class ChatReadView(HouseholdAPIView):
    def post(self, request):
        services.mark_chat_read(self.household, request.user)
        return no_content()


# ============================================================
# MEETINGS & AGREEMENT ITEMS
# ============================================================

class MeetingListView(CrudListView):
    model = Meeting
    form_class = MeetingForm
    serialize = staticmethod(s.meeting)

    def get_queryset(self):
        return self.household.meetings.prefetch_related('agreements', 'participants')

    def get(self, request):
        today = timezone.now().date()
        open_items = AgreementItem.objects.filter(meeting__household=self.household).exclude(
            status__in=[AgreementItem.STATUS_DONE, AgreementItem.STATUS_CANCELLED])
        suggested = services.suggest_next_meeting_date(self.household)
        return Response({
            'results': [s.meeting(m) for m in self.get_queryset()],
            'open_count': open_items.count(),
            'overdue_count': open_items.filter(target_date__lt=today).count(),
            'next_suggested_date': suggested.isoformat(),
            'next_suggested_title': f"Q{((suggested.month - 1) // 3) + 1} {suggested.year} Review",
        })

    def post(self, request):
        data = _data(request)
        if 'participants' not in data:  # web form pre-ticks every member
            data['participants'] = list(self.household.members.values_list('pk', flat=True))
        if 'carry_over_open_items' not in data:
            data['carry_over_open_items'] = True
        form = validated_form(MeetingForm, data, household=self.household)
        m = form.save(commit=False)
        m.household = self.household
        services.snapshot_meeting_state(m)
        m.save()
        form.save_m2m()
        carried = 0
        if form.cleaned_data.get('carry_over_open_items') and form._previous_meeting:
            carried = services.carry_over_open_items(form._previous_meeting, m)
        return created({**s.meeting(m, with_items=True), 'carried_over': carried})


class MeetingDetailView(CrudDetailView):
    model = Meeting
    form_class = MeetingForm
    serialize = staticmethod(lambda m: s.meeting(m, with_items=True))


class AgreementCreateView(HouseholdAPIView):
    def post(self, request, pk):
        meeting = self.get_owned(Meeting, pk)
        form = validated_form(AgreementItemForm, request.data, household=self.household)
        item = form.save(commit=False)
        item.meeting = meeting
        services.normalize_agreement_completion(item)
        item.save()
        return created(s.agreement(item))


class AgreementDetailView(HouseholdAPIView):
    def get_item(self, pk, item_pk):
        meeting = self.get_owned(Meeting, pk)
        item = AgreementItem.objects.filter(pk=item_pk, meeting=meeting).first()
        if item is None:
            raise NotFound()
        return item

    def patch(self, request, pk, item_pk):
        item = self.get_item(pk, item_pk)
        form = bind_form(AgreementItemForm, request.data, instance=item, household=self.household)
        if not form.is_valid():
            form_error(form)
        item = form.save(commit=False)
        services.normalize_agreement_completion(item)
        item.save()
        return Response(s.agreement(item))

    def delete(self, request, pk, item_pk):
        self.get_item(pk, item_pk).delete()
        return no_content()


class AgreementQuickUpdateView(AgreementDetailView):
    def post(self, request, pk, item_pk):
        item = services.quick_update_agreement(
            self.get_item(pk, item_pk),
            request.data.get('status'), request.data.get('progress'),
        )
        return Response(s.agreement(item))
