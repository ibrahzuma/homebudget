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
savings goals, projects, meetings and action items, currencies and exchange rates,
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

## Push notifications

Money requests, approvals and chat messages pop up on the phone even when the
app is closed. Two paths carry the same events:

- **`/ws/notify/` WebSocket** (`lib/core/realtime.dart`) while the app is open —
  live list updates, badges and in-app snackbars.
- **Firebase Cloud Messaging** (`lib/core/push.dart`) for everything else.
  Android and iOS draw the notification themselves while the app is away;
  tapping it opens the request or the chat tab. In the foreground the app draws
  the banner itself, and skips it while the tab that already shows the event
  live is on top.

The app runs fine **without** Firebase configured — `PushService` logs one line
and disables itself, the Gradle plugin is skipped when `google-services.json` is
absent, and the WebSocket keeps working. Only background notifications are lost.

### Setting it up

1. Create a Firebase project (the same one the server points
   `FCM_CREDENTIALS_FILE` at — see `../budget_tracker_v2/README.md`).
2. **Android:** add an Android app with package name
   `tz.co.hotone.homebudget_mobile`, download `google-services.json` and put it
   at `android/app/google-services.json`.
3. **iOS:** add an iOS app with the same bundle id, put
   `GoogleService-Info.plist` in `ios/Runner/` **and add it to the Runner target
   in Xcode** (a file on disk alone is not enough). Then upload an APNs
   authentication key under Project settings → Cloud Messaging; push on iOS
   needs a paid Apple Developer account. `ios/Runner/Runner.entitlements` and
   the `remote-notification` background mode are already committed.
4. `flutter run` and sign in. The app asks for notification permission, then
   registers its FCM token with `POST devices/`; it re-registers whenever
   Firebase rotates the token, and unregisters on sign-out.

Server-side configuration, including which events push to whom, is in
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
│   ├── push.dart             FCM registration, notifications while the app is away, tap routing
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
