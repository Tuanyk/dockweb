#!/bin/bash
# dockweb - monitoring and logs

cmd_monitor() {
    header "System Health"

    # Container health
    echo -e "  ${BOLD}Container Status:${NC}"
    docker ps --format "table  {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || {
        log_warn "No containers running."
        return
    }

    # Check for unhealthy containers
    local unhealthy
    unhealthy=$(docker ps --filter "health=unhealthy" --format "{{.Names}}" 2>/dev/null)
    if [[ -n "$unhealthy" ]]; then
        echo ""
        log_warn "Unhealthy containers:"
        echo "$unhealthy" | while read -r name; do
            echo "    - $name"
        done
    fi

    # Disk usage
    echo ""
    echo -e "  ${BOLD}Disk Usage:${NC}"
    df -h / | tail -1 | awk '{printf "    Root: %s used of %s (%s)\n", $3, $2, $5}'
    local docker_size
    docker_size=$(docker system df --format "{{.Size}}" 2>/dev/null | head -1)
    [[ -n "$docker_size" ]] && echo "    Docker: ${docker_size}"

    # Memory
    echo ""
    echo -e "  ${BOLD}Memory:${NC}"
    free -h | awk '/^Mem:/{printf "    RAM:  %s used of %s\n", $3, $2}'
    free -h | awk '/^Swap:/{printf "    Swap: %s used of %s\n", $3, $2}'

    # Site status
    echo ""
    echo -e "  ${BOLD}Sites:${NC}"
    local sites
    sites=$(list_all_sites)
    if [[ -n "$sites" ]]; then
        while IFS= read -r domain; do
            [[ -z "$domain" ]] && continue
            local SSL_MODE="" PHP_CONTAINER="" DB_NAME="" DB_USER="" DB_PASS="" DOMAIN=""
            get_site_conf "$domain"
            local status="down"
            docker ps --format '{{.Names}}' | grep -q "^${PHP_CONTAINER}$" && status="up"
            printf "    %-30s [%s] (%s)\n" "$domain" "$status" "$SSL_MODE"
        done <<< "$sites"
    else
        echo "    No sites configured."
    fi

    echo ""
}

_alerts_enabled_label() {
    local value="$1"
    if [[ "$value" =~ ^(1|true|TRUE|yes|YES|on|ON|enabled|ENABLED)$ ]]; then
        echo -e "${GREEN}enabled${NC}"
    else
        echo -e "${RED}disabled${NC}"
    fi
}

_alerts_send_telegram() {
    local text="$1"
    local token chat

    load_env
    token=$(get_env_val TELEGRAM_BOT_TOKEN "")
    chat=$(get_env_val TELEGRAM_CHAT_ID "")

    if [[ -z "$token" || -z "$chat" ]]; then
        log_error "Telegram bot token and chat ID are required."
        log_info "Run: dockweb alerts setup"
        return 1
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl is required to send Telegram messages."
        return 1
    fi

    curl -fsS -X POST "https://api.telegram.org/bot${token}/sendMessage" \
        --data-urlencode "chat_id=${chat}" \
        --data-urlencode "text=${text}" \
        >/dev/null 2>&1
}

cmd_alerts() {
    local subcmd="${1:-}"

    case "$subcmd" in
        ""|menu)  cmd_alerts_menu ;;
        setup)    cmd_alerts_setup ;;
        status)   cmd_alerts_status ;;
        test)     cmd_alerts_test ;;
        check)    cmd_alerts_check ;;
        reset)    cmd_alerts_reset ;;
        enable)
            set_env_val "TELEGRAM_ALERTS_ENABLED" "true"
            log_success "Telegram health alerts enabled."
            ;;
        disable)
            set_env_val "TELEGRAM_ALERTS_ENABLED" "false"
            log_success "Telegram health alerts disabled."
            ;;
        *)
            log_error "Usage: dockweb alerts {setup|status|test|check|reset|enable|disable}"
            return 1
            ;;
    esac
}

cmd_alerts_menu() {
    header "Telegram Alerts"

    echo ""
    echo "  1) Setup Telegram alerts"
    echo "  2) Show alert status"
    echo "  3) Send test notification"
    echo "  4) Run health check now"
    echo "  5) Enable Telegram alerts"
    echo "  6) Disable Telegram alerts"
    echo "  7) Reset alert state"
    echo "  0) Back"
    echo ""
    echo -ne "  Choose: "
    read -r choice

    case "$choice" in
        1) cmd_alerts_setup ;;
        2) cmd_alerts_status ;;
        3) cmd_alerts_test ;;
        4) cmd_alerts_check ;;
        5) cmd_alerts enable ;;
        6) cmd_alerts disable ;;
        7) cmd_alerts_reset ;;
        0) return 0 ;;
        *) log_error "Invalid choice." ;;
    esac
}

