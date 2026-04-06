#!/bin/bash
# dockweb - configuration management

# Helper: get a value from .env (with default)
get_env_val() {
    local key="$1"
    local default="$2"
    local env_file="${DOCKWEB_ROOT}/.env"
    local val
    val=$(grep "^${key}=" "$env_file" 2>/dev/null | head -1 | cut -d= -f2-)
    # Strip surrounding quotes if present
    val="${val#\"}"
    val="${val%\"}"
    val="${val#\'}"
    val="${val%\'}"
    echo "${val:-$default}"
}

# Helper: set a value in .env (add if missing, update if exists)
# Automatically quotes values containing spaces or special chars
set_env_val() {
    local key="$1"
    local value="$2"
    local env_file="${DOCKWEB_ROOT}/.env"

    # Quote values that contain spaces or glob chars
    if [[ "$value" == *" "* || "$value" == *"*"* ]]; then
        value="\"${value}\""
    fi

    if grep -q "^${key}=" "$env_file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"
    elif grep -q "^# *${key}=" "$env_file" 2>/dev/null; then
        # Uncomment and set
        sed -i "s|^# *${key}=.*|${key}=${value}|" "$env_file"
    else
        echo "${key}=${value}" >> "$env_file"
    fi
}

# Helper: mask a password for display
mask_password() {
    local pw="$1"
    if [[ -z "$pw" ]]; then
        echo "(not set)"
    elif [[ ${#pw} -le 4 ]]; then
        echo "****"
    else
        echo "${pw:0:3}$(printf '*%.0s' $(seq 1 $((${#pw}-3))))"
    fi
}

cmd_config() {
    local subcmd="${1:-}"

    case "$subcmd" in
        "")       cmd_config_show ;;
        backup)   cmd_config_backup ;;
        passwords) cmd_config_passwords ;;
        resources) cmd_config_resources ;;
        swap)      setup_swap ;;
        *)
            log_error "Unknown config section: $subcmd"
            echo "  Usage: dockweb config [backup|passwords|resources|swap]"
            return 1
            ;;
    esac
}

cmd_config_show() {
    load_env
    header "Configuration Overview"

    echo ""
    echo -e "  ${BOLD}Backup${NC}"
    local backup_enabled
    backup_enabled=$(get_env_val BACKUP_ENABLED "true")
    if [[ "$backup_enabled" == "false" ]]; then
        echo "    Status:          ${RED}disabled${NC}"
    else
        echo "    Status:          ${GREEN}enabled${NC}"
        echo "    Schedule:        $(get_env_val BACKUP_SCHEDULE '0 3 * * *')"
        echo "    Retention:       $(get_env_val BACKUP_KEEP_DAILY 7)d / $(get_env_val BACKUP_KEEP_WEEKLY 4)w / $(get_env_val BACKUP_KEEP_MONTHLY 6)m"
        echo "    Alert email:     $(get_env_val ALERT_EMAIL '(not set)')"
    fi

    echo ""
    echo -e "  ${BOLD}Passwords${NC}"
    echo "    DB root:         $(mask_password "$(get_env_val DB_ROOT_PASSWORD '')")"
    echo "    Restic:          $(mask_password "$(get_env_val RESTIC_PASSWORD '')")"
    echo "    Glances user:    $(get_env_val GLANCES_USERNAME 'admin')"
    echo "    Glances pass:    $(mask_password "$(get_env_val GLANCES_PASSWORD '')")"
    echo "    Certbot email:   $(get_env_val CERTBOT_EMAIL '(not set)')"

    echo ""
    echo -e "  ${BOLD}Resources${NC}"
    echo "    MySQL buffer:    $(get_env_val MYSQL_INNODB_BUFFER_POOL_SIZE '512M')"
    echo "    PHP max children:$(get_env_val PHP_PM_MAX_CHILDREN '5')"
    echo "    Redis maxmemory: $(get_env_val REDIS_MAXMEMORY '256mb')"

    echo ""
    echo -e "  ${BOLD}Swap${NC}"
    if /usr/sbin/swapon --show 2>/dev/null | grep -q '/'; then
        local swap_size_mb
        swap_size_mb=$(/usr/sbin/swapon --show --noheadings --bytes 2>/dev/null | awk '{total+=$3} END {printf "%.0f", total/1048576}')
        local swap_h
        swap_h=$(awk "BEGIN {printf \"%.1f\", $swap_size_mb / 1024}")
        echo "    Swap:            ${GREEN}${swap_h} GB${NC}"
    else
        echo "    Swap:            ${RED}none${NC}"
    fi
    local swappiness
    swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "?")
    echo "    Swappiness:      ${swappiness}"

    echo ""
    echo -e "  ${DIM}Edit with: dockweb config [backup|passwords|resources|swap]${NC}"
}

