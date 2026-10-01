import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api.dart';
import 'models.dart';

enum SessionState { loading, signedOut, needsHousehold, ready }

/// Who is signed in, their household, sidebar badges and form pickers.
///
/// Screens read this with `context.watch<Session>()` and call [api] for data.
/// After a mutation that changes pickers (categories, projects, members,
/// currencies) call [refreshMeta]; after anything that changes badge counts
/// call [refreshMe].
class Session extends ChangeNotifier {
  Session({ApiClient? api, FlutterSecureStorage? storage})
      : api = api ?? ApiClient(),
        _storage = storage ?? const FlutterSecureStorage() {
    this.api.onUnauthorized = _handleUnauthorized;
  }

  static const _tokenKey = 'api_token';

  final ApiClient api;
  final FlutterSecureStorage _storage;

  SessionState state = SessionState.loading;
  UserBrief? user;
  String email = '';
  Household? household;
  Badges badges = Badges();
  Meta? meta;

  /// Last error from [restore] when the server couldn't be reached.
  String? startupError;

  String get currencySymbol => household?.currencySymbol ?? '\$';
  String get currencyCode => household?.currencyCode ?? 'USD';
  bool get hasPartner => (household?.members.length ?? 0) > 1;

  /// Load a saved token and fetch the profile.
  Future<void> restore() async {
    startupError = null;
    final saved = await _storage.read(key: _tokenKey);
    if (saved == null) {
      _setState(SessionState.signedOut);
      return;
    }
    api.token = saved;
    try {
      await refreshMe();
      if (household != null) await refreshMeta();
    } on ApiException catch (e) {
      if (e.isUnauthorized) return; // handled by _handleUnauthorized
      startupError = e.message;
      notifyListeners();
    }
  }

  Future<void> login(String username, String password) async {
    final res = await api.post('auth/login/', {'username': username, 'password': password});
    await _adoptToken(res['token'] as String);
  }

  Future<void> signup({
    required String username,
    required String email,
    required String password1,
    required String password2,
    String? invite,
  }) async {
    final res = await api.post('auth/signup/', {
      'username': username,
      'email': email,
      'password1': password1,
      'password2': password2,
      if (invite != null && invite.isNotEmpty) 'invite': invite,
    });
    await _adoptToken(res['token'] as String);
  }

  Future<void> logout() async {
    try {
      await api.post('auth/logout/');
    } catch (_) {
      // Signing out locally matters more than telling the server.
    }
    await _clear();
  }

  Future<void> _adoptToken(String token) async {
    api.token = token;
    await _storage.write(key: _tokenKey, value: token);
    await refreshMe();
    if (household != null) await refreshMeta();
  }

  /// Re-fetch user, household and badge counts.
  Future<void> refreshMe() async {
    final res = await api.get('me/') as Map<String, dynamic>;
    final u = res['user'] as Map<String, dynamic>;
    user = UserBrief.fromJson(u);
    email = u['email'] as String? ?? '';
    final h = res['household'];
    household = h == null ? null : Household.fromJson(h as Map<String, dynamic>);
    badges = Badges.fromJson(res['badges'] as Map<String, dynamic>?);
    _setState(household == null ? SessionState.needsHousehold : SessionState.ready);
  }

  /// Badges only; cheap enough to call after any mutation. Never throws.
  Future<void> refreshBadges() async {
    try {
      await refreshMe();
    } catch (_) {}
  }

  Future<void> refreshMeta() async {
    meta = Meta.fromJson(await api.get('meta/') as Map<String, dynamic>);
    notifyListeners();
  }

  /// After creating or joining a household.
  Future<void> householdChanged() async {
    await refreshMe();
    if (household != null) await refreshMeta();
  }

  void _handleUnauthorized() {
    if (state != SessionState.signedOut) _clear();
  }

  Future<void> _clear() async {
    api.token = null;
    user = null;
    household = null;
    meta = null;
    badges = Badges();
    await _storage.delete(key: _tokenKey);
    _setState(SessionState.signedOut);
  }

  void _setState(SessionState s) {
    state = s;
    notifyListeners();
  }
}
