FROM alpine:latest

# Install Restic, MySQL Client (for dumping DB), Bash, and tzdata.
# - mariadb-connector-c brings the caching_sha2_password.so auth plugin into
#   /usr/lib/mariadb/plugin/. MySQL 8.4 uses caching_sha2_password by default
#   and rejects clients that can't load the plugin, so mariadb-client alone
#   isn't enough.
# - tzdata lets crond honor the BACKUP_TIMEZONE env var so schedules run in
#   the operator's local time rather than UTC.
RUN apk add --no-cache restic mariadb-client mariadb-connector-c bash tzdata

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
