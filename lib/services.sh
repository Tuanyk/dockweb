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
             "${DOCKWEB_ROOT}/mysql/data" \
             "${DOCKWEB_ROOT}/mysql/init" \
             "${DOCKWEB_ROOT}/monitoring" \
             "${DOCKWEB_ROOT}/cloudflare-certs"

    # Nginx cache: bind-mounted over /var/cache/nginx in the alpine image.
    # The image's built-in temp subdirs are shadowed by the bind mount, and
    # nginx inside the container runs as uid 101 — so we create the subdirs
    # here and ensure the whole tree is owned by uid 101. Without these dirs
    # nginx fails with "mkdir() .../fastcgi_temp/N failed" and returns 502
    # on every PHP response that spills out of the inline fastcgi_buffers.
    local cache_dir="${DOCKWEB_ROOT}/nginx/cache"
    local cache_subs=(fastcgi_temp client_temp proxy_temp scgi_temp uwsgi_temp)
    local cache_sudo=""
    [[ -d "$cache_dir" ]] || mkdir -p "$cache_dir"
    # If the dir already exists and is owned by nginx (uid 101), we can't
    # mkdir into it as the current user — fall back to sudo.
    [[ -w "$cache_dir" ]] || cache_sudo="sudo"
    local sub missing_subs=0
    for sub in "${cache_subs[@]}"; do
        if [[ ! -d "$cache_dir/$sub" ]]; then
            $cache_sudo mkdir -p "$cache_dir/$sub" \
                || log_warn "Could not create ${cache_dir}/${sub}"
            missing_subs=1
        fi
    done
    # Ensure uid 101 owns the tree. Runs on first-time setup or whenever we
    # just created subdirs as a different user (e.g. via sudo → root).
    local cache_owner
    cache_owner=$(stat -c '%u' "$cache_dir" 2>/dev/null || echo "")
    if [[ "$cache_owner" != "101" ]] || [[ "$missing_subs" == "1" ]]; then
        log_info "Setting nginx cache ownership to uid 101 (nginx container user)..."
        sudo chown -R 101:101 "$cache_dir" 2>/dev/null \
            || log_warn "Could not chown ${cache_dir} — run: sudo chown -R 101:101 ${cache_dir}"
    fi

    while IFS= read -r domain; do
        [[ -z "$domain" ]] && continue
        mkdir -p "${DOCKWEB_ROOT}/logs/php/${domain}"
        mkdir -p "${DOCKWEB_ROOT}/sites/${domain}/public"
    done <<< "$sites"

    # Fix ownership of directories the script needs to write to
    # (in case they were created by Docker or a previous sudo run).
    # Note: nginx/cache is intentionally excluded — it must stay owned by
    # uid 101 (the nginx user inside the alpine image), handled above.
    local current_user
    current_user=$(id -un)
    for dir in "${DOCKWEB_ROOT}/nginx/conf.d" \
               "${DOCKWEB_ROOT}/logs" \
               "${DOCKWEB_ROOT}/cloudflare-certs"; do
        if [[ -d "$dir" ]] && [[ ! -w "$dir" ]]; then
            log_warn "Fixing ownership of ${dir} (not writable by ${current_user})..."
            sudo chown -R "${current_user}:${current_user}" "$dir" 2>/dev/null \
                || log_warn "Could not fix ${dir} — you may need to run: sudo chown -R ${current_user} ${dir}"
        fi
    done

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

# ── Cache Management ──────────────────────────────────────────────────

cmd_cache() {
    local subcmd="${1:-}"
    local arg="${2:-}"

    case "$subcmd" in
        clear)       cmd_cache_clear "$arg" ;;
        clear-nginx) cmd_cache_clear_nginx "$arg" ;;
        clear-php)   cmd_cache_clear_php "$arg" ;;
        status)      cmd_cache_status ;;
        "")          menu_cache ;;
        *)
            log_error "Unknown cache command: $subcmd"
            echo "  Usage: dockweb cache {clear|clear-nginx|clear-php|status}"
            return 1
            ;;
    esac
}

# Backward compat alias
cmd_opcache_clear() { cmd_cache_clear "$@"; }

# Clear both nginx + PHP OPcache
cmd_cache_clear() {
    local domain="${1:-}"

    if [[ -z "$domain" ]]; then
        header "Clearing all caches"
        _clear_php_opcache
        _purge_nginx_cache
    else
        header "Clearing all caches: ${domain}"
        _clear_php_opcache "$domain"
        _purge_nginx_cache
    fi
}

# Clear nginx FastCGI cache only
cmd_cache_clear_nginx() {
    header "Clearing nginx FastCGI cache"
    _purge_nginx_cache
}

# Clear PHP OPcache only
cmd_cache_clear_php() {
    local domain="${1:-}"

    if [[ -z "$domain" ]]; then
        header "Clearing PHP OPcache (all sites)"
        _clear_php_opcache
    else
        header "Clearing PHP OPcache: ${domain}"
        _clear_php_opcache "$domain"
    fi
}

