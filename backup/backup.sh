#!/bin/bash

# Function to send alert
send_alert() {
    local subject="$1"
    local message="$2"

    echo "[ALERT] $subject: $message"

    # If email is configured, send it
    if [ -n "$ALERT_EMAIL" ]; then
        echo "$message" | mail -s "$subject" "$ALERT_EMAIL" 2>/dev/null || true
    fi
}

echo "--- Starting Backup $(date) ---"

# 1. Configuration
export RESTIC_REPOSITORY=/backups/repo
# RESTIC_PASSWORD comes from environment variable

# 2. Initialize Repository (if not exists)
if [ ! -f "$RESTIC_REPOSITORY/config" ]; then
    echo "Initializing new Restic repository..."
    restic init
    if [ $? -ne 0 ]; then
        send_alert "Backup Failed" "Failed to initialize Restic repository"
        exit 1
    fi
fi

# 3. Dump Database
echo "Dumping databases..."
mysqldump -h shared_mysql -u root -p"$DB_ROOT_PASSWORD" --all-databases --single-transaction --quick --lock-tables=false > /tmp/all_databases.sql

if [ $? -ne 0 ]; then
    send_alert "Backup Failed" "Database dump failed"
    echo "ERROR: Database dump failed!"
    exit 1
fi

# Verify dump is not empty
if [ ! -s /tmp/all_databases.sql ]; then
    send_alert "Backup Failed" "Database dump is empty"
    echo "ERROR: Database dump is empty!"
    rm /tmp/all_databases.sql
    exit 1
fi

# Calculate checksum
DUMP_CHECKSUM=$(md5sum /tmp/all_databases.sql | awk '{print $1}')
echo "Database dump checksum: $DUMP_CHECKSUM"

# 4. Perform Backup
echo "Running Restic backup..."

# Build exclude flags from BACKUP_EXCLUDE_SITES (comma-separated domains)
EXCLUDE_FLAGS=""
if [ -n "$BACKUP_EXCLUDE_SITES" ]; then
    IFS=',' read -ra EXCLUDED <<< "$BACKUP_EXCLUDE_SITES"
    for domain in "${EXCLUDED[@]}"; do
        domain=$(echo "$domain" | xargs)  # trim whitespace
        if [ -n "$domain" ]; then
            EXCLUDE_FLAGS="$EXCLUDE_FLAGS --exclude /sites/$domain"
            echo "Excluding from backup: $domain"
        fi
    done
fi

restic backup /sites /tmp/all_databases.sql --tag "scheduled-backup" $EXCLUDE_FLAGS

if [ $? -ne 0 ]; then
    send_alert "Backup Failed" "Restic backup command failed"
    rm /tmp/all_databases.sql
    exit 1
fi

# 5. Verify backup integrity
echo "Verifying backup integrity..."
restic check --read-data-subset=5%

if [ $? -ne 0 ]; then
    send_alert "Backup Warning" "Backup integrity check failed"
    echo "WARNING: Backup integrity check failed!"
fi

# 6. Prune Old Backups (Retention Policy)
KEEP_DAILY="${BACKUP_KEEP_DAILY:-7}"
KEEP_WEEKLY="${BACKUP_KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${BACKUP_KEEP_MONTHLY:-6}"
echo "Pruning old backups (keep: ${KEEP_DAILY}d/${KEEP_WEEKLY}w/${KEEP_MONTHLY}m)..."
restic forget --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" --prune

# 7. Clean up
rm /tmp/all_databases.sql

# 8. Show statistics
echo "Backup Statistics:"
restic stats latest --mode raw-data

echo "--- Backup Completed Successfully $(date) ---"
