#!/bin/bash
# dockweb - SSL management

cmd_ssl_menu() {
    local domain="$1"
    local new_mode="$2"

    if [[ -z "$domain" ]]; then
        header "SSL Management"
        local sites
        sites=$(list_all_sites)
        if [[ -z "$sites" ]]; then
            log_warn "No sites configured."
            return 0
        fi

        # List sites with SSL status
        echo "  Sites:"
        local i=0
        local domains_arr=()
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            i=$((i + 1))
            domains_arr+=("$d")
            local SSL_MODE="" PHP_CONTAINER="" DB_NAME="" DB_USER="" DB_PASS="" DOMAIN=""
            get_site_conf "$d"
            local cert_status="missing"
            if [[ "$SSL_MODE" == "cloudflare" ]]; then
                [[ -f "${DOCKWEB_ROOT}/cloudflare-certs/${d}/origin.pem" ]] && cert_status="installed"
            else
                [[ -f "${DOCKWEB_ROOT}/certbot/conf/live/${d}/fullchain.pem" ]] && cert_status="installed"
            fi
            printf "    %d) %-30s %-12s [%s]\n" "$i" "$d" "$SSL_MODE" "$cert_status"
        done <<< "$sites"

        echo ""
        echo "  Actions:"
        echo "    a) Install Cloudflare Origin Cert"
        echo "    b) Install Let's Encrypt Cert"
        echo "    c) Switch SSL mode for a site"
        echo "    d) Update Cloudflare IP ranges"
        echo "    0) Back"
        echo ""
        echo -ne "  Choose: "
        read -r action

        case "$action" in
            a)
                echo -ne "  Site number: "
                read -r num
                [[ -z "${domains_arr[$((num-1))]}" ]] && { log_error "Invalid."; return 1; }
                cmd_ssl_install_cf "${domains_arr[$((num-1))]}"
                ;;
            b)
                echo -ne "  Site number: "
                read -r num
                [[ -z "${domains_arr[$((num-1))]}" ]] && { log_error "Invalid."; return 1; }
                cmd_ssl_install_le "${domains_arr[$((num-1))]}"
                ;;
            c)
                echo -ne "  Site number: "
                read -r num
                [[ -z "${domains_arr[$((num-1))]}" ]] && { log_error "Invalid."; return 1; }
                local d="${domains_arr[$((num-1))]}"
                echo "  New SSL mode:"
                echo "    1) cloudflare"
                echo "    2) letsencrypt"
                echo -ne "  Choose: "
                read -r mode_choice
                case "$mode_choice" in
                    1) cmd_ssl_switch "$d" "cloudflare" ;;
                    2) cmd_ssl_switch "$d" "letsencrypt" ;;
                    *) log_error "Invalid." ;;
                esac
                ;;
            d) update_cloudflare_ips ;;
            0) return 0 ;;
            *) log_error "Invalid choice." ;;
        esac
        return
    fi

    # Direct command: dockweb ssl <domain> <mode>
    if [[ -n "$new_mode" ]]; then
        cmd_ssl_switch "$domain" "$new_mode"
    else
        # Show SSL info for domain
        if [[ ! -f "${DOCKWEB_ROOT}/sites/${domain}/.dockweb.conf" ]]; then
            log_error "Site '$domain' not found."
            return 1
        fi
        local SSL_MODE="" PHP_CONTAINER="" DB_NAME="" DB_USER="" DB_PASS="" DOMAIN=""
        get_site_conf "$domain"
        echo "  Domain:   $domain"
        echo "  SSL Mode: $SSL_MODE"
        local cert_status="missing"
        if [[ "$SSL_MODE" == "cloudflare" ]]; then
            [[ -f "${DOCKWEB_ROOT}/cloudflare-certs/${domain}/origin.pem" ]] && cert_status="installed"
        else
            [[ -f "${DOCKWEB_ROOT}/certbot/conf/live/${domain}/fullchain.pem" ]] && cert_status="installed"
        fi
        echo "  Cert:     $cert_status"
    fi
}

