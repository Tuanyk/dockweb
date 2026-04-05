#!/bin/bash
# dockweb - backup management

cmd_backup_now() {
    header "Running Backup"

    if ! docker ps --format '{{.Names}}' | grep -q '^backup_service$'; then
        log_error "Backup container is not running. Start services first."
        return 1
    fi

    log_info "Starting backup (database + site files)..."
    docker exec backup_service /scripts/backup.sh
    log_success "Backup complete!"
}

cmd_backup_list() {
    header "Backup Snapshots"

    if ! docker ps --format '{{.Names}}' | grep -q '^backup_service$'; then
        log_error "Backup container is not running."
        return 1
    fi

    docker exec backup_service restic snapshots
}

cmd_backup_restore() {
    header "Restore Backup"

    if ! docker ps --format '{{.Names}}' | grep -q '^backup_service$'; then
        log_error "Backup container is not running."
        return 1
    fi

    # List snapshots
    echo ""
    docker exec backup_service restic snapshots
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
            docker exec backup_service restic restore "$snapshot_id" --target / --include "/sites"
            log_success "Site files restored."
            ;;
        2)
            log_info "Restoring database dump..."
            docker exec backup_service restic restore "$snapshot_id" --target /tmp/restore --include "all_databases.sql"

            load_env
            log_info "Importing database..."
            docker exec backup_service sh -c "cat /tmp/restore/tmp/all_databases.sql | mysql -h shared_mysql -u root -p'${DB_ROOT_PASSWORD}'"
            docker exec backup_service rm -rf /tmp/restore
            log_success "Database restored."
            ;;
        3)
            log_info "Restoring site files..."
            docker exec backup_service restic restore "$snapshot_id" --target / --include "/sites"

            log_info "Restoring database..."
            docker exec backup_service restic restore "$snapshot_id" --target /tmp/restore --include "all_databases.sql"

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

    if ! docker ps --format '{{.Names}}' | grep -q '^backup_service$'; then
        log_error "Backup container is not running."
        return 1
    fi

    log_info "Running restore test (safe, non-destructive)..."
    docker exec backup_service /scripts/test-restore.sh
}
