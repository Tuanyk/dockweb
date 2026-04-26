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

    printf "\n  ${BOLD}%-30s %-12s %-25s %-18s %-6s${NC}\n" \
        "DOMAIN" "SSL" "PHP CONTAINER" "DATABASE" "CACHE"
    printf "  ${DIM}%-30s %-12s %-25s %-18s %-6s${NC}\n" \
        "──────────────────────────────" "────────────" \
        "─────────────────────────" "──────────────────" "──────"

    while IFS= read -r domain; do
        [[ -z "$domain" ]] && continue
        local SSL_MODE="" PHP_CONTAINER="" DB_NAME="" DB_USER="" DB_PASS="" \
              DOMAIN="" CACHE_ENABLED=""
        if get_site_conf "$domain"; then
            local cache_display="${CACHE_ENABLED:-true}"
            [[ "$cache_display" == "true" ]]  && cache_display="on"
            [[ "$cache_display" == "false" ]] && cache_display="off"
            printf "  %-30s %-12s %-25s %-18s %-6s\n" \
                "$DOMAIN" "$SSL_MODE" "$PHP_CONTAINER" "$DB_NAME" "$cache_display"
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
    local sanitized db_name db_user db_pass
    sanitized=$(sanitize_domain "$domain")
    db_name="${sanitized}_db"
    db_user="${sanitized}_user"
    db_pass=$(generate_password)

    # Step 4: Pick PHP container — create new (isolated) or share an existing one
    local php_container share_note=""
    php_container=$(_pick_php_container "$sanitized") || return 1
    if _container_is_shared_target "$php_container"; then
        local members
        members=$(sites_in_container "$php_container" | paste -sd',' -)
        share_note="(shared with: $members — they will briefly restart)"
    fi

    # Step 4b: Cache opt-in (FastCGI cache is only applied for cloudflare /
    # letsencrypt modes; dev/local templates don't include it regardless).
    local cache_enabled="true"
    if [[ "$ssl_mode" == "cloudflare" || "$ssl_mode" == "letsencrypt" ]]; then
        echo ""
        if confirm "  Enable FastCGI cache for this site?" "y"; then
            cache_enabled="true"
        else
            cache_enabled="false"
        fi
    fi

    # Step 5: Confirm
    echo ""
    echo -e "  ${BOLD}Summary:${NC}"
    echo "  ──────────────────────────────────────"
    echo "  Domain:         $domain"
    echo "  SSL Mode:       $ssl_mode"
    if [[ "$ssl_mode" == "dev" ]]; then
        echo "  Local Domain:   $(get_local_domain "$domain")  ← add to /etc/hosts"
    fi
    echo "  PHP Container:  $php_container ${share_note}"
    if [[ "$ssl_mode" == "cloudflare" || "$ssl_mode" == "letsencrypt" ]]; then
        echo "  FastCGI Cache:  $cache_enabled"
    fi
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
    # PHP log dir is per-container (matches the compose mount below)
    mkdir -p "${DOCKWEB_ROOT}/logs/php/${php_container}"

    # Placeholder index (only if no index.php exists yet)
    if [[ ! -f "${DOCKWEB_ROOT}/sites/${domain}/public/index.php" ]]; then
        cat > "${DOCKWEB_ROOT}/sites/${domain}/public/index.php" <<PHPEOF
<?php
echo "<h1>$domain</h1><p>Site is ready. Deploy your application here.</p>";
phpinfo();
PHPEOF
    fi

    # Step 6: Write site config
    log_info "Saving site config..."
    cat > "${DOCKWEB_ROOT}/sites/${domain}/.dockweb.conf" <<CONFEOF
