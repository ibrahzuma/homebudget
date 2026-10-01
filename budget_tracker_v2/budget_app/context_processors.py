"""Make household, currency, and unread alerts available in all templates."""
from .models import resolve_user_household
from .services import badge_counts


def household_context(request):
    if not request.user.is_authenticated:
        return {}
    household = resolve_user_household(request.user)
    if not household:
        return {'current_household': None}

    counts = badge_counts(household, request.user)
    return {
        'current_household': household,
        'currency_symbol': household.currency_symbol,
        'currency_code': household.currency_code,
        'unread_alerts_count': counts['unread_alerts'],
        'pending_requests_count': counts['pending_requests'],
        'unread_chat_count': counts['unread_chat'],
    }
