"""Mobile push notifications via Firebase Cloud Messaging (HTTP v1).

The ``/ws/notify/`` WebSocket only reaches an app that is running and in the
foreground. A notification that has to pop up while the app is backgrounded or
closed — the WhatsApp behaviour — must be handed to Firebase, which forwards it
to Google Play services (Android) or APNs (iOS). That is all this module does.

Configuration is one environment variable, ``FCM_CREDENTIALS_FILE``, pointing at
a Firebase **service account** JSON key (Firebase console -> Project settings ->
Service accounts -> Generate new private key). With it unset — local dev, tests,
a web-only deployment — every function here is a silent no-op, so callers never
have to care whether push is set up.

Called from ``services.push_to_household``; nothing else should need it.
"""
import json
import logging
import threading

from django.conf import settings

logger = logging.getLogger(__name__)

FCM_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging'
FCM_ENDPOINT = 'https://fcm.googleapis.com/v1/projects/{project}/messages:send'

# Must match the channel the Flutter app creates (mobile/lib/core/push.dart):
# Android silently drops a notification aimed at a channel that doesn't exist.
ANDROID_CHANNEL_ID = 'homebudget_default'

_HTTP_TIMEOUT = 15

_lock = threading.Lock()
_service_account = None     # (google credentials, project_id), built once


def credentials_file():
    return (getattr(settings, 'FCM_CREDENTIALS_FILE', '') or '').strip()


def is_configured():
    """True when a service-account key is configured (not that it works)."""
    return bool(credentials_file())


def _load_service_account():
    """Service-account credentials + project id, or None if unusable.

    google-auth is imported lazily: only deployments that actually send push
    need the dependency, and a missing or broken key must never raise into a
    request.
    """
    global _service_account
    with _lock:
        if _service_account is not None:
            return _service_account
        path = credentials_file()
        if not path:
            return None
        try:
            from google.oauth2 import service_account
            with open(path, 'r', encoding='utf-8') as fh:
                info = json.load(fh)
            project = info.get('project_id')
            if not project:
                logger.error('push: %s has no project_id', path)
                return None
            creds = service_account.Credentials.from_service_account_info(
                info, scopes=[FCM_SCOPE])
            _service_account = (creds, project)
            return _service_account
        except ImportError:
            logger.error('push: FCM_CREDENTIALS_FILE is set but google-auth is not '
                         'installed (pip install -r requirements.txt)')
        except Exception:
            logger.exception('push: could not load %s', path)
        return None


def _access_token(creds):
    """A valid OAuth2 bearer token; google-auth caches it until it nears expiry."""
    from google.auth.transport.requests import Request
    if not creds.valid:
        creds.refresh(Request())
    return creds.token


# ============================================================
# Sending
# ============================================================

def send_to_users(users, title, body, data=None, thread_id=None):
    """Push ``title``/``body`` to every device belonging to ``users``.

    ``users`` is any iterable of User objects or ids; duplicates are fine.
    ``data`` is a flat dict delivered alongside the notification (values are
    coerced to strings, as FCM requires) and is what the app reads to decide
    which screen to open when the notification is tapped. ``thread_id`` groups
    notifications that should replace each other instead of stacking up.

    Returns immediately: delivery runs on a daemon thread, so a slow or
    unreachable Firebase never holds up the request that triggered it. The
    thread is handed back (None when there was nothing to send) so a caller
    that needs to — a test — can wait for it.
    """
    if not is_configured():
        return None
    ids = {getattr(u, 'pk', u) for u in (users or []) if u is not None}
    if not ids:
        return None
    payload = {str(k): ('' if v is None else str(v)) for k, v in (data or {}).items()}
    worker = threading.Thread(
        target=_deliver,
        args=(sorted(ids), title, body, payload, thread_id),
        name='fcm-send',
        daemon=True,
    )
    worker.start()
    return worker


def _deliver(user_ids, title, body, data, thread_id):
    """Thread body: look up tokens, send one message each, drop dead tokens."""
    from django.db import connections
    from .models import DeviceToken
    try:
        rows = list(DeviceToken.objects.filter(user_id__in=user_ids))
        if not rows:
            return
        account = _load_service_account()
        if not account:
            return
        creds, project = account
        try:
            bearer = _access_token(creds)
        except Exception:
            logger.exception('push: could not mint an access token')
            return
        url = FCM_ENDPOINT.format(project=project)
        headers = {'Authorization': 'Bearer ' + bearer,
                   'Content-Type': 'application/json; charset=UTF-8'}
        stale = []
        for row in rows:
            if _post(url, headers, _message(row, title, body, data, thread_id)) == 'stale':
                stale.append(row.pk)
        if stale:
            DeviceToken.objects.filter(pk__in=stale).delete()
            logger.info('push: dropped %d unregistered device token(s)', len(stale))
    except Exception:
        # Background work must never surface anywhere.
        logger.exception('push: delivery failed')
    finally:
        # This thread opened its own DB connection; don't leak it.
        connections.close_all()


def _message(row, title, body, data, thread_id):
    """One FCM HTTP v1 message.

    Sending ``notification`` *and* ``data`` is deliberate: the system tray draws
    the notification while the app is backgrounded or closed, and the data
    reaches the app on tap — or straight away when it is in the foreground,
    where the app draws the banner itself.
    """
    android_notification = {
        'channel_id': ANDROID_CHANNEL_ID,
        'sound': 'default',
        'default_vibrate_timings': True,
    }
    aps = {'sound': 'default'}
    if thread_id:
        android_notification['tag'] = thread_id
        aps['thread-id'] = thread_id
    return {
        'message': {
            'token': row.token,
            'notification': {'title': title, 'body': body},
            'data': data,
            'android': {
                'priority': 'high',     # wake the device; show a heads-up banner
                'notification': android_notification,
            },
            'apns': {
                'headers': {'apns-priority': '10'},
                'payload': {'aps': aps},
            },
        }
    }


def _post(url, headers, message):
    """Send one message. Returns 'ok', 'stale' (the token is dead) or 'error'."""
    import requests
    try:
        res = requests.post(url, headers=headers, json=message, timeout=_HTTP_TIMEOUT)
    except Exception as exc:
        logger.warning('push: request to FCM failed: %s', exc)
        return 'error'
    if res.status_code < 300:
        return 'ok'
    body = res.text or ''
    # 404 UNREGISTERED: the app was uninstalled or the token rotated.
    # 400 INVALID_ARGUMENT naming the token field: it was never valid.
    if res.status_code == 404 or 'UNREGISTERED' in body:
        return 'stale'
    if res.status_code == 400 and 'token' in body:
        return 'stale'
    logger.warning('push: FCM returned %s: %s', res.status_code, body[:500])
    return 'error'
