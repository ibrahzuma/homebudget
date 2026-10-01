"""Model -> JSON dicts for the mobile API.

Plain functions rather than DRF serializers: input is validated by the same
Django forms the web UI uses (see ``base.bind_form``), so these only shape
output. Money is always a string (never a float) so clients don't lose cents;
percentages are floats.
"""
from decimal import Decimal

from django.utils import timezone


def money(v):
    if v is None:
        return None
    return str(Decimal(v).quantize(Decimal('0.01')))


def iso(d):
    return d.isoformat() if d else None


def dt(d):
    return timezone.localtime(d).isoformat() if d else None


def user_brief(u):
    if u is None:
        return None
    return {'id': u.id, 'username': u.username}


def currency(c):
    if c is None:
        return None
    return {'id': c.id, 'code': c.code, 'name': c.name, 'symbol': c.symbol}


def category_brief(c):
    if c is None:
        return None
    return {'id': c.id, 'name': c.name, 'type': c.category_type,
            'color': c.color, 'icon': c.icon}


category = category_brief


def project_brief(p):
    if p is None:
        return None
    return {'id': p.id, 'name': p.name, 'color': p.color, 'icon': p.icon}


def household(h, include_members=True):
    data = {
        'id': h.id,
        'name': h.name,
        'base_currency': currency(h.base_currency),
        'currency_symbol': h.currency_symbol,
        'currency_code': h.currency_code,
        'created_at': dt(h.created_at),
    }
    if include_members:
        data['members'] = [user_brief(u) for u in h.members.order_by('username')]
    return data


def invitation(i):
    return {
        'id': i.id,
        'code': i.code,
        'path': f'/join/{i.code}/',
        'note': i.note,
        'status': i.status,
        'is_usable': i.is_usable,
        'invited_by': user_brief(i.invited_by),
        'accepted_by': user_brief(i.accepted_by),
        'created_at': dt(i.created_at),
        'expires_at': dt(i.expires_at),
        'accepted_at': dt(i.accepted_at),
    }


def transaction(t):
    return {
        'id': t.id,
        'type': t.transaction_type,
        'amount': money(t.amount),
        'currency': currency(t.currency),
        'amount_base': money(t.amount_base),
        'description': t.description,
        'payee': t.payee,
        'date': iso(t.date),
        'created_at': dt(t.created_at),
        'source': t.source,
        'user': user_brief(t.user),
        'category': category_brief(t.category),
        'project': project_brief(t.project),
    }


def budget(b, spent=None, is_current=False):
    pct = None
    if spent is not None and b.monthly_limit:
        pct = min(round(float(spent / b.monthly_limit * 100), 1), 100)
    return {
        'id': b.id,
        'category': category_brief(b.category),
        'monthly_limit': money(b.monthly_limit),
        'month': iso(b.month),
        'is_current': is_current,
        'spent': money(spent),
        'pct': pct,
        'over': spent is not None and spent > b.monthly_limit,
    }


def recurring(r):
    return {
        'id': r.id,
        'name': r.name,
        'type': r.transaction_type,
        'category': category_brief(r.category),
        'amount': money(r.amount),
        'currency': currency(r.currency),
        'payee': r.payee,
        'frequency': r.frequency,
        'start_date': iso(r.start_date),
        'end_date': iso(r.end_date),
        'next_due_date': iso(r.next_due_date),
        'days_until_due': r.days_until_due,
        'auto_create': r.auto_create,
        'is_active': r.is_active,
        'notes': r.notes,
        'user': user_brief(r.user),
    }


def rule(r):
    return {
        'id': r.id,
        'pattern': r.pattern,
        'match_type': r.match_type,
        'case_sensitive': r.case_sensitive,
        'category': category_brief(r.category),
        'priority': r.priority,
        'is_active': r.is_active,
    }


def alert(a):
    return {
        'id': a.id,
        'title': a.title,
        'message': a.message,
        'level': a.level,
        'link_url': a.link_url,
        'is_read': a.is_read,
        'user': user_brief(a.user),
        'created_at': dt(a.created_at),
    }


