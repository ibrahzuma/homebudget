/// Server endpoints. Defaults to production; override for local dev with
///   flutter run --dart-define=API_ORIGIN=http://10.0.2.2:8000
/// (10.0.2.2 is the host machine from the Android emulator).
class AppConfig {
  static const String origin = String.fromEnvironment(
    'API_ORIGIN',
    defaultValue: 'https://budget.hotone.co.tz',
  );

  static String get apiBase => '$origin/api/v1';

  static String get wsUrl {
    final uri = Uri.parse(origin);
    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    return uri.replace(scheme: scheme, path: '/ws/notify/').toString();
  }

  /// Shareable invite link for a code (the web join page).
  static String inviteUrl(String code) => '$origin/join/$code/';
}
