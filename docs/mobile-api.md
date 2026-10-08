# Mobile API (`/api/v1/`)

JSON API used by the Flutter app in `mobile/`. Served by the same Django
process as the web UI (`budget_tracker_v2/budget_app/api/`).

- **Base URL:** `https://budget.hotone.co.tz/api/v1/`
- **Auth:** `Authorization: Token <key>` on every request except login/signup.
  Tokens come from `auth/login/` or `auth/signup/` and are revoked by `auth/logout/`.
- **Scope:** every endpoint works on the caller's household, resolved with
  `resolve_user_household()`, the same resolver the web UI uses. Rows from other households return 404.
- **Validation:** input runs through the same Django forms as the web UI. A 400
  returns `{"field": ["message", ...], "non_field_errors": [...]}`.
- **Other errors:** `{"detail": "..."}`. 401 means a bad token, 403 means the action isn't
  allowed (for example, approving your own request), and 409 means no household yet
  (`code: no_household`).
- **Money** is always a decimal **string** (`"1250.00"`). Percentages are numbers.
  Dates are `YYYY-MM-DD`. Datetimes are ISO-8601 in Africa/Dar_es_Salaam.
- **Writes** take ids for foreign keys (`category`, `currency`, `project`,
  `approver`, `owner`) and lists of ids for `participants`. `PATCH` is partial:
  any field you leave out keeps its value.
- **Throttling:** `auth/login/` and `auth/signup/` allow 10 requests a minute per client.
- **Daily catch-up:** the first API call each day per user applies due recurring
  transactions and creates budget/meeting alerts. The middleware does the same
  for web sessions.

## Endpoints

| Method | Path | Notes |
|---|---|---|
| POST | `auth/login/` | `{username, password}` → `{token, user}` |
| POST | `auth/signup/` | `{username, email, password1, password2, invite?}` → `{token, user}`. A valid `invite` joins that household immediately. |
| POST | `auth/logout/` | Deletes the token. Optional `{device_token}` also unregisters that phone from push |
| POST | `devices/` | `{token, platform}` (`android`/`ios`) registers this install's FCM token → 204. Idempotent; a token already on file moves to the caller |
| POST | `devices/unregister/` | `{token}` stops push to this install → 204 |
| GET | `me/` | `{user{id,username,email}, household\|null, badges{unread_alerts,pending_requests,unread_chat}\|null}` |
| GET | `meta/` | Picker data: `currencies`, `categories`, `members`, active `projects`, `choices{<enum>: [{value,label}]}` |
| GET / POST / PATCH | `household/` | GET: settings incl. `members`, `pending_invites`, `past_invites`. POST: create `{name, base_currency?, partner_username?}`. PATCH: `{name?, base_currency?}` |
| POST | `household/join/` | `{code}`: a bare code or a pasted `/join/<code>/` URL |
| POST | `household/members/` | `{username}` adds an existing user |
| DELETE | `household/members/<user_id>/` | Can't remove yourself |
| POST | `household/invites/` | `{note?}` → invitation (`code`, `path`) |
| POST | `household/invites/<id>/revoke/` | |
| GET | `dashboard/` | Month totals, per-member split, budgets, recent, upcoming recurring, forecast, net worth, pending approvals, goals, next meeting, lent/owed |
| GET / POST | `transactions/` | Filters: `type`, `member`, `category`, `project`, `uncategorized=1`, `date_from`, `date_to`, `q`, `page`, `page_size` (≤200). Returns `{count, page, page_size, has_next, results, totals{income,expense}}` |
| GET / PATCH / DELETE | `transactions/<id>/` | |
| GET | `transactions/export/` | CSV |
| POST | `transactions/import/` | multipart `file` (≤5 MB) → `{created, errors[]}` |
| GET / POST | `categories/` | `{name, category_type, color, icon}` |
| PATCH / DELETE | `categories/<id>/` | |
| GET / POST | `budgets/` | `{category, monthly_limit, month}` (month is normalised to the 1st). Rows include `spent`, `pct`, `over` for the current month |
| GET / PATCH / DELETE | `budgets/<id>/` | |
| GET / POST | `recurring/` | `next_due_date` defaults to `start_date` |
| GET / PATCH / DELETE | `recurring/<id>/` | |
| POST | `recurring/run-now/` | Applies everything due → `{created, transactions[]}` |
| GET | `calendar/?year=&month=` | Mon–Sun weeks of projected recurring income/expense |
| GET | `forecast/` | End-of-month projection |
| GET / POST | `rules/` | `{pattern, match_type, case_sensitive, category, priority, is_active}` |
| PATCH / DELETE | `rules/<id>/` | |
| POST | `rules/apply/` | Categorises uncategorised transactions → `{categorized}` |
| GET | `alerts/?unread=1` | Paginated; only household-wide alerts and alerts for you |
| POST | `alerts/<id>/read/`, `alerts/read-all/` | |
| GET / POST | `requests/` | GET → `{incoming[], outgoing[]}`. POST `{approver, amount, currency?, purpose, category?, notes?}` (needs 2+ members) |
| GET | `requests/<id>/` | Includes `can_respond`, `can_cancel` |
| POST | `requests/<id>/approve/` · `reject/` · `cancel/` | `{note?}`. Approve records one expense for the requester |
| GET | `networth/` | Totals, by-type breakdowns, `assets[]`, `liabilities[]`, last 24 `snapshots[]` |
| POST | `networth/snapshot/` | Saves today's snapshot |
| GET / POST | `assets/` · GET / PATCH / DELETE `assets/<id>/` | Currency defaults to base |
| GET / POST | `debts/` | GET → `{results[], total_balance, total_paid}` |
| GET / PATCH / DELETE | `debts/<id>/` | Detail includes `payments[]` |
| POST | `debts/<id>/payments/` | `{date, amount, currency?, notes?, record_as_expense?, expense_category?}`. Lowers the balance |
| DELETE | `debts/<id>/payments/<pid>/` | Restores the balance and removes the linked expense |
| GET / POST | `lent/` | GET → `{results[], total_outstanding, total_received, overdue_count}`. POST accepts `record_as_expense` |
| GET / PATCH / DELETE | `lent/<id>/` | Detail includes `payments[]` |
| POST / DELETE | `lent/<id>/repayments/` · `lent/<id>/repayments/<pid>/` | POST `{date, amount, currency?, notes?, record_as_income?}`. Marks it paid when the balance hits 0 |
| GET / POST | `goals/` · GET / PATCH / DELETE `goals/<id>/` | Detail includes `contributions[]` |
| POST / DELETE | `goals/<id>/contributions/` · `.../<cid>/` | POST `{amount, date, notes?, record_as_expense?}`. Switches the goal to `achieved` when it reaches the target |
| GET / POST | `projects/` · GET / PATCH / DELETE `projects/<id>/` | Detail includes up to 200 `transactions[]` |
| GET / POST | `currencies/` | GET → `{currencies[], rates[]}` (works before you have a household) |
| POST | `currencies/rates/` | `{from_currency, to_currency, rate}`. Recomputes base amounts |
| GET | `reports/monthly/?year=&month=` | Full monthly report |
| GET | `reports/monthly/<y>/<m>/csv/` | CSV |
| GET / POST | `chat/` | GET `?limit=50&before=<id>&after=<id>` → `{results[] oldest-first, has_more}`. Loading the latest page marks the chat read. POST `{body}` |
| POST | `chat/read/` | |
| GET / POST | `meetings/` | GET → `{results[], open_count, overdue_count, next_suggested_date, next_suggested_title}`. POST: `participants` defaults to all members, `carry_over_open_items` defaults to true |
| GET / PATCH / DELETE | `meetings/<id>/` | Detail includes `items[]` |
| POST | `meetings/<id>/items/` | Agreement item |
| PATCH / DELETE | `meetings/<id>/items/<iid>/` | |
| POST | `meetings/<id>/items/<iid>/quick/` | `{status?, progress?}` |