def money_request(r, viewer=None):
    from ..models import MoneyRequest
    pending = r.status == MoneyRequest.STATUS_PENDING
    return {
        'id': r.id,
        'requester': user_brief(r.requester),
        'approver': user_brief(r.approver),
        'amount': money(r.amount),
        'currency': currency(r.currency),
        'purpose': r.purpose,
        'notes': r.notes,
        'category': category_brief(r.category),
        'status': r.status,
        'response_note': r.response_note,
        'created_at': dt(r.created_at),
        'resolved_at': dt(r.resolved_at),
        'expense_transaction_id': r.expense_transaction_id,
        'can_respond': bool(viewer and pending and viewer.id == r.approver_id),
        'can_cancel': bool(viewer and pending and viewer.id == r.requester_id),
    }


def asset(a):
    return {
        'id': a.id,
        'name': a.name,
        'asset_type': a.asset_type,
        'asset_type_display': a.get_asset_type_display(),
        'is_major': a.is_major,
        'value': money(a.value),
        'currency': currency(a.currency),
        'acquisition_date': iso(a.acquisition_date),
        'location': a.location,
        'size': a.size,
        'registration_number': a.registration_number,
        'notes': a.notes,
        'updated_at': dt(a.updated_at),
    }


def _progress(paid, balance, original_amount):
    original = original_amount or (balance + paid)
    pct = float(paid / original * 100) if original else 0
    return original, min(round(pct, 1), 100)


def liability(l, with_payments=False):
    paid = l.total_paid
    original, pct = _progress(paid, l.balance, l.original_amount)
    data = {
        'id': l.id,
        'name': l.name,
        'liability_type': l.liability_type,
        'liability_type_display': l.get_liability_type_display(),
        'lender': l.lender,
        'balance': money(l.balance),
        'original_amount': money(l.original_amount),
        'currency': currency(l.currency),
        'interest_rate': money(l.interest_rate),
        'start_date': iso(l.start_date),
        'due_date': iso(l.due_date),
        'notes': l.notes,
        'paid': money(paid),
        'original': money(original),
        'pct': pct,
        'payments_count': l.payments.count(),
        'updated_at': dt(l.updated_at),
    }
    if with_payments:
        data['payments'] = [payment(p) for p in l.payments.select_related('currency').all()]
    return data


def payment(p):
    return {
        'id': p.id,
        'date': iso(p.date),
        'amount': money(p.amount),
        'currency': currency(p.currency),
        'notes': p.notes,
        'transaction_id': p.transaction_id,
        'created_at': dt(p.created_at),
    }


def receivable(r, with_payments=False):
    received = r.total_received
    original = r.original_amount or (r.balance + received)
    data = {
        'id': r.id,
        'debtor_name': r.debtor_name,
        'debtor_contact': r.debtor_contact,
        'description': r.description,
        'balance': money(r.balance),
        'original_amount': money(r.original_amount),
        'currency': currency(r.currency),
        'interest_rate': money(r.interest_rate),
        'lent_date': iso(r.lent_date),
        'due_date': iso(r.due_date),
        'status': r.status,
        'notes': r.notes,
        'received': money(received),
        'original': money(original),
        'pct': r.progress_percent,
        'is_overdue': r.is_overdue,
        'payments_count': r.payments.count(),
        'updated_at': dt(r.updated_at),
    }
    if with_payments:
        data['payments'] = [payment(p) for p in r.payments.select_related('currency').all()]
    return data


def goal(g, with_contributions=False):
    data = {
        'id': g.id,
        'name': g.name,
        'target_amount': money(g.target_amount),
        'current_amount': money(g.current_amount),
        'amount_remaining': money(g.amount_remaining),
        'target_date': iso(g.target_date),
        'monthly_contribution': money(g.monthly_contribution),
        'monthly_needed': money(g.monthly_needed),
        'months_remaining': g.months_remaining,
        'on_track': g.on_track,
        'progress_percent': g.progress_percent,
        'currency': currency(g.currency),
        'icon': g.icon,
        'color': g.color,
        'status': g.status,
        'notes': g.notes,
        'created_at': dt(g.created_at),
    }
    if with_contributions:
        data['contributions'] = [{
            'id': c.id,
            'amount': money(c.amount),
            'date': iso(c.date),
            'notes': c.notes,
            'user': user_brief(c.user),
            'transaction_id': c.transaction_id,
        } for c in g.contributions.select_related('user').all()]
    return data


