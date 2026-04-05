#!/bin/bash
# dockweb - service management (start/stop/restart/status)

cmd_start() {
    check_dependencies || return 1
    load_env
    ensure_sites_compose

    header "Starting Docker Web Server"

    # Create required directories
    log_info "Creating directories..."
    local sites
    sites=$(list_all_sites)
    mkdir -p "${DOCKWEB_ROOT}/logs/nginx" \
             "${DOCKWEB_ROOT}/logs/mysql" \
             "${DOCKWEB_ROOT}/logs/modsecurity" \
             "${DOCKWEB_ROOT}/backups" \
             "${DOCKWEB_ROOT}/certbot/conf" \
             "${DOCKWEB_ROOT}/certbot/www" \
             "${DOCKWEB_ROOT}/certbot/logs" \
             "${DOCKWEB_ROOT}/nginx/cache" \
             "${DOCKWEB_ROOT}/mysql/data" \
             "${DOCKWEB_ROOT}/mysql/init" \
             "${DOCKWEB_ROOT}/monitoring" \
             "${DOCKWEB_ROOT}/cloudflare-certs"

    while IFS= read -r domain; do
        [[ -z "$domain" ]] && continue
        mkdir -p "${DOCKWEB_ROOT}/logs/php/${domain}"
        mkdir -p "${DOCKWEB_ROOT}/sites/${domain}/public"
    done <<< "$sites"

    # Make scripts executable
    chmod +x "${DOCKWEB_ROOT}/backup/backup.sh" \
             "${DOCKWEB_ROOT}/backup/test-restore.sh" \
             "${DOCKWEB_ROOT}/monitoring/healthcheck.sh" \
             "${DOCKWEB_ROOT}/monitoring/setup-monitoring.sh" \
             "${DOCKWEB_ROOT}/init-letsencrypt.sh" 2>/dev/null || true

    # Calculate resources
    calculate_resources

    # Regenerate sites compose
    generate_sites_compose

    # Security check
    if grep -q 'secret\|changeme\|CHANGE' "${DOCKWEB_ROOT}/.env" 2>/dev/null; then
        log_warn "Default passwords detected in .env file!"
        log_warn "Change all passwords before deploying to production."
        echo ""
    fi

    # Start services
    log_info "Starting containers..."
    local cmd
    cmd="$(docker_compose_cmd)"
    $cmd up -d --build

    echo ""
    log_success "Services started!"
    echo ""
    $cmd ps
}

cmd_stop() {
    ensure_sites_compose
    if ! confirm_dangerous \
        "Stop all services" \
        "All sites will go offline immediately" \
        "Until you run 'dockweb start' again"; then
        log_info "Cancelled."
        return 0
    fi
    header "Stopping Services"
    local cmd
    cmd="$(docker_compose_cmd)"
    $cmd down
    log_success "All services stopped."
}

