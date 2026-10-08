import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:web_socket_channel/io.dart';

import 'config.dart';
import 'notifications.dart';
import 'session.dart';

/// Notifications while the app is closed, served entirely by our own server.
///
/// An Android foreground service holds the same `/ws/notify/` socket the app
/// already uses, authenticated with the same API token, and raises a
/// notification for each event — so a money request reaches the phone without
/// Google Play Services or Firebase in the path. The alternative,
/// [PushService], needs Firebase; this one needs nothing but
/// budget.hotone.co.tz.
///
/// The trade-offs, which the user sees:
///  * Android requires a permanent "watching for requests" notification while a
///    foreground service runs. It cannot be hidden.
///  * Battery optimisation will eventually kill the service on most phones
///    unless the app is exempted, which [start] asks for.
///  * **Android only.** iOS has no equivalent — only APNs can wake a closed
///    app there — so iOS keeps [PushService].
///
/// The service runs in its own isolate, which shares no memory with the UI.
/// Everything it needs (socket URL, token, who "I" am) is handed over through
/// [FlutterForegroundTask.saveData] before it starts, and events come back the
/// other way through `sendDataToMain`.

/// True where a foreground service can keep a socket open — Android only.
bool get selfHostedAlertsSupported => defaultTargetPlatform == TargetPlatform.android;

// Keys in the plugin's shared store, written by the UI, read by the service.
const _kWsUrl = 'hb.watch.wsUrl';
const _kToken = 'hb.watch.token';
const _kUserId = 'hb.watch.userId';
const _kPendingTap = 'hb.watch.pendingTap';

/// Entry point for the service isolate. Must stay top-level.
@pragma('vm:entry-point')
void watchServiceCallback() {
  FlutterForegroundTask.setTaskHandler(_WatchTaskHandler());
}

/// Runs inside the foreground service: owns a socket, turns events into
/// notifications.
class _WatchTaskHandler extends TaskHandler {
  IOWebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _retry;
  int _attempt = 0;

  String? _wsUrl;
  String? _token;
  int? _me;

  /// Which screens are currently showing events live, so the watcher does not
  /// raise a banner over the list that is already updating. Sent by the UI.
  final Set<String> _muted = <String>{};

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // This isolate starts with no plugins registered.
    DartPluginRegistrant.ensureInitialized();
    _wsUrl = await FlutterForegroundTask.getData<String>(key: _kWsUrl);
    _token = await FlutterForegroundTask.getData<String>(key: _kToken);
    _me = await FlutterForegroundTask.getData<int>(key: _kUserId);
    EventNotifier.instance.onTap = _onNotificationTap;
    await EventNotifier.instance.initialise();
    _connect();
  }

  /// Watchdog. The socket can die without `onDone` ever firing — a dozing
  /// radio, a NAT timeout — so every tick re-checks it rather than trusting
  /// the stream callbacks alone.
  @override
  void onRepeatEvent(DateTime timestamp) {
    if (_channel == null && _retry == null) _connect();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _retry?.cancel();
    await _sub?.cancel();
    await _channel?.sink.close();
    _channel = null;
  }

  @override
  void onReceiveData(Object data) {
    // {'mute': 'chat.', 'value': bool}
    final msg = data is String ? _tryDecode(data) : data;
    if (msg is! Map) return;
    final mute = msg['mute'];
    if (mute is String) {
      if (msg['value'] == true) {
        _muted.add(mute);
      } else {
        _muted.remove(mute);
      }
    }
  }

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp();

  // ---- socket ----

  void _connect() {
    _retry?.cancel();
    _retry = null;
    final url = _wsUrl;
    final token = _token;
    if (url == null || token == null) return;
    try {
      final ch = IOWebSocketChannel.connect(
        Uri.parse(url),
        headers: {'Authorization': 'Token $token'},
        pingInterval: const Duration(seconds: 25),
      );
      _channel = ch;
      _sub = ch.stream.listen(
        (raw) {
          _attempt = 0;
          _onEvent(raw);
        },
        onError: (_) => _dropped(),
        onDone: _dropped,
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('watch: connect failed ($e)');
      _dropped();
    }
  }

  void _dropped() {
    _sub?.cancel();
    _sub = null;
    _channel = null;
    _retry?.cancel();
    // Capped backoff. onRepeatEvent is the backstop if even this is missed.
    final delay = Duration(seconds: min(60, pow(2, _attempt).toInt()));
    _attempt++;
    _retry = Timer(delay, _connect);
  }

  Future<void> _onEvent(dynamic raw) async {
    final event = _tryDecode(raw is String ? raw : '');
    if (event is! Map<String, dynamic>) return;

    // Tell the UI, if it is alive, so lists and badges refresh.
    FlutterForegroundTask.sendDataToMain(jsonEncode(event));

    final notification = event['notification'];
    if (notification is! Map) return; // not something worth a notification
    if (!_concernsMe(event, notification)) return;
    final kind = event['kind'] as String? ?? '';
    // While the app is open its own socket surfaces the event; only step in
    // for the screens that are not showing it. Asked live rather than tracked,
    // so a missed lifecycle message cannot leave this stale.
    if (_muted.any(kind.startsWith) && await FlutterForegroundTask.isAppOnForeground) {
      return;
    }

    EventNotifier.instance.show(
      kind: kind,
      title: notification['title'] as String?,
      body: notification['body'] as String?,
      data: {
        for (final k in const ['request_id', 'link', 'id', 'sender_id'])
          if (event[k] != null) k: event[k],
      },
    );
  }

  /// The same rule the server applies when choosing who to push to: the member
  /// named by `for_user_id`, or everyone bar whoever caused it.
  bool _concernsMe(Map<String, dynamic> event, Map notification) {
    final target = event['for_user_id'];
    if (target != null) return target == _me;
    final excluded = notification['exclude_user_id'];
    return excluded == null || excluded != _me;
  }

  void _onNotificationTap(PushTap tap) {
    // The UI may be dead; leave the tap where the shell will find it on start,
    // and also send it in case the UI is alive right now.
    FlutterForegroundTask.saveData(
        key: _kPendingTap, value: jsonEncode(tap.toJson()));
    FlutterForegroundTask.sendDataToMain(jsonEncode({'tap': tap.toJson()}));
    FlutterForegroundTask.launchApp();
  }

  Object? _tryDecode(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }
}

