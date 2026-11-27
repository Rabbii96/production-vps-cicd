#!/usr/bin/env bash
# Safe production deploy, run on the VPS by the GitHub Actions deploy job.
#   1. snapshot the database      2. remember the last good commit
#   3. rebuild + recreate the app 4. wait for the Docker health check
#   5. on failure -> rollback.sh  (previous image + previous commit)
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/app}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/app/pre-deploy}"
PG_CONTAINER="${PG_CONTAINER:-app-postgres}"
STAMP="$(date +%Y%m%d_%H%M%S)"

cd "$APP_DIR"
mkdir -p "$BACKUP_DIR"

echo "1) Database snapshot before deploy"
docker exec "$PG_CONTAINER" sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$BACKUP_DIR/pre_deploy_${STAMP}.dump"
find "$BACKUP_DIR" -name 'pre_deploy_*.dump' -mtime +14 -delete   # keep two weeks of snapshots

echo "2) Remember the running image as the rollback target"
if docker image inspect app:latest >/dev/null 2>&1; then
  docker tag app:latest app:previous
fi
git rev-parse HEAD > .deployed_commit

echo "3) Build and recreate the app container (database keeps running)"
docker compose build app
docker compose up -d --no-deps --force-recreate app

echo "4) Wait for the health check"
for _ in $(seq 1 20); do
  state="$(docker inspect app --format '{{.State.Health.Status}}' 2>/dev/null || echo starting)"
  if [ "$state" = "healthy" ]; then
    echo "   app is healthy"
    docker image prune -f >/dev/null
    echo "Deploy OK ($(git rev-parse --short HEAD))"
    exit 0
  fi
  sleep 6
done

echo "5) App did not become healthy -> rolling back"
bash "$APP_DIR/scripts/rollback.sh"
exit 1