DOMAIN=$domain
SSL_MODE=$ssl_mode
DB_NAME=$db_name
DB_USER=$db_user
DB_PASS=$db_pass
PHP_CONTAINER=$php_container
CACHE_ENABLED=$cache_enabled
CONFEOF
    chmod 600 "${DOCKWEB_ROOT}/sites/${domain}/.dockweb.conf"

    # Step 7: Generate nginx config
    log_info "Generating nginx config..."
    generate_nginx_conf "$domain" "$ssl_mode" "$php_container" "$cache_enabled"

    # Step 8: Create database
    create_database "$db_name" "$db_user" "$db_pass"

    # Step 8b: If WordPress already exists, offer to wire the DB settings into
    # wp-config.php so the site can come up without a manual edit.
    maybe_patch_wp_config "$domain" "$db_name" "$db_user" "$db_pass" "shared_mysql"

    # Step 9: Regenerate compose
    log_info "Regenerating docker-compose.sites.yml..."
    generate_sites_compose

    # Step 10: Start / recreate the PHP container if the stack is already running.
    # MUST happen before any nginx reload (Step 11): the new vhost references
    # this container's hostname as an upstream, so `nginx -t` fails with
    # "host not found in upstream" until the container is actually up.
    local stack_was_running=false
    if is_running; then
        stack_was_running=true
        echo ""
        local cmd
        cmd="$(docker_compose_cmd)"
        # Recalculate PM_MAX_CHILDREN against the new topology before bringing
        # the container up, otherwise a newly shared container would be
        # recreated with a stale .env value.
        calculate_resources
        log_info "Bringing up PHP container '${php_container}'..."
        # --no-deps: don't restart mysql/redis, just this container.
        # --build: uses cached image layers if Dockerfile unchanged (fast).
        # --force-recreate: compose's config-drift detection doesn't always
        # notice new bind mounts on an existing container, so force it. For a
        # brand-new container this is a no-op; for a shared container the
        # sibling sites get a brief (~2s) restart while the new mount is
        # applied — unavoidable if we want the new site to actually work.
        $cmd up -d --no-deps --build --force-recreate "$php_container"
        log_success "PHP container ready."
    fi

    # Step 11: SSL setup (after PHP container is up so nginx -t resolves the upstream)
    if [[ "$ssl_mode" == "cloudflare" ]]; then
        echo ""
        if [[ "$stack_was_running" == true ]]; then
            if confirm "  Install Cloudflare Origin Certificate now?"; then
                cmd_ssl_install_cf "$domain"
            else
                log_info "Run 'dockweb ssl install-cf $domain' later to install the certificate."
            fi
        else
            log_info "Run 'dockweb start' first, then 'dockweb ssl install-cf $domain' to install the certificate."
        fi
    elif [[ "$ssl_mode" == "letsencrypt" ]]; then
        echo ""
        log_info "Start services first, then run: dockweb ssl install-le $domain"
    fi

    # Step 11b: Reload nginx for non-SSL flows (cmd_ssl_install_* reloads internally).
    if [[ "$stack_was_running" == true && "$ssl_mode" != "cloudflare" ]]; then
        docker exec gateway_nginx nginx -s reload 2>/dev/null || true
    fi

    if [[ "$stack_was_running" == false ]]; then
        log_info "Run 'dockweb start' to bring up all services."
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

# Interactive picker: returns a PHP container name on stdout.
# If no containers exist yet, silently returns a fresh "php_<sanitized>".
_pick_php_container() {
    local sanitized="$1"
    local existing
    existing=$(list_php_containers)

    if [[ -z "$existing" ]]; then
        echo "php_${sanitized}"
        return 0
    fi

    # Emit the menu to stderr so stdout stays clean for the caller.
    {
        echo ""
        echo "  PHP Container:"
        echo "    1) Create new (isolated)  -> php_${sanitized}"
        local i=2
        while IFS= read -r c; do
            [[ -z "$c" ]] && continue
            local member_list
            member_list=$(sites_in_container "$c" | paste -sd',' -)
            echo "    ${i}) Share with ${c}  (hosts: ${member_list})"
            ((i++))
        done <<< "$existing"
        echo ""
        echo -n "  Choose [1-$((i-1))]: "
    } >&2

    local choice
    read -r choice

    if [[ "$choice" == "1" ]]; then
        echo "php_${sanitized}"
        return 0
    fi

    local idx=2
    while IFS= read -r c; do
        [[ -z "$c" ]] && continue
        if [[ "$choice" == "$idx" ]]; then
            echo "$c"
            return 0
        fi
        ((idx++))
    done <<< "$existing"

    log_error "Invalid choice."
    return 1
}

# True if $1 is a container already referenced by at least one existing site.
_container_is_shared_target() {
    local container="$1"
    list_php_containers | grep -qx "$container"
}

