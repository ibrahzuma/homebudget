import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';

import 'config.dart';
import 'session.dart';

/// Live household events over the same WebSocket the web app uses
/// (`/ws/notify/`), authenticated with the API token header.
///
/// Events are JSON maps with a `kind`: `chat.new`, `request.created`,
/// `request.approved`, `request.rejected`. Some carry `for_user_id` — only
/// that member should surface them. Listen with [events]; the connection
/// reconnects with backoff and refreshes badge counts on every event.
class Realtime {
  Realtime(this._session);

  final Session _session;
  final _controller = StreamController<Map<String, dynamic>>.broadcast();
  IOWebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _retry;
  int _attempt = 0;
  bool _wanted = false;

  Stream<Map<String, dynamic>> get events => _controller.stream;

  /// Events addressed to everyone or to the current user.
  Stream<Map<String, dynamic>> get myEvents => events.where((e) {
        final target = e['for_user_id'];
        return target == null || target == _session.user?.id;
      });

  void connect() {
    _wanted = true;
    if (_channel != null) return;
    final token = _session.api.token;
    if (token == null) return;
    try {
      final ch = IOWebSocketChannel.connect(
        Uri.parse(AppConfig.wsUrl),
        headers: {'Authorization': 'Token $token'},
        pingInterval: const Duration(seconds: 25),
      );
      _channel = ch;
      _sub = ch.stream.listen(
        (raw) {
          _attempt = 0;
          try {
            final data = jsonDecode(raw as String);
            if (data is Map<String, dynamic>) {
              _controller.add(data);
              _session.refreshBadges();
            }
          } catch (e) {
            debugPrint('realtime: bad message $e');
          }
        },
        onError: (_) => _dropped(),
        onDone: _dropped,
        cancelOnError: true,
      );
    } catch (e) {
      _dropped();
    }
  }

  void _dropped() {
    _sub?.cancel();
    _sub = null;
    _channel = null;
    if (!_wanted) return;
    _retry?.cancel();
    final delay = Duration(seconds: min(60, pow(2, _attempt).toInt()));
    _attempt++;
    _retry = Timer(delay, connect);
  }

  void disconnect() {
    _wanted = false;
    _retry?.cancel();
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
  }

  void dispose() {
    disconnect();
    _controller.close();
  }
}