/// The UI-side handle on the watcher.
class WatchService implements BackgroundAlerts {
  WatchService(this._session);

  final Session _session;
  final _taps = StreamController<PushTap>.broadcast();
  PushTap? _pendingTap;
  bool _started = false;

  @override
  Stream<PushTap> get taps => _taps.stream;

  @override
  PushTap? takeLaunchTap() {
    final tap = _pendingTap;
    _pendingTap = null;
    return tap;
  }

  @override
  Future<void> initialise() async {
    if (!selfHostedAlertsSupported) return;
    try {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'homebudget_watch',
          channelName: 'Background connection',
          channelDescription:
              'The permanent notice Android requires while Home Budget watches '
              'for money requests and messages.',
          // Low importance: this one is housekeeping, not news. The actual
          // alerts go out on the high-importance channel in notifications.dart.
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          // The socket pushes; the tick is only the reconnect watchdog.
          eventAction: ForegroundTaskEventAction.repeat(60000),
          autoRunOnBoot: true,
          autoRunOnMyPackageReplaced: true,
          allowWakeLock: true,
          allowWifiLock: true,
        ),
      );
      FlutterForegroundTask.addTaskDataCallback(_onTaskData);
      _pendingTap = await _consumeStoredTap();
    } catch (e) {
      debugPrint('watch: init failed ($e)');
    }
  }

  @override
  Future<void> start() async {
    if (!selfHostedAlertsSupported || _started) return;
    final token = _session.api.token;
    final me = _session.user?.id;
    if (token == null || me == null) return;
    _started = true;
    try {
      await _requestPermissions();
      // Hand the isolate what it needs before it starts.
      await FlutterForegroundTask.saveData(key: _kWsUrl, value: AppConfig.wsUrl);
      await FlutterForegroundTask.saveData(key: _kToken, value: token);
      await FlutterForegroundTask.saveData(key: _kUserId, value: me);
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.restartService();
      } else {
        await FlutterForegroundTask.startService(
          serviceId: 4201,
          serviceTypes: const [ForegroundServiceTypes.remoteMessaging],
          notificationTitle: 'Home Budget',
          notificationText: 'Watching for requests and messages',
          notificationInitialRoute: '/',
          callback: watchServiceCallback,
        );
      }
    } catch (e) {
      debugPrint('watch: could not start the service ($e)');
      _started = false;
    }
  }

  @override
  Future<void> stop() async {
    _started = false;
    if (!selfHostedAlertsSupported) return;
    try {
      await FlutterForegroundTask.stopService();
      // The token is gone; don't leave it on disk for the next account.
      await FlutterForegroundTask.removeData(key: _kToken);
      await FlutterForegroundTask.removeData(key: _kUserId);
    } catch (e) {
      debugPrint('watch: could not stop the service ($e)');
    }
  }

  @override
  void setMuted(String prefix, bool muted) {
    if (!_started) return;
    try {
      FlutterForegroundTask.sendDataToTask(
          jsonEncode({'mute': prefix, 'value': muted}));
    } catch (_) {}
  }

  @override
  void dispose() {
    if (selfHostedAlertsSupported) {
      FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
    }
    _taps.close();
  }

  // ---- internals ----

  Future<void> _requestPermissions() async {
    if (await FlutterForegroundTask.checkNotificationPermission() !=
        NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    // Without this the system stops the service once the phone dozes, which is
    // the difference between notifications arriving and not.
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
  }

  void _onTaskData(Object data) {
    // Runs inside the plugin's callback, so it must not throw.
    Object? msg;
    try {
      msg = data is String ? jsonDecode(data) : data;
    } catch (e) {
      debugPrint('watch: undecodable message from the service ($e)');
      return;
    }
    if (msg is! Map) return;
    final tap = msg['tap'];
    if (tap is Map) {
      final parsed = PushTap.fromData(Map<String, dynamic>.from(tap));
      if (parsed != null) _emit(parsed);
      return;
    }
    // Any other event means household data changed; refresh the badges.
    _session.refreshBadges();
  }

  void _emit(PushTap tap) {
    if (_taps.hasListener) {
      _taps.add(tap);
    } else {
      _pendingTap = tap; // tapped before the shell is listening
    }
  }

  Future<PushTap?> _consumeStoredTap() async {
    try {
      final raw = await FlutterForegroundTask.getData<String>(key: _kPendingTap);
      if (raw == null || raw.isEmpty) return null;
      await FlutterForegroundTask.removeData(key: _kPendingTap);
      return PushTap.fromData(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('watch: could not read a stored tap ($e)');
      return null;
    }
  }
}