find_wp_config() {
    local domain="$1"
    local site_root="${DOCKWEB_ROOT}/sites/${domain}"
    local candidate

    for candidate in \
        "${site_root}/wp-config.php" \
        "${site_root}/public/wp-config.php"; do
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

_escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

_wp_define_line() {
    local key="$1"
    local value="$2"
    printf "define( '%s', '%s' );" "$key" "$value"
}

wp_config_has_standard_db_constants() {
    local path="$1"
    local key

    for key in DB_NAME DB_USER DB_PASSWORD DB_HOST; do
        if ! grep -Eq "^[[:space:]]*define[[:space:]]*\\([[:space:]]*['\"]${key}['\"]" "$path"; then
            return 1
        fi
    done

    return 0
}

verify_wp_config_db_settings() {
    local path="$1"
    local db_name="$2"
    local db_user="$3"
    local db_pass="$4"
    local db_host="$5"

    grep -Fq "$(_wp_define_line DB_NAME "$db_name")" "$path" \
        && grep -Fq "$(_wp_define_line DB_USER "$db_user")" "$path" \
        && grep -Fq "$(_wp_define_line DB_PASSWORD "$db_pass")" "$path" \
        && grep -Fq "$(_wp_define_line DB_HOST "$db_host")" "$path"
}

patch_wp_config_db_settings() {
    local path="$1"
    local db_name="$2"
    local db_user="$3"
    local db_pass="$4"
    local db_host="$5"
    local rel_path="${path#${DOCKWEB_ROOT}/}"
    local backup="${path}.dockweb.bak.$(date +%Y%m%d%H%M%S)"
    local db_name_esc db_user_esc db_pass_esc db_host_esc

    if [[ ! -w "$path" ]]; then
        log_warn "wp-config.php is not writable: ${rel_path}"
        return 1
    fi

    if ! wp_config_has_standard_db_constants "$path"; then
        log_warn "Detected ${rel_path}, but its DB settings are not in the standard define() format."
        log_info "Skipped wp-config.php patch."
        return 1
    fi

    if ! cp "$path" "$backup"; then
        log_warn "Could not create backup before patching: ${backup#${DOCKWEB_ROOT}/}"
        return 1
    fi

    db_name_esc=$(_escape_sed_replacement "$db_name")
    db_user_esc=$(_escape_sed_replacement "$db_user")
    db_pass_esc=$(_escape_sed_replacement "$db_pass")
    db_host_esc=$(_escape_sed_replacement "$db_host")

    if ! sed -Ei \
        -e "s|^([[:space:]]*)define[[:space:]]*\\([[:space:]]*['\"]DB_NAME['\"][[:space:]]*,[[:space:]]*.*\\);.*$|\\1define( 'DB_NAME', '${db_name_esc}' );|" \
        -e "s|^([[:space:]]*)define[[:space:]]*\\([[:space:]]*['\"]DB_USER['\"][[:space:]]*,[[:space:]]*.*\\);.*$|\\1define( 'DB_USER', '${db_user_esc}' );|" \
        -e "s|^([[:space:]]*)define[[:space:]]*\\([[:space:]]*['\"]DB_PASSWORD['\"][[:space:]]*,[[:space:]]*.*\\);.*$|\\1define( 'DB_PASSWORD', '${db_pass_esc}' );|" \
        -e "s|^([[:space:]]*)define[[:space:]]*\\([[:space:]]*['\"]DB_HOST['\"][[:space:]]*,[[:space:]]*.*\\);.*$|\\1define( 'DB_HOST', '${db_host_esc}' );|" \
        "$path"; then
        cp "$backup" "$path" 2>/dev/null || true
        log_warn "Failed to patch ${rel_path}; restored the backup."
        return 1
    fi

    if ! verify_wp_config_db_settings "$path" "$db_name" "$db_user" "$db_pass" "$db_host"; then
        cp "$backup" "$path" 2>/dev/null || true
        log_warn "Patch verification failed for ${rel_path}; restored the backup."
        return 1
    fi

    log_success "Patched WordPress config: ${rel_path}"
    log_info "Backup saved to: ${backup#${DOCKWEB_ROOT}/}"
}

maybe_patch_wp_config() {
    local domain="$1"
    local db_name="$2"
    local db_user="$3"
    local db_pass="$4"
    local db_host="$5"
    local wp_config

    if ! wp_config=$(find_wp_config "$domain"); then
        return 0
    fi

    echo ""
    log_info "Detected WordPress config: ${wp_config#${DOCKWEB_ROOT}/}"

    if confirm "  Patch WordPress DB settings in this file now?" "y"; then
        patch_wp_config_db_settings "$wp_config" "$db_name" "$db_user" "$db_pass" "$db_host"
    else
        log_info "Skipped wp-config.php patch."
    fi
}

cmd_site_remove() {
    local domain="${1:-}"
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

    # Are any other sites sharing this PHP container?
    local siblings
    siblings=$(sites_in_container "$PHP_CONTAINER" | grep -vx "$domain" || true)

    local container_action
    if [[ -n "$siblings" ]]; then
        container_action="Keep '${PHP_CONTAINER}' running (shared with: $(echo "$siblings" | paste -sd',' -)); just unmount this site"
    else
        container_action="Stop and remove container '${PHP_CONTAINER}' (this site is the only member)"
    fi

    if ! confirm_dangerous \
        "Remove site '${domain}'" \
        "${container_action}. Nginx config deleted; database ${DB_NAME} optionally dropped" \
        "Site goes offline immediately"; then
        log_info "Cancelled."
        return 0
    fi

    # Remove the site conf first so generate_sites_compose + list_php_containers
    # see the new state.
    rm -f "${DOCKWEB_ROOT}/sites/${domain}/.dockweb.conf"

    # Remove nginx config
    rm -f "${DOCKWEB_ROOT}/nginx/conf.d/${domain}.conf"
    log_success "Nginx config removed."

    # Regenerate compose *before* touching containers so the new definitions
    # are in place for `up -d`.
    generate_sites_compose

    if [[ -z "$siblings" ]]; then
        # Sole member — stop + remove the container outright.
        if is_running; then
            docker stop "$PHP_CONTAINER" 2>/dev/null || true
            docker rm "$PHP_CONTAINER" 2>/dev/null || true
        fi
    else
        # Shared container — recreate so the removed volume mount drops off.
        if is_running; then
            local cmd
            cmd="$(docker_compose_cmd)"
            # Recompute sizing so the recreated container doesn't pick up a
            # stale PM_MAX_CHILDREN from .env.
            calculate_resources
            log_info "Recreating shared container '${PHP_CONTAINER}' without this site's mount..."
            $cmd up -d --no-deps "$PHP_CONTAINER"
        fi
    fi

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
    fi

    # Reload nginx so stale upstream IPs are flushed
    if is_running; then
        local cmd
        cmd="$(docker_compose_cmd)"
        $cmd up -d --remove-orphans >/dev/null 2>&1 || true
        docker exec gateway_nginx nginx -s reload 2>/dev/null || true
    fi

    log_success "Site '$domain' removed."
}

generate_sites_compose() {
    local output="${DOCKWEB_ROOT}/docker-compose.sites.yml"
    local tmp="${output}.tmp"
    local containers
    containers=$(list_php_containers)

    cat > "$tmp" <<'HEADER'
# Auto-generated by dockweb - DO NOT EDIT MANUALLY
# Regenerate with: dockweb start (or dockweb site add/remove)

HEADER

    if [[ -z "$containers" ]]; then
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

    local container_total=0
    while IFS= read -r c; do
        [[ -z "$c" ]] && continue
        container_total=$((container_total + 1))
        _emit_php_service "$c" >> "$tmp"
        echo "" >> "$tmp"
    done <<< "$containers"

    cat >> "$tmp" <<'FOOTER'
networks:
  web_network:
    driver: bridge
FOOTER

    mv "$tmp" "$output"
    local site_total
    site_total=$(site_count)
    log_success "docker-compose.sites.yml updated (${container_total} PHP container(s), ${site_total} site(s))."
}

# Emit one service block for a PHP container with all its mounted sites.
# Service name == container_name so that restart/update commands can target
# either interchangeably.
_emit_php_service() {
    local container="$1"
    local domains site_names
    domains=$(sites_in_container "$container")
    site_names=$(echo "$domains" | paste -sd',' -)

    cat <<SERVICE
  ${container}:
    build:
      context: ./php
      args:
        PHP_UID: \${PHP_UID:-1000}
        PHP_GID: \${PHP_GID:-1000}
    container_name: ${container}
    restart: unless-stopped
    environment:
      PM_MAX_CHILDREN: \${PHP_PM_MAX_CHILDREN:-3}
      SITE_NAMES: "${site_names}"
    volumes:
SERVICE

    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        echo "      - ./sites/${d}:/var/www/sites/${d}"
    done <<< "$domains"

    cat <<SERVICE
      - ./logs/php/${container}:/var/log
    depends_on:
      - mysql
      - redis
    networks:
      - web_network
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    healthcheck:
      test: ["CMD-SHELL", "php-fpm-healthcheck || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    deploy:
      resources:
        limits:
          memory: 768M
          cpus: '1.0'
        reservations:
          memory: 128M
          cpus: '0.25'
SERVICE
}

ssl_mode_cert_ready() {
    local domain="$1"
    local ssl_mode="$2"

    case "$ssl_mode" in
        cloudflare)
            [[ -f "${DOCKWEB_ROOT}/cloudflare-certs/${domain}/origin.pem" \
               && -f "${DOCKWEB_ROOT}/cloudflare-certs/${domain}/origin.key" ]]
            ;;
        letsencrypt)
            [[ -f "${DOCKWEB_ROOT}/certbot/conf/live/${domain}/fullchain.pem" \
               && -f "${DOCKWEB_ROOT}/certbot/conf/live/${domain}/privkey.pem" \
               && -f "${DOCKWEB_ROOT}/certbot/conf/options-ssl-nginx.conf" \
               && -f "${DOCKWEB_ROOT}/certbot/conf/ssl-dhparams.pem" ]]
            ;;
        dev-ssl)
            [[ -f "${DOCKWEB_ROOT}/local-certs/${domain}/cert.pem" \
               && -f "${DOCKWEB_ROOT}/local-certs/${domain}/key.pem" ]]
            ;;
        *)
            return 0
            ;;
    esac
}

