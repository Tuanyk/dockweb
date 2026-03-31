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