# Show cache sizes and status
cmd_cache_status() {
    header "Cache Status"

    # Nginx FastCGI cache
    echo -e "  ${BOLD}Nginx FastCGI Cache${NC}"
    local nginx_size
    nginx_size=$(docker exec gateway_nginx du -sh /var/cache/nginx/ 2>/dev/null | awk '{print $1}')
    if [[ -n "$nginx_size" ]]; then
        echo "    Size: ${nginx_size}"
    else
        echo "    Size: unavailable (container not running?)"
    fi
    echo ""

    # PHP OPcache per site
    echo -e "  ${BOLD}PHP OPcache${NC}"
    local sites
    sites=$(list_all_sites)
    if [[ -z "$sites" ]]; then
        echo "    No sites configured."
        return
    fi

    while IFS= read -r site; do
        [[ -z "$site" ]] && continue
        local SSL_MODE="" PHP_CONTAINER="" DB_NAME="" DB_USER="" DB_PASS="" DOMAIN=""
        if get_site_conf "$site"; then
            local opcache_info
            opcache_info=$(docker exec "$PHP_CONTAINER" php -r '
                $s = opcache_get_status(false);
                if ($s) {
                    $used = round($s["memory_usage"]["used_memory"] / 1048576, 1);
                    $total = round(($s["memory_usage"]["used_memory"] + $s["memory_usage"]["free_memory"]) / 1048576, 1);
                    $hit = $s["opcache_statistics"]["hits"];
                    $miss = $s["opcache_statistics"]["misses"];
                    $rate = ($hit + $miss) > 0 ? round($hit / ($hit + $miss) * 100, 1) : 0;
                    echo "${used}/${total} MB | hit rate: ${rate}%";
                } else {
                    echo "disabled";
                }
            ' 2>/dev/null)
            echo "    ${site} (${PHP_CONTAINER}): ${opcache_info:-unavailable}"
        fi
    done <<< "$sites"
}

# ── Cache internals ──────────────────────────────────────────────────

# Clear PHP OPcache for one or all sites (zero-downtime via USR2)
_clear_php_opcache() {
    local domain="${1:-}"
    local failed=0

    # USR2 gracefully reloads PHP-FPM workers, clearing opcache
    # Active requests finish before workers restart — zero downtime
    _opcache_reload_site() {
        local site="$1"
        local SSL_MODE="" PHP_CONTAINER="" DB_NAME="" DB_USER="" DB_PASS="" DOMAIN=""
        if get_site_conf "$site"; then
            if docker exec "$PHP_CONTAINER" kill -USR2 1 2>/dev/null; then
                log_success "${site} — OPcache cleared"
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

    if [[ -n "$domain" ]]; then
        _opcache_reload_site "$domain"
    else
        local sites
        sites=$(list_all_sites)
        if [[ -z "$sites" ]]; then
            log_error "No sites configured."
            return 1
        fi
        while IFS= read -r site; do
            [[ -z "$site" ]] && continue
            _opcache_reload_site "$site" || failed=1
        done <<< "$sites"
        [[ $failed -eq 0 ]] && log_success "All PHP OPcache cleared."
    fi
}

# Purge nginx FastCGI cache and reload (zero-downtime)
_purge_nginx_cache() {
    docker exec gateway_nginx sh -c 'rm -rf /var/cache/nginx/*' 2>/dev/null || true
    docker exec gateway_nginx nginx -s reload 2>/dev/null || true
    log_success "Nginx FastCGI cache purged."
}

# ── Cache interactive menu ───────────────────────────────────────────

menu_cache() {
    header "Cache Management"

    # Show current status inline
    local nginx_size
    nginx_size=$(docker exec gateway_nginx du -sh /var/cache/nginx/ 2>/dev/null | awk '{print $1}')
    echo -e "  Nginx FastCGI cache: ${nginx_size:-N/A}"

    local sites
    sites=$(list_all_sites)
    if [[ -n "$sites" ]]; then
        while IFS= read -r site; do
            [[ -z "$site" ]] && continue
            local SSL_MODE="" PHP_CONTAINER="" DB_NAME="" DB_USER="" DB_PASS="" DOMAIN=""
            if get_site_conf "$site"; then
                local mem
                mem=$(docker exec "$PHP_CONTAINER" php -r '
                    $s = opcache_get_status(false);
                    if ($s) {
                        $used = round($s["memory_usage"]["used_memory"] / 1048576, 1);
                        $total = round(($s["memory_usage"]["used_memory"] + $s["memory_usage"]["free_memory"]) / 1048576, 1);
                        echo "${used}/${total} MB";
                    } else { echo "off"; }
                ' 2>/dev/null)
                echo -e "  PHP OPcache (${site}): ${mem:-N/A}"
            fi
        done <<< "$sites"
    fi

    echo ""
    echo "  Which cache to clear?"
    echo "    1) Nginx cache only"
    echo "    2) PHP OPcache only"
    echo "    3) Both (nginx + PHP)"
    echo "    0) Back"
    echo ""
    echo -ne "  Choose [0-3]: "
    read -r layer_choice

    case "$layer_choice" in
        1) cmd_cache_clear_nginx ;;
        2) _menu_cache_pick_site "php" ;;
        3) _menu_cache_pick_site "both" ;;
        0) return ;;
        *) log_error "Invalid choice." ;;
    esac
}

# Site picker for cache clearing (used by interactive menu)
_menu_cache_pick_site() {
    local mode="$1"  # "php" or "both"
    local sites
    sites=$(list_all_sites)
    if [[ -z "$sites" ]]; then
        log_error "No sites configured."
        return 1
    fi

    echo ""
    echo "  Clear for which site?"
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

    local domain=""
    if [[ "$choice" == "0" ]]; then
        domain=""
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#site_arr[@]} )); then
        domain="${site_arr[$((choice-1))]}"
    else
        log_error "Invalid choice."
        return 1
    fi

    case "$mode" in
        php)  cmd_cache_clear_php "$domain" ;;
        both) cmd_cache_clear "$domain" ;;
    esac
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
