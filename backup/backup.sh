#!/bin/bash

echo "--- Starting Backup $(date) ---"

# 1. Configuration
export RESTIC_REPOSITORY=/backups/repo
# RESTIC_PASSWORD comes from environment variable

# 2. Initialize Repository (if not exists)
if [ ! -f "$RESTIC_REPOSITORY/config" ]; then
    echo "Initializing new Restic repository..."
    restic init
fi

# 3. Dump Database
echo "Dumping databases..."
mysqldump -h shared_mysql -u root -p"$DB_ROOT_PASSWORD" --all-databases --single-transaction --quick --lock-tables=false > /tmp/all_databases.sql

if [ $? -ne 0 ]; then
    echo "ERROR: Database dump failed!"
    exit 1
fi

# 4. Perform Backup
# We backup the Sites directory and the DB Dump
echo "Running Restic backup..."
restic backup /sites /tmp/all_databases.sql --tag "scheduled-backup"

# 5. Prune Old Backups (Retention Policy)
# Keep last 7 days, 4 weeks, and 6 months
echo "Pruning old backups..."
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune

# 6. Clean up
rm /tmp/all_databases.sql

echo "--- Backup Completed $(date) ---"
