import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'events.dart';

/// Error from the API. [fieldErrors] mirrors Django form errors:
/// `{"amount": ["This field is required."], "non_field_errors": [...]}`.
class ApiException implements Exception {
  ApiException(this.statusCode, this.message, [this.fieldErrors = const {}]);

  final int statusCode;
  final String message;
  final Map<String, List<String>> fieldErrors;

  bool get isUnauthorized => statusCode == 401;
  bool get isNoHousehold => statusCode == 409;
  bool get isNetwork => statusCode == 0;

  /// First error for [field], if any.
  String? errorFor(String field) {
    final e = fieldErrors[field];
    return (e == null || e.isEmpty) ? null : e.first;
  }

  @override
  String toString() => message;
}

/// Thin JSON client for /api/v1/. Paths are relative, e.g. `transactions/`.
class ApiClient {
  ApiClient({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;
  String? token;

  /// Called on any 401 so the session can drop the stale token.
  void Function()? onUnauthorized;

  static const _timeout = Duration(seconds: 30);

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final q = <String, String>{};
    query?.forEach((k, v) {
      if (v != null && v.toString().isNotEmpty) q[k] = v.toString();
    });
    return Uri.parse('${AppConfig.apiBase}/$path')
        .replace(queryParameters: q.isEmpty ? null : q);
  }

  Map<String, String> get _headers => {
        'Accept': 'application/json',
        if (token != null) 'Authorization': 'Token $token',
      };

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) =>
      _send(() => _http.get(_uri(path, query), headers: _headers));

  Future<dynamic> post(String path, [Object? body]) => _write(path, () => _http.post(
        _uri(path),
        headers: {..._headers, 'Content-Type': 'application/json'},
        body: jsonEncode(body ?? {}),
      ));

  Future<dynamic> patch(String path, Object body) => _write(path, () => _http.patch(
        _uri(path),
        headers: {..._headers, 'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ));

  Future<dynamic> delete(String path) =>
      _write(path, () => _http.delete(_uri(path), headers: _headers));

  /// Multipart upload of a single file under [field].
  Future<dynamic> upload(String path, String field, String filePath) {
    return _write(path, () async {
      final req = http.MultipartRequest('POST', _uri(path))
        ..headers.addAll(_headers)
        ..files.add(await http.MultipartFile.fromPath(field, filePath));
      return http.Response.fromStream(await _http.send(req));
    });
  }

  /// Raw bytes (CSV exports).
  Future<List<int>> download(String path, {Map<String, dynamic>? query}) async {
    final res = await _raw(() => _http.get(_uri(path, query), headers: _headers));
    return res.bodyBytes;
  }

  Future<dynamic> _write(String path, Future<http.Response> Function() call) async {
    final result = await _send(call);
    noteWrite(path);
    return result;
  }

  Future<dynamic> _send(Future<http.Response> Function() call) async {
    final res = await _raw(call);
    if (res.statusCode == 204 || res.bodyBytes.isEmpty) return null;
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  Future<http.Response> _raw(Future<http.Response> Function() call) async {
    http.Response res;
    try {
      res = await call().timeout(_timeout);
    } on SocketException {
      throw ApiException(0, 'No connection. Check your internet and try again.');
    } on TimeoutException {
      throw ApiException(0, 'The server took too long to respond.');
    } on http.ClientException catch (e) {
      throw ApiException(0, 'Network error: ${e.message}');
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return res;
    throw _error(res);
  }

  ApiException _error(http.Response res) {
    if (res.statusCode == 401) onUnauthorized?.call();
    dynamic body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      body = null;
    }
    final fields = <String, List<String>>{};
    String? message;
    if (body is Map) {
      if (body['detail'] != null) message = body['detail'].toString();
      body.forEach((k, v) {
        if (k == 'detail') return;
        if (v is List) {
          fields[k.toString()] = v.map((e) => e.toString()).toList();
        } else if (v is String) {
          fields[k.toString()] = [v];
        }
      });
      message ??= fields['non_field_errors']?.first ??
          (fields.isNotEmpty ? 'Please fix the highlighted fields.' : null);
    } else if (body is List && body.isNotEmpty) {
      message = body.first.toString();
    }
    message ??= switch (res.statusCode) {
      403 => "You don't have permission to do that.",
      404 => 'Not found.',
      429 => 'Too many attempts. Wait a minute and try again.',
      >= 500 => 'Server error (${res.statusCode}). Try again shortly.',
      _ => 'Request failed (${res.statusCode}).',
    };
    return ApiException(res.statusCode, message, fields);
  }
}
