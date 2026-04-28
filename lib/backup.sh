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
            _restic_restore_files "$snapshot_id"
            ;;
        2)
            _restic_restore_db "$snapshot_id"
            ;;
        3)
            _restic_restore_files "$snapshot_id"
            _restic_restore_db "$snapshot_id"
            log_success "Full restore complete."
            ;;
        *)
            log_error "Invalid choice."
            return 1
            ;;
    esac
}

# Restore site files. Handles new (/var/www/sites) and legacy (/sites) layouts.
_restic_restore_files() {
    local snapshot="$1"
    log_info "Restoring site files..."
    # New layout (current backup script writes here)
    _restic restore "$snapshot" --target / --include /var/www/sites 2>/dev/null || true
    # Legacy snapshots wrote to /sites (the path was buggy then but /sites still
    # contains the empty restic baseline — including it is harmless).
    _restic restore "$snapshot" --target / --include /sites 2>/dev/null || true
    log_success "Site files restored."
}

# Import one site's current per-table dump directory.
_backup_import_dump_dir() {
    local site="$1"
    docker exec -e DB_ROOT_PASSWORD="$DB_ROOT_PASSWORD" backup_service sh -c '
        set -e
        site="$1"
        dir="/tmp/restore/tmp/db_dumps/$site"
        {
            printf "%s\n" "SET FOREIGN_KEY_CHECKS=0;"
            find "$dir" -maxdepth 1 -type f -name "*.sql" | sort | while IFS= read -r f; do
                cat "$f"
                printf "\n"
            done
            printf "%s\n" "SET FOREIGN_KEY_CHECKS=1;"
        } | mysql -h shared_mysql -u root -p"$DB_ROOT_PASSWORD" --skip-ssl
    ' sh "$site"
}

# Import one legacy top-level per-site SQL dump.
_backup_import_dump_file() {
    local dump="$1"
    docker exec -e DB_ROOT_PASSWORD="$DB_ROOT_PASSWORD" backup_service sh -c '
        set -e
        dump="$1"
        mysql -h shared_mysql -u root -p"$DB_ROOT_PASSWORD" --skip-ssl < "/tmp/restore/tmp/db_dumps/$dump"
    ' sh "$dump"
}

# Restore databases. Supports current per-table dumps, previous per-site dumps,
# and old all_databases.sql snapshots.
# After importing each per-site dump, recreate the user/grant from .dockweb.conf
# so the restored DB is usable on a fresh MySQL.
_restic_restore_db() {
    local snapshot="$1"
    load_env

    docker exec backup_service rm -rf /tmp/restore 2>/dev/null || true

    # Try current /tmp/db_dumps/<domain>/*.sql layout first.
    _restic restore "$snapshot" --target /tmp/restore --include /tmp/db_dumps 2>/dev/null || true

    local sites
    sites=$(docker exec backup_service sh -c 'for d in /tmp/restore/tmp/db_dumps/*; do [ -d "$d" ] && basename "$d"; done | sort' 2>/dev/null || true)

    if [[ -n "$sites" ]]; then
        log_info "Restoring per-table database dumps..."
        local count=0 site file_count
        while IFS= read -r site; do
            [[ -z "$site" ]] && continue
            file_count=$(docker exec backup_service sh -c 'find "/tmp/restore/tmp/db_dumps/$1" -maxdepth 1 -type f -name "*.sql" | wc -l' sh "$site" 2>/dev/null || echo "0")
            log_info "  importing ${site} (${file_count} file(s))..."
            if ! _backup_import_dump_dir "$site"; then
                docker exec backup_service rm -rf /tmp/restore 2>/dev/null || true
                log_error "Failed to import database dumps for ${site}."
                return 1
            fi
            _regrant_site_user "$site"
            count=$((count + 1))
        done <<< "$sites"
        docker exec backup_service rm -rf /tmp/restore
        log_success "Restored ${count} site database(s)."
        return 0
    fi

    # Fall back to previous /tmp/db_dumps/<domain>.sql layout.
    local dumps
    dumps=$(docker exec backup_service sh -c 'for f in /tmp/restore/tmp/db_dumps/*.sql; do [ -f "$f" ] && basename "$f"; done | sort' 2>/dev/null || true)
    if [[ -n "$dumps" ]]; then
        log_info "Restoring per-site database dumps..."
        local count=0 dump domain
        while IFS= read -r dump; do
            [[ -z "$dump" ]] && continue
            domain="${dump%.sql}"
            log_info "  importing ${domain}..."
            if ! _backup_import_dump_file "$dump"; then
                docker exec backup_service rm -rf /tmp/restore 2>/dev/null || true
                log_error "Failed to import database dump for ${domain}."
                return 1
            fi
            _regrant_site_user "$domain"
            count=$((count + 1))
        done <<< "$dumps"
        docker exec backup_service rm -rf /tmp/restore
        log_success "Restored ${count} site database(s)."
        return 0
    fi

    # Fall back to legacy single-dump layout
    log_info "No per-site dumps in snapshot; trying legacy all_databases.sql..."
    docker exec backup_service rm -rf /tmp/restore 2>/dev/null || true
    _restic restore "$snapshot" --target /tmp/restore --include /tmp/all_databases.sql

    if docker exec backup_service test -f /tmp/restore/tmp/all_databases.sql; then
        if ! docker exec -e DB_ROOT_PASSWORD="$DB_ROOT_PASSWORD" backup_service sh -c 'mysql -h shared_mysql -u root -p"$DB_ROOT_PASSWORD" --skip-ssl < /tmp/restore/tmp/all_databases.sql'; then
            docker exec backup_service rm -rf /tmp/restore 2>/dev/null || true
            log_error "Failed to import legacy all_databases.sql."
            return 1
        fi
        docker exec backup_service rm -rf /tmp/restore
        log_success "Database restored (legacy layout)."
    else
        docker exec backup_service rm -rf /tmp/restore 2>/dev/null || true
        log_error "Snapshot contains neither db_dumps/ nor all_databases.sql."
        return 1
    fi
}

