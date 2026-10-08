"""Tests for the mobile JSON API (/api/v1/) and the web views that now share
its service layer."""
from contextlib import contextmanager
from datetime import date, timedelta
from decimal import Decimal
from unittest import mock

from asgiref.sync import async_to_sync
from django.contrib.auth.models import User
from django.core.cache import cache
from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import Client, TestCase, TransactionTestCase, override_settings
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from .models import (
    AgreementItem, Alert, Category, Currency, DeviceToken, ExchangeRate, Goal,
    Household, HouseholdInvitation, Liability, Meeting, MoneyRequest, Receivable,
    RecurringTransaction, Transaction,
)
from .services import seed_household_defaults

NO_THROTTLE = {
    'REST_FRAMEWORK': {
        'DEFAULT_AUTHENTICATION_CLASSES': ['rest_framework.authentication.TokenAuthentication'],
        'DEFAULT_PERMISSION_CLASSES': ['rest_framework.permissions.IsAuthenticated'],
        'DEFAULT_RENDERER_CLASSES': ['rest_framework.renderers.JSONRenderer'],
        'DEFAULT_PARSER_CLASSES': ['rest_framework.parsers.JSONParser',
                                   'rest_framework.parsers.MultiPartParser'],
        'DEFAULT_THROTTLE_CLASSES': [],
        'DEFAULT_THROTTLE_RATES': {'auth': None},
    }
}


def make_household(name, *users):
    h = Household.objects.create(name=name)
    for u in users:
        h.members.add(u)
    seed_household_defaults(h)
    return h


@contextmanager
def captured_push():
    """Record what would go to Firebase instead of sending it.

    Pretends a service-account key is configured, so the device-push half of
    ``push_to_household`` runs, and collects its arguments.
    """
    sent = []

    def capture(users, title, body, data=None, thread_id=None):
        sent.append({
            'users': sorted(getattr(u, 'pk', u) for u in users),
            'title': title, 'body': body,
            'data': data or {}, 'thread_id': thread_id,
        })

    with override_settings(FCM_CREDENTIALS_FILE='/not/a/real/key.json'),             mock.patch('budget_app.push.send_to_users', side_effect=capture):
        yield sent


def api_for(user):
    c = APIClient()
    c.credentials(HTTP_AUTHORIZATION='Token ' + Token.objects.get_or_create(user=user)[0].key)
    return c


@override_settings(**NO_THROTTLE)
class APITestBase(TestCase):
    def setUp(self):
        cache.clear()
        self.alice = User.objects.create_user('alice', 'a@example.com', 'pw-alice-123')
        self.bob = User.objects.create_user('bob', 'b@example.com', 'pw-bob-123')
        self.hh = make_household('Home', self.alice, self.bob)
        self.a = api_for(self.alice)
        self.b = api_for(self.bob)
        self.usd = Currency.objects.get(code='USD')
        self.tzs = Currency.objects.get(code='TZS')
        self.groceries = Category.objects.get(household=self.hh, name='Groceries')
        self.salary = Category.objects.get(household=self.hh, name='Salary')

    def ok(self, resp, code=200):
        self.assertEqual(resp.status_code, code, getattr(resp, 'data', resp.content))
        return resp.data if hasattr(resp, 'data') else resp

    def add_tx(self, client=None, **kw):
        body = {'transaction_type': 'expense', 'amount': '25.50', 'currency': self.usd.pk,
                'category': self.groceries.pk, 'date': timezone.now().date().isoformat(),
                'payee': 'Shoprite', 'description': ''}
        body.update(kw)
        return self.ok((client or self.a).post('/api/v1/transactions/', body, format='json'), 201)