cmd_restart() {
    local target="${1:-}"
    ensure_sites_compose
    local cmd
    cmd="$(docker_compose_cmd)"

    if [[ -z "$target" ]]; then
        # Restart everything — dangerous
        if ! confirm_dangerous \
            "Restart all services" \
            "All sites will be offline during restart" \
            "30-60 seconds"; then
            log_info "Cancelled."
            return 0
        fi
        header "Restarting All Services"
        $cmd down
        cmd_start
        return
    fi

    # Restart a single service
    local service
    if ! service=$(resolve_service "$target"); then
        log_error "Unknown service: $target"
        log_info "Available: nginx, mysql, redis, or a site domain"
        return 1
    fi

    case "$service" in
        mysql)
            if ! confirm_dangerous \
                "Restart MySQL" \
                "All sites will temporarily lose database connections" \
                "5-30 seconds"; then
                log_info "Cancelled."
                return 0
            fi
            header "Restarting MySQL"
            $cmd restart mysql
            _wait_healthy "shared_mysql" 60
            log_success "MySQL restarted."
            ;;
        redis)
            if ! warn_action "Restart Redis" "Object cache will be cleared"; then
                log_info "Cancelled."
                return 0
            fi
            header "Restarting Redis"
            $cmd restart redis
            _wait_healthy "shared_redis" 30
            log_success "Redis restarted."
            ;;
        nginx)
            header "Restarting Nginx"
            $cmd restart nginx
            _wait_healthy "gateway_nginx" 30
            log_success "Nginx restarted."
            ;;
        *)
            # PHP site container — find the container name
            local domain=""
            local conf
            for conf in "${DOCKWEB_ROOT}"/sites/*/.dockweb.conf; do
                [[ -f "$conf" ]] || continue
                local d
                d=$(grep '^DOMAIN=' "$conf" | cut -d= -f2)
                if [[ "$(sanitize_domain "$d")" == "$service" ]]; then
                    domain="$d"
                    break
                fi
            done
            if [[ -z "$domain" ]]; then
                header "Restarting ${service}"
                $cmd restart "$service"
                log_success "${service} restarted."
            else
                get_site_conf "$domain"
                header "Restarting PHP for ${domain}"
                $cmd restart "$service"
                _wait_healthy "$PHP_CONTAINER" 60
                log_success "PHP for ${domain} restarted."
            fi
            ;;
    esac
}

cmd_status() {
    ensure_sites_compose
    header "Service Status"

    local cmd
    cmd="$(docker_compose_cmd)"
    $cmd ps

    echo ""
    header "Resource Usage"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" 2>/dev/null || log_warn "No running containers."

    echo ""
    header "Disk Usage"
    df -h / | tail -1 | awk '{printf "  Disk: %s used of %s (%s)\n", $3, $2, $5}'

    echo ""
    header "Sites"
    cmd_site_list 2>/dev/null || true
}

cmd_update() {
    local target="${1:-}"
    ensure_sites_compose
    local cmd
    cmd="$(docker_compose_cmd)"

    if [[ -n "$target" ]]; then
        _update_single_service "$target"
        return
    fi

    # Full update — sequential per-category
    header "Updating All Services"

    log_info "Pulling latest images..."
    $cmd pull

    # 1. Infrastructure services (safe, no user impact)
    log_info "Updating infrastructure services..."
    for svc in fail2ban logrotate certbot adminer monitor modsecurity; do
        $cmd up -d --no-deps "$svc" 2>/dev/null || true
    done
    log_success "Infrastructure services updated."

    # 2. Redis (warn about cache)
    echo ""
    if warn_action "Update Redis" "Object cache may be briefly unavailable"; then
        log_info "Updating Redis..."
        $cmd up -d --no-deps redis
        _wait_healthy "shared_redis" 30
        log_success "Redis updated."
    else
        log_info "Skipping Redis."
    fi

    # 3. PHP containers — one site at a time (rolling)
    echo ""
    log_info "Updating PHP containers (rolling, one at a time)..."
    local sites
    sites=$(list_all_sites)
    while IFS= read -r domain; do
        [[ -z "$domain" ]] && continue
        local service_name
        service_name=$(sanitize_domain "$domain")
        log_info "Updating PHP for ${domain}..."
        $cmd up -d --no-deps --build "$service_name"
        # Re-source to get PHP_CONTAINER for this domain
        local SSL_MODE="" PHP_CONTAINER="" DB_NAME="" DB_USER="" DB_PASS="" DOMAIN=""
        get_site_conf "$domain"
        _wait_healthy "$PHP_CONTAINER" 60
        log_success "${domain} updated and healthy."
    done <<< "$sites"

    # 4. Nginx
    echo ""
    log_info "Updating Nginx..."
    $cmd up -d --no-deps nginx
    _wait_healthy "gateway_nginx" 30
    log_success "Nginx updated."

    # 5. MySQL — last, most dangerous
    echo ""
    if confirm_dangerous \
        "Update MySQL" \
        "All sites will briefly lose database connections" \
        "5-30 seconds"; then
        log_info "Updating MySQL..."
        $cmd up -d --no-deps mysql
        _wait_healthy "shared_mysql" 60
        log_success "MySQL updated."
    else
        log_info "Skipping MySQL update."
    fi

    echo ""
    log_success "Update complete!"
    $cmd ps
}

_update_single_service() {
    local target="$1"
    local cmd
    cmd="$(docker_compose_cmd)"
    local service
    if ! service=$(resolve_service "$target"); then
        log_error "Unknown service: $target"
        return 1
    fi

    case "$service" in
        mysql)
            if ! confirm_dangerous \
                "Update MySQL" \
                "All sites will briefly lose database connections" \
                "5-30 seconds"; then
                log_info "Cancelled."
                return 0
            fi
            header "Updating MySQL"
            $cmd pull mysql
            $cmd up -d --no-deps mysql
            _wait_healthy "shared_mysql" 60
            log_success "MySQL updated."
            ;;
        redis)
            if ! warn_action "Update Redis" "Object cache may be briefly unavailable"; then
                log_info "Cancelled."
                return 0
            fi
            header "Updating Redis"
            $cmd pull redis
            $cmd up -d --no-deps redis
            _wait_healthy "shared_redis" 30
            log_success "Redis updated."
            ;;
        nginx)
            header "Updating Nginx"
            $cmd pull nginx
            $cmd up -d --no-deps nginx
            _wait_healthy "gateway_nginx" 30
            log_success "Nginx updated."
            ;;
        *)
            # PHP site or infrastructure service
            header "Updating ${service}"
            $cmd up -d --no-deps --build "$service"
            # Try to find container name for health check
            local domain=""
            local conf
            for conf in "${DOCKWEB_ROOT}"/sites/*/.dockweb.conf; do
                [[ -f "$conf" ]] || continue
                local d
                d=$(grep '^DOMAIN=' "$conf" | cut -d= -f2)
                if [[ "$(sanitize_domain "$d")" == "$service" ]]; then
                    domain="$d"
                    break
                fi
            done
            if [[ -n "$domain" ]]; then
                get_site_conf "$domain"
                _wait_healthy "$PHP_CONTAINER" 60
            fi
            log_success "${service} updated."
            ;;
    esac
}