## Real-time

Connect to `wss://budget.hotone.co.tz/ws/notify/` with the same
`Authorization: Token <key>` header. That is the same socket the web app uses.
Each message is a JSON object with a `kind`:

- `chat.new`: `{id, sender_id, sender_name, body, created_at}`
- `request.created` · `request.approved` · `request.rejected`: `{message, link, level, for_user_id, request_id}`

Only the member named in `for_user_id` should surface an event that carries one.

## Push notifications

The socket above only reaches an app that is **running**. For a notification
that has to appear while the app is backgrounded or closed, the server also
sends the event through Firebase Cloud Messaging (`budget_app/push.py`) to every
device token registered at `POST devices/`.

Which events push, and to whom:

| Event | Recipient | Title / body |
|---|---|---|
| `request.created` | the approver | `Money request from <user>` / `<amount> for <purpose>` |
| `request.approved` · `request.rejected` | the requester | `Request approved/rejected by <user>` / the purpose |
| `chat.new` | every member except the sender | the sender's name / the message |

Each message carries both a `notification` block — so Android and iOS draw the
popup themselves while the app is away — and a `data` block holding the same
routing keys as the WebSocket event (`kind`, `link`, `request_id`, `id`,
`sender_id`), which is what the app reads to open the right screen on a tap.
Android messages are high priority and target the `homebudget_default` channel,
which the app must have created; `thread_id` (`chat-<household>`,
`request-<id>`) groups notifications that should replace each other.

The server only pushes when `FCM_CREDENTIALS_FILE` is set to a Firebase
service-account key. With it unset the API behaves identically, minus the push.
Tokens Firebase reports as unregistered are deleted automatically, so a client
that never calls `devices/unregister/` does no harm.