class AuthTests(APITestBase):
    def test_login_returns_token_and_me_works(self):
        c = APIClient()
        data = self.ok(c.post('/api/v1/auth/login/',
                              {'username': 'alice', 'password': 'pw-alice-123'}, format='json'))
        c.credentials(HTTP_AUTHORIZATION='Token ' + data['token'])
        me = self.ok(c.get('/api/v1/me/'))
        self.assertEqual(me['user']['username'], 'alice')
        self.assertEqual(me['household']['id'], self.hh.id)
        self.assertEqual(set(me['badges']), {'unread_alerts', 'pending_requests', 'unread_chat'})

    def test_bad_password_is_400_without_token(self):
        r = APIClient().post('/api/v1/auth/login/',
                             {'username': 'alice', 'password': 'nope'}, format='json')
        self.assertEqual(r.status_code, 400)
        self.assertNotIn('token', r.data)

    def test_unauthenticated_requests_are_rejected(self):
        self.assertEqual(APIClient().get('/api/v1/transactions/').status_code, 401)

    def test_logout_revokes_token(self):
        self.ok(self.a.post('/api/v1/auth/logout/'), 204)
        self.assertEqual(self.a.get('/api/v1/me/').status_code, 401)

    def test_signup_then_create_household(self):
        c = APIClient()
        data = self.ok(c.post('/api/v1/auth/signup/', {
            'username': 'carol', 'email': 'c@example.com',
            'password1': 'sup3r-s3cret-pw', 'password2': 'sup3r-s3cret-pw',
        }, format='json'), 201)
        c.credentials(HTTP_AUTHORIZATION='Token ' + data['token'])
        self.assertIsNone(self.ok(c.get('/api/v1/me/'))['household'])
        self.assertGreaterEqual(len(self.ok(c.get('/api/v1/currencies/'))['currencies']), 5)
        self.assertEqual(c.post('/api/v1/currencies/', {'code': 'ZAR', 'name': 'Rand',
                                                         'symbol': 'R'}, format='json').status_code, 409)
        # Household-scoped endpoints say why they can't answer
        self.assertEqual(c.get('/api/v1/dashboard/').status_code, 409)
        hh = self.ok(c.post('/api/v1/household/', {'name': 'Carol Home',
                                                   'base_currency': self.tzs.pk},
                            format='json'), 201)
        self.assertEqual(hh['base_currency']['code'], 'TZS')
        self.assertEqual(len(self.ok(c.get('/api/v1/meta/'))['categories']), 12)

    def test_signup_validation_errors_are_per_field(self):
        r = APIClient().post('/api/v1/auth/signup/', {
            'username': 'alice', 'email': 'x', 'password1': 'a', 'password2': 'b'}, format='json')
        self.assertEqual(r.status_code, 400)
        self.assertIn('username', r.data)
        self.assertIn('email', r.data)

    def test_signup_with_invite_joins_household_directly(self):
        inv = self.ok(self.a.post('/api/v1/household/invites/', {'note': 'for dan'},
                                  format='json'), 201)
        c = APIClient()
        data = self.ok(c.post('/api/v1/auth/signup/', {
            'username': 'dan', 'email': 'd@example.com',
            'password1': 'sup3r-s3cret-pw', 'password2': 'sup3r-s3cret-pw',
            'invite': inv['code'],
        }, format='json'), 201)
        c.credentials(HTTP_AUTHORIZATION='Token ' + data['token'])
        self.assertEqual(self.ok(c.get('/api/v1/me/'))['household']['id'], self.hh.id)
        self.assertEqual(HouseholdInvitation.objects.get(code=inv['code']).status, 'accepted')

    def test_join_with_pasted_url(self):
        carol = User.objects.create_user('carol', 'c@example.com', 'pw')
        make_household('Carol stub', carol)  # empty signup stub
        inv = HouseholdInvitation.objects.create(
            household=self.hh, code=HouseholdInvitation.generate_code(), invited_by=self.alice)
        c = api_for(carol)
        self.ok(c.post('/api/v1/household/join/',
                       {'code': f'https://budget.hotone.co.tz/join/{inv.code}/'}, format='json'))
        self.assertEqual(self.ok(c.get('/api/v1/me/'))['household']['id'], self.hh.id)
        self.assertFalse(Household.objects.filter(name='Carol stub').exists())
        r = c.post('/api/v1/household/join/', {'code': inv.code}, format='json')
        self.assertEqual(r.status_code, 400)


class HouseholdIsolationTests(APITestBase):
    def setUp(self):
        super().setUp()
        self.eve = User.objects.create_user('eve', 'e@example.com', 'pw')
        self.other = make_household('Other', self.eve)
        self.e = api_for(self.eve)

    def test_cannot_read_or_edit_another_households_rows(self):
        tx = self.add_tx()
        for method in ('get', 'patch', 'delete'):
            r = getattr(self.e, method)(f"/api/v1/transactions/{tx['id']}/", {}, format='json')
            self.assertEqual(r.status_code, 404, method)
        self.assertEqual(self.ok(self.e.get('/api/v1/transactions/'))['count'], 0)

    def test_cannot_use_another_households_category(self):
        r = self.e.post('/api/v1/transactions/', {
            'transaction_type': 'expense', 'amount': '1', 'date': '2026-01-01',
            'category': self.groceries.pk}, format='json')
        self.assertEqual(r.status_code, 400)
        self.assertIn('category', r.data)

    def test_alerts_for_partner_are_hidden(self):
        Alert.objects.create(household=self.hh, user=self.bob, title='for bob only')
        Alert.objects.create(household=self.hh, title='for everyone')
        titles = [a['title'] for a in self.ok(self.a.get('/api/v1/alerts/'))['results']]
        self.assertIn('for everyone', titles)
        self.assertNotIn('for bob only', titles)