cmd_config_backup() {
    load_env
    header "Backup Configuration"

    local backup_enabled
    backup_enabled=$(get_env_val BACKUP_ENABLED "true")

    local current_schedule current_daily current_weekly current_monthly
    current_schedule=$(get_env_val BACKUP_SCHEDULE "0 3 * * *")
    current_daily=$(get_env_val BACKUP_KEEP_DAILY 7)
    current_weekly=$(get_env_val BACKUP_KEEP_WEEKLY 4)
    current_monthly=$(get_env_val BACKUP_KEEP_MONTHLY 6)

    local current_exclude
    current_exclude=$(get_env_val BACKUP_EXCLUDE_SITES "")

    echo ""
    if [[ "$backup_enabled" == "false" ]]; then
        echo -e "  Status: ${RED}disabled${NC}"
    else
        echo -e "  Status: ${GREEN}enabled${NC}"
        echo "    Schedule:     $current_schedule"
        echo "    Retention:    ${current_daily} daily / ${current_weekly} weekly / ${current_monthly} monthly"
        echo "    Alert email:  $(get_env_val ALERT_EMAIL '(not set)')"
        if [[ -n "$current_exclude" ]]; then
            echo -e "    Excluded:     ${YELLOW}${current_exclude}${NC}"
        else
            echo "    Excluded:     (none — all sites backed up)"
        fi
    fi

    echo ""
    echo "  What to change?"
    if [[ "$backup_enabled" == "false" ]]; then
        echo "    1) Enable backup"
    else
        echo "    1) Disable backup (for local dev)"
        echo "    2) Backup schedule"
        echo "    3) Retention policy (how many backups to keep)"
        echo "    4) Alert email"
        echo "    5) Exclude sites from backup"
    fi
    echo "    0) Back"
    echo ""
    echo -ne "  Choose: "
    read -r choice

    # Handle disabled state — only option 1 (enable) is valid
    if [[ "$backup_enabled" == "false" ]]; then
        case "$choice" in
            1)
                set_env_val "BACKUP_ENABLED" "true"
                log_success "Backup enabled."
                _config_backup_apply_hint
                ;;
            0) return 0 ;;
            *) log_error "Invalid choice." ;;
        esac
        return
    fi

    case "$choice" in
        1)
            set_env_val "BACKUP_ENABLED" "false"
            log_success "Backup disabled."
            _config_backup_apply_hint
            ;;
        2)
            echo ""
            echo "  Presets:"
            echo "    1) Daily at 3:00 AM    (0 3 * * *)"
            echo "    2) Daily at midnight   (0 0 * * *)"
            echo "    3) Twice daily         (0 3,15 * * *)"
            echo "    4) Every 6 hours       (0 */6 * * *)"
            echo "    5) Weekly (Sunday 3AM) (0 3 * * 0)"
            echo "    6) Custom cron expression"
            echo ""
            echo -ne "  Choose [1-6]: "
            read -r sched_choice

            local new_schedule
            case "$sched_choice" in
                1) new_schedule="0 3 * * *" ;;
                2) new_schedule="0 0 * * *" ;;
                3) new_schedule="0 3,15 * * *" ;;
                4) new_schedule="0 */6 * * *" ;;
                5) new_schedule="0 3 * * 0" ;;
                6)
                    echo -ne "  Cron expression (5 fields): "
                    read -r new_schedule
                    ;;
                *) log_error "Invalid."; return 1 ;;
            esac

            set_env_val "BACKUP_SCHEDULE" "$new_schedule"
            log_success "Backup schedule set to: $new_schedule"
            _config_backup_apply_hint
            ;;
        3)
            echo ""
            echo "  Retention = how many old backups to keep before deleting."
            echo "  Example: 7 daily means the last 7 days of backups are kept."
            echo ""
            echo -ne "  Keep daily backups [${current_daily}]: "
            read -r new_daily
            echo -ne "  Keep weekly backups [${current_weekly}]: "
            read -r new_weekly
            echo -ne "  Keep monthly backups [${current_monthly}]: "
            read -r new_monthly

            [[ -n "$new_daily" ]]   && set_env_val "BACKUP_KEEP_DAILY" "$new_daily"
            [[ -n "$new_weekly" ]]  && set_env_val "BACKUP_KEEP_WEEKLY" "$new_weekly"
            [[ -n "$new_monthly" ]] && set_env_val "BACKUP_KEEP_MONTHLY" "$new_monthly"

            log_success "Retention policy updated."
            _config_backup_apply_hint
            ;;
        4)
            echo -ne "  Alert email (empty to disable): "
            read -r new_email
            set_env_val "ALERT_EMAIL" "$new_email"
            log_success "Alert email updated."
            _config_backup_apply_hint
            ;;
        5)
            _config_backup_exclude_sites
            ;;
        0) return 0 ;;
        *) log_error "Invalid choice." ;;
    esac
}