# Recreate the MySQL user + grant for a site from its .dockweb.conf so the
# restored DB is reachable from PHP. Idempotent. No-op if conf is missing
# (e.g. DB-only restore on a system that doesn't have the site files yet —
# the user can re-add the site, then re-run restore).
_regrant_site_user() {
    local domain="$1"
    local conf="${DOCKWEB_ROOT}/sites/${domain}/.dockweb.conf"
    if [[ ! -f "$conf" ]]; then
        log_warn "  no .dockweb.conf for ${domain} on host; skipping user/grant recreate"
        return 0
    fi
    local DOMAIN="" SSL_MODE="" PHP_CONTAINER="" DB_NAME="" DB_USER="" DB_PASS=""
    source "$conf"
    [[ -z "$DB_NAME" || -z "$DB_USER" || -z "$DB_PASS" ]] && return 0
    local sql
    sql=$(sed \
        -e "s|{{DB_NAME}}|${DB_NAME}|g" \
        -e "s|{{DB_USER}}|${DB_USER}|g" \
        -e "s|{{DB_PASS}}|${DB_PASS}|g" \
        "${DOCKWEB_ROOT}/templates/db-init.sql.tpl")
    echo "$sql" | docker exec -i shared_mysql mysql -u root -p"${DB_ROOT_PASSWORD}" 2>/dev/null || true
}

cmd_backup_test() {
    header "Testing Backup Restore"
    _backup_check_running || return 1

    log_info "Running restore test (safe, non-destructive)..."
    docker exec backup_service /scripts/test-restore.sh
}

cmd_backup_setup_drive() {
    header "Configure Google Drive Offsite Backup"
    _backup_check_running || return 1

    _backup_ensure_rclone || return 1

    log_info "This wizard configures rclone, offsite backup settings, and Telegram notifications."
    log_info "The Google OAuth token will be saved under ./rclone/ (ignored by git)."
    echo ""

    if confirm "Open rclone config now?" "y"; then
        log_info "Create a Google Drive remote, commonly named: gdrive"
        echo ""
        docker exec backup_service mkdir -p /config/rclone
        docker exec -it backup_service rclone config --config /config/rclone/rclone.conf
    fi

    _backup_configure_offsite_env

    if confirm "Restart backup_service now to apply these settings?" "y"; then
        _config_backup_apply_hint
    else
        log_info "Apply later with: ./dockweb update backup"
    fi
}

_backup_ensure_rclone() {
    if docker exec backup_service command -v rclone >/dev/null 2>&1; then
        return 0
    fi

    log_warn "rclone is not installed in the running backup_service container."
    if confirm "Rebuild and recreate backup_service now?" "y"; then
        local cmd
        cmd="$(docker_compose_cmd)"
        $cmd up -d --no-deps --build --force-recreate backup
        if docker exec backup_service command -v rclone >/dev/null 2>&1; then
            log_success "backup_service rebuilt with rclone."
            return 0
        fi
    fi

    log_error "rclone is still missing from backup_service."
    log_info "Try a clean rebuild: docker compose -f docker-compose.yml -f docker-compose.sites.yml build --no-cache backup"
    log_info "Then recreate it: ./dockweb update backup"
    return 1
}