class TransactionTests(APITestBase):
    def test_crud_and_base_conversion(self):
        ExchangeRate.objects.create(from_currency=self.usd, to_currency=self.tzs, rate=Decimal('2500'))
        self.hh.base_currency = self.tzs
        self.hh.save()
        tx = self.add_tx(amount='10.00')
        self.assertEqual(tx['amount_base'], '25000.00')
        self.assertEqual(tx['user']['username'], 'alice')

        tx = self.ok(self.b.patch(f"/api/v1/transactions/{tx['id']}/", {'amount': '2'},
                                  format='json'))
        self.assertEqual(tx['amount'], '2.00')
        self.assertEqual(tx['amount_base'], '5000.00')
        self.assertEqual(tx['payee'], 'Shoprite')  # untouched by partial update

        self.ok(self.a.delete(f"/api/v1/transactions/{tx['id']}/"), 204)
        self.assertFalse(Transaction.objects.exists())

    def test_validation_error_shape(self):
        r = self.a.post('/api/v1/transactions/', {'transaction_type': 'expense'}, format='json')
        self.assertEqual(r.status_code, 400)
        self.assertIn('amount', r.data)
        self.assertIsInstance(r.data['amount'], list)

    def test_filters_paging_and_totals(self):
        self.add_tx(payee='TotalEnergies', amount='40')
        self.add_tx(payee='Shoprite', amount='10')
        self.add_tx(transaction_type='income', category=self.salary.pk, amount='100', payee='Work')
        data = self.ok(self.a.get('/api/v1/transactions/?type=expense&page_size=1'))
        self.assertEqual(data['count'], 2)
        self.assertTrue(data['has_next'])
        self.assertEqual(len(data['results']), 1)
        self.assertEqual(data['totals'], {'expense': '50.00'})
        self.assertEqual(self.ok(self.a.get('/api/v1/transactions/?q=total'))['count'], 1)
        self.assertEqual(self.a.get('/api/v1/transactions/?member=abc').status_code, 400)

    def test_rules_categorize_new_transactions(self):
        fuel = Category.objects.get(household=self.hh, name='Fuel')
        self.ok(self.a.post('/api/v1/rules/', {'pattern': 'total', 'match_type': 'contains',
                                               'category': fuel.pk, 'priority': 1,
                                               'is_active': True}, format='json'), 201)
        tx = self.add_tx(category=None, payee='TotalEnergies Mbezi')
        self.assertEqual(Transaction.objects.get(pk=tx['id']).category, fuel)

    def test_csv_round_trip(self):
        self.add_tx(amount='12.34')
        csv_bytes = self.a.get('/api/v1/transactions/export/').content
        self.assertIn(b'12.34', csv_bytes)
        upload = SimpleUploadedFile('t.csv', csv_bytes + b'not-a-date,expense,1,,,,,,,\n',
                                    content_type='text/csv')
        result = self.ok(self.a.post('/api/v1/transactions/import/', {'file': upload},
                                     format='multipart'))
        self.assertEqual(result['created'], 1)
        self.assertEqual(len(result['errors']), 1)
        self.assertEqual(Transaction.objects.count(), 2)


class BudgetCategoryTests(APITestBase):
    def test_budget_progress_and_alert(self):
        b = self.ok(self.a.post('/api/v1/budgets/', {
            'category': self.groceries.pk, 'monthly_limit': '100',
            'month': timezone.now().date().isoformat()}, format='json'), 201)
        self.assertEqual(b['month'], timezone.now().date().replace(day=1).isoformat())
        self.add_tx(amount='85')
        rows = self.ok(self.a.get('/api/v1/budgets/'))
        self.assertEqual(rows[0]['spent'], '85.00')
        self.assertEqual(rows[0]['pct'], 85.0)
        self.assertTrue(Alert.objects.filter(title__startswith='Approaching budget').exists())
        dup = self.a.post('/api/v1/budgets/', {
            'category': self.groceries.pk, 'monthly_limit': '5',
            'month': timezone.now().date().isoformat()}, format='json')
        self.assertEqual(dup.status_code, 400)

    def test_duplicate_category_is_400_not_500(self):
        r = self.a.post('/api/v1/categories/', {'name': 'Groceries', 'category_type': 'expense',
                                                'color': '#000000', 'icon': 'bi-tag'},
                        format='json')
        self.assertEqual(r.status_code, 400)
        self.ok(self.a.post('/api/v1/categories/', {'name': 'Pets', 'category_type': 'expense',
                                                    'color': '#000000', 'icon': 'bi-tag'},
                            format='json'), 201)


class MoneyRequestTests(APITestBase):
    def _request(self):
        return self.ok(self.a.post('/api/v1/requests/', {
            'approver': self.bob.pk, 'amount': '30', 'currency': self.usd.pk,
            'purpose': 'School fees', 'category': self.groceries.pk}, format='json'), 201)

    def test_approve_creates_one_expense_for_requester(self):
        r = self._request()
        self.assertTrue(r['can_cancel'])
        self.assertEqual(self.ok(self.b.get('/api/v1/me/'))['badges']['pending_requests'], 1)
        self.assertEqual(self.a.post(f"/api/v1/requests/{r['id']}/approve/").status_code, 403)
        r = self.ok(self.b.post(f"/api/v1/requests/{r['id']}/approve/", {'note': 'ok'},
                                format='json'))
        self.assertEqual(r['status'], 'approved')
        tx = Transaction.objects.get()
        self.assertEqual((tx.user, tx.transaction_type, tx.source),
                         (self.alice, 'expense', 'request'))
        again = self.b.post(f"/api/v1/requests/{r['id']}/approve/")
        self.assertEqual(again.status_code, 400)

    def test_reject_and_cancel(self):
        r = self._request()
        self.ok(self.b.post(f"/api/v1/requests/{r['id']}/reject/", {'note': 'no'}, format='json'))
        self.assertEqual(MoneyRequest.objects.get().status, 'rejected')
        r = self._request()
        self.assertEqual(self.b.post(f"/api/v1/requests/{r['id']}/cancel/").status_code, 403)
        self.ok(self.a.post(f"/api/v1/requests/{r['id']}/cancel/"))
        self.assertFalse(Transaction.objects.exists())

    def test_cannot_request_from_yourself(self):
        r = self.a.post('/api/v1/requests/', {'approver': self.alice.pk, 'amount': '1',
                                              'purpose': 'x'}, format='json')
        self.assertEqual(r.status_code, 400)
        self.assertIn('approver', r.data)


