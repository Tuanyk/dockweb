#!/bin/bash
# Write cron schedule from environment variable (default: daily at 3am)

if [[ "${BACKUP_ENABLED:-true}" == "false" ]]; then
    echo "Backup is disabled (BACKUP_ENABLED=false). Sleeping..."
    exec sleep infinity
fi

BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-0 3 * * *}"
BACKUP_TIMEZONE="${BACKUP_TIMEZONE:-UTC}"

# Apply timezone so crond interprets BACKUP_SCHEDULE in local time.
# tzdata is installed in the image; an unknown zone falls back to UTC.
if [ -f "/usr/share/zoneinfo/${BACKUP_TIMEZONE}" ]; then
    cp "/usr/share/zoneinfo/${BACKUP_TIMEZONE}" /etc/localtime
    echo "${BACKUP_TIMEZONE}" > /etc/timezone
    export TZ="${BACKUP_TIMEZONE}"
else
    echo "WARNING: unknown timezone '${BACKUP_TIMEZONE}', falling back to UTC."
    export TZ="UTC"
fi

echo "${BACKUP_SCHEDULE} /scripts/backup.sh >> /proc/1/fd/1 2>> /proc/1/fd/2" > /etc/crontabs/root

echo "Backup scheduled: ${BACKUP_SCHEDULE} (timezone: ${TZ})"
echo "Container time now: $(date)"

# Start crond in foreground
exec crond -f -d 8
