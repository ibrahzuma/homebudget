"""Shared plumbing for the mobile API views."""
from django.core.cache import cache
from django.db.models import Model
from django.forms.models import model_to_dict
from django.shortcuts import get_object_or_404
from django.utils import timezone
from rest_framework import status
from rest_framework.exceptions import APIException, ValidationError
from rest_framework.response import Response
from rest_framework.views import APIView

from ..models import resolve_user_household
from ..services import run_daily_household_tasks


class NoHousehold(APIException):
    status_code = status.HTTP_409_CONFLICT
    default_detail = 'Create or join a household first.'
    default_code = 'no_household'


def form_error(form):
    """Raise a 400 carrying the form's errors as {field: [messages]}.

    Non-field errors land under ``non_field_errors`` to match DRF's own shape.
    """
    errors = {}
    for field, errs in form.errors.items():
        key = 'non_field_errors' if field == '__all__' else field
        errors[key] = [str(e) for e in errs]
    raise ValidationError(errors)


def bind_form(form_cls, data, instance=None, files=None, **kwargs):
    """Bind the web UI's form to JSON input so both share validation.

    On update the instance's current values are used as the base, so clients
    can PATCH just the fields they change (unchecked booleans would otherwise
    read as False).
    """
    payload = {}
    if instance is not None:
        fields = [f for f in form_cls._meta.fields]
        for key, value in model_to_dict(instance, fields=fields).items():
            if isinstance(value, list):  # m2m -> list of pks
                value = [v.pk if isinstance(v, Model) else v for v in value]
            payload[key] = value
    payload.update(data.dict() if hasattr(data, 'dict') else dict(data))
    return form_cls(data=payload, files=files, instance=instance, **kwargs)


def validated_form(form_cls, data, **kwargs):
    form = bind_form(form_cls, data, **kwargs)
    if not form.is_valid():
        form_error(form)
    return form


def paginate(request, qs, serialize, default_size=50, max_size=200):
    try:
        page = max(1, int(request.query_params.get('page', 1)))
        size = min(max_size, max(1, int(request.query_params.get('page_size', default_size))))
    except ValueError:
        raise ValidationError({'page': ['Must be an integer.']})
    total = qs.count()
    start = (page - 1) * size
    items = list(qs[start:start + size])
    return {
        'count': total,
        'page': page,
        'page_size': size,
        'has_next': start + size < total,
        'results': [serialize(i) for i in items],
    }


class HouseholdAPIView(APIView):
    """Authenticated view scoped to the caller's household (``self.household``).

    Also runs the once-a-day recurring/alert catch-up that the session-based
    middleware does for the web UI, since token requests have no session.
    """

    requires_household = True

    def initial(self, request, *args, **kwargs):
        super().initial(request, *args, **kwargs)
        self.household = resolve_user_household(request.user)
        if self.household is None:
            if self.requires_household:
                raise NoHousehold()
            return
        key = f'hb:daily:{request.user.pk}:{timezone.now().date().isoformat()}'
        if cache.add(key, True, timeout=60 * 60 * 26):
            try:
                run_daily_household_tasks(self.household)
            except Exception:
                pass  # never break the request because of background work

    def get_owned(self, model, pk, **filters):
        """404 unless the object belongs to this household."""
        return get_object_or_404(model, pk=pk, household=self.household, **filters)


def created(data):
    return Response(data, status=status.HTTP_201_CREATED)


def no_content():
    return Response(status=status.HTTP_204_NO_CONTENT)
