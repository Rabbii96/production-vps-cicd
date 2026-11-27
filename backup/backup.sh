#!/usr/bin/env bash
# Production backup:
#   * PostgreSQL dump (pg_dump custom format, compressed) — verified with pg_restore --list
#   * AES-256 encrypted with gpg + SHA-256 checksum
#   * once a day also uploaded files + server config
#   * off-site copy to Google Drive with rclone, size verified after upload
#   * retention, a status file the admin panel reads, Discord alert on any failure
#   * --check mode = dead-man switch: alert if no successful backup for STALE_HOURS
set -Eeuo pipefail

APP_DIR="${APP_DIR:-/opt/app}"
ROOT="${BACKUP_ROOT:-/var/backups/app}"
PG_CONTAINER="${PG_CONTAINER:-app-postgres}"
PASS_FILE="${PASS_FILE:-/root/.backup-passphrase}"
REMOTE="${REMOTE:-gdrive}"
REMOTE_DIR="${REMOTE_DIR:-app-backups}"
REQUIRED_TABLE="${REQUIRED_TABLE:-orders}"     # a dump without this table's data is treated as broken
STALE_HOURS="${STALE_HOURS:-8}"
STATUS="$ROOT/status/status.json"
LOG="$ROOT/backup.log"

mkdir -p "$ROOT/db" "$ROOT/files" "$ROOT/status"
log() { echo "$(date -u +%FT%TZ) $*" | tee -a "$LOG" >&2; }

alert() {
  local url
  url="$(grep -E '^DISCORD_WEBHOOK=' "$APP_DIR/.env" 2>/dev/null | cut -d= -f2- || true)"
  [ -n "$url" ] || return 0
  curl -s -m 15 -H 'Content-Type: application/json' -d "{\"content\":\"$1\"}" "$url" >/dev/null || true
}

status_set() {   # merge key=json pairs into status.json (atomic write)
  python3 - "$STATUS" "$@" <<'PY'
import json, os, sys
path, *pairs = sys.argv[1:]
try: s = json.load(open(path))
except Exception: s = {}
for p in pairs:
    k, v = p.split("=", 1)
    try: s[k] = json.loads(v)
    except Exception: s[k] = v
tmp = path + ".tmp"; json.dump(s, open(tmp, "w"), indent=2); os.replace(tmp, path)
PY
}

# ── dead-man switch ────────────────────────────────────────────────────────────
if [ "${1:-}" = "--check" ]; then
  age_h=$(python3 - "$STATUS" <<'PY'
import json, sys, time, datetime
try:
    s = json.load(open(sys.argv[1]))
    t = datetime.datetime.fromisoformat(s["lastSuccess"].replace("Z", "+00:00")).timestamp()
    print(int((time.time() - t) / 3600))
except Exception:
    print(9999)
PY
)
  if [ "$age_h" -ge "$STALE_HOURS" ]; then
    alert "Backup STALE: no successful database backup for ${age_h}h."
    exit 1
  fi
  exit 0
fi

exec 9>"$ROOT/.lock"
flock -n 9 || { log "another backup is running"; exit 0; }
on_error() {
  local rc=$? line=$1
  log "FAILED (exit $rc) at line $line"
  status_set "lastError=\"line $line exit $rc\""
  alert "Backup FAILED at line $line (exit $rc)."
}
trap 'on_error $LINENO' ERR

[ -s "$PASS_FILE" ] || { log "missing passphrase file $PASS_FILE"; exit 2; }
STAMP="$(date +%Y%m%d-%H%M)"
TODAY="$(date +%Y%m%d)"
TIER="H"                                                          # H = hourly-tier copy
ls "$ROOT/files/files-${TODAY}"-*-D.tar.gz.gpg >/dev/null 2>&1 || TIER="D"   # first run of the day = long-term D copy
status_set "lastRun=\"$(date -u +%FT%TZ)\""