def project(p, with_transactions=False):
    data = {
        'id': p.id,
        'name': p.name,
        'description': p.description,
        'budget': money(p.budget),
        'currency': currency(p.currency),
        'start_date': iso(p.start_date),
        'end_date': iso(p.end_date),
        'status': p.status,
        'color': p.color,
        'icon': p.icon,
        'spent': money(p.spent),
        'income_received': money(p.income_received),
        'progress_percent': p.progress_percent,
        'is_over_budget': p.is_over_budget,
        'created_at': dt(p.created_at),
    }
    if with_transactions:
        data['transactions'] = [transaction(t) for t in p.transactions.select_related(
            'user', 'category', 'currency', 'project')[:200]]
    return data


def agreement(i):
    return {
        'id': i.id,
        'meeting_id': i.meeting_id,
        'title': i.title,
        'description': i.description,
        'owner': user_brief(i.owner),
        'target_date': iso(i.target_date),
        'status': i.status,
        'progress': i.progress,
        'priority': i.priority,
        'completed_date': iso(i.completed_date),
        'notes': i.notes,
        'is_overdue': i.is_overdue,
    }


def meeting(m, with_items=False):
    data = {
        'id': m.id,
        'title': m.title,
        'meeting_date': iso(m.meeting_date),
        'participants': [user_brief(u) for u in m.participants.all()],
        'agenda': m.agenda,
        'minutes': m.minutes,
        'status': m.status,
        'income_snapshot': money(m.income_snapshot),
        'expense_snapshot': money(m.expense_snapshot),
        'net_worth_snapshot': money(m.net_worth_snapshot),
        'progress_percent': m.progress_percent,
        'open_count': m.open_count,
        'done_count': m.done_count,
        'created_at': dt(m.created_at),
    }
    if with_items:
        data['items'] = [agreement(i) for i in m.agreements.select_related('owner').all()]
    return data


def chat_message(m):
    return {
        'id': m.id,
        'sender': user_brief(m.sender),
        'body': m.body,
        'created_at': dt(m.created_at),
    }


def snapshot(s):
    return {
        'id': s.id,
        'snapshot_date': iso(s.snapshot_date),
        'total_assets': money(s.total_assets),
        'total_liabilities': money(s.total_liabilities),
        'net_worth': money(s.net_worth),
    }


def exchange_rate(r):
    return {
        'id': r.id,
        'from_currency': currency(r.from_currency),
        'to_currency': currency(r.to_currency),
        'rate': str(r.rate),
        'updated_at': dt(r.updated_at),
    }


def networth(data):
    return {
        'total_assets': money(data['total_assets']),
        'total_receivables': money(data['total_receivables']),
        'total_liabilities': money(data['total_liabilities']),
        'net_worth': money(data['net_worth']),
        'assets_by_type': {k: money(v) for k, v in data['assets_by_type'].items()},
        'liabilities_by_type': {k: money(v) for k, v in data['liabilities_by_type'].items()},
    }


def forecast(f):
    out = {}
    for k, v in f.items():
        out[k] = v if isinstance(v, int) else money(v)
    return out


def members_rows(rows):
    return [{
        'user': user_brief(r['user']),
        'income': money(r['income']),
        'expense': money(r['expense']),
        'net': money(r['net']),
        'income_share_pct': r['income_share_pct'],
        'expense_share_pct': r['expense_share_pct'],
    } for r in rows]


