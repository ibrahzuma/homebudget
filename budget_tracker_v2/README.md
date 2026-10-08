# Home Budget & Income Tracker — v2

A Django + Bootstrap personal finance app for two-person households with a sidebar layout and a full set of advanced features.

## Features

### Layout
- **Left sidebar navigation** (replaces the top navbar from v1) with grouped sections: Overview, Money, Smart Tools, Settings.
- Mobile-responsive with hamburger toggle.
- Topbar with quick-add buttons and an alerts bell.

### Core
- **Two-person household** — both members log their own income and expenses, see combined and per-member totals.
- **Categories, transactions, monthly budgets** with progress bars and per-member breakdown.
- **Dashboard** with stat cards, forecast, by-member breakdown, doughnut chart, budget progress, upcoming bills, recent activity.

### Advanced (new in v2)

1. **Recurring Transaction Reminders** — Auto-creates entries for fixed costs (rent, subscriptions, loans). Daily / weekly / bi-weekly / monthly / quarterly / yearly. Middleware applies due entries on each login per day.
2. **Bill Calendar View** — Monthly Mon–Sun calendar showing every projected bill with daily totals and prev/next navigation.
3. **Predictive Forecasting** — End-of-month balance projection based on daily burn rate + known recurring bills, with a cumulative-spending line chart.
4. **Smart Alerts** — Notifications when a category budget reaches 80% (warning) or 100% (danger). Alerts also fire for incoming/responded money requests.
5. **Auto-Categorization Rules** — Set rules like *"TotalEnergies" contains → Fuel*. Applied automatically on new transactions and on demand to existing uncategorized ones.
6. **Net Worth Tracker** — Track Assets (cash, bank, investments, property, vehicle) minus Liabilities (loans, mortgage, credit card). Snapshots over time with line chart.
7. **Multi-Currency Support** — Add currencies, set exchange rates. All values aggregate in the household's base currency.
8. **Data Export/Import (CSV)** — One-click CSV export of all transactions; CSV import with auto-categorization and on-the-fly category creation.
9. **Money Requests** — One member requests money with a stated purpose; the other approves or rejects. On approval, an income transaction is recorded for the requester and an expense for the approver.

## Stack
- Django 4.2+ (server-side rendering)
- Bootstrap 5.3 + Bootstrap Icons (CDN)
- Chart.js 4 for charts (CDN)
- SQLite (default; switch to Postgres in `settings.py` for production)

## Setup

```bash
cd budget_tracker_v2
pip install -r requirements.txt

python manage.py makemigrations
python manage.py migrate
python manage.py createsuperuser   # optional, for admin

python manage.py runserver
```

Open http://127.0.0.1:8000/

## Getting Started

1. Sign up at `/signup/`
2. Create your household — pick a name and base currency. Optionally add your partner's username (they need to sign up first).
3. Default categories and currencies (USD, TZS, EUR, GBP, KES) are seeded automatically.
4. Add transactions, set budgets, configure recurring entries, and create auto-categorization rules.

## URLs

| Path | Description |
|---|---|
| `/` | Dashboard |
| `/forecast/` | End-of-month forecast |
| `/networth/` | Net worth tracker |
| `/transactions/` | Transaction list with filters |
| `/recurring/` | Recurring transactions |
| `/calendar/` | Bill calendar |
| `/budgets/` | Monthly budgets |
| `/rules/` | Auto-categorization rules |
| `/alerts/` | Smart alerts |
| `/requests/` | Money requests (incoming + outgoing) |
| `/categories/` | Manage categories |
| `/currencies/` | Currencies & exchange rates |
| `/import/csv/` | CSV import & export |
| `/household/settings/` | Household members & base currency |
| `/admin/` | Django admin |

## Architecture Notes

- **`models.py`** — 13 models: `Currency`, `ExchangeRate`, `Household`, `Category`, `Transaction`, `Budget`, `RecurringTransaction`, `CategoryRule`, `Alert`, `MoneyRequest`, `Asset`, `Liability`, `NetWorthSnapshot`.
- **`services.py`** — Business logic isolated from views: `apply_due_recurring`, `check_budget_alerts`, `apply_category_rules`, `forecast_end_of_month`, `compute_net_worth`, `bills_in_month`.
- **`middleware.py`** — `AutoApplyRecurringMiddleware` runs once per session-day to create due recurring transactions and check budget alerts.
- **`context_processors.py`** — Provides `current_household`, `currency_symbol`, `unread_alerts_count`, `pending_requests_count` to every template.
- **All financial aggregation** uses `Transaction.amount_base` — the original amount converted to the household's base currency via `ExchangeRate`. Recomputed automatically when rates change.

## Money Request Flow

1. Member A goes to **Money Requests → New Request**, picks Member B as approver, fills amount, currency, purpose, and (optionally) which expense category it falls under.
2. Member B sees a notification (alert + sidebar badge), opens the request, and either:
   - **Approves** → atomically creates an income transaction for A and an expense transaction for B, both at the requested amount and category.
   - **Rejects** with an optional note → A is notified.
3. Member A can also cancel the request while it's still pending.

