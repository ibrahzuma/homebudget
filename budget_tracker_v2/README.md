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

## Note

`DEBUG = True` and `SECRET_KEY` are checked in for convenience. Before deploying:
- Set `DEBUG = False`
- Move `SECRET_KEY` to an environment variable
- Set `ALLOWED_HOSTS`
- Switch to Postgres or another production database
