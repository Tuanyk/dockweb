#!/bin/bash
# dockweb - backup management

# Restic repo path inside the backup container
_RESTIC_REPO="/backups/repo"

# Run restic command inside backup container with repo env set
_restic() {
    docker exec -e RESTIC_REPOSITORY="$_RESTIC_REPO" backup_service restic "$@"
}

_backup_check_running() {
    if ! docker ps --format '{{.Names}}' | grep -q '^backup_service$'; then
        log_error "Backup container is not running. Start services first."
        return 1
    fi
}

cmd_backup_now() {
    header "Running Backup"
    _backup_check_running || return 1

    log_info "Starting backup (database + site files)..."
    docker exec backup_service /scripts/backup.sh
    log_success "Backup complete!"
}

cmd_backup_list() {
    header "Backup Snapshots"
    _backup_check_running || return 1

    _restic snapshots
}

cmd_backup_restore() {
    header "Restore Backup"
    _backup_check_running || return 1

    # List snapshots
    echo ""
    _restic snapshots
    echo ""

    echo -ne "  Snapshot ID to restore (or 'latest'): "
    read -r snapshot_id
    [[ -z "$snapshot_id" ]] && snapshot_id="latest"

    echo ""
    echo "  Restore what?"
    echo "    1) Site files only"
    echo "    2) Database only"
    echo "    3) Everything"
    echo ""
    echo -ne "  Choose [1-3]: "
    read -r restore_choice

    echo ""
    if ! confirm_dangerous \
        "Restore from backup" \
        "Current site files and/or database will be overwritten" \
        "Sites may be briefly unavailable during restore"; then
        log_info "Cancelled."
        return 0
    fi

    case "$restore_choice" in
        1)
            log_info "Restoring site files..."
            _restic restore "$snapshot_id" --target / --include "/sites"
            log_success "Site files restored."
            ;;
        2)
            log_info "Restoring database dump..."
            _restic restore "$snapshot_id" --target /tmp/restore --include "all_databases.sql"

            load_env
            log_info "Importing database..."
            docker exec backup_service sh -c "cat /tmp/restore/tmp/all_databases.sql | mysql -h shared_mysql -u root -p'${DB_ROOT_PASSWORD}'"
            docker exec backup_service rm -rf /tmp/restore
            log_success "Database restored."
            ;;
        3)
            log_info "Restoring site files..."
            _restic restore "$snapshot_id" --target / --include "/sites"

            log_info "Restoring database..."
            _restic restore "$snapshot_id" --target /tmp/restore --include "all_databases.sql"

            load_env
            docker exec backup_service sh -c "cat /tmp/restore/tmp/all_databases.sql | mysql -h shared_mysql -u root -p'${DB_ROOT_PASSWORD}'"
            docker exec backup_service rm -rf /tmp/restore
            log_success "Full restore complete."
            ;;
        *)
            log_error "Invalid choice."
            return 1
            ;;
    esac
}

cmd_backup_test() {
    header "Testing Backup Restore"
    _backup_check_running || return 1

    log_info "Running restore test (safe, non-destructive)..."
    docker exec backup_service /scripts/test-restore.sh
}
