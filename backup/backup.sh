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

sql_ident() {
    printf '%s' "$1" | sed 's/`/``/g'
}

safe_dump_name() {
    printf '%s' "$1" | sed 's/[^A-Za-z0-9_.-]/_/g'
}

write_database_prelude() {
    local db_name="$1"
    local out="$2"
    local db_sql
    db_sql=$(sql_ident "$db_name")

    {
        printf 'CREATE DATABASE IF NOT EXISTS `%s`;\n' "$db_sql"
        printf 'USE `%s`;\n' "$db_sql"
    } > "$out"
}

dump_db_object() {
    local db_name="$1"
    local object_name="$2"
    local object_type="$3"
    local out="$4"
    local err="${out}.err"
    local db_sql
    local order_flag=()

    db_sql=$(sql_ident "$db_name")
    if [ "$object_type" = "BASE TABLE" ]; then
        order_flag=(--order-by-primary)
    fi

    {
        printf 'CREATE DATABASE IF NOT EXISTS `%s`;\n' "$db_sql"
        printf 'USE `%s`;\n\n' "$db_sql"
        mysqldump -h shared_mysql -u root -p"$DB_ROOT_PASSWORD" \
            --skip-ssl \
            --single-transaction --quick --lock-tables=false \
            --skip-dump-date \
            "${order_flag[@]}" \
            "$db_name" "$object_name"
    } > "$out" 2>"$err"

    if [ $? -ne 0 ] || [ ! -s "$out" ]; then
        [ -s "$err" ] && sed 's/^/    /' "$err" >&2
        return 1
    fi

    rm -f "$err"
    return 0
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

# 3. Per-site database dumps. Each non-excluded site gets its own directory
# containing CREATE DATABASE plus one dump per table/view. Splitting dumps this
# way gives Restic smaller, more stable files to deduplicate between snapshots.
# The user/grant is recreated from .dockweb.conf at restore time, not stored in
# the dump.
echo "Dumping databases per site/table..."
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

    site_dump_dir="$DB_DUMP_DIR/$domain"
    mkdir -p "$site_dump_dir"
    write_database_prelude "$db_name" "$site_dump_dir/00-create-database.sql"

    objects_file="$site_dump_dir/.objects"
    objects_err="$site_dump_dir/.objects.err"
    db_sql=$(sql_ident "$db_name")
    # --skip-ssl: shared_mysql ships a self-signed cert and the client would
    # otherwise refuse to connect. Traffic stays on the docker bridge network.
    mysql -h shared_mysql -u root -p"$DB_ROOT_PASSWORD" \
        --skip-ssl --batch --skip-column-names \
        -e "SHOW FULL TABLES FROM \`$db_sql\` WHERE Table_type IN ('BASE TABLE', 'VIEW')" \
        > "$objects_file" 2>"$objects_err"

    if [ $? -ne 0 ]; then
        send_alert "Backup Failed" "could not list tables for $domain ($db_name)"
        echo "ERROR: could not list tables for $domain"
        [ -s "$objects_err" ] && sed 's/^/    /' "$objects_err" >&2
        rm -rf "$DB_DUMP_DIR"
        exit 1
    fi
    LC_ALL=C sort "$objects_file" -o "$objects_file"

    object_count=0
    while IFS=$'\t' read -r object_name object_type; do
        [ -z "$object_name" ] && continue

        case "$object_type" in
            "BASE TABLE") prefix="10" ;;
            "VIEW")       prefix="20" ;;
            *)            continue ;;
        esac

        object_count=$((object_count + 1))
        safe_name=$(safe_dump_name "$object_name")
        out="$site_dump_dir/${prefix}-$(printf '%04d' "$object_count")-${safe_name}.sql"

        if ! dump_db_object "$db_name" "$object_name" "$object_type" "$out"; then
            send_alert "Backup Failed" "mysqldump failed or empty for $domain ($db_name.$object_name)"
            echo "ERROR: dump failed for $domain ($object_name)"
            rm -rf "$DB_DUMP_DIR"
            exit 1
        fi
    done < "$objects_file"

    rm -f "$objects_file" "$objects_err"

    echo "  - $domain: dumped $object_count table/view file(s) ($(du -sh "$site_dump_dir" | cut -f1))"
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