cmd_ssl_install_cf() {
    local domain="$1"
    if [[ -z "$domain" ]]; then
        echo -ne "  Domain: "
        read -r domain
    fi

    if [[ ! -f "${DOCKWEB_ROOT}/sites/${domain}/.dockweb.conf" ]]; then
        log_error "Site '$domain' not found."
        return 1
    fi

    header "Install Cloudflare Origin Certificate: $domain"

    local cert_dir="${DOCKWEB_ROOT}/cloudflare-certs/${domain}"
    mkdir -p "$cert_dir"

    echo ""
    echo "  Go to Cloudflare Dashboard > SSL/TLS > Origin Server"
    echo "  Click 'Create Certificate' and download both files."
    echo ""
    echo "  How to provide the certificate:"
    echo "    1) Paste certificate content"
    echo "    2) Provide file paths"
    echo ""
    echo -ne "  Choose [1-2]: "
    read -r method

    case "$method" in
        1)
            echo ""
            echo "  Paste the Origin Certificate PEM (end with empty line):"
            local cert_content=""
            while IFS= read -r line; do
                [[ -z "$line" ]] && break
                cert_content+="${line}"$'\n'
            done
            echo "$cert_content" > "${cert_dir}/origin.pem"

            echo "  Paste the Private Key PEM (end with empty line):"
            local key_content=""
            while IFS= read -r line; do
                [[ -z "$line" ]] && break
                key_content+="${line}"$'\n'
            done
            echo "$key_content" > "${cert_dir}/origin.key"
            ;;
        2)
            echo -ne "  Path to origin.pem: "
            read -r cert_path
            echo -ne "  Path to origin.key: "
            read -r key_path
            if [[ ! -f "$cert_path" ]] || [[ ! -f "$key_path" ]]; then
                log_error "File not found."
                return 1
            fi
            cp "$cert_path" "${cert_dir}/origin.pem"
            cp "$key_path" "${cert_dir}/origin.key"
            ;;
        *)
            log_error "Invalid choice."
            return 1
            ;;
    esac

    chmod 644 "${cert_dir}/origin.pem"
    chmod 600 "${cert_dir}/origin.key"

    log_success "Certificate installed at: cloudflare-certs/${domain}/"

    # Reload nginx if running
    if docker exec gateway_nginx nginx -t 2>/dev/null; then
        docker exec gateway_nginx nginx -s reload 2>/dev/null
        log_success "Nginx reloaded."
    fi
}

cmd_ssl_install_le() {
    local domain="$1"
    if [[ -z "$domain" ]]; then
        echo -ne "  Domain: "
        read -r domain
    fi

    if [[ ! -f "${DOCKWEB_ROOT}/sites/${domain}/.dockweb.conf" ]]; then
        log_error "Site '$domain' not found."
        return 1
    fi

    load_env
    header "Install Let's Encrypt Certificate: $domain"

    local email="${CERTBOT_EMAIL:-}"
    local cmd
    cmd="$(docker_compose_cmd)"

    # Ensure certbot dirs exist
    mkdir -p "${DOCKWEB_ROOT}/certbot/conf" \
             "${DOCKWEB_ROOT}/certbot/www" \
             "${DOCKWEB_ROOT}/certbot/logs"

    # Download TLS parameters if needed
    if [[ ! -f "${DOCKWEB_ROOT}/certbot/conf/options-ssl-nginx.conf" ]]; then
        log_info "Downloading TLS parameters..."
        curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf \
            > "${DOCKWEB_ROOT}/certbot/conf/options-ssl-nginx.conf"
    fi
    if [[ ! -f "${DOCKWEB_ROOT}/certbot/conf/ssl-dhparams.pem" ]]; then
        log_info "Downloading DH parameters..."
        curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot/certbot/ssl-dhparams.pem \
            > "${DOCKWEB_ROOT}/certbot/conf/ssl-dhparams.pem"
    fi

    # Create dummy cert for nginx to start
    log_info "Creating temporary certificate..."
    local le_path="/etc/letsencrypt/live/${domain}"
    mkdir -p "${DOCKWEB_ROOT}/certbot/conf/live/${domain}"
    $cmd run --rm --entrypoint "openssl req -x509 -nodes -newkey rsa:4096 -days 1 \
        -keyout '${le_path}/privkey.pem' \
        -out '${le_path}/fullchain.pem' \
        -subj '/CN=localhost'" certbot

    # Ensure nginx is running
    log_info "Starting nginx..."
    $cmd up -d nginx

    # Remove dummy cert
    log_info "Removing temporary certificate..."
    $cmd run --rm --entrypoint "rm -rf /etc/letsencrypt/live/${domain} && \
        rm -rf /etc/letsencrypt/archive/${domain} && \
        rm -rf /etc/letsencrypt/renewal/${domain}.conf" certbot

    # Request real certificate
    log_info "Requesting certificate from Let's Encrypt..."
    local email_arg=""
    if [[ -n "$email" ]]; then
        email_arg="--email $email"
    else
        email_arg="--register-unsafely-without-email"
    fi

    $cmd run --rm --entrypoint "certbot certonly --webroot -w /var/www/certbot \
        $email_arg \
        -d $domain -d www.$domain \
        --rsa-key-size 4096 \
        --agree-tos \
        --force-renewal" certbot

    # Reload nginx
    log_info "Reloading nginx..."
    docker exec gateway_nginx nginx -s reload 2>/dev/null

    log_success "Let's Encrypt certificate installed for $domain!"
    log_info "Auto-renewal handled by certbot container (every 12h)."
}

