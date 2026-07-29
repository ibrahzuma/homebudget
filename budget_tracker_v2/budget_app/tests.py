from django.contrib.auth.models import User
from django.test import TestCase, Client
from django.utils import timezone

from .models import (Household, HouseholdInvitation, MoneyRequest, Transaction,
                     Category, resolve_user_household)


class PartnerVisibilityTests(TestCase):
    """A partner added to a household must see that household's data.

    Regression guard for: every new account is funnelled through
    /household/setup/, so an invited partner arrives already owning a solo
    household. Resolving 'the user's household' by pk handed them that solo one
    and they saw no money requests, transactions or alerts.
    """

    def _signup(self, username):
        c = Client()
        resp = c.post('/signup/', {
            'username': username,
            'email': f'{username}@example.com',
            'password1': 'sup3r-s3cret-pw',
            'password2': 'sup3r-s3cret-pw',
        })
        self.assertEqual(resp.status_code, 302, resp.content[:500])
        return c

    def _create_household(self, client, name):
        resp = client.post('/household/setup/', {'name': name})
        self.assertEqual(resp.status_code, 302, resp.content[:500])
        return Household.objects.get(name=name)

    def _invite(self, client, username):
        resp = client.post('/household/settings/',
                           {'action': 'add_member', 'username': username})
        self.assertEqual(resp.status_code, 302, resp.content[:500])

    def test_resolves_shared_household_when_partner_signed_up_first(self):
        """The failing order: partner's solo household has the lower pk."""
        cb = self._signup('bob')
        self._create_household(cb, 'Bob Solo')

        ca = self._signup('alice')
        hh = self._create_household(ca, 'Shared')

        bob = User.objects.get(username='bob')
        hh.members.add(bob)  # raw add, no stub cleanup

        self.assertEqual(resolve_user_household(bob), hh)

    def test_resolves_shared_household_when_partner_signed_up_second(self):
        ca = self._signup('alice')
        hh = self._create_household(ca, 'Shared')

        cb = self._signup('bob')
        self._create_household(cb, 'Bob Solo')

        bob = User.objects.get(username='bob')
        hh.members.add(bob)

        self.assertEqual(resolve_user_household(bob), hh)

    def test_partner_sees_money_request(self):
        """End-to-end: alice requests money from bob, bob sees it."""
        cb = self._signup('bob')
        self._create_household(cb, 'Bob Solo')

        ca = self._signup('alice')
        hh = self._create_household(ca, 'Shared')
        bob = User.objects.get(username='bob')
        self._invite(ca, 'bob')

        resp = ca.post('/requests/new/', {
            'approver': bob.pk,
            'amount': '50.00',
            'currency': hh.base_currency_id,
            'purpose': 'Groceries',
            'notes': '',
        })
        self.assertEqual(resp.status_code, 302, resp.content[:800])
        self.assertEqual(MoneyRequest.objects.count(), 1, "request was not created")

        self.assertIn('Groceries', cb.get('/requests/').content.decode())
        # and the sidebar badge counts it
        self.assertEqual(cb.get('/').context['pending_requests_count'], 1)

    def test_partner_sees_shared_dashboard_and_household_name(self):
        cb = self._signup('bob')
        self._create_household(cb, 'Bob Solo')
        ca = self._signup('alice')
        self._create_household(ca, 'Shared')
        self._invite(ca, 'bob')

        self.assertEqual(cb.get('/').context['current_household'].name, 'Shared')

    def test_invite_deletes_empty_signup_stub(self):
        cb = self._signup('bob')
        self._create_household(cb, 'Bob Solo')
        ca = self._signup('alice')
        self._create_household(ca, 'Shared')

        self._invite(ca, 'bob')

        bob = User.objects.get(username='bob')
        self.assertEqual([h.name for h in bob.households.all()], ['Shared'])
        self.assertFalse(Household.objects.filter(name='Bob Solo').exists())

    def test_invite_keeps_household_that_holds_data(self):
        """Never cascade-delete a household the user actually used."""
        cb = self._signup('bob')
        solo = self._create_household(cb, 'Bob Solo')
        Transaction.objects.create(
            household=solo, user=User.objects.get(username='bob'),
            transaction_type=Transaction.EXPENSE, amount='10.00',
            currency=solo.base_currency,
            category=Category.objects.filter(household=solo).first(),
            date='2026-01-01',
        )

        ca = self._signup('alice')
        hh = self._create_household(ca, 'Shared')
        self._invite(ca, 'bob')

        bob = User.objects.get(username='bob')
        self.assertTrue(Household.objects.filter(name='Bob Solo').exists())
        self.assertEqual(bob.households.count(), 2)
        # still resolves to the shared one
        self.assertEqual(resolve_user_household(bob), hh)

    def test_invite_is_idempotent(self):
        cb = self._signup('bob')
        self._create_household(cb, 'Bob Solo')
        ca = self._signup('alice')
        hh = self._create_household(ca, 'Shared')

        self._invite(ca, 'bob')
        self._invite(ca, 'bob')

        self.assertEqual(hh.members.count(), 2)

    def test_solo_user_still_resolves_own_household(self):
        ca = self._signup('alice')
        hh = self._create_household(ca, 'Solo')
        self.assertEqual(resolve_user_household(User.objects.get(username='alice')), hh)