class DebtLentGoalTests(APITestBase):
    def test_debt_payment_and_undo(self):
        d = self.ok(self.a.post('/api/v1/debts/', {'name': 'Car loan', 'liability_type': 'loan',
                                                   'balance': '1000'}, format='json'), 201)
        self.assertEqual(d['currency']['code'], 'USD')  # defaulted to base currency
        d = self.ok(self.a.post(f"/api/v1/debts/{d['id']}/payments/", {
            'date': '2026-09-01', 'amount': '250', 'record_as_expense': True}, format='json'), 201)
        self.assertEqual(d['balance'], '750.00')
        self.assertEqual(d['paid'], '250.00')
        self.assertTrue(Transaction.objects.filter(category__name='Debt Payment').exists())
        pid = d['payments'][0]['id']
        d = self.ok(self.a.delete(f"/api/v1/debts/{d['id']}/payments/{pid}/"))
        self.assertEqual(d['balance'], '1000.00')
        self.assertFalse(Transaction.objects.exists())
        listing = self.ok(self.a.get('/api/v1/debts/'))
        self.assertEqual(listing['total_balance'], '1000.00')

    def test_lent_repayment_marks_paid(self):
        r = self.ok(self.a.post('/api/v1/lent/', {
            'debtor_name': 'Juma', 'balance': '100', 'lent_date': '2026-08-01',
            'status': 'active', 'record_as_expense': True}, format='json'), 201)
        self.assertEqual(r['original_amount'], '100.00')
        r = self.ok(self.a.post(f"/api/v1/lent/{r['id']}/repayments/", {
            'date': '2026-09-01', 'amount': '100', 'record_as_income': True}, format='json'), 201)
        self.assertEqual(r['status'], 'paid')
        self.assertEqual(Receivable.objects.get().balance, 0)
        self.assertEqual(Transaction.objects.count(), 2)  # lent expense + repayment income

    def test_goal_contribution_reaches_target(self):
        g = self.ok(self.a.post('/api/v1/goals/', {
            'name': 'Trip', 'target_amount': '200', 'icon': 'bi-airplane',
            'color': '#0d6efd', 'status': 'active'}, format='json'), 201)
        g = self.ok(self.a.post(f"/api/v1/goals/{g['id']}/contributions/", {
            'amount': '200', 'date': '2026-09-02'}, format='json'), 201)
        self.assertEqual(g['status'], 'achieved')
        self.assertEqual(g['progress_percent'], 100)
        cid = g['contributions'][0]['id']
        g = self.ok(self.a.delete(f"/api/v1/goals/{g['id']}/contributions/{cid}/"))
        self.assertEqual(g['current_amount'], '0.00')

    def test_networth_and_snapshot(self):
        self.ok(self.a.post('/api/v1/assets/', {'name': 'Bank', 'asset_type': 'bank',
                                                'value': '5000'}, format='json'), 201)
        self.ok(self.a.post('/api/v1/debts/', {'name': 'Card', 'liability_type': 'credit_card',
                                               'balance': '1000'}, format='json'), 201)
        nw = self.ok(self.a.get('/api/v1/networth/'))
        self.assertEqual(nw['net_worth'], '4000.00')
        snap = self.ok(self.a.post('/api/v1/networth/snapshot/'), 201)
        self.assertEqual(snap['net_worth'], '4000.00')


