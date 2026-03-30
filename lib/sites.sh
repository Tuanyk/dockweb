#!/bin/bash
# dockweb - site management

cmd_site_list() {
    local sites
    sites=$(list_all_sites)

    if [[ -z "$sites" ]]; then
        log_warn "No sites configured."
        log_info "Run 'dockweb site add' to add your first site."
        return 0
    fi

    printf "\n  ${BOLD}%-30s %-12s %-25s %-20s${NC}\n" "DOMAIN" "SSL" "PHP CONTAINER" "DATABASE"
    printf "  ${DIM}%-30s %-12s %-25s %-20s${NC}\n" "──────────────────────────────" "────────────" "─────────────────────────" "────────────────────"

    while IFS= read -r domain; do
        [[ -z "$domain" ]] && continue
        local SSL_MODE="" PHP_CONTAINER="" DB_NAME="" DB_USER="" DB_PASS="" DOMAIN=""
        if get_site_conf "$domain"; then
            printf "  %-30s %-12s %-25s %-20s\n" "$DOMAIN" "$SSL_MODE" "$PHP_CONTAINER" "$DB_NAME"
        fi
    done <<< "$sites"
    echo ""
}

cmd_site_add() {
    header "Add New Site"
    load_env

    # Step 1: Domain
    echo -ne "  Domain name: "
    read -r domain
    if ! validate_domain "$domain"; then
        log_error "Invalid domain: $domain"
        return 1
    fi
    if [[ -f "${DOCKWEB_ROOT}/sites/${domain}/.dockweb.conf" ]]; then
        log_error "Site '$domain' already exists."
        return 1
    fi

    # Step 2: SSL mode
    echo ""
    echo "  SSL Mode:"
    echo "    1) Cloudflare Origin Certificate"
    echo "    2) Let's Encrypt"
    echo "    3) Local (HTTP only, serves as $domain)"
    echo "    4) Dev   (HTTP only, serves as .local domain)"
    echo ""
    echo -ne "  Choose [1-4]: "
    read -r ssl_choice
    local ssl_mode
    case "$ssl_choice" in
        1) ssl_mode="cloudflare" ;;
        2) ssl_mode="letsencrypt" ;;
        3) ssl_mode="local" ;;
        4) ssl_mode="dev" ;;
        *) log_error "Invalid choice."; return 1 ;;
    esac

    # Step 3: Auto-generate values
    local sanitized php_container db_name db_user db_pass
    sanitized=$(sanitize_domain "$domain")
    php_container="php_${sanitized}"
    db_name="${sanitized}_db"
    db_user="${sanitized}_user"
    db_pass=$(generate_password)

    # Step 4: Confirm
    echo ""
    echo -e "  ${BOLD}Summary:${NC}"
    echo "  ──────────────────────────────────────"
    echo "  Domain:         $domain"
    echo "  SSL Mode:       $ssl_mode"
    if [[ "$ssl_mode" == "dev" ]]; then
        echo "  Local Domain:   $(get_local_domain "$domain")  ← add to /etc/hosts"
    fi
    echo "  PHP Container:  $php_container"
    echo "  Database:       $db_name"
    echo "  DB User:        $db_user"
    echo "  DB Password:    $db_pass"
    echo "  Doc Root:       sites/$domain/public/"
    echo ""

    if ! confirm "  Create this site?"; then
        log_info "Cancelled."
        return 0
    fi

    echo ""

    # Step 5: Create directories
    log_info "Creating site directories..."
    mkdir -p "${DOCKWEB_ROOT}/sites/${domain}/public"
    mkdir -p "${DOCKWEB_ROOT}/logs/php/${domain}"

    # Placeholder index
    cat > "${DOCKWEB_ROOT}/sites/${domain}/public/index.php" <<PHPEOF
<?php
echo "<h1>$domain</h1><p>Site is ready. Deploy your application here.</p>";
phpinfo();
PHPEOF

    # Step 6: Write site config
    log_info "Saving site config..."
    cat > "${DOCKWEB_ROOT}/sites/${domain}/.dockweb.conf" <<CONFEOF