cmd_opcache_clear() {
    local domain="${1:-}"

    # USR2 gracefully reloads PHP-FPM workers, clearing opcache
    # This is zero-downtime — active requests finish before workers restart
    _clear_opcache_for() {
        local site="$1"
        if get_site_conf "$site"; then
            if docker exec "$PHP_CONTAINER" kill -USR2 1 2>/dev/null; then
                log_success "${site} — OPcache cleared (PHP-FPM reloaded)"
                return 0
            else
                log_error "${site} — failed (container not running?)"
                return 1
            fi
        else
            log_error "Site not found: ${site}"
            return 1
        fi
    }

    if [[ -z "$domain" ]]; then
        header "Clearing OPcache (all sites)"
        local sites
        sites=$(list_all_sites)
        if [[ -z "$sites" ]]; then
            log_error "No sites configured."
            return 1
        fi
        local failed=0
        while IFS= read -r site; do
            [[ -z "$site" ]] && continue
            _clear_opcache_for "$site" || failed=1
        done <<< "$sites"
        [[ $failed -eq 0 ]] && log_success "All sites cleared."
    else
        header "Clearing OPcache: ${domain}"
        _clear_opcache_for "$domain"
    fi
}

menu_opcache_clear() {
    local sites
    sites=$(list_all_sites)
    if [[ -z "$sites" ]]; then
        log_error "No sites configured."
        return 1
    fi

    header "Clear OPcache"
    echo "    0) All sites"
    local i=1
    local site_arr=()
    while IFS= read -r site; do
        [[ -z "$site" ]] && continue
        echo "    ${i}) ${site}"
        site_arr+=("$site")
        ((i++))
    done <<< "$sites"
    echo ""
    echo -ne "  Choose [0-$((i-1))]: "
    read -r choice

    if [[ "$choice" == "0" ]]; then
        cmd_opcache_clear
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#site_arr[@]} )); then
        cmd_opcache_clear "${site_arr[$((choice-1))]}"
    else
        log_error "Invalid choice."
    fi
}

cmd_deploy() {
    local domain="${1:-}"
    if [[ -z "$domain" ]]; then
        # Interactive site picker
        local sites
        sites=$(list_all_sites)
        if [[ -z "$sites" ]]; then
            log_error "No sites configured."
            return 1
        fi
        header "Deploy Code (zero-downtime)"
        echo "    0) All sites"
        local i=1
        local site_arr=()
        while IFS= read -r site; do
            [[ -z "$site" ]] && continue
            echo "    ${i}) ${site}"
            site_arr+=("$site")
            ((i++))
        done <<< "$sites"
        echo ""
        echo -ne "  Choose [0-$((i-1))]: "
        read -r choice

        if [[ "$choice" == "0" ]]; then
            cmd_deploy_all
            return
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#site_arr[@]} )); then
            domain="${site_arr[$((choice-1))]}"
        else
            log_error "Invalid choice."
            return 1
        fi
    fi

    header "Deploying: ${domain}"
    log_info "Reloading PHP-FPM workers (zero-downtime)..."
    cmd_opcache_clear "$domain"
    sleep 2

    if get_site_conf "$domain"; then
        local health
        health=$(docker inspect --format='{{.State.Health.Status}}' "$PHP_CONTAINER" 2>/dev/null)
        if [[ "$health" == "healthy" ]]; then
            log_success "Deploy complete. Container healthy."
        else
            log_warn "Container health: ${health:-unknown}. Check logs with: dockweb log"
        fi
    fi
}