generate_nginx_conf() {
    local domain="$1"
    local ssl_mode="$2"
    local php_container="$3"
    # 4th arg is optional — enables/disables FastCGI cache for this site.
    # Default is "true" for backwards-compat with older sites that predate
    # the CACHE_ENABLED field in .dockweb.conf.
    local cache_enabled="${4:-true}"
    local template output

    case "$ssl_mode" in
        cloudflare)
            if ssl_mode_cert_ready "$domain" "$ssl_mode"; then
                template="${DOCKWEB_ROOT}/templates/nginx-cloudflare.conf.tpl"
            else
                template="${DOCKWEB_ROOT}/templates/nginx-pending-ssl.conf.tpl"
                log_warn "SSL cert missing for ${domain} (cloudflare). Generated temporary HTTP-only config."
                log_info "Run 'dockweb ssl install-cf ${domain}' to enable HTTPS."
            fi
            ;;
        letsencrypt)
            if ssl_mode_cert_ready "$domain" "$ssl_mode"; then
                template="${DOCKWEB_ROOT}/templates/nginx-letsencrypt.conf.tpl"
            else
                template="${DOCKWEB_ROOT}/templates/nginx-pending-ssl.conf.tpl"
                log_warn "SSL cert missing for ${domain} (letsencrypt). Generated temporary HTTP-only config."
                log_info "Run 'dockweb ssl install-le ${domain}' to enable HTTPS."
            fi
            ;;
        local)       template="${DOCKWEB_ROOT}/templates/nginx-local.conf.tpl" ;;
        dev)         template="${DOCKWEB_ROOT}/templates/nginx-dev.conf.tpl" ;;
        dev-ssl)     template="${DOCKWEB_ROOT}/templates/nginx-dev-ssl.conf.tpl" ;;
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

    # Strip the FastCGI cache block if the site opted out. The dev/local
    # templates don't have these markers, so this is a no-op for them.
    if [[ "$cache_enabled" != "true" ]]; then
        sed -i '/# CACHE: BEGIN/,/# CACHE: END/d' "$output"
    fi

    log_success "Nginx config: nginx/conf.d/${domain}.conf"
}

# Regenerate every site's nginx conf from its current template. Called from
# `dockweb start` so template updates picked up via `git pull` apply to
# existing sites without needing to re-run `site add`.
regenerate_all_nginx_confs() {
    local sites
    sites=$(list_all_sites)
    [[ -z "$sites" ]] && return 0
    log_info "Regenerating nginx site configs from templates..."
    local count=0
    while IFS= read -r site; do
        [[ -z "$site" ]] && continue
        local SSL_MODE="" PHP_CONTAINER="" DB_NAME="" DB_USER="" DB_PASS="" \
              DOMAIN="" CACHE_ENABLED=""
        if get_site_conf "$site"; then
            generate_nginx_conf "$DOMAIN" "$SSL_MODE" "$PHP_CONTAINER" \
                "${CACHE_ENABLED:-true}" >/dev/null
            count=$((count + 1))
        fi
    done <<< "$sites"
    log_success "Regenerated ${count} site config(s)."
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
