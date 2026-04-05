#!/bin/bash
# dockweb - SSL management

cmd_ssl_menu() {
    local domain="${1:-}"
    local new_mode="${2:-}"

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
            elif [[ "$SSL_MODE" == "letsencrypt" ]]; then
                [[ -f "${DOCKWEB_ROOT}/certbot/conf/live/${d}/fullchain.pem" ]] && cert_status="installed"
            elif [[ "$SSL_MODE" == "dev-ssl" ]]; then
                [[ -f "${DOCKWEB_ROOT}/local-certs/${d}/cert.pem" ]] && cert_status="installed" || cert_status="missing"
            elif [[ "$SSL_MODE" == "local" || "$SSL_MODE" == "dev" ]]; then
                cert_status="n/a (http)"
            fi
            printf "    %d) %-30s %-12s [%s]\n" "$i" "$d" "$SSL_MODE" "$cert_status"
        done <<< "$sites"

        echo ""
        echo "  Actions:"
        echo "    a) Install Cloudflare Origin Cert"
        echo "    b) Install Let's Encrypt Cert"
        echo "    c) Install Local Dev Cert (mkcert)"
        echo "    d) Switch SSL mode for a site"
        echo "    e) Update Cloudflare IP ranges"
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
                cmd_ssl_install_local "${domains_arr[$((num-1))]}"
                ;;
            d)
                echo -ne "  Site number: "
                read -r num
                [[ -z "${domains_arr[$((num-1))]}" ]] && { log_error "Invalid."; return 1; }
                local d="${domains_arr[$((num-1))]}"
                echo "  New SSL mode:"
                echo "    1) cloudflare"
                echo "    2) letsencrypt"
                echo "    3) local   (HTTP only, real domain)"
                echo "    4) dev     (HTTP only, .local domain)"
                echo "    5) dev-ssl (HTTPS, .local domain, mkcert)"
                echo -ne "  Choose: "
                read -r mode_choice
                case "$mode_choice" in
                    1) cmd_ssl_switch "$d" "cloudflare" ;;
                    2) cmd_ssl_switch "$d" "letsencrypt" ;;
                    3) cmd_ssl_switch "$d" "local" ;;
                    4) cmd_ssl_switch "$d" "dev" ;;
                    5) cmd_ssl_switch "$d" "dev-ssl" ;;
                    *) log_error "Invalid." ;;
                esac
                ;;
            e) update_cloudflare_ips ;;
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
        elif [[ "$SSL_MODE" == "letsencrypt" ]]; then
            [[ -f "${DOCKWEB_ROOT}/certbot/conf/live/${domain}/fullchain.pem" ]] && cert_status="installed"
        elif [[ "$SSL_MODE" == "dev-ssl" ]]; then
            [[ -f "${DOCKWEB_ROOT}/local-certs/${domain}/cert.pem" ]] && cert_status="installed" || cert_status="missing"
        elif [[ "$SSL_MODE" == "local" || "$SSL_MODE" == "dev" ]]; then
            cert_status="n/a (http)"
        fi
        echo "  Cert:     $cert_status"
        if [[ "$SSL_MODE" == "dev" ]]; then
            echo "  Local:    http://$(get_local_domain "$domain")"
        elif [[ "$SSL_MODE" == "dev-ssl" ]]; then
            echo "  Local:    https://$(get_local_domain "$domain")"
        fi
    fi
}

_get_base_domain() {
    # example.com from sub.example.com, or example.com from example.com
    echo "$1" | awk -F. '{print $(NF-1)"."$NF}'
}

_extract_json_value() {
    # Lightweight JSON value extraction without jq dependency
    # Usage: _extract_json_value "key" <<< "$json"
    local key="$1"
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed "s/\"${key}\"[[:space:]]*:[[:space:]]*\"//" | sed 's/"$//'
}

_extract_json_bool() {
    local key="$1"
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*[a-z]*" | head -1 | sed "s/\"${key}\"[[:space:]]*:[[:space:]]*//"
}