DOMAIN=$domain
SSL_MODE=$ssl_mode
DB_NAME=$db_name
DB_USER=$db_user
DB_PASS=$db_pass
PHP_CONTAINER=$php_container
CONFEOF
    chmod 600 "${DOCKWEB_ROOT}/sites/${domain}/.dockweb.conf"

    # Step 7: Generate nginx config
    log_info "Generating nginx config..."
    generate_nginx_conf "$domain" "$ssl_mode" "$php_container"

    # Step 8: Create database
    create_database "$db_name" "$db_user" "$db_pass"

    # Step 9: Regenerate compose
    log_info "Regenerating docker-compose.sites.yml..."
    generate_sites_compose

    # Step 10: SSL setup
    if [[ "$ssl_mode" == "cloudflare" ]]; then
        echo ""
        if confirm "  Install Cloudflare Origin Certificate now?"; then
            cmd_ssl_install_cf "$domain"
        else
            log_info "Run 'dockweb ssl install-cf $domain' later to install the certificate."
        fi
    elif [[ "$ssl_mode" == "letsencrypt" ]]; then
        echo ""
        log_info "Start services first, then run: dockweb ssl install-le $domain"
    fi

    # Step 11: Restart if running
    if is_running; then
        echo ""
        log_info "Rebuilding containers..."
        local cmd
        cmd="$(docker_compose_cmd)"
        $cmd up -d --build
        docker exec gateway_nginx nginx -s reload 2>/dev/null || true
    fi

    # Step 12: Summary
    echo ""
    log_success "Site '$domain' created!"
    echo ""
    echo -e "  ${BOLD}WordPress Database Config:${NC}"
    echo "  DB_HOST:     shared_mysql"
    echo "  DB_NAME:     $db_name"
    echo "  DB_USER:     $db_user"
    echo "  DB_PASSWORD: $db_pass"
    echo ""
    if [[ "$ssl_mode" == "dev" ]]; then
        local local_domain
        local_domain=$(get_local_domain "$domain")
        echo -e "  ${BOLD}Dev /etc/hosts entry:${NC}"
        echo "  Add this line to /etc/hosts (sudo required):"
        echo ""
        echo -e "  ${CYAN}127.0.0.1  ${local_domain} www.${local_domain}${NC}"
        echo ""
        echo "  Run: sudo sh -c 'echo \"127.0.0.1  ${local_domain} www.${local_domain}\" >> /etc/hosts'"
        echo "  Then visit: http://${local_domain}"
        echo ""
    fi
}

