FROM alpine:latest

# Install Restic, MySQL Client (for dumping DB), Bash, and tzdata
# (tzdata lets crond honor the BACKUP_TIMEZONE env var so schedules
# run in the operator's local time rather than UTC.)
RUN apk add --no-cache restic mariadb-client bash tzdata

# Create directories
RUN mkdir -p /backups /sites /scripts

# Copy scripts
COPY backup.sh /scripts/backup.sh
COPY entrypoint.sh /scripts/entrypoint.sh
RUN chmod +x /scripts/backup.sh /scripts/entrypoint.sh

# Copy test restore if exists
COPY test-restore.sh /scripts/test-restore.sh
RUN chmod +x /scripts/test-restore.sh 2>/dev/null || true

# Entrypoint: configure cron from env, then start crond
CMD ["/scripts/entrypoint.sh"]