cmd_ssl_switch() {
    local domain="$1"
    local new_mode="$2"

    if [[ ! -f "${DOCKWEB_ROOT}/sites/${domain}/.dockweb.conf" ]]; then
        log_error "Site '$domain' not found."
        return 1
    fi

    if [[ "$new_mode" != "cloudflare" && "$new_mode" != "letsencrypt" ]]; then
        log_error "SSL mode must be 'cloudflare' or 'letsencrypt'."
        return 1
    fi

    local SSL_MODE="" PHP_CONTAINER="" DB_NAME="" DB_USER="" DB_PASS="" DOMAIN=""
    get_site_conf "$domain"

    if [[ "$SSL_MODE" == "$new_mode" ]]; then
        log_info "Site '$domain' is already using $new_mode."
        return 0
    fi

    log_info "Switching $domain: $SSL_MODE -> $new_mode"

    # Update config
    sed -i "s/^SSL_MODE=.*/SSL_MODE=${new_mode}/" "${DOCKWEB_ROOT}/sites/${domain}/.dockweb.conf"

    # Regenerate nginx config
    generate_nginx_conf "$domain" "$new_mode" "$PHP_CONTAINER"

    # Reload nginx if running
    if docker exec gateway_nginx nginx -t 2>/dev/null; then
        docker exec gateway_nginx nginx -s reload 2>/dev/null
        log_success "Nginx reloaded with $new_mode config."
    else
        log_warn "Nginx config test failed. Check certificate files exist."
        log_info "For cloudflare: run 'dockweb ssl install-cf $domain'"
        log_info "For letsencrypt: run 'dockweb ssl install-le $domain'"
    fi

    log_success "SSL mode changed to '$new_mode' for $domain."
}

update_cloudflare_ips() {
    header "Updating Cloudflare IP Ranges"

    local cf_conf="${DOCKWEB_ROOT}/nginx/cloudflare-ips.conf"
    local tmp="${cf_conf}.tmp"

    cat > "$tmp" <<'HEADER'
# Cloudflare IP ranges for real_ip restoration
# Auto-updated by dockweb
# Source: https://www.cloudflare.com/ips/

HEADER

    log_info "Fetching IPv4 ranges..."
    echo "# IPv4" >> "$tmp"
    if curl -s https://www.cloudflare.com/ips-v4 | while read -r ip; do
        [[ -n "$ip" ]] && echo "set_real_ip_from ${ip};" >> "$tmp"
    done; then
        log_success "IPv4 ranges updated."
    else
        log_error "Failed to fetch IPv4 ranges."
        rm -f "$tmp"
        return 1
    fi

    echo "" >> "$tmp"
    log_info "Fetching IPv6 ranges..."
    echo "# IPv6" >> "$tmp"
    if curl -s https://www.cloudflare.com/ips-v6 | while read -r ip; do
        [[ -n "$ip" ]] && echo "set_real_ip_from ${ip};" >> "$tmp"
    done; then
        log_success "IPv6 ranges updated."
    else
        log_error "Failed to fetch IPv6 ranges."
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$cf_conf"
    log_success "Cloudflare IPs updated: nginx/cloudflare-ips.conf"

    # Reload nginx if running
    if docker exec gateway_nginx nginx -t 2>/dev/null; then
        docker exec gateway_nginx nginx -s reload 2>/dev/null
        log_success "Nginx reloaded."
    fi
}
