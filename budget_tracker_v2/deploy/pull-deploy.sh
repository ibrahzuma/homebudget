#!/usr/bin/env bash
#
# Pull the latest code and bring production up to date, on the box itself.
#
#   sudo /opt/homebudget/src/deploy/pull-deploy.sh
#
# Does, in order: snapshot the database, pull, install dependencies, migrate,
# collect static files, restart daphne, and check it came back. Stops at the
# first failure rather than leaving a half-deployed service.
#
# Safe to re-run: every step is idempotent, and a run with nothing to pull just
# reinstalls and restarts.
set -euo pipefail

SRC="${SRC:-/opt/homebudget/src}"
VENV="${VENV:-/opt/homebudget/.venv}"
ENV_FILE="${ENV_FILE:-/opt/homebudget/.env}"
SERVICE="${SERVICE:-homebudget}"
PY="$VENV/bin/python"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mx %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run this with sudo: systemctl and the venv need root."
[ -d "$SRC" ]        || die "No source tree at $SRC (override with SRC=...)."
[ -x "$PY" ]         || die "No interpreter at $PY (override with VENV=...)."
[ -f "$ENV_FILE" ]   || die "No environment file at $ENV_FILE. Without it Django
  would fall back to SQLite and 'migrate' would quietly build the wrong database."

# manage.py sits at the root of the uploaded tree, but a git checkout of the
# whole repository keeps it one level down. Handle both.
if   [ -f "$SRC/manage.py" ];                    then APP_DIR="$SRC"
elif [ -f "$SRC/budget_tracker_v2/manage.py" ];  then APP_DIR="$SRC/budget_tracker_v2"
else die "Can't find manage.py under $SRC."
fi
say "Using $APP_DIR"

# ---------------------------------------------------------------- 1. snapshot
# Before any schema change, so there is something to go back to. The timer unit
# verifies its own output and discards a snapshot that fails (deploy/backup-db.py).
if systemctl list-unit-files | grep -q '^homebudget-backup\.service'; then
    say "Snapshotting the database"
    systemctl start homebudget-backup.service
    sleep 2
    systemctl is-active --quiet homebudget-backup.service \
        && echo "  still running; continuing (it finishes on its own)" \
        || journalctl -u homebudget-backup.service -n 3 --no-pager | sed 's/^/  /'
else
    echo "  (no backup unit installed — skipping the snapshot)"
fi

# -------------------------------------------------------------------- 2. pull
say "Pulling the latest code"
if git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1; then
    BEFORE="$(git -C "$SRC" rev-parse HEAD)"
    git -C "$SRC" pull --ff-only
    AFTER="$(git -C "$SRC" rev-parse HEAD)"
    if [ "$BEFORE" = "$AFTER" ]; then
        echo "  already up to date at ${AFTER:0:8}"
    else
        git -C "$SRC" --no-pager log --oneline "$BEFORE..$AFTER" | sed 's/^/  /'
    fi
else
    die "$SRC is not a git checkout, so there is nothing to pull.

  This tree was uploaded rather than cloned, and it holds the *contents* of
  budget_tracker_v2/ — manage.py is at its root. The repository keeps manage.py
  one level down, so do NOT 'git init && git reset --hard' in place: that would
  rearrange this directory and break the unit file that points at it.

  Clone alongside and point SRC at the app directory inside it instead:

      git clone https://github.com/ibrahzuma/homebudget.git /opt/homebudget/repo
      # then either run this script with
      #     SRC=/opt/homebudget/repo sudo -E $0
      # or switch the service over for good: set
      #     WorkingDirectory=/opt/homebudget/repo/budget_tracker_v2
      # in 'systemctl edit --full $SERVICE', keeping the old tree until the new
      # one has served a request.

  Or keep uploading: rsync the new code over $SRC and re-run — every step after
  the pull works the same either way."
fi

# ------------------------------------------------------- 3. environment + deps
# Export everything in .env so DATABASE_URL, REDIS_URL and the rest are set for
# the management commands below. Without this, migrate targets the dev SQLite.
set -a; . "$ENV_FILE"; set +a
[ -n "${DATABASE_URL:-}" ] \
    || echo "  warning: DATABASE_URL is not set — Django will use SQLite"

say "Installing dependencies"
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet -r "$APP_DIR/requirements.txt"

# ----------------------------------------------------------------- 4. migrate
cd "$APP_DIR"
say "Applying migrations"
PENDING="$("$PY" manage.py showmigrations --plan 2>/dev/null | grep -c '^\[ \]' || true)"
echo "  $PENDING pending"
"$PY" manage.py migrate --noinput

say "Collecting static files"
"$PY" manage.py collectstatic --noinput | tail -2 | sed 's/^/  /'

say "Checking the project"
"$PY" manage.py check --deploy 2>&1 | tail -15 | sed 's/^/  /' || true

# ----------------------------------------------------------------- 5. restart
say "Restarting $SERVICE"
systemctl restart "$SERVICE"
sleep 3
if systemctl is-active --quiet "$SERVICE"; then
    echo "  active"
else
    journalctl -u "$SERVICE" -n 30 --no-pager | sed 's/^/  /'
    die "$SERVICE did not come back. The log above is the reason; the database
  snapshot from step 1 is in /opt/homebudget/backups if you need to roll back."
fi

# ------------------------------------------------------------------ 6. smoke
say "Smoke test"
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:8005/login/ || echo 000)"
case "$CODE" in
    200|302) echo "  daphne answered $CODE on 127.0.0.1:8005" ;;
    *)       die "daphne answered '$CODE' — check: journalctl -u $SERVICE -n 50" ;;
esac
PUBLIC="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 https://budget.hotone.co.tz/login/ || echo 000)"
echo "  https://budget.hotone.co.tz/login/ → $PUBLIC"

say "Done"
cat <<'NOTE'
  Not handled here, because the file lives on your machine, not the server:
  publishing a new Android build. To do that, copy the APK up and point the
  download page at it:

      scp mobile/build/app/outputs/flutter-apk/app-release.apk \
          root@157.173.127.96:/opt/homebudget/releases/homebudget.apk

  then set APK_PATH=/opt/homebudget/releases/homebudget.apk and bump
  APK_VERSION in /opt/homebudget/.env, and run this script again.

  Logs: journalctl -u homebudget -f
NOTE
