FROM alpine:latest

# Install Restic, MySQL Client (for dumping DB), and Bash
RUN apk add --no-cache restic mariadb-client bash

# Create directories
RUN mkdir -p /backups /sites /scripts

# Copy backup script
COPY backup.sh /scripts/backup.sh
RUN chmod +x /scripts/backup.sh

# Setup Crontab (Run at 03:00 AM every day)
RUN echo "0 3 * * * /scripts/backup.sh >> /var/log/backup.log 2>&1" > /etc/crontabs/root

# Entrypoint: Start crond in foreground
CMD ["crond", "-f", "-d", "8"]