class MeetingChatRecurringTests(APITestBase):
    def test_meeting_items_and_carry_over(self):
        m1 = self.ok(self.a.post('/api/v1/meetings/', {
            'title': 'Q1', 'meeting_date': '2026-01-10', 'status': 'held'}, format='json'), 201)
        self.assertEqual(len(m1['participants']), 2)  # defaults to all members
        item = self.ok(self.a.post(f"/api/v1/meetings/{m1['id']}/items/", {
            'title': 'Open savings account', 'status': 'open', 'progress': 0,
            'priority': 'high'}, format='json'), 201)
        self.ok(self.a.post(f"/api/v1/meetings/{m1['id']}/items/", {
            'title': 'Done thing', 'status': 'done', 'progress': 0,
            'priority': 'normal'}, format='json'), 201)
        bad = self.a.post(f"/api/v1/meetings/{m1['id']}/items/", {
            'title': 'x', 'status': 'open', 'progress': 150, 'priority': 'low'}, format='json')
        self.assertIn('progress', bad.data)
        m2 = self.ok(self.a.post('/api/v1/meetings/', {
            'title': 'Q2', 'meeting_date': '2026-04-10', 'status': 'planned'}, format='json'), 201)
        self.assertEqual(m2['carried_over'], 1)
        q = self.ok(self.a.post(f"/api/v1/meetings/{m1['id']}/items/{item['id']}/quick/",
                                {'progress': 100}, format='json'))
        self.assertEqual(q['status'], 'done')
        self.assertIsNotNone(q['completed_date'])
        listing = self.ok(self.a.get('/api/v1/meetings/'))
        self.assertEqual(listing['next_suggested_date'], '2026-07-10')

    def test_chat_send_page_and_unread(self):
        for i in range(5):
            self.ok(self.a.post('/api/v1/chat/', {'body': f'msg {i}'}, format='json'), 201)
        self.assertEqual(self.ok(self.b.get('/api/v1/me/'))['badges']['unread_chat'], 5)
        page = self.ok(self.b.get('/api/v1/chat/?limit=2'))
        self.assertEqual([m['body'] for m in page['results']], ['msg 3', 'msg 4'])
        self.assertTrue(page['has_more'])
        older = self.ok(self.b.get(f"/api/v1/chat/?limit=10&before={page['results'][0]['id']}"))
        self.assertEqual(len(older['results']), 3)
        self.assertEqual(self.ok(self.b.get('/api/v1/me/'))['badges']['unread_chat'], 0)
        self.assertEqual(self.a.post('/api/v1/chat/', {'body': '  '}, format='json').status_code, 400)
        self.assertEqual(len(self.ok(self.a.get('/api/v1/chat/?limit=-5'))['results']), 1)

    def test_recurring_defaults_and_run_now(self):
        start = (timezone.now().date() - timedelta(days=2)).isoformat()
        r = self.ok(self.a.post('/api/v1/recurring/', {
            'name': 'Netflix', 'transaction_type': 'expense', 'amount': '15',
            'currency': self.usd.pk, 'frequency': 'monthly', 'start_date': start,
            'auto_create': True, 'is_active': True}, format='json'), 201)
        self.assertEqual(r['next_due_date'], start)
        # partial update must not flip unchecked booleans off
        r = self.ok(self.a.patch(f"/api/v1/recurring/{r['id']}/", {'amount': '16'},
                                 format='json'))
        self.assertTrue(r['auto_create'] and r['is_active'])
        out = self.ok(self.a.post('/api/v1/recurring/run-now/'))
        self.assertEqual(out['created'], 1)
        self.assertGreater(RecurringTransaction.objects.get().next_due_date,
                           timezone.now().date())

    def test_daily_tasks_run_for_token_requests(self):
        RecurringTransaction.objects.create(
            household=self.hh, user=self.alice, name='Rent', transaction_type='expense',
            amount=Decimal('500'), next_due_date=timezone.now().date())
        self.ok(self.a.get('/api/v1/me/'))
        self.assertEqual(Transaction.objects.filter(source='recurring').count(), 1)


class ReadOnlyEndpointTests(APITestBase):
    def test_summary_endpoints_render(self):
        self.add_tx()
        self.add_tx(transaction_type='income', category=self.salary.pk, amount='900')
        RecurringTransaction.objects.create(
            household=self.hh, user=self.alice, name='Rent', transaction_type='expense',
            amount=Decimal('500'), next_due_date=timezone.now().date() + timedelta(days=3))
        for url in ('/api/v1/dashboard/', '/api/v1/meta/', '/api/v1/household/',
                    '/api/v1/forecast/', '/api/v1/calendar/', '/api/v1/calendar/?year=2026&month=12',
                    '/api/v1/reports/monthly/', '/api/v1/networth/', '/api/v1/currencies/',
                    '/api/v1/alerts/', '/api/v1/requests/', '/api/v1/goals/',
                    '/api/v1/projects/', '/api/v1/lent/', '/api/v1/debts/',
                    '/api/v1/recurring/', '/api/v1/rules/', '/api/v1/categories/',
                    '/api/v1/budgets/', '/api/v1/meetings/', '/api/v1/chat/'):
            self.ok(self.a.get(url))
        dash = self.ok(self.a.get('/api/v1/dashboard/'))
        self.assertEqual(dash['balance'], '874.50')
        self.assertEqual(len(dash['members']), 2)
        report = self.ok(self.a.get('/api/v1/reports/monthly/'))
        self.assertEqual(report['by_category'][0]['name'], 'Groceries')
        self.assertTrue(report['is_current_month'])
        today = timezone.now().date()
        csv = self.a.get(f'/api/v1/reports/monthly/{today.year}/{today.month}/csv/')
        self.assertEqual(csv.status_code, 200)
        self.assertEqual(self.a.get('/api/v1/calendar/?month=13').status_code, 400)


