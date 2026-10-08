#!/usr/bin/env bash
#
# One-off: turn the uploaded /opt/homebudget/src into a git checkout, so
# deploys become `git pull` instead of an rsync from someone's laptop.
#
#   sudo bash adopt-git-checkout.sh
#
# The tree at /opt/homebudget/src holds the *contents* of budget_tracker_v2/,
# while the repository keeps them one level down. Rather than rearranging the
# directory — which would break `WorkingDirectory=/opt/homebudget/src` and the
# nginx alias for staticfiles/ — this clones the repository alongside and
# replaces src with a symlink to the app directory inside it:
#
#   /opt/homebudget/repo/            <- the git checkout
#   /opt/homebudget/src -> repo/budget_tracker_v2
#
# Every configured path keeps resolving, and rolling back is one `mv`.
#
# The old tree is kept as src.uploaded-<timestamp>; nothing is deleted.
set -euo pipefail

REPO="${REPO:-/opt/homebudget/repo}"
SRC="${SRC:-/opt/homebudget/src}"
SERVICE="${SERVICE:-homebudget}"
REMOTE="${REMOTE:-https://github.com/ibrahzuma/homebudget.git}"
BACKUP="$SRC.uploaded-$(date +%Y%m%d-%H%M%S)"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mx %s\033[0m\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ preflight
[ "$(id -u)" -eq 0 ]  || die "Run with sudo."
command -v git >/dev/null || die "git is not installed: apt install git"
[ -e "$SRC" ]         || die "$SRC does not exist."
[ ! -L "$SRC" ]       && : || die "$SRC is already a symlink — this has been done."
[ -f "$SRC/manage.py" ] || die "$SRC/manage.py is missing, so this is not the
  layout this script expects. Stop and look before changing anything."

say "What the server currently has"
echo "  $SRC -> $(readlink -f "$SRC")"
NGINX_REFS="$(grep -rl "$SRC" /etc/nginx/ 2>/dev/null || true)"
if [ -n "$NGINX_REFS" ]; then
    echo "  nginx refers to it in:"; echo "$NGINX_REFS" | sed 's/^/    /'
    echo "  (the symlink keeps those paths working — no nginx change needed)"
fi

# --------------------------------------------------------------------- clone
say "Fetching the repository into $REPO"
if [ -d "$REPO/.git" ]; then
    git -C "$REPO" remote set-url origin "$REMOTE"
    git -C "$REPO" fetch --quiet origin main
    git -C "$REPO" reset --hard origin/main
else
    git clone --quiet "$REMOTE" "$REPO"
fi
APP="$REPO/budget_tracker_v2"
[ -f "$APP/manage.py" ]            || die "$APP/manage.py missing — wrong repository?"
[ -d "$APP/budget_project" ]       || die "$APP/budget_project missing; daphne imports budget_project.asgi from here."
[ -f "$APP/deploy/pull-deploy.sh" ] || die "$APP/deploy/pull-deploy.sh missing; is main up to date?"
echo "  at $(git -C "$REPO" rev-parse --short HEAD) — $(git -C "$REPO" log -1 --format=%s)"

# ------------------------------------------------- anything only on the server
# Build artefacts and local databases are expected to differ; a source file that
# exists only on the server is not, and the swap would hide it.
say "Checking for files that exist only on the server"
ONLY="$(diff -rq "$SRC" "$APP" 2>/dev/null \
        | grep "^Only in $SRC" \
        | grep -vE 'staticfiles|__pycache__|\.pyc|db\.sqlite3|\.env|releases' || true)"
if [ -n "$ONLY" ]; then
    echo "$ONLY" | sed 's/^/  /'
    if [ "${CONFIRM:-}" != "1" ]; then
        die "The files above are on the server but not in the repository, and the
  symlink would hide them (they stay readable in $BACKUP).
  Copy anything you need into the repository and push it, then re-run.
  To proceed anyway: CONFIRM=1 sudo -E bash $0"
    fi
    warn "Proceeding with CONFIRM=1 — those files will only exist in $BACKUP."
else
    echo "  nothing unexpected"
fi

# ----------------------------------------------------------------- the swap
rollback() {
    warn "Rolling back"
    [ -L "$SRC" ] && rm -f "$SRC"
    [ -d "$BACKUP" ] && [ ! -e "$SRC" ] && mv "$BACKUP" "$SRC"
    systemctl start "$SERVICE" || true
    sleep 2
    systemctl is-active --quiet "$SERVICE" \
        && echo "  back on the old tree, service active" \
        || warn "service is NOT active — check: journalctl -u $SERVICE -n 40"
}
trap 'rollback; die "Failed. The old tree is back in place."' ERR

say "Swapping $SRC for a symlink"
systemctl stop "$SERVICE"
mv "$SRC" "$BACKUP"
ln -s "$APP" "$SRC"
echo "  $SRC -> $(readlink "$SRC")"
echo "  old tree kept at $BACKUP"

# ------------------------------------------------------------------- deploy
# pull-deploy.sh does the rest: snapshot, deps, migrate, collectstatic, restart
# and the smoke test. It resolves the symlink, so SRC stays as configured.
say "Handing over to pull-deploy.sh"
trap - ERR
if bash "$APP/deploy/pull-deploy.sh"; then
    say "Done"
    cat <<NOTE
  From now on, deploy with:
      sudo $SRC/deploy/pull-deploy.sh

  To undo this change:
      systemctl stop $SERVICE
      rm $SRC && mv $BACKUP $SRC
      systemctl start $SERVICE
NOTE
else
    warn "The deploy step failed. The symlink is in place but the service may be down."
    cat <<NOTE
  Look at:   journalctl -u $SERVICE -n 50
  Roll back: systemctl stop $SERVICE && rm $SRC && mv $BACKUP $SRC && systemctl start $SERVICE
NOTE
    exit 1
fi
