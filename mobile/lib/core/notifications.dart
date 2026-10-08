import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Drawing and routing the notifications the household raises, shared by both
/// ways they can reach the phone:
///
///  * [PushService] (`push.dart`) — Firebase, for iOS.
///  * [WatchService] (`watch_service.dart`) — a foreground service holding the
///    `/ws/notify/` socket open, for Android, so nothing leaves our server.
///
/// Both end up here so a money request looks and behaves the same either way.
/// Note that the watcher runs this code in its own isolate, which gets its own
/// copy of everything below — hence [EventNotifier.instance] per isolate rather
/// than one shared object.

/// Our notification channel. The id must match `ANDROID_CHANNEL_ID` in
/// `budget_app/push.py`: Android silently drops a pushed notification aimed at
/// a channel that does not exist. High importance is what makes it a heads-up
/// banner with a sound instead of a silent tray entry.
const AndroidNotificationChannel appNotificationChannel = AndroidNotificationChannel(
  'homebudget_default',
  'Requests and chat',
  description: 'Money requests, approvals and household chat messages.',
  importance: Importance.high,
);

/// A tapped notification, resolved to somewhere the app can navigate.
class PushTap {
  const PushTap({required this.kind, this.requestId});

  /// Server event kind: `request.created`, `request.approved`,
  /// `request.rejected`, `chat.new`.
  final String kind;

  /// Set for `request.*`.
  final int? requestId;

  bool get isRequest => kind.startsWith('request.');
  bool get isChat => kind == 'chat.new';

  /// Reads the routing keys both transports attach to a notification. Values
  /// arrive as strings over FCM and as ints over the WebSocket, so both are
  /// accepted.
  static PushTap? fromData(Map<String, dynamic>? data) {
    final kind = data?['kind'];
    if (kind is! String || kind.isEmpty) return null;
    return PushTap(kind: kind, requestId: int.tryParse('${data?['request_id']}'));
  }

  Map<String, dynamic> toJson() => {'kind': kind, 'request_id': requestId};
}

/// What a client must provide to deliver household events while the app is not
/// in the foreground. Implemented by [PushService] and [WatchService]; the app
/// is given whichever one suits the platform, so nothing above this layer has
/// to know which is in use.
abstract class BackgroundAlerts {
  /// Prepare whatever the platform needs. Safe before sign-in, and safe when
  /// the platform support simply is not there.
  Future<void> initialise();

  /// Begin delivering, once signed in. A repeat call is a no-op.
  Future<void> start();

  /// Stop delivering, on sign-out.
  Future<void> stop();

  /// Notifications the user tapped while the app was already running.
  Stream<PushTap> get taps;

  /// The tap that launched the app, if any — consumed once, by the shell.
  PushTap? takeLaunchTap();

  /// Suppress banners for event kinds starting with [prefix] (`chat.`,
  /// `request.`) while the screen that shows those events live is on top — a
  /// banner over the very list that is already updating is just noise.
  void setMuted(String prefix, bool muted);

  void dispose();
}

/// Shows our notifications through flutter_local_notifications.
///
/// One per isolate: the main isolate uses it for notifications that arrive
/// while the app is open, and the watcher isolate for the ones that arrive
/// while it is not.
class EventNotifier {
  EventNotifier._();

  static final EventNotifier instance = EventNotifier._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  /// Called when one of our notifications is tapped in this isolate.
  void Function(PushTap tap)? onTap;

  Future<void> initialise() async {
    if (_ready) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          // Asked for at sign-in instead, so the prompt lands on a screen that
          // can explain itself.
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: _handleTap,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(appNotificationChannel);
    _ready = true;
  }

  /// Raise a notification for a household event. [data] is the routing payload
  /// handed back on a tap.
  Future<void> show({
    required String kind,
    String? title,
    String? body,
    Map<String, dynamic> data = const {},
  }) async {
    if (!_ready) await initialise();
    // One notification per conversation / per request, replaced rather than
    // stacked, matching the `thread_id` the server sends. Masked because
    // Android notification ids are 32-bit signed.
    final tag = data['request_id']?.toString() ?? kind;
    await _plugin.show(
      id: tag.hashCode & 0x7fffffff,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          appNotificationChannel.id,
          appNotificationChannel.name,
          channelDescription: appNotificationChannel.description,
          importance: Importance.high,
          priority: Priority.high,
          ticker: title,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
      payload: jsonEncode({...data, 'kind': kind}),
    );
  }

  /// The notification that launched the app, if it was one of ours.
  Future<PushTap?> launchTap() async {
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details == null || !details.didNotificationLaunchApp) return null;
      return _decode(details.notificationResponse?.payload);
    } catch (e) {
      debugPrint('notifications: could not read launch details ($e)');
      return null;
    }
  }

  void _handleTap(NotificationResponse response) {
    final tap = _decode(response.payload);
    if (tap != null) onTap?.call(tap);
  }

  PushTap? _decode(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      return PushTap.fromData(jsonDecode(payload) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('notifications: bad payload ($e)');
      return null;
    }
  }
}