class WebViewRegressionTests(TestCase):
    """The web views now delegate to services; make sure each still works."""

    def setUp(self):
        self.alice = User.objects.create_user('alice', 'a@example.com', 'pw')
        self.bob = User.objects.create_user('bob', 'b@example.com', 'pw')
        self.hh = make_household('Home', self.alice, self.bob)
        self.ca, self.cb = Client(), Client()
        self.ca.force_login(self.alice)
        self.cb.force_login(self.bob)
        self.groceries = Category.objects.get(household=self.hh, name='Groceries')

    def test_every_page_renders(self):
        Transaction.objects.create(household=self.hh, user=self.alice, transaction_type='expense',
                                   amount=Decimal('5'), category=self.groceries)
        for url in ('/', '/transactions/', '/categories/', '/budgets/', '/recurring/',
                    '/calendar/', '/rules/', '/alerts/', '/requests/', '/networth/', '/debts/',
                    '/lent/', '/goals/', '/projects/', '/currencies/', '/forecast/',
                    '/reports/', '/chat/', '/chat/recent/', '/meetings/', '/meetings/new/',
                    '/household/settings/', '/export/csv/', '/reports/2026/9/csv/'):
            self.assertEqual(self.ca.get(url).status_code, 200, url)

    def test_web_actions_use_shared_services(self):
        mr = MoneyRequest.objects.create(household=self.hh, requester=self.alice,
                                         approver=self.bob, amount=Decimal('10'), purpose='x')
        self.cb.post(f'/requests/{mr.pk}/', {'action': 'approve'})
        self.assertEqual(MoneyRequest.objects.get().status, 'approved')

        debt = Liability.objects.create(household=self.hh, name='Loan', balance=Decimal('100'))
        self.ca.post(f'/debts/{debt.pk}/payments/new/',
                     {'date': '2026-09-01', 'amount': '40', 'record_as_expense': 'on'})
        self.assertEqual(Liability.objects.get().balance, Decimal('60'))

        goal = Goal.objects.create(household=self.hh, name='G', target_amount=Decimal('10'))
        self.ca.post(f'/goals/{goal.pk}/contribute/', {'amount': '10', 'date': '2026-09-01'})
        self.assertEqual(Goal.objects.get().status, 'achieved')

        self.ca.post('/lent/new/', {'debtor_name': 'J', 'balance': '50',
                                    'lent_date': '2026-09-01', 'status': 'active'})
        rec = Receivable.objects.get()
        self.ca.post(f'/lent/{rec.pk}/repayments/new/',
                     {'date': '2026-09-02', 'amount': '50'})
        self.assertEqual(Receivable.objects.get().status, 'paid')

        self.ca.post('/meetings/new/', {'title': 'M', 'meeting_date': '2026-09-01',
                                        'status': 'planned', 'participants': [self.alice.pk]})
        m = Meeting.objects.get()
        self.assertIsNotNone(m.net_worth_snapshot)
        self.ca.post(f'/meetings/{m.pk}/items/new/', {'title': 'I', 'status': 'done',
                                                      'progress': 0, 'priority': 'normal'})
        self.assertEqual(AgreementItem.objects.get().progress, 100)

        self.ca.post('/chat/send/', {'body': 'hi'})
        self.assertEqual(self.hh.chat_messages.count(), 1)

        upload = SimpleUploadedFile('t.csv', 'date,type,amount\n2026-09-01,expense,3\n'.encode(),
                                    content_type='text/csv')
        resp = self.ca.post('/import/csv/', {'file': upload})
        self.assertEqual(resp.context['result']['created'], 1)

        self.ca.post('/currencies/rates/new/', {'from_currency': Currency.objects.get(code='EUR').pk,
                                                'to_currency': Currency.objects.get(code='USD').pk,
                                                'rate': '1.1'})
        self.assertTrue(ExchangeRate.objects.exists())


@override_settings(CHANNEL_LAYERS={'default': {'BACKEND': 'channels.layers.InMemoryChannelLayer'}})
class WebSocketTokenAuthTests(TransactionTestCase):
    def test_token_header_authenticates_and_receives_pushes(self):
        from channels.testing import WebsocketCommunicator
        from budget_project.asgi import application
        from .services import send_chat_message

        alice = User.objects.create_user('alice', 'a@example.com', 'pw')
        hh = make_household('Home', alice)
        key = Token.objects.create(user=alice).key

        async def run():
            anon = WebsocketCommunicator(application, '/ws/notify/')
            connected, _ = await anon.connect()
            assert not connected
            await anon.disconnect()

            comm = WebsocketCommunicator(application, '/ws/notify/',
                                         headers=[(b'authorization', f'Token {key}'.encode())])
            connected, _ = await comm.connect()
            assert connected
            from channels.db import database_sync_to_async
            await database_sync_to_async(send_chat_message)(hh, alice, 'hello')
            msg = await comm.receive_json_from(timeout=3)
            await comm.disconnect()
            return msg

        msg = async_to_sync(run)()
        self.assertEqual(msg['kind'], 'chat.new')
        self.assertEqual(msg['body'], 'hello')

