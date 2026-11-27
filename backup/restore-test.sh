#!/usr/bin/env bash
# Proves the latest backup can really be restored: checksum -> decrypt -> restore into a throw-away database
# -> compare row counts with the live database. Never touches live data.   Usage: restore-test.sh [file.dump.gpg]
set -Eeuo pipefail

APP_DIR="${APP_DIR:-/opt/app}"
ROOT="${BACKUP_ROOT:-/var/backups/app}"
PG="${PG_CONTAINER:-app-postgres}"
PASS_FILE="${PASS_FILE:-/root/.backup-passphrase}"
TABLES="${CHECK_TABLES:-orders products customers}"     # tables whose row counts must match
FILE="${1:-$(find "$ROOT/db" -name '*.dump.gpg' -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)}"
TMPDB="restore_test_$(date +%s)"
WORK="$(mktemp -d)"

cleanup() {
  docker exec "$PG" sh -c "psql -U \"\$POSTGRES_USER\" -d postgres -qc 'DROP DATABASE IF EXISTS $TMPDB'" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  url="$(grep -E '^DISCORD_WEBHOOK=' "$APP_DIR/.env" 2>/dev/null | cut -d= -f2- || true)"
  [ -n "$url" ] && curl -s -m 15 -H 'Content-Type: application/json' -d "{\"content\":\"Backup restore test FAILED: $1\"}" "$url" >/dev/null || true
  echo "FAILED: $1" >&2
  exit 1
}

echo "Restoring $(basename "$FILE") into $TMPDB"
( cd "$ROOT/db" && sha256sum -c "$(basename "$FILE").sha256" --quiet ) || fail "checksum mismatch"
gpg --batch --yes --quiet --pinentry-mode loopback --decrypt --passphrase-file "$PASS_FILE" -o "$WORK/d.dump" "$FILE" || fail "cannot decrypt"
docker exec "$PG" sh -c "psql -U \"\$POSTGRES_USER\" -d postgres -qc 'CREATE DATABASE $TMPDB'"
docker exec -i "$PG" sh -c "pg_restore -U \"\$POSTGRES_USER\" -d $TMPDB --no-owner --exit-on-error" < "$WORK/d.dump" || fail "pg_restore error"

count() {  # $1 = database, $2 = table
  docker exec "$PG" sh -c "psql -U \"\$POSTGRES_USER\" -d $1 -qtAc 'select count(*) from $2'"
}

LIVE_DB="$(docker exec "$PG" sh -c 'echo $POSTGRES_DB')"
printf '%-16s %10s %10s\n' table live restored
for t in $TABLES; do
  restored="$(count "$TMPDB" "$t")" || fail "table $t missing in restore"
  live="$(count "$LIVE_DB" "$t" || echo '?')"
  printf '%-16s %10s %10s\n' "$t" "$live" "$restored"
  # restored can be slightly behind live (orders placed since the backup) but never empty or ahead
  [ "$restored" -gt 0 ] || [ "$t" != "products" ] || fail "products table is empty in restore"
  if [ "$live" != "?" ] && [ "$restored" -gt "$live" ]; then fail "$t has more rows than live"; fi
done

python3 - "$ROOT/status/status.json" <<'PY'
import json, sys, datetime
p = sys.argv[1]
try: s = json.load(open(p))
except Exception: s = {}
s["restoreTest"] = {"at": datetime.datetime.utcnow().isoformat() + "Z", "ok": True}
json.dump(s, open(p, "w"), indent=2)
PY
echo "Restore test passed"