def dashboard(d, viewer):
    return {
        'month_label': d['month_label'],
        'total_income': money(d['total_income']),
        'total_expense': money(d['total_expense']),
        'balance': money(d['balance']),
        'members': members_rows(d['members_data']),
        'budgets': [{
            'category': category_brief(b['category']),
            'limit': money(b['limit']),
            'spent': money(b['spent']),
            'pct': b['pct'],
            'over': b['over'],
        } for b in d['budget_progress']],
        'recent': [transaction(t) for t in d['recent']],
        'upcoming': [recurring(r) for r in d['upcoming']],
        'forecast': forecast(d['forecast']),
        'networth': networth(d['networth']),
        'pending_my_approvals': [money_request(r, viewer) for r in
                                 d['pending_my_approvals'].select_related(
                                     'requester', 'approver', 'currency', 'category')],
        'active_goals': [goal(g) for g in d['active_goals']],
        'next_meeting': meeting(d['next_meeting']) if d['next_meeting'] else None,
        'total_lent_out': money(d['total_lent_out']),
        'total_owed': money(d['total_owed']),
        'overdue_lent': d['overdue_lent'],
    }


def calendar(cal):
    def bill(b):
        return {
            'kind': b['kind'],
            'name': b['name'],
            'amount': money(b['amount']),
            'payee': b['payee'],
            'category': category_brief(b['category']),
        }
    return {
        'year': cal['target'].year,
        'month': cal['target'].month,
        'month_label': cal['target'].strftime('%B %Y'),
        'prev': {'year': cal['prev_month'].year, 'month': cal['prev_month'].month},
        'next': {'year': cal['next_month'].year, 'month': cal['next_month'].month},
        'month_income': money(cal['month_income']),
        'month_expense': money(cal['month_expense']),
        'month_net': money(cal['month_net']),
        'weeks': [[{
            'date': iso(day['date']),
            'in_month': day['in_month'],
            'is_today': day['is_today'],
            'income': money(day['income']),
            'expense': money(day['expense']),
            'net': money(day['net']),
            'bills': [bill(b) for b in day['bills']],
        } for day in week] for week in cal['weeks']],
    }


def monthly_report(r):
    return {
        'year': r['target'].year,
        'month': r['target'].month,
        'month_label': r['month_label'],
        'prev': {'year': r['prev_target'].year, 'month': r['prev_target'].month},
        'next': {'year': r['next_target'].year, 'month': r['next_target'].month},
        'income': money(r['income']),
        'expense': money(r['expense']),
        'net': money(r['net']),
        'savings_rate': r['savings_rate'],
        'income_delta_pct': r['inc_delta'],
        'expense_delta_pct': r['exp_delta'],
        'prev_income': money(r['prev_income']),
        'prev_expense': money(r['prev_expense']),
        'members': members_rows(r['members_data']),
        'by_category': [{
            'name': c['category__name'],
            'color': c['category__color'],
            'icon': c['category__icon'],
            'total': money(c['total']),
            'count': c['n'],
            'pct': round(c['pct'], 1),
        } for c in r['by_category']],
        'top_payees': [{'payee': p['payee'], 'total': money(p['total']), 'count': p['n']}
                       for p in r['top_payees']],
        'top_transactions': [transaction(t) for t in r['top_transactions']],
        'budgets': [{
            'category': category_brief(b['category']),
            'limit': money(b['limit']),
            'spent': money(b['spent']),
            'remaining': money(b['remaining']),
            'pct': b['pct'],
            'over': b['over'],
        } for b in r['budget_perf']],
        'requests': r['requests_stats'],
        'goal_contributions': [{
            'goal': {'id': c.goal_id, 'name': c.goal.name},
            'amount': money(c.amount),
            'date': iso(c.date),
            'user': user_brief(c.user),
        } for c in r['goal_contribs']],
        'goal_total': money(r['goal_total']),
        'projects': [{**project_brief(p), 'month_spent': money(p.month_spent)}
                     for p in r['project_spending']],
        'meetings': [{'id': m.id, 'title': m.title, 'meeting_date': iso(m.meeting_date),
                      'status': m.status} for m in r['meetings']],
        'debt_paid': money(r['debt_paid']),
        'debt_paid_count': r['debt_paid_count'],
        'receivable_received': money(r['receivable_received']),
        'transaction_count': r['tx_count'],
    }
