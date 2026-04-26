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

# Read a KEY=value from a .dockweb.conf, stripping any surrounding quotes
# and trailing CR. Echoes empty string when missing.
read_conf_val() {
    local conf="$1"
    local key="$2"
    [ -f "$conf" ] || { echo ""; return; }
    awk -v k="$key" '
        index($0, k "=") == 1 {
            v = substr($0, length(k) + 2)
            sub(/\r$/, "", v)
            f = substr(v,1,1); l = substr(v,length(v),1)
            if ((f=="\"" && l=="\"") || (f=="\047" && l=="\047")) v = substr(v,2,length(v)-2)
            print v; exit
        }
    ' "$conf"
}

is_excluded() {
    local domain="$1"
    [ -z "$BACKUP_EXCLUDE_SITES" ] && return 1
    local IFS=','
    local d
    for d in $BACKUP_EXCLUDE_SITES; do
        d=$(echo "$d" | xargs)  # trim
        [ "$d" = "$domain" ] && return 0
    done
    return 1
}

echo "--- Starting Backup $(date) ---"

# 1. Configuration
export RESTIC_REPOSITORY=/backups/repo
SITES_ROOT="/var/www/sites"
DB_DUMP_DIR="/tmp/db_dumps"

# 2. Initialize Repository (if not exists)
if [ ! -f "$RESTIC_REPOSITORY/config" ]; then
    echo "Initializing new Restic repository..."
    restic init
    if [ $? -ne 0 ]; then
        send_alert "Backup Failed" "Failed to initialize Restic repository"
        exit 1
    fi
fi

# 3. Per-site database dumps. Each non-excluded site gets its own
# .sql file containing CREATE DATABASE + schema + data, so it can be
# restored independently. The user/grant is recreated from .dockweb.conf
# at restore time, not stored in the dump.
echo "Dumping databases per site..."
rm -rf "$DB_DUMP_DIR"
mkdir -p "$DB_DUMP_DIR"

DUMPED_COUNT=0
SKIPPED_COUNT=0
for conf in "$SITES_ROOT"/*/.dockweb.conf; do
    [ -f "$conf" ] || continue
    domain=$(read_conf_val "$conf" "DOMAIN")
    db_name=$(read_conf_val "$conf" "DB_NAME")

    [ -z "$domain" ] && continue
    if [ -z "$db_name" ]; then
        echo "  - $domain: no DB_NAME in conf, skipping DB dump"
        continue
    fi

    if is_excluded "$domain"; then
        echo "  - $domain: excluded (skipping DB dump)"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        continue
    fi

    out="$DB_DUMP_DIR/${domain}.sql"
    mysqldump -h shared_mysql -u root -p"$DB_ROOT_PASSWORD" \
        --databases "$db_name" \
        --single-transaction --quick --lock-tables=false \
        > "$out" 2>/dev/null

    if [ $? -ne 0 ] || [ ! -s "$out" ]; then
        send_alert "Backup Failed" "mysqldump failed or empty for $domain ($db_name)"
        echo "ERROR: dump failed for $domain"
        rm -rf "$DB_DUMP_DIR"
        exit 1
    fi

    echo "  - $domain: dumped ($(wc -c < "$out") bytes)"
    DUMPED_COUNT=$((DUMPED_COUNT + 1))
done

if [ "$DUMPED_COUNT" -eq 0 ]; then
    echo "WARNING: no site databases dumped (excluded=$SKIPPED_COUNT)."
fi

# 4. Perform Backup. Files (/var/www/sites) and per-site DB dumps go into
# the same snapshot. Exclude flags drop the file tree for excluded sites;
# their DB dumps were skipped above, so they're absent from both layers.
echo "Running Restic backup..."

EXCLUDE_FLAGS=""
if [ -n "$BACKUP_EXCLUDE_SITES" ]; then
    IFS=',' read -ra EXCLUDED <<< "$BACKUP_EXCLUDE_SITES"
    for domain in "${EXCLUDED[@]}"; do
        domain=$(echo "$domain" | xargs)
        if [ -n "$domain" ]; then
            EXCLUDE_FLAGS="$EXCLUDE_FLAGS --exclude $SITES_ROOT/$domain"
            echo "Excluding files: $domain"
        fi
    done
fi

restic backup "$SITES_ROOT" "$DB_DUMP_DIR" --tag "scheduled-backup" $EXCLUDE_FLAGS

if [ $? -ne 0 ]; then
    send_alert "Backup Failed" "Restic backup command failed"
    rm -rf "$DB_DUMP_DIR"
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
rm -rf "$DB_DUMP_DIR"

# 8. Show statistics
echo "Backup Statistics:"
restic stats latest --mode raw-data

echo "--- Backup Completed Successfully $(date) ---"