enc() { gpg --batch --yes --quiet --pinentry-mode loopback --symmetric --cipher-algo AES256 --passphrase-file "$PASS_FILE" -o "$2" "$1"; }

# ── 1. database ────────────────────────────────────────────────────────────────
RAW="$(mktemp "$ROOT/db/.dump.XXXXXX")"
trap 'rm -f "$RAW" "$RAW.toc"' EXIT
docker exec "$PG_CONTAINER" sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc -Z 9 --no-owner' > "$RAW"
[ "$(stat -c %s "$RAW")" -gt 2000 ] || { log "dump suspiciously small"; exit 3; }
docker exec -i "$PG_CONTAINER" pg_restore --list < "$RAW" > "$RAW.toc"
grep -qE "TABLE DATA public ${REQUIRED_TABLE} " "$RAW.toc" || { log "dump has no ${REQUIRED_TABLE} data"; exit 3; }
DB_FILE="$ROOT/db/db-$STAMP-$TIER.dump.gpg"
enc "$RAW" "$DB_FILE"
( cd "$ROOT/db" && sha256sum "$(basename "$DB_FILE")" > "$(basename "$DB_FILE").sha256" )
log "database dump ok: $(basename "$DB_FILE")"

# ── 2. daily: uploaded files + config ─────────────────────────────────────────
FILES_FILE=""
if [ "$TIER" = "D" ]; then
  FILES_TMP="$(mktemp "$ROOT/files/.f.XXXXXX")"
  tar -czf "$FILES_TMP" -C "$APP_DIR" public/uploads .env docker-compose.yml
  FILES_FILE="$ROOT/files/files-$STAMP-$TIER.tar.gz.gpg"
  enc "$FILES_TMP" "$FILES_FILE"
  rm -f "$FILES_TMP"
fi

# ── 3. off-site copy + verification ───────────────────────────────────────────
OFFSITE="not_configured"
if rclone listremotes 2>/dev/null | grep -qx "$REMOTE:"; then
  if rclone copy "$DB_FILE" "$REMOTE:$REMOTE_DIR/db" --retries 3 --quiet \
     && rclone copy "$DB_FILE.sha256" "$REMOTE:$REMOTE_DIR/db" --quiet \
     && { [ -z "$FILES_FILE" ] || rclone copy "$FILES_FILE" "$REMOTE:$REMOTE_DIR/files" --retries 3 --quiet; }; then
    want=$(stat -c %s "$DB_FILE")
    got=$(rclone size "$REMOTE:$REMOTE_DIR/db/$(basename "$DB_FILE")" --json | python3 -c "import json,sys;print(json.load(sys.stdin)['bytes'])" || echo -1)
    if [ "$want" = "$got" ]; then OFFSITE="ok"; else OFFSITE="size_mismatch"; fi
    rclone delete "$REMOTE:$REMOTE_DIR/db" --min-age 3d --include "*-H.dump.gpg*" --quiet || true
    rclone delete "$REMOTE:$REMOTE_DIR" --min-age 90d --include "*-D.*" --quiet || true
  else
    OFFSITE="upload_failed"
  fi
fi

# ── 4. local retention ─────────────────────────────────────────────────────────
find "$ROOT/db" -name '*-H.dump.gpg*' -mtime +3 -delete
find "$ROOT/db" "$ROOT/files" -name '*-D.*' -mtime +30 -delete

# ── 5. status + alerts ─────────────────────────────────────────────────────────
status_set "lastSuccess=\"$(date -u +%FT%TZ)\"" "lastFile=\"$(basename "$DB_FILE")\"" "offsite=\"$OFFSITE\"" "lastError=null" "tier=\"$TIER\""
log "backup complete (offsite=$OFFSITE)"
case "$OFFSITE" in
  ok) ;;
  not_configured) [ "$TIER" = "D" ] && alert "Backup is local only: off-site copy not configured." ;;
  *) alert "Off-site backup problem: $OFFSITE (local copy is safe)." ;;
esac
