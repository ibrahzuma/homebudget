"""WebSocket consumers for live household notifications."""
import json
from channels.generic.websocket import AsyncWebsocketConsumer


class NotificationConsumer(AsyncWebsocketConsumer):
    """One socket per authenticated user, joined to a household group.

    Server-side code publishes events to the group via the channel layer;
    this consumer relays them to the browser as JSON messages.
    """

    async def connect(self):
        user = self.scope.get('user')
        if not user or not user.is_authenticated:
            await self.close()
            return

        # Resolve which household this user belongs to (sync ORM call wrapped)
        from channels.db import database_sync_to_async
        household = await database_sync_to_async(self._user_household)(user)
        if not household:
            await self.close()
            return

        self.household_id = household.id
        self.group_name = f'household_{self.household_id}'
        await self.channel_layer.group_add(self.group_name, self.channel_name)
        await self.accept()

    async def disconnect(self, close_code):
        if hasattr(self, 'group_name'):
            await self.channel_layer.group_discard(self.group_name, self.channel_name)

    @staticmethod
    def _user_household(user):
        return user.households.first()

    # ---- Group event handlers (called when something is broadcast) ----

    async def notify(self, event):
        """Generic 'notify' fan-out: forwards the payload dict to the client."""
        await self.send(text_data=json.dumps(event.get('payload', {})))
