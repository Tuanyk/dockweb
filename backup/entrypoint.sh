#!/bin/bash
# Write cron schedule from environment variable (default: daily at 3am)

if [[ "${BACKUP_ENABLED:-true}" == "false" ]]; then
    echo "Backup is disabled (BACKUP_ENABLED=false). Sleeping..."
    exec sleep infinity
fi

BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-0 3 * * *}"

echo "${BACKUP_SCHEDULE} /scripts/backup.sh >> /var/log/backup.log 2>&1" > /etc/crontabs/root

echo "Backup scheduled: ${BACKUP_SCHEDULE}"

# Start crond in foreground
exec crond -f -d 8
