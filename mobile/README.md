# Home Budget — mobile app

Flutter (Android and iOS) client for the Home Budget household finance app. It
talks to the production server at **https://budget.hotone.co.tz** through the
token-authenticated JSON API (`/api/v1/`, see [`../docs/mobile-api.md`](../docs/mobile-api.md))
and the same `/ws/notify/` WebSocket the website uses for live chat and request
notifications, plus Firebase Cloud Messaging so those notifications still arrive
when the app is closed.

It covers every section of the web app: dashboard, transactions (filters, search,
infinite scroll), categories, budgets, recurring items, the cash-flow calendar, the
forecast, auto-categorise rules, alerts, money requests with approve/reject,
household chat, net worth and assets, debts and payments, money lent and repayments,
savings goals, vikoba and mchezo groups, projects, meetings and action items,
currencies and exchange rates,
the monthly report, CSV import/export, and household settings with invite links.

## Run

```bash
cd mobile
flutter pub get
flutter run                          # against production
```

Against a local dev server (`python manage.py runserver 0.0.0.0:8000`):

```bash
flutter run --dart-define=API_ORIGIN=http://10.0.2.2:8000     # Android emulator
flutter run --dart-define=API_ORIGIN=http://192.168.x.y:8000  # physical device on your LAN
```

Debug builds allow cleartext HTTP so this works. Release builds only talk HTTPS.

## Build

```bash
flutter build apk --release          # android/app/build/outputs/flutter-apk/app-release.apk
flutter build appbundle --release    # Play Store
flutter build ipa                    # on macOS, with signing set up in Xcode
```

The Android release build is still signed with the **debug key** (Flutter's
default). Before you publish to the Play Store, create an upload keystore and
configure `signingConfigs` in `android/app/build.gradle.kts`. Note that
switching keys later forces everyone who already installed the app to uninstall
it first.

### Publishing it for download

The server hosts the APK at **https://budget.hotone.co.tz/download/** — a public
page with install instructions, linked from the login screen. Copy a release
build to the path the server's `APK_PATH` points at and bump `APK_VERSION`; the
steps are in [`../budget_tracker_v2/README.md`](../budget_tracker_v2/README.md#publishing-the-android-app).

## Notifications

Money requests, approvals and chat messages reach the phone even when the app is
closed. Three pieces, all raising the same notification through
`lib/core/notifications.dart`:

| | When | Needs |
|---|---|---|
| `realtime.dart` | app open | nothing — the `/ws/notify/` socket |
| `watch_service.dart` | **Android**, app closed | nothing — our own server |
| `push.dart` | **iOS**, app closed | a Firebase project |

`main.dart` picks the second or third by platform (`selfHostedAlertsSupported`),
behind one `BackgroundAlerts` interface, so nothing above that layer knows which
is running.

### Android: the watcher (no Google, no Firebase)

An Android foreground service keeps the same `/ws/notify/` socket open with the
same API token and raises notifications itself, so nothing leaves
budget.hotone.co.tz. The service runs in its own isolate: the socket URL, token
and user id are handed over through the plugin's shared store before it starts,
and events come back through `sendDataToMain` so open screens still refresh.

What the user sees, and the honest limits:

- **A permanent low-priority notice** ("Watching for requests and messages").
  Android requires it while a foreground service runs; it cannot be hidden. The
  actual alerts arrive on a separate high-importance channel.
- **Battery optimisation must be off for the app**, or the system kills the
  service once the phone dozes. `start()` asks for the exemption at sign-in —
  if the user declines, notifications stop arriving once the phone sleeps.
  Tecno, Infinix, Xiaomi and Oppo are the aggressive ones; some need the app
  added to a "protected apps" list by hand, which no API can do for you.
- The service is declared `foregroundServiceType="remoteMessaging"`, which is
  the type Android intends for exactly this and, unlike `dataSync`, is not
  capped at 6 hours a day on Android 15.
- A dead socket is caught two ways: `onDone`/`onError` reconnect with capped
  backoff, and a 60-second watchdog tick reconnects if the socket vanished
  without either firing.

Nothing to configure — it works against whatever `API_ORIGIN` the build points
at.

### iOS: Firebase

Only APNs can wake a closed app on iOS, so there is no self-hosted option
there. `PushService` registers an FCM token at `POST devices/` and the server
sends through Firebase (`budget_app/push.py`).

1. Create a Firebase project (the same one the server points
   `FCM_CREDENTIALS_FILE` at — see `../budget_tracker_v2/README.md`).
2. Add an iOS app with bundle id `tz.co.hotone.homebudgetMobile`, put
   `GoogleService-Info.plist` in `ios/Runner/` **and add it to the Runner target
   in Xcode** (a file on disk alone is not enough). Upload an APNs
   authentication key under Project settings → Cloud Messaging; this needs a
   paid Apple Developer account. `ios/Runner/Runner.entitlements` and the
   `remote-notification` background mode are already committed.

The Firebase path still works on Android if you would rather use it — add
`android/app/google-services.json` and flip `selfHostedAlertsSupported` in
`watch_service.dart`. The Gradle plugin is applied only when that file exists,
so a build without it still compiles.

Server-side configuration, including which events notify whom, is in
[`../docs/mobile-api.md`](../docs/mobile-api.md#push-notifications).

Android draws the notification icon as a white silhouette. The app currently
points at `@mipmap/ic_launcher`, so a one-colour `drawable/ic_notification` is
worth adding before release (referenced from `AndroidManifest.xml`).

## Structure

```
lib/
├── main.dart                 app, theme, AuthGate (login → household setup → shell)
├── core/
│   ├── config.dart           server origin (API_ORIGIN dart-define)
│   ├── api.dart              ApiClient + ApiException (Django form errors per field)
│   ├── session.dart          token in secure storage, me/household/badges, form pickers (meta/)
│   ├── realtime.dart         WebSocket with token header, auto-reconnect
│   ├── notifications.dart    the notification channel, drawing them, tap payloads, BackgroundAlerts
│   ├── watch_service.dart    Android foreground service holding the socket open (self-hosted)
│   ├── push.dart             FCM registration and delivery (iOS)
│   ├── models.dart           typed models for every API payload
│   ├── format.dart           money/date formatting
│   └── icons.dart            Bootstrap icon names (stored by the server) → Material icons
├── widgets/
│   ├── common.dart           LoadBuilder, empty/error states, stat tiles, dialogs
│   └── entity_form.dart      declarative create/edit forms (FieldSpec) with server-side errors inline
└── screens/                  one folder per feature; shell.dart = bottom tabs, more_screen.dart = everything else
```

Forms use the Django form field names, so validation errors from the server
show up under the matching field. All business rules live on the server.
For example, approving a request records the expense, a debt payment lowers the
balance, and a contribution can complete a goal. The app only calls endpoints.