_config_backup_exclude_sites() {
    local all_sites excluded_csv excluded_arr=()

    all_sites=$(list_all_sites)
    if [[ -z "$all_sites" ]]; then
        log_error "No sites found. Add a site first with: dockweb site add"
        return 1
    fi

    excluded_csv=$(get_env_val BACKUP_EXCLUDE_SITES "")
    IFS=',' read -ra excluded_arr <<< "$excluded_csv"

    echo ""
    echo "  Select sites to EXCLUDE from backup."
    echo "  Currently excluded sites are marked with [x]."
    echo ""

    local i=1
    local site_list=()
    while IFS= read -r site; do
        site_list+=("$site")
        local marker=" "
        for ex in "${excluded_arr[@]}"; do
            if [[ "$(echo "$ex" | xargs)" == "$site" ]]; then
                marker="x"
                break
            fi
        done
        echo "    ${i}) [${marker}] ${site}"
        ((i++))
    done <<< "$all_sites"

    echo ""
    echo "  Enter site numbers to toggle (space-separated), or 'clear' to include all."
    echo -ne "  Toggle: "
    read -r toggle_input

    if [[ "$toggle_input" == "clear" ]]; then
        set_env_val "BACKUP_EXCLUDE_SITES" ""
        log_success "All sites will be backed up."
        _config_backup_apply_hint
        return
    fi

    # Toggle selected sites
    for num in $toggle_input; do
        if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#site_list[@]} )); then
            local site="${site_list[$((num-1))]}"
            local found=false
            local new_arr=()
            for ex in "${excluded_arr[@]}"; do
                local trimmed
                trimmed=$(echo "$ex" | xargs)
                if [[ "$trimmed" == "$site" ]]; then
                    found=true
                else
                    [[ -n "$trimmed" ]] && new_arr+=("$trimmed")
                fi
            done
            if [[ "$found" == "false" ]]; then
                new_arr+=("$site")
            fi
            excluded_arr=("${new_arr[@]}")
        fi
    done

    # Build comma-separated string
    local result=""
    for ex in "${excluded_arr[@]}"; do
        [[ -n "$ex" ]] && result="${result:+${result},}${ex}"
    done

    set_env_val "BACKUP_EXCLUDE_SITES" "$result"

    if [[ -n "$result" ]]; then
        log_success "Excluded sites: ${result}"
    else
        log_success "All sites will be backed up."
    fi
    _config_backup_apply_hint
}