## Default Seed Data

- **Currencies:** USD, TZS, EUR, GBP, KES
- **Categories:** Salary, Freelance, Other Income, Groceries, Rent / Mortgage, Utilities, Fuel, Transport, Dining Out, Entertainment, Subscriptions, Healthcare

## Configuration

Settings read from the environment, falling back to dev-friendly defaults so
`runserver` works with nothing set:

| Variable | Default | Purpose |
|---|---|---|
| `DJANGO_SECRET_KEY` | insecure dev key | Signing key |
| `DJANGO_DEBUG` | `True` | Set `False` in production |
| `DJANGO_ALLOWED_HOSTS` | `*` | Comma-separated hostnames |
| `DJANGO_CSRF_TRUSTED_ORIGINS` | empty | Comma-separated scheme+host origins |
| `DJANGO_SECURE_COOKIES` | `False` | Marks session/CSRF cookies `Secure` (needs HTTPS) |
| `DATABASE_URL` | unset | `postgres://user:pass@host:port/name`; falls back to SQLite when unset |
| `DJANGO_DB_PATH` | `BASE_DIR/db.sqlite3` | SQLite location, ignored when `DATABASE_URL` is set |
| `DJANGO_CONN_MAX_AGE` | `600` | Postgres connection reuse, seconds |
| `REDIS_URL` | unset | Channels layer; falls back to in-memory when unset |
| `FCM_CREDENTIALS_FILE` | unset | Firebase service-account JSON key; unset means no mobile push notifications |
| `APK_PATH` | `BASE_DIR/releases/homebudget.apk` | Android build served from `/download/` |
| `APK_VERSION` | empty | Version shown on the download page, e.g. `1.0.0 (3)` |

Local development still uses SQLite with zero configuration — set `DATABASE_URL`
only where you want Postgres.

## Vikoba & Mchezo

Two kinds of Tanzanian savings group, at `/groups/`:

- **Vikoba** — savings you can borrow against. Contributions go out, a share-out
  comes back in, and a loan from the pool is recorded as an ordinary
  **debt linked to the group**, so it shows on the group page and under Debts
  with the existing repayment screens. No duplicate loan model.
- **Mchezo** — a rotating pot: everyone pays in on the agreed date and one
  member collects the lot, turn by turn. The rotation is stored, so the app
  knows what a full pot is worth (contribution × members), whose turn is next,
  and when yours falls.

A contribution can be recorded directly as an expense, or sent to your partner
through the **money-request** flow — then nothing hits the books until they
approve, and the approval is what creates the expense. Money collected from
either kind of group comes in as **income**.

Collection dates are reminders, not automation: `check_group_due_alerts` raises
one alert per collection date when it is within three days or overdue, and the
date steps forward as contributions are recorded.

## Mobile API

The Flutter app in `../mobile` talks to a token-authenticated JSON API under
`/api/v1/` (Django REST Framework). Endpoint reference: `../docs/mobile-api.md`.
It reuses the web forms for validation and `services.py` for every side effect,
so data entered on the phone behaves exactly like data entered in the browser.

```bash
python manage.py test budget_app     # includes tests_api.py
```

### Push notifications

`/ws/notify/` only reaches an app that is open, so events that should interrupt
someone also carry a `notification: {title, body, thread_id, exclude_user_id}`
block, and are sent through Firebase as well.

How each platform gets them while the app is closed:

- **Android needs nothing from this section.** The app keeps the same
  `/ws/notify/` socket open in a foreground service and raises its own
  notifications from that block, so delivery never leaves this server. See
  `../mobile/README.md`.
- **iOS needs Firebase**, because only APNs can wake a closed app there.

To turn on the Firebase half (iOS, or Android if you prefer it):

1. In the [Firebase console](https://console.firebase.google.com/), create a
   project and add an Android app with package name
   `tz.co.hotone.homebudget_mobile` (and an iOS app, if you ship to iOS).
2. Project settings → Service accounts → **Generate new private key**. Put the
   JSON somewhere only the service user can read, e.g.
   `/opt/homebudget/fcm-service-account.json` (chmod 600), and point
   `FCM_CREDENTIALS_FILE` at it in `/opt/homebudget/.env`.
3. `pip install -r requirements.txt` (adds `google-auth` and `requests`) and
   restart `homebudget.service`.
4. Build the app with the matching `google-services.json` — see
   `../mobile/README.md`.

Without `FCM_CREDENTIALS_FILE` everything else works exactly as before; the
Firebase calls become no-ops and Android is unaffected. Delivery happens on a background thread, so a slow or
unreachable Firebase never delays a request, and tokens Firebase reports as
unregistered are deleted automatically.

### Publishing the Android app

`/download/` is a public landing page — no account needed, so someone who was
just invited can install the app first — with a download button, the build's
version, size and date, and the three install steps Android requires.
`/download/app.apk` serves the file itself. Both are skipped gracefully when no
build has been uploaded: the page says so and the file 404s.

To publish a build:

```bash
cd mobile
flutter build apk --release
scp build/app/outputs/flutter-apk/app-release.apk     server:/opt/homebudget/releases/homebudget.apk
```

Then set `APK_PATH=/opt/homebudget/releases/homebudget.apk` and bump
`APK_VERSION` in `/opt/homebudget/.env`, and restart `homebudget.service`. The
APK lives outside the code tree so a redeploy never clobbers it, and
`releases/` plus `*.apk` are in `.gitignore` — a release build is ~25 MB of
build output and does not belong in git.

Two things worth knowing:

- The release APK is still signed with Flutter's **debug key** (see
  `mobile/README.md`). It installs fine by sideloading, but once you switch to a
  real upload keystore, everyone has to uninstall before the new build will
  install over it. Create the keystore before you hand the link to anyone you
  can't ask to reinstall.
