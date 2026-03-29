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
    header "Stopping Services"
    local cmd
    cmd="$(docker_compose_cmd)"
    $cmd down
    log_success "All services stopped."
}

cmd_restart() {
    ensure_sites_compose
    header "Restarting Services"
    local cmd
    cmd="$(docker_compose_cmd)"
    $cmd down
    cmd_start
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
    ensure_sites_compose
    header "Updating Images"

    local cmd
    cmd="$(docker_compose_cmd)"

    log_info "Pulling latest images..."
    $cmd pull

    log_info "Rebuilding and restarting..."
    $cmd up -d --build

    log_success "Update complete!"
    $cmd ps
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
