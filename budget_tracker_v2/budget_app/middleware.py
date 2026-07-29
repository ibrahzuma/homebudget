"""Middleware to auto-apply due recurring transactions and check alerts."""
from django.utils import timezone
from datetime import timedelta

from .models import resolve_user_household
from .services import apply_due_recurring, check_budget_alerts, check_upcoming_meeting_alerts


class AutoApplyRecurringMiddleware:
    """Once per session-day, apply due recurring transactions for the user's household."""

    SESSION_KEY = '_recurring_last_check'

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        if request.user.is_authenticated:
            today_str = timezone.now().date().isoformat()
            last = request.session.get(self.SESSION_KEY)
            if last != today_str:
                household = resolve_user_household(request.user)
                if household:
                    try:
                        apply_due_recurring(household=household)
                        check_budget_alerts(household)
                        check_upcoming_meeting_alerts(household)
                    except Exception:
                        pass  # never break the request because of background work
                request.session[self.SESSION_KEY] = today_str
        return self.get_response(request)