class PushNotificationTests(APITestBase):
    """Device registration and the OS-level pushes that go with household events."""

    def register(self, client, token, platform='android'):
        return client.post('/api/v1/devices/', {'token': token, 'platform': platform},
                           format='json')

    def test_register_requires_a_token_and_a_known_platform(self):
        self.assertEqual(self.a.post('/api/v1/devices/', {}, format='json').status_code, 400)
        self.assertEqual(self.register(self.a, 'tok-1', 'symbian').status_code, 400)
        self.assertFalse(DeviceToken.objects.exists())

    def test_registering_is_idempotent_and_moves_a_token_between_accounts(self):
        self.assertEqual(self.register(self.a, 'tok-1', 'ios').status_code, 204)
        self.assertEqual(self.register(self.a, 'tok-1', 'ios').status_code, 204)
        row = DeviceToken.objects.get()
        self.assertEqual((row.user, row.platform), (self.alice, 'ios'))
        # Same handset, now signed in as Bob: the token must not push to Alice.
        self.assertEqual(self.register(self.b, 'tok-1').status_code, 204)
        row = DeviceToken.objects.get()
        self.assertEqual((row.user, row.platform), (self.bob, 'android'))

    def test_unregister_only_touches_your_own_token(self):
        self.register(self.a, 'tok-alice')
        self.register(self.b, 'tok-bob')
        self.ok(self.b.post('/api/v1/devices/unregister/', {'token': 'tok-alice'},
                            format='json'), 204)
        self.assertEqual(DeviceToken.objects.count(), 2)
        self.ok(self.a.post('/api/v1/devices/unregister/', {'token': 'tok-alice'},
                            format='json'), 204)
        self.assertEqual([r.token for r in DeviceToken.objects.all()], ['tok-bob'])

    def test_logout_drops_this_devices_registration(self):
        self.register(self.a, 'tok-1')
        self.register(self.b, 'tok-2')
        self.ok(self.a.post('/api/v1/auth/logout/', {'device_token': 'tok-1'},
                            format='json'), 204)
        self.assertEqual([r.token for r in DeviceToken.objects.all()], ['tok-2'])

    def test_a_new_request_pushes_to_the_approver_only(self):
        with captured_push() as sent:
            self.ok(self.a.post('/api/v1/requests/', {
                'approver': self.bob.pk, 'amount': '30', 'currency': self.usd.pk,
                'purpose': 'School fees'}, format='json'), 201)
        self.assertEqual(len(sent), 1)
        push = sent[0]
        self.assertEqual(push['users'], [self.bob.pk])
        self.assertEqual(push['title'], 'Money request from alice')
        self.assertIn('School fees', push['body'])
        # What the app needs to open the right screen on a tap.
        self.assertEqual(push['data']['kind'], 'request.created')
        self.assertEqual(push['data']['request_id'], MoneyRequest.objects.get().pk)

    def test_approving_and_rejecting_push_back_to_the_requester(self):
        made = self.ok(self.a.post('/api/v1/requests/', {
            'approver': self.bob.pk, 'amount': '30', 'purpose': 'Fuel'}, format='json'), 201)
        with captured_push() as sent:
            self.ok(self.b.post(f"/api/v1/requests/{made['id']}/approve/"))
        self.assertEqual([p['users'] for p in sent], [[self.alice.pk]])
        self.assertEqual(sent[0]['title'], 'Request approved by bob')

        made = self.ok(self.a.post('/api/v1/requests/', {
            'approver': self.bob.pk, 'amount': '30', 'purpose': 'Fuel'}, format='json'), 201)
        with captured_push() as sent:
            self.ok(self.b.post(f"/api/v1/requests/{made['id']}/reject/", {'note': 'later'},
                                format='json'))
        self.assertEqual(sent[0]['users'], [self.alice.pk])
        self.assertIn('later', sent[0]['body'])

    def test_a_chat_message_pushes_to_everyone_but_the_sender(self):
        with captured_push() as sent:
            self.ok(self.a.post('/api/v1/chat/', {'body': 'dinner?'}, format='json'), 201)
        self.assertEqual(len(sent), 1)
        self.assertEqual(sent[0]['users'], [self.bob.pk])
        self.assertEqual((sent[0]['title'], sent[0]['body']), ('alice', 'dinner?'))
        # One running notification per conversation rather than one per line.
        self.assertEqual(sent[0]['thread_id'], f'chat-{self.hh.id}')

    def test_cancelling_pushes_to_nobody(self):
        made = self.ok(self.a.post('/api/v1/requests/', {
            'approver': self.bob.pk, 'amount': '30', 'purpose': 'Fuel'}, format='json'), 201)
        with captured_push() as sent:
            self.ok(self.a.post(f"/api/v1/requests/{made['id']}/cancel/"))
        self.assertEqual(sent, [])

    def test_nothing_is_sent_when_firebase_is_not_configured(self):
        from . import push as push_module
        self.register(self.b, 'tok-bob')
        self.assertFalse(push_module.is_configured())
        with mock.patch.object(push_module, '_deliver') as deliver:
            # The app's own default: no credentials file, so no delivery at all.
            self.ok(self.a.post('/api/v1/requests/', {
                'approver': self.bob.pk, 'amount': '5', 'purpose': 'Airtime'}, format='json'), 201)
            push_module.send_to_users([self.bob], 'x', 'y')
        deliver.assert_not_called()