cmd_config_passwords() {
    load_env
    header "Passwords & Credentials"

    echo ""
    echo "  Current values:"
    echo "    1) DB root password:  $(mask_password "$(get_env_val DB_ROOT_PASSWORD '')")"
    echo "    2) Restic password:   $(mask_password "$(get_env_val RESTIC_PASSWORD '')")"
    echo "    3) Glances username:  $(get_env_val GLANCES_USERNAME 'admin')"
    echo "    4) Glances password:  $(mask_password "$(get_env_val GLANCES_PASSWORD '')")"
    echo "    5) Certbot email:     $(get_env_val CERTBOT_EMAIL '(not set)')"
    echo "    6) Generate all new passwords"
    echo "    0) Back"
    echo ""
    echo -ne "  Choose: "
    read -r choice

    case "$choice" in
        1)
            echo ""
            echo "    a) Enter manually"
            echo "    b) Generate random (32 chars)"
            echo -ne "  Choose: "
            read -r method
            local new_pw
            if [[ "$method" == "b" ]]; then
                new_pw=$(generate_password)
                echo "  Generated: $new_pw"
            else
                echo -ne "  New DB root password: "
                read -rs new_pw
                echo ""
            fi
            [[ -z "$new_pw" ]] && { log_error "Empty password."; return 1; }
            set_env_val "DB_ROOT_PASSWORD" "$new_pw"
            log_success "DB root password updated."
            log_warn "Restart MySQL and update database: dockweb restart"
            ;;
        2)
            echo ""
            echo "    a) Enter manually"
            echo "    b) Generate random (32 chars)"
            echo -ne "  Choose: "
            read -r method
            local new_pw
            if [[ "$method" == "b" ]]; then
                new_pw=$(generate_password)
                echo "  Generated: $new_pw"
            else
                echo -ne "  New Restic password: "
                read -rs new_pw
                echo ""
            fi
            [[ -z "$new_pw" ]] && { log_error "Empty password."; return 1; }
            log_warn "Changing Restic password will make existing backups inaccessible!"
            if confirm "  Continue?" "n"; then
                set_env_val "RESTIC_PASSWORD" "$new_pw"
                log_success "Restic password updated."
                log_warn "Restart backup service: dockweb restart"
            else
                log_info "Cancelled."
            fi
            ;;
        3)
            echo -ne "  New Glances username [$(get_env_val GLANCES_USERNAME 'admin')]: "
            read -r new_user
            [[ -n "$new_user" ]] && set_env_val "GLANCES_USERNAME" "$new_user"
            log_success "Glances username updated."
            ;;
        4)
            echo ""
            echo "    a) Enter manually"
            echo "    b) Generate random (32 chars)"
            echo -ne "  Choose: "
            read -r method
            local new_pw
            if [[ "$method" == "b" ]]; then
                new_pw=$(generate_password)
                echo "  Generated: $new_pw"
            else
                echo -ne "  New Glances password: "
                read -rs new_pw
                echo ""
            fi
            [[ -n "$new_pw" ]] && set_env_val "GLANCES_PASSWORD" "$new_pw"
            log_success "Glances password updated."
            ;;
        5)
            echo -ne "  Certbot email: "
            read -r new_email
            [[ -n "$new_email" ]] && set_env_val "CERTBOT_EMAIL" "$new_email"
            log_success "Certbot email updated."
            ;;
        6)
            log_warn "This will generate new random passwords for DB, Restic, and Glances."
            log_warn "Changing Restic password will make existing backups inaccessible!"
            if ! confirm "  Continue?" "n"; then
                log_info "Cancelled."
                return 0
            fi
            local pw_db pw_restic pw_glances
            pw_db=$(generate_password)
            pw_restic=$(generate_password)
            pw_glances=$(generate_password)

            set_env_val "DB_ROOT_PASSWORD" "$pw_db"
            set_env_val "RESTIC_PASSWORD" "$pw_restic"
            set_env_val "GLANCES_PASSWORD" "$pw_glances"

            echo ""
            echo "  New passwords:"
            echo "    DB root:    $pw_db"
            echo "    Restic:     $pw_restic"
            echo "    Glances:    $pw_glances"
            echo ""
            log_warn "Save these passwords! They won't be shown again in full."
            log_success "All passwords updated."
            log_warn "Restart all services: dockweb restart"
            ;;
        0) return 0 ;;
        *) log_error "Invalid choice." ;;
    esac
}