cloudflare_api_install_cert() {
    local domain="$1"
    local cert_dir="$2"

    load_env

    # Origin CA Key is required for the certificates API (different from regular API token)
    local origin_ca_key="${CLOUDFLARE_ORIGIN_CA_KEY:-${CLOUDFLARE_API_TOKEN:-}}"
    if [[ -z "$origin_ca_key" ]]; then
        log_error "CLOUDFLARE_ORIGIN_CA_KEY not set in .env"
        log_info "Get it from: https://dash.cloudflare.com/profile/api-tokens > Origin CA Key"
        log_info "(This is different from a regular API token)"
        return 1
    fi

    local base_domain
    base_domain=$(_get_base_domain "$domain")

    # Auto-detect zone ID if not set
    local zone_id="${CLOUDFLARE_ZONE_ID:-}"
    if [[ -z "$zone_id" ]]; then
        log_info "Zone ID not set, auto-detecting for ${base_domain}..."
        local zone_response
        zone_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${base_domain}" \
            -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
            -H "Content-Type: application/json")

        local zone_success
        zone_success=$(echo "$zone_response" | _extract_json_bool "success")
        if [[ "$zone_success" != "true" ]]; then
            log_error "Failed to query Cloudflare zones API."
            log_info "You may need to set CLOUDFLARE_ZONE_ID manually in .env"
            return 1
        fi

        zone_id=$(echo "$zone_response" | grep -o '"id":"[^"]*"' | head -1 | sed 's/"id":"//;s/"//')
        if [[ -z "$zone_id" ]]; then
            log_error "Could not find zone for ${base_domain}."
            log_info "Set CLOUDFLARE_ZONE_ID manually in .env"
            return 1
        fi
        log_success "Found zone ID: ${zone_id}"
    fi

    # Generate private key and CSR locally
    log_info "Generating private key and CSR..."
    local key_file="${cert_dir}/origin.key"
    local csr_file="${cert_dir}/origin.csr"

    openssl genrsa -out "$key_file" 2048 2>/dev/null
    openssl req -new -key "$key_file" -out "$csr_file" \
        -subj "/CN=${domain}" 2>/dev/null

    local csr_content
    csr_content=$(cat "$csr_file")

    # Escape CSR for JSON (newlines to \n)
    local csr_escaped
    csr_escaped=$(echo "$csr_content" | awk '{printf "%s\\n", $0}')

    # Request origin certificate from Cloudflare (15-year validity)
    # The /certificates endpoint requires the Origin CA Key via X-Auth-User-Service-Key,
    # NOT a regular API token with Bearer auth.
    log_info "Requesting origin certificate from Cloudflare..."
    local api_response
    api_response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/certificates" \
        -H "X-Auth-User-Service-Key: ${origin_ca_key}" \
        -H "Content-Type: application/json" \
        --data "{
            \"hostnames\": [\"${domain}\", \"*.${domain}\"],
            \"requested_validity\": 5475,
            \"request_type\": \"origin-rsa\",
            \"csr\": \"${csr_escaped}\"
        }")

    # Check success
    local api_success
    api_success=$(echo "$api_response" | _extract_json_bool "success")
    if [[ "$api_success" != "true" ]]; then
        local error_msg
        error_msg=$(echo "$api_response" | grep -o '"message":"[^"]*"' | head -1 | sed 's/"message":"//;s/"//')
        log_error "Cloudflare API error: ${error_msg:-unknown error}"
        log_info "Tip: Origin CA certificates require the Origin CA Key, not a regular API token."
        log_info "Find it at: https://dash.cloudflare.com/profile/api-tokens > Origin CA Key"
        rm -f "$csr_file"
        return 1
    fi

    # Extract certificate from response
    local cert_content
    cert_content=$(echo "$api_response" | grep -o '"certificate":"[^"]*"' | head -1 | sed 's/"certificate":"//;s/"$//')

    if [[ -z "$cert_content" ]]; then
        log_error "Could not extract certificate from API response."
        rm -f "$csr_file"
        return 1
    fi

    # Convert escaped newlines back to real newlines
    echo -e "$cert_content" > "${cert_dir}/origin.pem"

    # Clean up CSR
    rm -f "$csr_file"

    chmod 644 "${cert_dir}/origin.pem"
    chmod 600 "${cert_dir}/origin.key"

    log_success "Origin certificate generated and installed!"
    log_info "  Cert: cloudflare-certs/${domain}/origin.pem"
    log_info "  Key:  cloudflare-certs/${domain}/origin.key"
    log_info "  Valid for: 15 years"
}

cmd_ssl_install_cf() {
    local domain="${1:-}"
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

    load_env
    local has_api="false"
    [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] && has_api="true"

    echo ""
    if [[ "$has_api" == "true" ]]; then
        echo "  How to provide the certificate:"
        echo "    1) Auto-generate via Cloudflare API (recommended)"
        echo "    2) Paste certificate content"
        echo "    3) Provide file paths"
        echo ""
        echo -ne "  Choose [1-3]: "
    else
        echo -e "  ${DIM}Tip: Set CLOUDFLARE_API_TOKEN in .env to auto-generate certs${NC}"
        echo ""
        echo "  Go to Cloudflare Dashboard > SSL/TLS > Origin Server"
        echo "  Click 'Create Certificate' and download both files."
        echo ""
        echo "  How to provide the certificate:"
        echo "    1) Paste certificate content"
        echo "    2) Provide file paths"
        echo ""
        echo -ne "  Choose [1-2]: "
    fi
    read -r method

    # Normalize: if no API token, shift choices so 1->paste, 2->file
    if [[ "$has_api" == "false" ]]; then
        method=$((method + 1))
    fi

    case "$method" in
        1)
            cloudflare_api_install_cert "$domain" "$cert_dir" || return 1
            ;;
        2)
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

            chmod 644 "${cert_dir}/origin.pem"
            chmod 600 "${cert_dir}/origin.key"
            log_success "Certificate installed at: cloudflare-certs/${domain}/"
            ;;
        3)
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

            chmod 644 "${cert_dir}/origin.pem"
            chmod 600 "${cert_dir}/origin.key"
            log_success "Certificate installed at: cloudflare-certs/${domain}/"
            ;;
        *)
            log_error "Invalid choice."
            return 1
            ;;
    esac

    # Reload nginx if running
    if docker exec gateway_nginx nginx -t 2>/dev/null; then
        docker exec gateway_nginx nginx -s reload 2>/dev/null
        log_success "Nginx reloaded."
    fi
}