cmd_alerts_setup() {
    load_env
    header "Setup Telegram Alerts"

    local current_enabled current_token current_chat current_name
    current_enabled=$(get_env_val TELEGRAM_ALERTS_ENABLED "false")
    current_token=$(get_env_val TELEGRAM_BOT_TOKEN "")
    current_chat=$(get_env_val TELEGRAM_CHAT_ID "")
    current_name=$(get_env_val HEALTHCHECK_NOTIFY_NAME "$(get_env_val BACKUP_NOTIFY_NAME dockweb)")

    echo ""
    echo "  Current:"
    echo "    Telegram alerts: $(_alerts_enabled_label "$current_enabled")"
    echo "    Bot token:       $(mask_password "$current_token")"
    echo "    Chat ID:         $(mask_password "$current_chat")"
    echo "    Alert name:      ${current_name}"
    echo ""

    if confirm "Enable Telegram health alerts?" "y"; then
        set_env_val "TELEGRAM_ALERTS_ENABLED" "true"
    else
        set_env_val "TELEGRAM_ALERTS_ENABLED" "false"
        log_success "Telegram health alerts disabled."
        return 0
    fi

    local new_token new_chat new_name
    echo "  Bot token: leave blank to keep current, or type '-' to clear."
    echo -ne "  Bot token: "
    read -rs new_token
    echo ""
    if [[ "$new_token" == "-" ]]; then
        set_env_val "TELEGRAM_BOT_TOKEN" ""
    elif [[ -n "$new_token" ]]; then
        set_env_val "TELEGRAM_BOT_TOKEN" "$new_token"
    fi

    echo -ne "  Chat ID or @channel [${current_chat:+set}${current_chat:-not set}]: "
    read -r new_chat
    if [[ "$new_chat" == "-" ]]; then
        set_env_val "TELEGRAM_CHAT_ID" ""
    elif [[ -n "$new_chat" ]]; then
        set_env_val "TELEGRAM_CHAT_ID" "$new_chat"
    fi

    echo -ne "  Alert name [${current_name}]: "
    read -r new_name
    new_name="${new_name:-$current_name}"
    set_env_val "HEALTHCHECK_NOTIFY_NAME" "$new_name"

    echo ""
    if confirm "Use recommended thresholds?" "y"; then
        set_env_val "ALERT_CPU_PERCENT" "$(get_env_val ALERT_CPU_PERCENT 85)"
        set_env_val "ALERT_MEMORY_PERCENT" "$(get_env_val ALERT_MEMORY_PERCENT 90)"
        set_env_val "ALERT_DISK_PERCENT" "$(get_env_val ALERT_DISK_PERCENT 85)"
        set_env_val "ALERT_SUSTAINED_CHECKS" "$(get_env_val ALERT_SUSTAINED_CHECKS 2)"
        set_env_val "ALERT_SITE_FAILURE_CHECKS" "$(get_env_val ALERT_SITE_FAILURE_CHECKS 2)"
        set_env_val "ALERT_TRAFFIC_RPM" "$(get_env_val ALERT_TRAFFIC_RPM 300)"
    else
        local cpu memory disk checks site_checks traffic_rpm
        echo -ne "  CPU percent threshold [$(get_env_val ALERT_CPU_PERCENT 85)]: "
        read -r cpu
        echo -ne "  RAM percent threshold [$(get_env_val ALERT_MEMORY_PERCENT 90)]: "
        read -r memory
        echo -ne "  Disk percent threshold [$(get_env_val ALERT_DISK_PERCENT 85)]: "
        read -r disk
        echo -ne "  Sustained checks before CPU/RAM alert [$(get_env_val ALERT_SUSTAINED_CHECKS 2)]: "
        read -r checks
        echo -ne "  Failed site checks before alert [$(get_env_val ALERT_SITE_FAILURE_CHECKS 2)]: "
        read -r site_checks
        echo -ne "  Request/minute traffic threshold [$(get_env_val ALERT_TRAFFIC_RPM 300)]: "
        read -r traffic_rpm

        [[ -n "$cpu" ]] && set_env_val "ALERT_CPU_PERCENT" "$cpu"
        [[ -n "$memory" ]] && set_env_val "ALERT_MEMORY_PERCENT" "$memory"
        [[ -n "$disk" ]] && set_env_val "ALERT_DISK_PERCENT" "$disk"
        [[ -n "$checks" ]] && set_env_val "ALERT_SUSTAINED_CHECKS" "$checks"
        [[ -n "$site_checks" ]] && set_env_val "ALERT_SITE_FAILURE_CHECKS" "$site_checks"
        [[ -n "$traffic_rpm" ]] && set_env_val "ALERT_TRAFFIC_RPM" "$traffic_rpm"
    fi

    log_success "Telegram alert settings updated."

    echo ""
    if confirm "Enable scheduled health checks with cron every 5 minutes?" "y"; then
        bash "${DOCKWEB_ROOT}/monitoring/setup-monitoring.sh"
    else
        log_info "You can enable scheduled checks later with: ./monitoring/setup-monitoring.sh"
    fi

    log_info "Send a test with: dockweb alerts test"
}

