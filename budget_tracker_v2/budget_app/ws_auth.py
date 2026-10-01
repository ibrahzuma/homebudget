"""Token authentication for WebSockets (used by the mobile app).

Browsers authenticate the socket with the session cookie via Channels'
AuthMiddlewareStack. The mobile app has no session, so it sends the same
``Authorization: Token <key>`` header it uses for the REST API on the
WebSocket handshake. Headers are used rather than a ``?token=`` query string
so the key never ends up in nginx access logs.
"""
from channels.db import database_sync_to_async
from channels.middleware import BaseMiddleware


@database_sync_to_async
def _user_for_token(key):
    from rest_framework.authtoken.models import Token
    token = Token.objects.select_related('user').filter(key=key).first()
    if token and token.user.is_active:
        return token.user
    return None


class TokenAuthMiddleware(BaseMiddleware):
    async def __call__(self, scope, receive, send):
        headers = dict(scope.get('headers') or [])
        auth = headers.get(b'authorization', b'').decode('latin-1')
        if auth.lower().startswith('token '):
            user = await _user_for_token(auth[6:].strip())
            if user is not None:
                scope = dict(scope, user=user)
        return await super().__call__(scope, receive, send)
