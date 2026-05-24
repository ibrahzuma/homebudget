"""Make household, currency, and unread alerts available in all templates."""
from django.db.models import Q

from .models import Alert, MoneyRequest


def household_context(request):
    if not request.user.is_authenticated:
        return {}
    household = request.user.households.first()
    if not household:
        return {'current_household': None}

    unread_alerts = Alert.objects.filter(
        household=household, is_read=False
    ).filter(
        Q(user__isnull=True) | Q(user=request.user)
    ).count()

    pending_requests = MoneyRequest.objects.filter(
        household=household, approver=request.user, status=MoneyRequest.STATUS_PENDING
    ).count()

    return {
        'current_household': household,
        'currency_symbol': household.currency_symbol,
        'currency_code': household.currency_code,
        'unread_alerts_count': unread_alerts,
        'pending_requests_count': pending_requests,
    }