cmd_alerts_status() {
    load_env
    header "Telegram Alert Status"

    local state_dir
    state_dir="${DOCKWEB_ROOT}/logs/healthcheck-state"

    echo ""
    echo "  Telegram:"
    echo "    Alerts:          $(_alerts_enabled_label "$(get_env_val TELEGRAM_ALERTS_ENABLED false)")"
    echo "    Bot token:       $(mask_password "$(get_env_val TELEGRAM_BOT_TOKEN '')")"
    echo "    Chat ID:         $(mask_password "$(get_env_val TELEGRAM_CHAT_ID '')")"
    echo "    Alert name:      $(get_env_val HEALTHCHECK_NOTIFY_NAME "$(get_env_val BACKUP_NOTIFY_NAME dockweb)")"
    echo ""
    echo "  Thresholds:"
    echo "    Containers:      $(get_env_val ALERT_CONTAINER_CHECKS_ENABLED true)"
    echo "    CPU:             $(get_env_val ALERT_CPU_PERCENT 85)% for $(get_env_val ALERT_SUSTAINED_CHECKS 2) checks"
    echo "    RAM:             $(get_env_val ALERT_MEMORY_PERCENT 90)% for $(get_env_val ALERT_SUSTAINED_CHECKS 2) checks"
    echo "    Swap:            $(get_env_val ALERT_SWAP_PERCENT 50)% for $(get_env_val ALERT_SUSTAINED_CHECKS 2) checks"
    echo "    Disk:            $(get_env_val ALERT_DISK_PERCENT 85)%"
    echo "    Site failures:   $(get_env_val ALERT_SITE_FAILURE_CHECKS 2) checks"
    echo "    Traffic:         $(get_env_val ALERT_TRAFFIC_RPM 300) req/min"
    echo "    SSL expiry:      $(get_env_val ALERT_SSL_EXPIRY_DAYS 14) day(s)"
    echo ""
    echo "  Active alerts:"
    if compgen -G "${state_dir}/*.active" >/dev/null; then
        local file line started title
        for file in "${state_dir}"/*.active; do
            line=$(head -1 "$file")
            started="${line%%$'\t'*}"
            title="${line#*$'\t'}"
            echo "    - ${title} (${started})"
        done
    else
        echo "    (none)"
    fi
    echo ""
    echo "  State directory: ${state_dir}"
}

cmd_alerts_test() {
    header "Test Telegram Alert"

    local msg
    msg="dockweb test notification

Host: $(hostname -f 2>/dev/null || hostname)
Time: $(date -Is)"

    if _alerts_send_telegram "$msg"; then
        log_success "Telegram test notification sent."
    else
        log_error "Telegram test notification failed."
        return 1
    fi
}

cmd_alerts_check() {
    header "Run Health Check"

    if bash "${DOCKWEB_ROOT}/monitoring/healthcheck.sh"; then
        log_success "Health check passed."
    else
        local rc=$?
        log_warn "Health check reported issues."
        return "$rc"
    fi
}

cmd_alerts_reset() {
    local state_dir="${DOCKWEB_ROOT}/logs/healthcheck-state"

    if [[ ! -d "$state_dir" ]]; then
        log_info "No alert state found."
        return 0
    fi

    if confirm "Clear health alert state and traffic baselines?" "n"; then
        rm -rf "$state_dir"
        log_success "Alert state cleared."
    else
        log_info "Cancelled."
    fi
}

cmd_log() {
    local service="${1:-}"

    if [[ -z "$service" ]]; then
        header "View Logs"
        echo "  Available services:"
        echo "    1) nginx"
        echo "    2) mysql"
        echo "    3) redis"
        echo "    4) backup"
        echo "    5) fail2ban"
        echo "    6) certbot"
        echo ""

        # List PHP sites
        local sites
        sites=$(list_all_sites)
        local i=6
        local site_map=()
        if [[ -n "$sites" ]]; then
            while IFS= read -r domain; do
                [[ -z "$domain" ]] && continue
                i=$((i + 1))
                site_map+=("$domain")
                echo "    $i) php: $domain"
            done <<< "$sites"
        fi

        echo "    0) Back"
        echo ""
        echo -ne "  Choose: "
        read -r choice

        case "$choice" in
            1) service="nginx" ;;
            2) service="mysql" ;;
            3) service="redis" ;;
            4) service="backup" ;;
            5) service="fail2ban" ;;
            6) service="certbot" ;;
            0) return 0 ;;
            *)
                local idx=$((choice - 7))
                if [[ -n "${site_map[$idx]}" ]]; then
                    local SSL_MODE="" PHP_CONTAINER="" DB_NAME="" DB_USER="" DB_PASS="" DOMAIN=""
                    get_site_conf "${site_map[$idx]}"
                    service="$PHP_CONTAINER"
                else
                    log_error "Invalid choice."
                    return 1
                fi
                ;;
        esac
    fi

    # Map service names to container names
    local container
    case "$service" in
        nginx)    container="gateway_nginx" ;;
        mysql)    container="shared_mysql" ;;
        redis)    container="shared_redis" ;;
        backup)   container="backup_service" ;;
        fail2ban) container="fail2ban" ;;
        certbot)  container="certbot" ;;
        monitor)  container="monitor_glances" ;;
        *)        container="$service" ;;
    esac

    log_info "Showing logs for: $container (Ctrl+C to exit)"
    echo ""
    docker logs --tail 100 -f "$container" 2>&1
}
