#!/usr/bin/env python3
"""Nightly database backup for the Home Budget Tracker.

Handles both engines so the backup follows the app rather than silently dumping
an abandoned file after a database switch:

  * DATABASE_URL set  -> pg_dump custom format (-Fc), verified with `pg_restore -l`
  * otherwise         -> SQLite online backup API, verified with PRAGMA integrity_check

Either way the result is compressed, integrity-checked before it is kept, and
old backups are pruned by age (the newest is never pruned).

Invoked by homebudget-backup.timer; run by hand for an ad-hoc backup.
"""
import gzip
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path
from urllib.parse import unquote, urlparse

DEST_DIR = Path(os.environ.get('BACKUP_DIR', '/opt/homebudget/backups'))
RETENTION_DAYS = int(os.environ.get('BACKUP_RETENTION_DAYS', '30'))
DB_PATH = Path(os.environ.get('DJANGO_DB_PATH', '/opt/homebudget/data/db.sqlite3'))
DATABASE_URL = os.environ.get('DATABASE_URL', '')

PATTERNS = ('db-*.sqlite3.gz', 'pg-*.dump')


def log(msg):
    print(msg, flush=True)


def prepare_dest():
    DEST_DIR.mkdir(parents=True, exist_ok=True)
    DEST_DIR.chmod(0o700)


def stamp():
    return datetime.now().strftime('%Y%m%d-%H%M%S')


# --------------------------------------------------------------- postgres ---

def backup_postgres():
    p = urlparse(DATABASE_URL)
    name = unquote(p.path.lstrip('/'))
    env = dict(os.environ, PGPASSWORD=unquote(p.password or ''))
    final = DEST_DIR / f'pg-{stamp()}.dump'
    tmp = final.with_suffix('.dump.tmp')

    cmd = [
        'pg_dump', '--format=custom', '--compress=9', '--no-owner', '--no-acl',
        '--dbname', name,
        '--host', p.hostname or '127.0.0.1', '--port', str(p.port or 5432),
        '--username', unquote(p.username or ''), '--no-password',
        '--file', str(tmp),
    ]
    try:
        r = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=1800)
        if r.returncode != 0:
            log(f'FATAL: pg_dump failed ({r.returncode}): {r.stderr.strip()[:500]}')
            return 1

        # A dump we cannot read back is worse than no dump at all.
        v = subprocess.run(['pg_restore', '--list', str(tmp)],
                           capture_output=True, text=True, timeout=300)
        if v.returncode != 0:
            log(f'FATAL: dump is unreadable: {v.stderr.strip()[:500]}')
            return 1
        tables = sum(1 for line in v.stdout.splitlines() if 'TABLE DATA' in line)
        if tables == 0:
            log('FATAL: dump contains no table data')
            return 1

        tmp.replace(final)
        final.chmod(0o600)
        log(f'OK  {final.name}  postgres:{name}  {tables} tables  '
            f'{final.stat().st_size/1024:.0f} KiB  (pg_restore -l: readable)')
        return 0
    finally:
        tmp.unlink(missing_ok=True)


# ----------------------------------------------------------------- sqlite ---

def backup_sqlite():
    if not DB_PATH.exists():
        log(f'FATAL: database not found at {DB_PATH}')
        return 1

    final = DEST_DIR / f'db-{stamp()}.sqlite3.gz'
    tmp_fd, tmp_name = tempfile.mkstemp(dir=DEST_DIR, suffix='.tmp')
    os.close(tmp_fd)
    tmp = Path(tmp_name)

    try:
        # Online backup: SQLite handles locking and retries busy pages itself.
        src = sqlite3.connect(f'file:{DB_PATH}?mode=ro', uri=True, timeout=30)
        dst = sqlite3.connect(str(tmp))
        with dst:
            src.backup(dst)
        src.close()
        dst.close()

        check = sqlite3.connect(str(tmp))
        result = check.execute('PRAGMA integrity_check').fetchone()[0]
        tables = check.execute(
            "SELECT count(*) FROM sqlite_master WHERE type='table'").fetchone()[0]
        check.close()
        if result != 'ok':
            log(f'FATAL: integrity check failed on fresh backup: {result}')
            return 1

        with open(tmp, 'rb') as f_in, gzip.open(final, 'wb', compresslevel=9) as f_out:
            shutil.copyfileobj(f_in, f_out)
        final.chmod(0o600)

        log(f'OK  {final.name}  sqlite  {tables} tables  '
            f'{tmp.stat().st_size/1024:.0f} KiB -> {final.stat().st_size/1024:.0f} KiB  '
            f'(integrity: {result})')
        return 0
    finally:
        tmp.unlink(missing_ok=True)


# ------------------------------------------------------------------ prune ---

def existing():
    out = []
    for pat in PATTERNS:
        out += [p for p in DEST_DIR.glob(pat) if p.is_file()]
    return sorted(out, key=lambda p: p.stat().st_mtime)


def prune():
    """Delete backups older than RETENTION_DAYS, but never the newest one."""
    cutoff = time.time() - RETENTION_DAYS * 86400
    removed = 0
    for p in existing()[:-1]:                   # keep the most recent regardless
        if p.stat().st_mtime < cutoff:
            p.unlink()
            removed += 1
    kept = existing()
    total = sum(p.stat().st_size for p in kept)
    log(f'    pruned {removed} older than {RETENTION_DAYS}d; '
        f'{len(kept)} kept, {total/1024:.0f} KiB total')


if __name__ == '__main__':
    prepare_dest()
    rc = backup_postgres() if DATABASE_URL else backup_sqlite()
    if rc == 0:
        prune()
    sys.exit(rc)