- Django streams the file with `FileResponse`, which ties up a worker for the
  duration. That is fine at household scale; if the link ever goes wide, let
  nginx serve it directly instead:

  ```nginx
  location = /download/app.apk {
      alias /opt/homebudget/releases/homebudget.apk;
      default_type application/vnd.android.package-archive;
      add_header Content-Disposition 'attachment; filename="home-budget.apk"';
  }
  ```

## Production deployment

Live at **https://budget.hotone.co.tz** (157.173.127.96).

| Piece | Value |
|---|---|
| Code | `/opt/homebudget/src` |
| Virtualenv | `/opt/homebudget/.venv` |
| Database | PostgreSQL 16 — database `homebudget`, role `homebudget`, on `127.0.0.1:5432` |
| Environment | `/opt/homebudget/.env` (mode `600`) — holds `DATABASE_URL` |
| Service | `homebudget.service` — daphne ASGI on `127.0.0.1:8005` |
| Web server | nginx vhost `/etc/nginx/sites-available/homebudget`, TLS via Let's Encrypt |
| Channel layer | Redis db 5 |

The box runs Postgres already, with one role + one database per app; this
follows that convention. Connections use `scram-sha-256` over loopback.
The pre-cutover SQLite file is retired at
`/opt/homebudget/data/db.sqlite3.retired-20260727` and is no longer read.

Served over ASGI (not WSGI) because the chat and live notifications need
WebSockets; nginx proxies `/ws/` with the upgrade headers and a 1h read timeout.

Redeploy after changing code:

```bash
# from the repo root, upload the source tree to /opt/homebudget/src, then:
ssh root@157.173.127.96
systemctl start homebudget-backup.service    # snapshot before touching the schema
cd /opt/homebudget/src
set -a; . /opt/homebudget/.env; set +a
/opt/homebudget/.venv/bin/pip install -r requirements.txt
/opt/homebudget/.venv/bin/python manage.py migrate --noinput
/opt/homebudget/.venv/bin/python manage.py collectstatic --noinput
systemctl restart homebudget
```

Logs: `journalctl -u homebudget -f`

## Backups

`deploy/backup-db.py` runs nightly at **02:30** via `homebudget-backup.timer`
(`Persistent=true`, so a missed run fires at next boot). It follows whichever
engine is configured, so it can't silently keep dumping an abandoned file:

- `DATABASE_URL` set → `pg_dump --format=custom --compress=9`, verified with `pg_restore --list`
- otherwise → SQLite online backup API, verified with `PRAGMA integrity_check`

A snapshot that fails verification is discarded rather than kept. Backups older
than 30 days are pruned; the newest is never pruned.

- Backups: `/opt/homebudget/backups/pg-YYYYmmdd-HHMMSS.dump` (dir `700`, files `600`)
- Run on demand: `systemctl start homebudget-backup.service`
- Check history: `journalctl -u homebudget-backup`
- Next run: `systemctl list-timers homebudget-backup.timer`

Restore (verify into a scratch database first — never straight over the live one):

```bash
set -a; . /opt/homebudget/.env; set +a
PGPW=$(echo "$DATABASE_URL" | sed -E 's#.*://[^:]+:([^@]+)@.*#\1#')
DUMP=/opt/homebudget/backups/pg-YYYYmmdd-HHMMSS.dump

# 1. rehearse
sudo -u postgres createdb -O homebudget hb_restoretest
PGPASSWORD="$PGPW" pg_restore -h 127.0.0.1 -U homebudget -d hb_restoretest --no-owner "$DUMP"
sudo -u postgres psql -d hb_restoretest -c '\dt'          # eyeball it
sudo -u postgres dropdb hb_restoretest

# 2. commit
systemctl stop homebudget
sudo -u postgres psql -c 'ALTER DATABASE homebudget RENAME TO homebudget_pre_restore;'
sudo -u postgres createdb -O homebudget homebudget
PGPASSWORD="$PGPW" pg_restore -h 127.0.0.1 -U homebudget -d homebudget --no-owner "$DUMP"
systemctl start homebudget
```

**These backups live on the same disk as the database.** They cover corruption,
a bad migration, or accidental deletion — not loss of the VM. Copy them off-box
for real disaster recovery.

### Still to harden

- `SECURE_HSTS_SECONDS` is intentionally unset; enable it once you're confident
  the domain will stay on HTTPS permanently (it is hard to walk back).
- Backups are on-box only (see above).
