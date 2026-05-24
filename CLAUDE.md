# Project: Home Budget Tracker (v2)

A Django 4.2 personal-finance web app for **two-person households**, server-rendered with Bootstrap 5 + Chart.js. SQLite by default.

## Layout

```
homebudget/
├── README.md                          ← skeleton placeholder
└── budget_tracker_v2/                 ← actual Django project root
    ├── manage.py
    ├── requirements.txt               ← only Django>=4.2,<5.0
    ├── db.sqlite3                     ← checked-in dev database
    ├── README.md                      ← real feature & setup docs
    ├── budget_project/                ← Django project config
    │   ├── settings.py                ← DEBUG=True, SECRET_KEY in source (dev only)
    │   ├── urls.py                    ← admin + auth + include budget_app.urls
    │   └── wsgi.py
    └── budget_app/                    ← the single app where everything lives
        ├── models.py                  ← 13 models (~450 lines)
        ├── views.py                   ← all views, ~1178 lines
        ├── forms.py                   ← Bootstrap-styled ModelForms
        ├── services.py                ← business logic (recurring, alerts, forecast, net worth)
        ├── middleware.py              ← AutoApplyRecurringMiddleware (per-session-day cron)
        ├── context_processors.py      ← household_context (household, currency, badge counts)
        ├── urls.py                    ← all app URLs
        ├── admin.py                   ← every model registered with default ModelAdmin
        ├── apps.py
        ├── migrations/0001_initial.py
        └── templates/budget_app/      ← 35 templates (one per CRUD page)
```

## Run

```bash
cd budget_tracker_v2
pip install -r requirements.txt
python manage.py migrate
python manage.py runserver       # http://127.0.0.1:8000/
```

Sign up at `/signup/`, then `/household/setup/` to create the household. `seed_household_defaults()` in `views.py` auto-creates 5 currencies (USD, TZS, EUR, GBP, KES) and 12 default categories on household creation.

## Domain model (`budget_app/models.py`)

| Model | Role |
|---|---|
| `Currency`, `ExchangeRate` | Multi-currency. Rate is `from → to`; conversion tries direct, then inverse. |
| `Household` | M2M to `User`. Has a `base_currency`. The pivot all data hangs off. |
| `Category` | Per-household. `income` or `expense`. Bootstrap-icon class + color. |
| `Transaction` | `amount` (original) + `amount_base` (auto-converted in `save()`). Has `source` field: manual/recurring/request/import. |
| `Budget` | One per (household, category, month). Tracks `alert_80_sent` / `alert_100_sent` flags to avoid spam. |
| `RecurringTransaction` | daily/weekly/biweekly/monthly/quarterly/yearly. `next_due_date` advances via `advance_due_date()`. |
| `CategoryRule` | contains/equals/starts-with against `payee + description`. `priority` ascending. |
| `Alert` | Optional `user` (null = household-wide). info/warning/danger. |
| `MoneyRequest` | pending/approved/rejected/cancelled. On approval: atomically creates paired income+expense transactions. |
| `Asset`, `Liability`, `NetWorthSnapshot` | Net worth tracking with optional periodic snapshots. |

Important invariants:
- **All aggregation uses `Transaction.amount_base`** — never sum `amount` directly across mixed currencies.
- `Transaction.save()` recomputes `amount_base` when null; pass `recompute_base=True` to force.
- `Category` is `SET_NULL` on `Transaction` (transactions survive category deletion); `Household` is `CASCADE` everywhere (deleting a household wipes all its data).

## Request lifecycle

1. `AutoApplyRecurringMiddleware` (in `MIDDLEWARE`) runs on every authenticated request. Once per session-day it calls `apply_due_recurring(household)` and `check_budget_alerts(household)`. Errors are swallowed so background work never breaks the page.
2. `household_context` processor injects `current_household`, `currency_symbol`, `currency_code`, `unread_alerts_count`, `pending_requests_count` into every template (drives the sidebar badges).
3. Views use the `@login_required` + custom `ensure_household` decorator pattern; `get_user_household(user) = user.households.first()` (one household per user assumed).

## Service layer (`budget_app/services.py`)

Business logic isolated from views — call from views or middleware:

- `apply_due_recurring(household, today)` — catches up to 24 occurrences per recurring entry to handle long gaps. Calls `apply_category_rules` on each created transaction.
- `apply_category_rules(transaction)` — only fires when category is null and rule type matches transaction type.
- `check_budget_alerts(household, today)` — fires 80% warning and 100% danger alerts; sets `alert_*_sent` flags. `reset_monthly_budget_alerts` clears them.
- `forecast_end_of_month(household)` — actual + (daily rate × days remaining) + known upcoming recurring. Note: incoming side is dampened by `* 0.3` (treats unknown future income conservatively).
- `compute_net_worth(household)` — sums `Asset.value` − `Liability.balance`, converting each via `ExchangeRate`. Returns totals + per-type breakdown.
- `bills_in_month(household, target_date)` — projects recurring expenses across a month for the calendar view. Has a 60-iteration guard.

## URL map (`budget_app/urls.py`)

Auth (`/login/`, `/logout/`) and `/admin/` live in `budget_project/urls.py`. Everything else is in `budget_app/urls.py`: dashboard `/`, `/signup/`, `/household/{setup,settings}/`, CRUD for `/transactions/`, `/categories/`, `/budgets/`, `/recurring/` (+ `/recurring/run-now/`), `/rules/` (+ `/rules/apply/`), `/alerts/`, `/requests/`, `/networth/` (+ `/assets/`, `/liabilities/`, `/networth/snapshot/`), `/currencies/` (+ `/currencies/rates/new/`), `/import/csv/` & `/export/csv/`, `/forecast/`, `/calendar/`.

## Stack

- **Backend:** Django 4.2 (server-rendered), only dependency.
- **Frontend:** Bootstrap 5.3 + Bootstrap Icons + Chart.js 4, all via CDN. No build step. Forms styled via `BootstrapMixin` in `forms.py`.
- **DB:** SQLite committed to repo (`db.sqlite3`). README says swap to Postgres for production.
- **Time zone:** `Africa/Dar_es_Salaam`.

## Production hardening to-do (per README)

`DEBUG = True`, hardcoded `SECRET_KEY`, and `ALLOWED_HOSTS = ['*']` are checked in for dev convenience. Before deploying: move secrets to env vars, set `DEBUG = False`, restrict `ALLOWED_HOSTS`, switch the database engine.