cmd_config_resources() {
    load_env
    header "Resource Configuration"

    local current_mysql current_php current_redis
    current_mysql=$(get_env_val MYSQL_INNODB_BUFFER_POOL_SIZE "512M")
    current_php=$(get_env_val PHP_PM_MAX_CHILDREN "5")
    current_redis=$(get_env_val REDIS_MAXMEMORY "256mb")

    echo ""
    echo "  Current settings:"
    echo "    1) MySQL InnoDB buffer pool:  $current_mysql"
    echo "    2) PHP-FPM max children:      $current_php"
    echo "    3) Redis max memory:          $current_redis"
    echo "    0) Back"
    echo ""
    echo -ne "  Choose: "
    read -r choice

    case "$choice" in
        1)
            echo ""
            echo "  Presets (based on available RAM):"
            echo "    a) 256M  (low memory, <2GB RAM)"
            echo "    b) 512M  (default, 2-4GB RAM)"
            echo "    c) 1G    (4-8GB RAM)"
            echo "    d) 2G    (8GB+ RAM)"
            echo "    e) Custom"
            echo -ne "  Choose: "
            read -r preset

            local new_val
            case "$preset" in
                a) new_val="256M" ;;
                b) new_val="512M" ;;
                c) new_val="1G" ;;
                d) new_val="2G" ;;
                e)
                    echo -ne "  Value (e.g. 512M, 1G): "
                    read -r new_val
                    ;;
                *) log_error "Invalid."; return 1 ;;
            esac
            set_env_val "MYSQL_INNODB_BUFFER_POOL_SIZE" "$new_val"
            log_success "MySQL buffer pool set to: $new_val"
            log_warn "Restart MySQL to apply: dockweb restart"
            ;;
        2)
            echo ""
            echo "  Presets:"
            echo "    a) 3   (low memory, <2GB RAM)"
            echo "    b) 5   (default, 2-4GB RAM)"
            echo "    c) 10  (4-8GB RAM)"
            echo "    d) 20  (8GB+ RAM)"
            echo "    e) Custom"
            echo -ne "  Choose: "
            read -r preset

            local new_val
            case "$preset" in
                a) new_val="3" ;;
                b) new_val="5" ;;
                c) new_val="10" ;;
                d) new_val="20" ;;
                e)
                    echo -ne "  Value: "
                    read -r new_val
                    ;;
                *) log_error "Invalid."; return 1 ;;
            esac
            set_env_val "PHP_PM_MAX_CHILDREN" "$new_val"
            log_success "PHP max children set to: $new_val"
            log_warn "Restart PHP containers to apply: dockweb restart"
            ;;
        3)
            echo ""
            echo "  Presets:"
            echo "    a) 128mb  (low memory)"
            echo "    b) 256mb  (default)"
            echo "    c) 512mb  (high traffic)"
            echo "    d) 1gb    (heavy caching)"
            echo "    e) Custom"
            echo -ne "  Choose: "
            read -r preset

            local new_val
            case "$preset" in
                a) new_val="128mb" ;;
                b) new_val="256mb" ;;
                c) new_val="512mb" ;;
                d) new_val="1gb" ;;
                e)
                    echo -ne "  Value (e.g. 256mb, 1gb): "
                    read -r new_val
                    ;;
                *) log_error "Invalid."; return 1 ;;
            esac
            set_env_val "REDIS_MAXMEMORY" "$new_val"
            log_success "Redis maxmemory set to: $new_val"
            log_warn "Restart Redis to apply: dockweb restart"
            ;;
        0) return 0 ;;
        *) log_error "Invalid choice." ;;
    esac
}

_config_backup_apply_hint() {
    if docker ps --format '{{.Names}}' | grep -q '^backup_service$'; then
        echo ""
        log_info "Restarting backup container to apply changes..."
        $(docker_compose_cmd) up -d --no-deps backup
        log_success "Backup container restarted."
    else
        echo ""
        log_info "Backup container is not running. Changes will apply on next start."
    fi
}
