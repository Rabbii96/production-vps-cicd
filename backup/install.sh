#!/usr/bin/env bash
# Installs the backup schedule on the server (idempotent). Run as root.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
chmod 750 "$D"/*.sh
mkdir -p /var/backups/app/db /var/backups/app/files /var/backups/app/status
chmod 700 /var/backups/app

if [ ! -s /root/.backup-passphrase ]; then
  umask 077
  openssl rand -base64 36 > /root/.backup-passphrase
  echo "Generated /root/.backup-passphrase -> copy it to a password manager. Without it the backups cannot be opened."
fi

cat > /etc/cron.d/app-backup <<CRON
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# backup every 6 hours
5 0,6,12,18 * * *  root $D/backup.sh >> /var/backups/app/cron.log 2>&1
# dead-man switch every hour
25 * * * *         root $D/backup.sh --check >> /var/backups/app/cron.log 2>&1
# weekly restore test (Sunday)
30 19 * * 0        root $D/restore-test.sh >> /var/backups/app/cron.log 2>&1
CRON
chmod 644 /etc/cron.d/app-backup

cat > /etc/logrotate.d/app-backup <<LR
/var/backups/app/*.log { weekly rotate 8 compress missingok notifempty }
LR
echo "Installed. Run $D/backup.sh once to test."