_backup_configure_offsite_env() {
    load_env

    local current_remote current_mode current_notify current_tg_chat
    current_remote=$(get_env_val OFFSITE_BACKUP_REMOTE "gdrive:dockweb-backups/repo")
    current_mode=$(get_env_val OFFSITE_BACKUP_MODE "sync")
    current_notify=$(get_env_val BACKUP_NOTIFY_NAME "dockweb")
    current_tg_chat=$(get_env_val TELEGRAM_CHAT_ID "")

    echo ""
    echo "  Offsite backup destination"
    echo "    Example: gdrive:dockweb-backups/repo"
    echo ""

    if confirm "Enable Google Drive offsite backup?" "y"; then
        local new_remote new_mode new_notify

        echo -ne "  Remote path [${current_remote}]: "
        read -r new_remote
        new_remote="${new_remote:-$current_remote}"

        echo ""
        echo "  Upload mode:"
        echo "    1) sync - mirror local retention to Drive"
        echo "    2) copy - upload new/changed files, never delete remote"
        echo -ne "  Choose [1-2] [$( [[ "$current_mode" == "copy" ]] && echo 2 || echo 1 )]: "
        read -r mode_choice
        case "${mode_choice:-$([[ "$current_mode" == "copy" ]] && echo 2 || echo 1)}" in
            1) new_mode="sync" ;;
            2) new_mode="copy" ;;
            *) log_error "Invalid upload mode."; return 1 ;;
        esac

        echo -ne "  Notification name [${current_notify}]: "
        read -r new_notify
        new_notify="${new_notify:-$current_notify}"

        set_env_val "OFFSITE_BACKUP_ENABLED" "true"
        set_env_val "OFFSITE_BACKUP_REMOTE" "$new_remote"
        set_env_val "OFFSITE_BACKUP_MODE" "$new_mode"
        set_env_val "BACKUP_NOTIFY_NAME" "$new_notify"
        log_success "Google Drive offsite backup settings updated."
    else
        set_env_val "OFFSITE_BACKUP_ENABLED" "false"
        log_success "Google Drive offsite backup disabled."
    fi

    echo ""
    if confirm "Configure Telegram backup notifications?" "y"; then
        local new_token new_chat

        echo "  Bot token: leave blank to keep current, or type '-' to clear."
        echo -ne "  Bot token: "
        read -rs new_token
        echo ""
        if [[ "$new_token" == "-" ]]; then
            set_env_val "TELEGRAM_BOT_TOKEN" ""
        elif [[ -n "$new_token" ]]; then
            set_env_val "TELEGRAM_BOT_TOKEN" "$new_token"
        fi

        echo -ne "  Chat ID or @channel [${current_tg_chat:-not set}]: "
        read -r new_chat
        if [[ "$new_chat" == "-" ]]; then
            set_env_val "TELEGRAM_CHAT_ID" ""
        elif [[ -n "$new_chat" ]]; then
            set_env_val "TELEGRAM_CHAT_ID" "$new_chat"
        fi

        log_success "Telegram notification settings updated."
    fi
}

# ---------------------------------------------------------------------------
# Per-site backup exclusion (CLI)
# ---------------------------------------------------------------------------
# `BACKUP_EXCLUDE_SITES` in .env is a comma-separated list of domains the
# backup script skips for both file backup and per-site DB dump.

_backup_excludes_get() {
    get_env_val BACKUP_EXCLUDE_SITES ""
}

_backup_excludes_contains() {
    local domain="$1"
    local current
    current=$(_backup_excludes_get)
    [[ -z "$current" ]] && return 1
    local IFS=','
    local d
    for d in $current; do
        d=$(echo "$d" | xargs)
        [[ "$d" == "$domain" ]] && return 0
    done
    return 1
}

cmd_backup_excludes() {
    header "Backup excludes"
    load_env
    local current
    current=$(_backup_excludes_get)
    if [[ -z "$current" ]]; then
        echo "  (no sites excluded — everything is backed up)"
    else
        echo "  Excluded sites:"
        local IFS=','
        local d
        for d in $current; do
            d=$(echo "$d" | xargs)
            [[ -n "$d" ]] && echo "    - $d"
        done
    fi
    echo ""
    echo -e "  ${DIM}Restart backup_service after changes for the new schedule to apply.${NC}"
}

cmd_backup_exclude() {
    local domain="${1:-}"
    if [[ -z "$domain" ]]; then
        log_error "Usage: dockweb backup exclude <domain>"
        return 1
    fi
    if ! [[ -f "${DOCKWEB_ROOT}/sites/${domain}/.dockweb.conf" ]]; then
        log_error "Site '${domain}' not found."
        return 1
    fi
    if _backup_excludes_contains "$domain"; then
        log_info "'${domain}' is already excluded."
        return 0
    fi

    local current new
    current=$(_backup_excludes_get)
    if [[ -z "$current" ]]; then
        new="$domain"
    else
        new="${current},${domain}"
    fi
    set_env_val "BACKUP_EXCLUDE_SITES" "$new"
    log_success "'${domain}' excluded from backup (files + DB)."
    log_info "Restart backup_service to pick up the change: docker restart backup_service"
}

cmd_backup_include() {
    local domain="${1:-}"
    if [[ -z "$domain" ]]; then
        log_error "Usage: dockweb backup include <domain>"
        return 1
    fi
    if ! _backup_excludes_contains "$domain"; then
        log_info "'${domain}' is not currently excluded."
        return 0
    fi

    local current new=""
    current=$(_backup_excludes_get)
    local IFS=','
    local d
    for d in $current; do
        d=$(echo "$d" | xargs)
        [[ -z "$d" || "$d" == "$domain" ]] && continue
        new="${new:+${new},}${d}"
    done
    set_env_val "BACKUP_EXCLUDE_SITES" "$new"
    log_success "'${domain}' will be backed up again."
    log_info "Restart backup_service to pick up the change: docker restart backup_service"
}
