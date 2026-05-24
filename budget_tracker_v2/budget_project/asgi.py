"""ASGI entry point — routes HTTP to Django and WebSocket to Channels consumers."""
import os
import django

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'budget_project.settings')
django.setup()

from django.core.asgi import get_asgi_application
from channels.routing import ProtocolTypeRouter, URLRouter
from channels.auth import AuthMiddlewareStack

import budget_app.routing

django_asgi_app = get_asgi_application()

application = ProtocolTypeRouter({
    'http': django_asgi_app,
    'websocket': AuthMiddlewareStack(
        URLRouter(budget_app.routing.websocket_urlpatterns)
    ),
})