class FCMMessageTests(TestCase):
    """The wire format we hand Firebase, and how its replies are read."""

    def test_message_is_high_priority_on_our_channel(self):
        from . import push as push_module
        row = DeviceToken(token='tok-1', platform='android')
        msg = push_module._message(row, 'Title', 'Body', {'kind': 'chat.new'},
                                   'chat-7')['message']
        self.assertEqual(msg['token'], 'tok-1')
        self.assertEqual(msg['notification'], {'title': 'Title', 'body': 'Body'})
        self.assertEqual(msg['data'], {'kind': 'chat.new'})
        self.assertEqual(msg['android']['priority'], 'high')
        self.assertEqual(msg['android']['notification']['channel_id'],
                         push_module.ANDROID_CHANNEL_ID)
        # Replaces the previous notification for the same conversation.
        self.assertEqual(msg['android']['notification']['tag'], 'chat-7')
        self.assertEqual(msg['apns']['payload']['aps']['thread-id'], 'chat-7')

    def test_data_values_are_stringified_for_fcm(self):
        from . import push as push_module
        with override_settings(FCM_CREDENTIALS_FILE='/not/a/real/key.json'), \
                mock.patch.object(push_module, '_deliver') as deliver:
            worker = push_module.send_to_users([7, 7, None], 'T', 'B',
                                               data={'request_id': 12, 'link': None})
            worker.join(timeout=5)
        user_ids, title, body, data, thread_id = deliver.call_args.args
        self.assertEqual(user_ids, [7])
        self.assertEqual(data, {'request_id': '12', 'link': ''})

    def test_dead_tokens_are_recognised_and_dropped(self):
        from . import push as push_module

        class Res:
            def __init__(self, status_code, text=''):
                self.status_code, self.text = status_code, text

        with mock.patch('requests.post') as post:
            post.return_value = Res(200)
            self.assertEqual(push_module._post('u', {}, {}), 'ok')
            post.return_value = Res(404, '{"error": {"status": "NOT_FOUND"}}')
            self.assertEqual(push_module._post('u', {}, {}), 'stale')
            post.return_value = Res(500, 'backend error')
            self.assertEqual(push_module._post('u', {}, {}), 'error')
            post.side_effect = OSError('no route to host')
            self.assertEqual(push_module._post('u', {}, {}), 'error')


class AppDownloadPageTests(TestCase):
    """The public /download/ landing page and the APK it serves."""

    def test_page_and_file_are_public_and_report_no_build(self):
        c = Client()
        with override_settings(APK_PATH='/no/such/build.apk'):
            page = c.get('/download/')
            self.assertEqual(page.status_code, 200)
            self.assertContains(page, 'No build has been published yet')
            # Signing in must not be a prerequisite for installing the app.
            self.assertEqual(c.get('/download/app.apk').status_code, 404)

    def test_published_build_is_offered_and_downloads(self):
        import tempfile
        from pathlib import Path

        with tempfile.TemporaryDirectory() as tmp:
            apk = Path(tmp) / 'homebudget.apk'
            apk.write_bytes(b'PK' + b'0' * 2048)
            with override_settings(APK_PATH=str(apk), APK_VERSION='1.0.0 (3)'):
                page = Client().get('/download/')
                self.assertContains(page, 'Version 1.0.0 (3)')
                self.assertContains(page, '/download/app.apk')

                res = Client().get('/download/app.apk')
                self.assertEqual(res.status_code, 200)
                self.assertEqual(res['Content-Type'],
                                 'application/vnd.android.package-archive')
                self.assertIn('home-budget-1.0.0.apk', res['Content-Disposition'])
                self.assertEqual(b''.join(res.streaming_content), apk.read_bytes())

    def test_login_and_dashboard_offer_the_build_only_when_there_is_one(self):
        import tempfile
        from pathlib import Path

        alice = User.objects.create_user('alice', 'a@example.com', 'pw')
        make_household('Home', alice)
        signed_in = Client()
        signed_in.force_login(alice)

        with tempfile.TemporaryDirectory() as tmp:
            apk = Path(tmp) / 'homebudget.apk'
            apk.write_bytes(b'PK' + b'0' * 2048)
            with override_settings(APK_PATH=str(apk), APK_VERSION='1.0.0 (3)'):
                login = Client().get('/login/')
                self.assertContains(login, 'Download the Android app')
                self.assertContains(login, '/download/app.apk')
                self.assertContains(signed_in.get('/'), 'Download APK')

        # No build uploaded: neither page mentions it rather than linking a 404.
        with override_settings(APK_PATH='/no/such/build.apk'):
            login = Client().get('/login/')
            self.assertEqual(login.status_code, 200)
            self.assertNotContains(login, 'Download the Android app')
            dash = signed_in.get('/')
            self.assertEqual(dash.status_code, 200)
            self.assertNotContains(dash, 'Download APK')

    def test_release_metadata_survives_a_missing_file(self):
        from .services import mobile_app_release
        with override_settings(APK_PATH='/no/such/build.apk'):
            release = mobile_app_release()
        self.assertFalse(release['available'])
        self.assertIsNone(release['size_mb'])
