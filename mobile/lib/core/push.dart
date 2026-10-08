import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'session.dart';

/// System notifications — the ones that pop up while the app is in the
/// background or closed, which the `/ws/notify/` socket in [Realtime] cannot
/// do because it only lives as long as the app is running.
///
/// The server sends these through Firebase (`budget_app/push.py`) to the FCM
/// token this class registers at `POST devices/`. Android and iOS draw the
/// notification themselves while the app is away; when the app is in the
/// foreground Firebase hands the message to us instead, and [PushService]
/// draws a banner for it unless the screen that already shows the event live
/// is on top (see [setMuted]).
///
/// Everything here is best-effort. A build with no Firebase config — no
/// `android/app/google-services.json`, no `ios/Runner/GoogleService-Info.plist`
/// — logs one line and runs with push disabled; nothing else in the app
/// changes behaviour.

/// Android channel for our notifications. The id must match
/// `ANDROID_CHANNEL_ID` in `budget_app/push.py`: Android drops a notification
/// addressed to a channel that does not exist. High importance is what makes it
/// a heads-up banner with a sound rather than a silent tray entry.
const AndroidNotificationChannel _channel = AndroidNotificationChannel(
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

  /// Reads the `data` block the server attaches to every push.
  static PushTap? fromData(Map<String, dynamic>? data) {
    final kind = data?['kind'];
    if (kind is! String || kind.isEmpty) return null;
    return PushTap(kind: kind, requestId: int.tryParse('${data?['request_id']}'));
  }

  Map<String, dynamic> toJson() => {'kind': kind, 'request_id': requestId};
}

class PushService {
  PushService(this._session);

  final Session _session;
  final _local = FlutterLocalNotificationsPlugin();
  final _taps = StreamController<PushTap>.broadcast();
  final _mutedPrefixes = <String>{};
  final _subs = <StreamSubscription<dynamic>>[];

  bool _available = false;
  bool _started = false;
  String? _registered;
  PushTap? _pendingTap;

  /// Notifications the user tapped while the app was already running.
  Stream<PushTap> get taps => _taps.stream;

  /// True once Firebase is up, i.e. push can work on this build.
  bool get available => _available;

  /// The tap that launched the app, if any — consumed once, by the shell.
  PushTap? takeLaunchTap() {
    final tap = _pendingTap;
    _pendingTap = null;
    return tap;
  }

  /// Connect to Firebase and prepare the local notification channel. Safe to
  /// call before sign-in, and safe to call on a build with no Firebase config.
  Future<void> initialise() async {
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(pushBackgroundHandler);
      await _local.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            // firebase_messaging asks for these at sign-in instead, so the
            // prompt lands on a screen that can explain itself.
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
        onDidReceiveNotificationResponse: _onLocalTap,
      );
      await _local
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(_channel);
      _pendingTap =
          PushTap.fromData((await FirebaseMessaging.instance.getInitialMessage())?.data);
      _available = true;
    } catch (e) {
      // Almost always a missing google-services.json / GoogleService-Info.plist.
      debugPrint('push: disabled ($e)');
      _available = false;
    }
  }

  /// Ask for permission, register this device with the server and start
  /// listening. Called once the session is signed in; a repeat call is a no-op.
  Future<void> start() async {
    if (!_available || _started) return;
    _started = true;
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      await _register(await messaging.getToken());
      _subs
        ..add(messaging.onTokenRefresh.listen(_register))
        ..add(FirebaseMessaging.onMessage.listen(_onForegroundMessage))
        ..add(FirebaseMessaging.onMessageOpenedApp.listen((m) => _emit(m.data)));
    } catch (e) {
      debugPrint('push: could not start ($e)');
    }
  }

  /// Stop pushing to this device. Called on sign-out — before the token is
  /// dropped, so the request is still authenticated.
  Future<void> stop() async {
    _started = false;
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    final token = _registered;
    _registered = null;
    if (token == null) return;
    try {
      await _session.api.post('devices/unregister/', {'token': token});
    } catch (_) {
      // Signing out locally matters more; the server drops the token when
      // Firebase reports it unregistered anyway.
    }
  }

  /// The FCM token currently registered with the server, if any. [Session]
  /// sends it along with sign-out so the server stops pushing to this phone
  /// even when the explicit unregister call did not get through.
  String? get deviceToken => _registered;

  /// Suppress foreground banners for event kinds starting with [prefix]
  /// (`chat.`, `request.`) while the screen that shows those events live is on
  /// top — a banner over the very list that is already updating is just noise.
  /// Notifications that arrive while the app is away are unaffected: the system
  /// draws those, not us.
  void setMuted(String prefix, bool muted) {
    if (muted) {
      _mutedPrefixes.add(prefix);
    } else {
      _mutedPrefixes.remove(prefix);
    }
  }

  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    _taps.close();
  }

  // ---- internals ----

  Future<void> _register(String? token) async {
    if (token == null || token.isEmpty || token == _registered) return;
    try {
      await _session.api.post('devices/', {
        'token': token,
        'platform': Platform.isIOS ? 'ios' : 'android',
      });
      _registered = token;
    } catch (e) {
      debugPrint('push: could not register this device ($e)');
    }
  }

  void _onForegroundMessage(RemoteMessage message) {
    final notification = message.notification;
    if (notification == null) return;
    final kind = message.data['kind'] as String? ?? '';
    if (_mutedPrefixes.any(kind.startsWith)) return;
    // One notification per conversation / per request, replaced rather than
    // stacked, matching the `thread_id` the server sends. Masked because
    // Android ids are 32-bit signed.
    final tag = message.data['request_id']?.toString() ?? kind;
    _local.show(
      id: tag.hashCode & 0x7fffffff,
      title: notification.title,
      body: notification.body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.high,
          priority: Priority.high,
          ticker: notification.title,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
      payload: jsonEncode(message.data),
    );
  }

  void _onLocalTap(NotificationResponse response) {
    final raw = response.payload;
    if (raw == null || raw.isEmpty) return;
    try {
      _emit(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('push: bad notification payload ($e)');
    }
  }

  void _emit(Map<String, dynamic>? data) {
    final tap = PushTap.fromData(data);
    if (tap == null) return;
    if (_taps.hasListener) {
      _taps.add(tap);
    } else {
      // Tapped before the shell is listening (cold start) — hold it.
      _pendingTap = tap;
    }
  }
}

/// Runs in its own isolate when a message arrives and the app is not running.
///
/// The server always sends a `notification` block, so the system draws the
/// popup itself and there is nothing to do here — but firebase_messaging
/// requires a registered handler to deliver background messages at all, and
/// without one the `data` would not survive to the tap.
@pragma('vm:entry-point')
Future<void> pushBackgroundHandler(RemoteMessage message) async {}
