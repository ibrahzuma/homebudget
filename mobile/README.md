# Home Budget — mobile app

Flutter (Android and iOS) client for the Home Budget household finance app. It
talks to the production server at **https://budget.hotone.co.tz** through the
token-authenticated JSON API (`/api/v1/`, see [`../docs/mobile-api.md`](../docs/mobile-api.md))
and the same `/ws/notify/` WebSocket the website uses for live chat and request
notifications.

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
configure `signingConfigs` in `android/app/build.gradle.kts`.

## Structure

```
lib/
├── main.dart                 app, theme, AuthGate (login → household setup → shell)
├── core/
│   ├── config.dart           server origin (API_ORIGIN dart-define)
│   ├── api.dart              ApiClient + ApiException (Django form errors per field)
│   ├── session.dart          token in secure storage, me/household/badges, form pickers (meta/)
│   ├── realtime.dart         WebSocket with token header, auto-reconnect
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