class InviteFlowTests(TestCase):
    """Joining a household by invite link, so a partner never has to create one."""

    def setUp(self):
        self.owner = Client()
        resp = self.owner.post('/signup/', {
            'username': 'alice', 'email': 'alice@example.com',
            'password1': 'sup3r-s3cret-pw', 'password2': 'sup3r-s3cret-pw',
        })
        self.assertEqual(resp.status_code, 302)
        self.owner.post('/household/setup/', {'name': 'Shared'})
        self.hh = Household.objects.get(name='Shared')
        self.alice = User.objects.get(username='alice')

    def _make_invite(self, note=''):
        resp = self.owner.post('/household/settings/',
                               {'action': 'create_invite', 'note': note})
        self.assertEqual(resp.status_code, 302)
        return HouseholdInvitation.objects.latest('created_at')

    def _signup_through_invite(self, client, code, username='bob'):
        return client.post(f'/signup/?invite={code}', {
            'username': username, 'email': f'{username}@example.com',
            'password1': 'sup3r-s3cret-pw', 'password2': 'sup3r-s3cret-pw',
            'invite': code,
        }, follow=True)

    def test_new_user_joins_via_link_without_creating_a_household(self):
        invite = self._make_invite('for bob')
        cb = Client()

        self._signup_through_invite(cb, invite.code)
        # Signup lands on the join page; accepting is an explicit POST.
        cb.post(f'/join/{invite.code}/')

        bob = User.objects.get(username='bob')
        self.assertEqual([h.name for h in bob.households.all()], ['Shared'])
        self.assertEqual(Household.objects.count(), 1, "no stray household was created")
        self.assertEqual(resolve_user_household(bob), self.hh)

    def test_joined_partner_sees_money_requests(self):
        invite = self._make_invite()
        cb = Client()
        self._signup_through_invite(cb, invite.code)
        cb.post(f'/join/{invite.code}/')
        bob = User.objects.get(username='bob')

        self.owner.post('/requests/new/', {
            'approver': bob.pk, 'amount': '75.00',
            'currency': self.hh.base_currency_id,
            'purpose': 'School fees', 'notes': '',
        })
        self.assertEqual(MoneyRequest.objects.count(), 1)
        self.assertIn('School fees', cb.get('/requests/').content.decode())

    def test_existing_user_can_accept(self):
        cb = Client()
        cb.post('/signup/', {
            'username': 'bob', 'email': 'bob@example.com',
            'password1': 'sup3r-s3cret-pw', 'password2': 'sup3r-s3cret-pw',
        })
        cb.post('/household/setup/', {'name': 'Bob Solo'})

        invite = self._make_invite()
        cb.post(f'/join/{invite.code}/')

        bob = User.objects.get(username='bob')
        self.assertEqual(resolve_user_household(bob), self.hh)
        # the empty stub they made at signup is cleaned up
        self.assertFalse(Household.objects.filter(name='Bob Solo').exists())

    def test_invite_is_single_use(self):
        invite = self._make_invite()
        cb = Client()
        self._signup_through_invite(cb, invite.code)
        cb.post(f'/join/{invite.code}/')

        invite.refresh_from_db()
        self.assertEqual(invite.status, HouseholdInvitation.STATUS_ACCEPTED)
        self.assertEqual(invite.accepted_by, User.objects.get(username='bob'))

        cc = Client()
        cc.post('/signup/', {
            'username': 'carol', 'email': 'carol@example.com',
            'password1': 'sup3r-s3cret-pw', 'password2': 'sup3r-s3cret-pw',
        })
        resp = cc.post(f'/join/{invite.code}/')
        self.assertEqual(resp.status_code, 410)
        self.assertNotIn(User.objects.get(username='carol'), self.hh.members.all())

    def test_expired_invite_is_rejected(self):
        invite = self._make_invite()
        invite.expires_at = timezone.now() - timezone.timedelta(days=1)
        invite.save(update_fields=['expires_at'])

        resp = Client().get(f'/join/{invite.code}/')
        self.assertEqual(resp.status_code, 410)
        self.assertIn('expired', resp.content.decode().lower())

    def test_revoked_invite_is_rejected(self):
        invite = self._make_invite()
        self.owner.post('/household/settings/',
                        {'action': 'revoke_invite', 'invite_id': invite.pk})
        invite.refresh_from_db()
        self.assertEqual(invite.status, HouseholdInvitation.STATUS_REVOKED)

        resp = Client().get(f'/join/{invite.code}/')
        self.assertEqual(resp.status_code, 410)

    def test_unknown_code_404s(self):
        self.assertEqual(Client().get('/join/not-a-real-code/').status_code, 404)

    def test_logged_out_visitor_sees_join_page_with_signup_link(self):
        invite = self._make_invite()
        body = Client().get(f'/join/{invite.code}/').content.decode()
        self.assertIn('Shared', body)
        self.assertIn(f'/signup/?invite={invite.code}', body)

    def test_setup_page_redirects_when_invite_pending_in_session(self):
        """Someone who clicked the link, then signed up separately, still joins."""
        invite = self._make_invite()
        cb = Client()
        cb.get(f'/join/{invite.code}/')          # stores code in session
        cb.post('/signup/', {
            'username': 'bob', 'email': 'bob@example.com',
            'password1': 'sup3r-s3cret-pw', 'password2': 'sup3r-s3cret-pw',
        })
        resp = cb.get('/household/setup/')
        self.assertRedirects(resp, f'/join/{invite.code}/')

    def test_join_by_pasting_code_on_setup_page(self):
        invite = self._make_invite()
        cb = Client()
        cb.post('/signup/', {
            'username': 'bob', 'email': 'bob@example.com',
            'password1': 'sup3r-s3cret-pw', 'password2': 'sup3r-s3cret-pw',
        })
        resp = cb.post('/household/setup/', {'action': 'join', 'code': invite.code})
        self.assertRedirects(resp, f'/join/{invite.code}/')

    def test_join_by_pasting_full_url_on_setup_page(self):
        invite = self._make_invite()
        cb = Client()
        cb.post('/signup/', {
            'username': 'bob', 'email': 'bob@example.com',
            'password1': 'sup3r-s3cret-pw', 'password2': 'sup3r-s3cret-pw',
        })
        resp = cb.post('/household/setup/', {
            'action': 'join',
            'code': f'https://budget.hotone.co.tz/join/{invite.code}/',
        })
        self.assertRedirects(resp, f'/join/{invite.code}/')

    def test_invite_only_revocable_by_its_own_household(self):
        invite = self._make_invite()
        outsider = Client()
        outsider.post('/signup/', {
            'username': 'mallory', 'email': 'm@example.com',
            'password1': 'sup3r-s3cret-pw', 'password2': 'sup3r-s3cret-pw',
        })
        outsider.post('/household/setup/', {'name': 'Other'})

        resp = outsider.post('/household/settings/',
                             {'action': 'revoke_invite', 'invite_id': invite.pk})
        self.assertEqual(resp.status_code, 404)
        invite.refresh_from_db()
        self.assertEqual(invite.status, HouseholdInvitation.STATUS_PENDING)

    def test_settings_page_renders_invite_link_and_history(self):
        invite = self._make_invite('for bob')
        body = self.owner.get(f'/household/settings/?new_invite={invite.code}').content.decode()
        self.assertIn(f'/join/{invite.code}', body)   # copyable full link
        self.assertIn('for bob', body)                # active-links list

        self.owner.post('/household/settings/',
                        {'action': 'revoke_invite', 'invite_id': invite.pk})
        body = self.owner.get('/household/settings/').content.decode()
        self.assertIn('revoked', body.lower())        # moved to used & expired

    def test_setup_page_renders_join_option(self):
        cb = Client()
        cb.post('/signup/', {
            'username': 'bob', 'email': 'bob@example.com',
            'password1': 'sup3r-s3cret-pw', 'password2': 'sup3r-s3cret-pw',
        })
        body = cb.get('/household/setup/').content.decode()
        self.assertIn('Create Household', body)
        self.assertIn('Been invited?', body)

    def test_signup_page_renders_invite_banner(self):
        invite = self._make_invite()
        body = Client().get(f'/signup/?invite={invite.code}').content.decode()
        self.assertIn('Shared', body)
        self.assertIn(f'value="{invite.code}"', body)  # carried through the POST

    def test_sender_previewing_own_link_does_not_consume_it(self):
        invite = self._make_invite()

        resp = self.owner.get(f'/join/{invite.code}/')
        self.assertRedirects(resp, '/household/settings/')
        resp = self.owner.post(f'/join/{invite.code}/')
        self.assertRedirects(resp, '/household/settings/')

        invite.refresh_from_db()
        self.assertEqual(invite.status, HouseholdInvitation.STATUS_PENDING)
        self.assertEqual(self.hh.members.count(), 1)

        # ...and it still works for the actual partner afterwards
        cb = Client()
        self._signup_through_invite(cb, invite.code)
        cb.post(f'/join/{invite.code}/')
        self.assertEqual(self.hh.members.count(), 2)

    def test_codes_are_unguessable_and_unique(self):
        codes = {self._make_invite().code for _ in range(5)}
        self.assertEqual(len(codes), 5)
        self.assertTrue(all(len(c) >= 30 for c in codes))
