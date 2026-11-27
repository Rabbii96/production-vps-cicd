#!/usr/bin/env bash
# Puts the previous working image back in seconds (no rebuild), then alerts.
# The database is not touched; pre-deploy snapshots are in /var/backups/app/pre-deploy if a migration went wrong.
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/app}"
cd "$APP_DIR"

if ! docker image inspect app:previous >/dev/null 2>&1; then
  echo "No app:previous image to roll back to" >&2
  exit 1
fi

docker tag app:previous app:latest
docker compose up -d --no-deps --force-recreate --no-build app
echo "Rolled back to the previous image."

# Optional alert
WEBHOOK="$(grep -E '^DISCORD_WEBHOOK=' .env 2>/dev/null | cut -d= -f2- || true)"
if [ -n "$WEBHOOK" ]; then
  curl -s -m 15 -H 'Content-Type: application/json' \
    -d '{"content":"Deploy failed its health check, production was rolled back to the previous image."}' "$WEBHOOK" >/dev/null || true
fi