cmd_ssl_install_le() {
    local domain="${1:-}"
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

cmd_ssl_install_local() {
    local domain="${1:-}"
    if [[ -z "$domain" ]]; then
        echo -ne "  Domain: "
        read -r domain
    fi

    if [[ ! -f "${DOCKWEB_ROOT}/sites/${domain}/.dockweb.conf" ]]; then
        log_error "Site '$domain' not found."
        return 1
    fi

    # Check mkcert is installed
    if ! command -v mkcert &>/dev/null; then
        log_error "mkcert is not installed."
        echo ""
        echo "  Install mkcert:"
        echo "    sudo apt install mkcert    # Debian/Ubuntu"
        echo "    brew install mkcert        # macOS"
        echo ""
        echo "  Then run: mkcert -install"
        return 1
    fi

    header "Install Local Dev Certificate (mkcert): $domain"

    local cert_dir="${DOCKWEB_ROOT}/local-certs/${domain}"
    mkdir -p "$cert_dir"

    local local_domain
    local_domain=$(get_local_domain "$domain")

    log_info "Generating certificate for ${local_domain}..."
    mkcert \
        -cert-file "${cert_dir}/cert.pem" \
        -key-file "${cert_dir}/key.pem" \
        "$local_domain" "*.${local_domain}" localhost 127.0.0.1 ::1

    if [[ $? -ne 0 ]]; then
        log_error "mkcert failed. Have you run 'mkcert -install' to set up the local CA?"
        return 1
    fi

    chmod 644 "${cert_dir}/cert.pem"
    chmod 600 "${cert_dir}/key.pem"

    log_success "Certificate installed at: local-certs/${domain}/"
    log_info "Cert: ${cert_dir}/cert.pem"
    log_info "Key:  ${cert_dir}/key.pem"

    # Reload nginx if running
    if docker exec gateway_nginx nginx -t 2>/dev/null; then
        docker exec gateway_nginx nginx -s reload 2>/dev/null
        log_success "Nginx reloaded."
    fi
}

cmd_ssl_switch() {
    local domain="${1:-}"
    local new_mode="${2:-}"

    if [[ ! -f "${DOCKWEB_ROOT}/sites/${domain}/.dockweb.conf" ]]; then
        log_error "Site '$domain' not found."
        return 1
    fi

    if [[ "$new_mode" != "cloudflare" && "$new_mode" != "letsencrypt" && "$new_mode" != "local" && "$new_mode" != "dev" && "$new_mode" != "dev-ssl" ]]; then
        log_error "SSL mode must be 'cloudflare', 'letsencrypt', 'local', 'dev', or 'dev-ssl'."
        return 1
    fi

    local SSL_MODE="" PHP_CONTAINER="" DB_NAME="" DB_USER="" DB_PASS="" DOMAIN=""
    get_site_conf "$domain"

    if [[ "$SSL_MODE" == "$new_mode" ]]; then
        log_info "Site '$domain' is already using $new_mode."
        return 0
    fi

    log_info "Switching $domain: $SSL_MODE -> $new_mode"

    # For dev-ssl, ensure mkcert certs exist
    if [[ "$new_mode" == "dev-ssl" ]]; then
        if [[ ! -f "${DOCKWEB_ROOT}/local-certs/${domain}/cert.pem" ]]; then
            log_info "No local certs found, generating with mkcert..."
            cmd_ssl_install_local "$domain"
        fi
    fi

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

    if [[ "$new_mode" == "dev" ]]; then
        local local_domain
        local_domain=$(get_local_domain "$domain")
        echo ""
        log_info "Add to /etc/hosts: 127.0.0.1  ${local_domain} www.${local_domain}"
        log_info "Visit: http://${local_domain}"
    elif [[ "$new_mode" == "dev-ssl" ]]; then
        local local_domain
        local_domain=$(get_local_domain "$domain")
        echo ""
        log_info "Add to /etc/hosts: 127.0.0.1  ${local_domain} www.${local_domain}"
        log_info "Visit: https://${local_domain}"
    fi
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