cmd_deploy_all() {
    header "Deploying All Sites (zero-downtime)"
    local sites
    sites=$(list_all_sites)
    while IFS= read -r domain; do
        [[ -z "$domain" ]] && continue
        log_info "Deploying ${domain}..."
        cmd_opcache_clear "$domain"
    done <<< "$sites"
    sleep 2
    log_success "All sites deployed."
}

cmd_self_update() {
    header "Self-Update"

    # Check if we're in a git repo
    if ! git -C "$DOCKWEB_ROOT" rev-parse --git-dir &>/dev/null; then
        log_error "Not a git repository. Cannot self-update."
        return 1
    fi

    # Check for uncommitted changes
    if ! git -C "$DOCKWEB_ROOT" diff --quiet 2>/dev/null || \
       ! git -C "$DOCKWEB_ROOT" diff --cached --quiet 2>/dev/null; then
        log_warn "You have uncommitted changes in the dockweb directory."
        log_warn "Self-update may overwrite them."
        if ! confirm "Continue anyway?" "n"; then
            return 0
        fi
    fi

    # Fetch and show what changed
    local branch
    branch=$(git -C "$DOCKWEB_ROOT" rev-parse --abbrev-ref HEAD)
    log_info "Fetching updates from origin/${branch}..."
    git -C "$DOCKWEB_ROOT" fetch origin "$branch"

    local changes
    changes=$(git -C "$DOCKWEB_ROOT" log "HEAD..origin/${branch}" --oneline 2>/dev/null)
    if [[ -z "$changes" ]]; then
        log_success "Already up to date."
        return 0
    fi

    log_info "Updates available:"
    echo "$changes"
    echo ""

    # Check if Docker-related files changed
    local compose_changed=false
    local changed_files
    changed_files=$(git -C "$DOCKWEB_ROOT" diff "HEAD..origin/${branch}" --name-only 2>/dev/null)
    if echo "$changed_files" | grep -qE '(docker-compose\.yml|php/Dockerfile|php/local\.ini|php/www\.conf|backup/)'; then
        compose_changed=true
        log_warn "Docker service files changed:"
        echo "$changed_files" | grep -E '(docker-compose\.yml|php/|backup/)' | sed 's/^/    /'
        echo ""
        log_warn "You will need to run 'dockweb update' after self-update to apply these."
    fi

    if ! confirm "Apply update?" "n"; then
        return 0
    fi

    git -C "$DOCKWEB_ROOT" pull origin "$branch"

    echo ""
    log_success "dockweb updated!"
    if [[ "$compose_changed" == "true" ]]; then
        echo ""
        log_warn "Run 'dockweb update' to apply Docker service changes."
    else
        log_success "No service restart needed."
    fi
}

# Wait for a container to become healthy
_wait_healthy() {
    local container="$1"
    local timeout="${2:-60}"
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        local status
        status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "not_found")
        case "$status" in
            healthy)
                return 0
                ;;
            not_found)
                # Container may not have health check, consider it ready
                return 0
                ;;
        esac
        sleep 2
        elapsed=$((elapsed + 2))
    done

    log_warn "${container} did not become healthy within ${timeout}s"
    return 1
}

calculate_resources() {
    local total_ram available_ram reserved_ram=800
    local num_sites mysql_ram total_php_ram ram_per_container calculated_children

    total_ram=$(free -m | awk '/^Mem:/{print $2}')
    available_ram=$((total_ram - reserved_ram))
    [[ $available_ram -le 0 ]] && available_ram=500

    num_sites=$(site_count)
    [[ $num_sites -lt 1 ]] && num_sites=1

    # MySQL: 30% of available RAM
    mysql_ram=$((available_ram * 30 / 100))
    export MYSQL_INNODB_BUFFER_POOL_SIZE="${mysql_ram}M"

    # PHP: 70% distributed across all site containers
    total_php_ram=$((available_ram * 70 / 100))
    ram_per_container=$((total_php_ram / num_sites))
    calculated_children=$((ram_per_container / 60))
    [[ $calculated_children -lt 4 ]] && calculated_children=4

    export PHP_PM_MAX_CHILDREN=$calculated_children

    echo ""
    log_info "Total RAM: ${total_ram}MB | Available: ${available_ram}MB"
    log_info "MySQL Buffer Pool: ${mysql_ram}MB"
    log_info "PHP sites: ${num_sites} | Max children/site: ${calculated_children}"
    echo ""
}
