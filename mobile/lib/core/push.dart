import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'notifications.dart';
import 'session.dart';

/// Notifications while the app is closed, delivered through Firebase.
///
/// Used on **iOS**, where only APNs can wake a closed app and Firebase is the
/// simplest way to reach it. Android uses [WatchService] instead, which keeps
/// everything on our own server — see `watch_service.dart`.
///
/// The server sends these from `budget_app/push.py` to the FCM token this class
/// registers at `POST devices/`. The system draws the notification while the app
/// is away; in the foreground Firebase hands the message to us and
/// [EventNotifier] draws it, unless the screen already showing the event live is
/// on top ([setMuted]).
///
/// Everything here is best-effort. A build with no Firebase config — no
/// `ios/Runner/GoogleService-Info.plist`, no `android/app/google-services.json`
/// — logs one line and runs with push disabled; nothing else changes.
class PushService implements BackgroundAlerts {
  PushService(this._session);

  final Session _session;
  final _taps = StreamController<PushTap>.broadcast();
  final _mutedPrefixes = <String>{};
  final _subs = <StreamSubscription<dynamic>>[];

  bool _available = false;
  bool _started = false;
  String? _registered;
  PushTap? _pendingTap;

  @override
  Stream<PushTap> get taps => _taps.stream;

  /// True once Firebase is up, i.e. push can work on this build.
  bool get available => _available;

  /// The FCM token currently registered with the server, if any.
  String? get deviceToken => _registered;

  @override
  PushTap? takeLaunchTap() {
    final tap = _pendingTap;
    _pendingTap = null;
    return tap;
  }

  @override
  Future<void> initialise() async {
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(pushBackgroundHandler);
      EventNotifier.instance.onTap = _emitTap;
      await EventNotifier.instance.initialise();
      _pendingTap =
          PushTap.fromData((await FirebaseMessaging.instance.getInitialMessage())?.data) ??
              await EventNotifier.instance.launchTap();
      _available = true;
    } catch (e) {
      // Almost always a missing google-services.json / GoogleService-Info.plist.
      debugPrint('push: disabled ($e)');
      _available = false;
    }
  }

  @override
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
        ..add(FirebaseMessaging.onMessageOpenedApp.listen((m) {
          final tap = PushTap.fromData(m.data);
          if (tap != null) _emitTap(tap);
        }));
    } catch (e) {
      debugPrint('push: could not start ($e)');
    }
  }

  /// Unregister this device. Called on sign-out, before the token is dropped,
  /// so the request is still authenticated.
  @override
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

  @override
  void setMuted(String prefix, bool muted) {
    if (muted) {
      _mutedPrefixes.add(prefix);
    } else {
      _mutedPrefixes.remove(prefix);
    }
  }

  @override
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
    EventNotifier.instance.show(
      kind: kind,
      title: notification.title,
      body: notification.body,
      data: message.data,
    );
  }

  void _emitTap(PushTap tap) {
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