cmd_site_remove() {
    local domain="$1"
    if [[ -z "$domain" ]]; then
        echo -ne "  Domain to remove: "
        read -r domain
    fi

    if [[ ! -f "${DOCKWEB_ROOT}/sites/${domain}/.dockweb.conf" ]]; then
        log_error "Site '$domain' not found."
        return 1
    fi

    local SSL_MODE="" PHP_CONTAINER="" DB_NAME="" DB_USER="" DB_PASS="" DOMAIN=""
    get_site_conf "$domain"

    echo ""
    echo -e "  ${RED}${BOLD}WARNING: This will remove site '$domain'${NC}"
    echo "  Container: $PHP_CONTAINER"
    echo "  Database:  $DB_NAME"
    echo ""

    if ! confirm "  Remove nginx config and container? (site files kept)" "n"; then
        log_info "Cancelled."
        return 0
    fi

    # Stop PHP container if running
    if is_running; then
        local cmd
        cmd="$(docker_compose_cmd)"
        docker stop "$PHP_CONTAINER" 2>/dev/null || true
        docker rm "$PHP_CONTAINER" 2>/dev/null || true
    fi

    # Remove nginx config
    rm -f "${DOCKWEB_ROOT}/nginx/conf.d/${domain}.conf"
    log_success "Nginx config removed."

    # Optionally drop database
    if confirm "  Also drop database '$DB_NAME'?" "n"; then
        load_env
        docker exec shared_mysql mysql -u root -p"${DB_ROOT_PASSWORD}" \
            -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`; DROP USER IF EXISTS '${DB_USER}'@'%';" 2>/dev/null \
            && log_success "Database dropped." \
            || log_warn "Could not drop database (MySQL might not be running)."
    fi

    # Optionally remove site files
    if confirm "  Also delete site files in sites/${domain}/?" "n"; then
        rm -rf "${DOCKWEB_ROOT}/sites/${domain}"
        log_success "Site files deleted."
    else
        rm -f "${DOCKWEB_ROOT}/sites/${domain}/.dockweb.conf"
    fi

    # Regenerate compose
    generate_sites_compose

    # Reload if running
    if is_running; then
        local cmd
        cmd="$(docker_compose_cmd)"
        $cmd up -d --remove-orphans
        docker exec gateway_nginx nginx -s reload 2>/dev/null || true
    fi

    log_success "Site '$domain' removed."
}

generate_sites_compose() {
    local output="${DOCKWEB_ROOT}/docker-compose.sites.yml"
    local tmp="${output}.tmp"
    local sites
    sites=$(list_all_sites)

    cat > "$tmp" <<'HEADER'
# Auto-generated by dockweb - DO NOT EDIT MANUALLY
# Regenerate with: dockweb start (or dockweb site add/remove)

HEADER

    if [[ -z "$sites" ]]; then
        cat >> "$tmp" <<'EMPTY'
services: {}

networks:
  web_network:
    driver: bridge
EMPTY
        mv "$tmp" "$output"
        return
    fi

    echo "services:" >> "$tmp"

    while IFS= read -r domain; do
        [[ -z "$domain" ]] && continue
        local SSL_MODE="" PHP_CONTAINER="" DB_NAME="" DB_USER="" DB_PASS="" DOMAIN=""
        get_site_conf "$domain" || continue

        local service_name
        service_name=$(sanitize_domain "$domain")

        sed \
            -e "s|{{SERVICE_NAME}}|${service_name}|g" \
            -e "s|{{CONTAINER_NAME}}|${PHP_CONTAINER}|g" \
            -e "s|{{DOMAIN}}|${domain}|g" \
            "${DOCKWEB_ROOT}/templates/php-service.yml.tpl" >> "$tmp"
        echo "" >> "$tmp"
    done <<< "$sites"

    cat >> "$tmp" <<'FOOTER'
networks:
  web_network:
    driver: bridge
FOOTER

    mv "$tmp" "$output"
    log_success "docker-compose.sites.yml updated ($(echo "$sites" | wc -l) site(s))."
}

generate_nginx_conf() {
    local domain="$1"
    local ssl_mode="$2"
    local php_container="$3"
    local template output

    case "$ssl_mode" in
        cloudflare)  template="${DOCKWEB_ROOT}/templates/nginx-cloudflare.conf.tpl" ;;
        letsencrypt) template="${DOCKWEB_ROOT}/templates/nginx-letsencrypt.conf.tpl" ;;
        local)       template="${DOCKWEB_ROOT}/templates/nginx-local.conf.tpl" ;;
        dev)         template="${DOCKWEB_ROOT}/templates/nginx-dev.conf.tpl" ;;
        *)           log_error "Unknown SSL mode: $ssl_mode"; return 1 ;;
    esac

    output="${DOCKWEB_ROOT}/nginx/conf.d/${domain}.conf"

    local local_domain
    local_domain=$(get_local_domain "$domain")

    sed \
        -e "s|{{DOMAIN}}|${domain}|g" \
        -e "s|{{LOCAL_DOMAIN}}|${local_domain}|g" \
        -e "s|{{PHP_CONTAINER}}|${php_container}|g" \
        "$template" > "$output"

    log_success "Nginx config: nginx/conf.d/${domain}.conf"
}

create_database() {
    local db_name="$1"
    local db_user="$2"
    local db_pass="$3"

    load_env

    local sql
    sql=$(sed \
        -e "s|{{DB_NAME}}|${db_name}|g" \
        -e "s|{{DB_USER}}|${db_user}|g" \
        -e "s|{{DB_PASS}}|${db_pass}|g" \
        "${DOCKWEB_ROOT}/templates/db-init.sql.tpl")

    # Try docker exec first (if MySQL is running)
    if docker exec shared_mysql mysql -u root -p"${DB_ROOT_PASSWORD}" -e "SELECT 1" &>/dev/null; then
        echo "$sql" | docker exec -i shared_mysql mysql -u root -p"${DB_ROOT_PASSWORD}" 2>/dev/null
        log_success "Database '$db_name' created with user '$db_user'."
    else
        # Save for next MySQL startup
        local init_file="${DOCKWEB_ROOT}/mysql/init/$(date +%s)-${db_name}.sql"
        echo "$sql" > "$init_file"
        log_info "MySQL not running. SQL saved to: $init_file"
        log_info "It will execute on next MySQL startup."
    fi
}
