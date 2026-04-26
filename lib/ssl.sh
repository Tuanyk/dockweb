#!/bin/bash
# dockweb - SSL management

_reload_or_start_nginx() {
    local cmd
    cmd="$(docker_compose_cmd)"

    if docker exec gateway_nginx nginx -t 2>/dev/null; then
        docker exec gateway_nginx nginx -s reload 2>/dev/null || true
        log_success "Nginx reloaded."
        return 0
    fi

    log_info "Starting nginx..."
    $cmd up -d nginx >/dev/null 2>&1 || true

    if docker exec gateway_nginx nginx -t 2>/dev/null; then
        docker exec gateway_nginx nginx -s reload 2>/dev/null || true
        log_success "Nginx started and reloaded."
        return 0
    fi

    log_warn "Nginx config test failed. Check certificate files and logs."
    return 1
}

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
            if [[ "$SSL_MODE" == "cloudflare" || "$SSL_MODE" == "letsencrypt" || "$SSL_MODE" == "dev-ssl" ]]; then
                ssl_mode_cert_ready "$d" "$SSL_MODE" && cert_status="installed"
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
        echo "    f) Manage Cloudflare accounts"
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
            f) cmd_cloudflare_menu ;;
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
        if [[ "$SSL_MODE" == "cloudflare" || "$SSL_MODE" == "letsencrypt" || "$SSL_MODE" == "dev-ssl" ]]; then
            ssl_mode_cert_ready "$domain" "$SSL_MODE" && cert_status="installed"
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
    # example.com from sub.example.com, or example.com from example.com.
    # NOTE: naive — assumes a single-label TLD. Wrong for multi-label
    # public suffixes (io.vn, co.uk, com.au, …). Use _resolve_cf_zone
    # for Cloudflare lookups; this helper is kept for non-API callers.
    echo "$1" | awk -F. '{print $(NF-1)"."$NF}'
}

# Walk candidate parent domains longest-first and return the first one that
# Cloudflare recognizes as a zone. Echoes "<zone_id> <zone_name>" on stdout.
# Handles multi-label public suffixes (foo.io.vn, site.co.uk, …) without
# needing a Public Suffix List — we just ask Cloudflare.
_resolve_cf_zone() {
    local domain="$1"
    local token="$2"
    local candidate="$domain" response success zone_id
    while [[ "$candidate" == *.*.* || "$candidate" == *.* ]]; do
        response=$(curl -s -X GET \
            "https://api.cloudflare.com/client/v4/zones?name=${candidate}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json")
        success=$(echo "$response" | _extract_json_bool "success")
        if [[ "$success" == "true" ]]; then
            zone_id=$(echo "$response" \
                | grep -o '"id":"[^"]*"' | head -1 \
                | sed 's/"id":"//;s/"//')
            if [[ -n "$zone_id" ]]; then
                echo "${zone_id} ${candidate}"
                return 0
            fi
        fi
        # Strip the leftmost label and try the parent. Stop when only the
        # TLD (one label) would remain.
        [[ "$candidate" != *.*.* ]] && break
        candidate="${candidate#*.}"
    done
    return 1
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

# Echo configured Cloudflare account names, one per line. Falls back to a
# synthetic "default" account backed by the unsuffixed CLOUDFLARE_* vars
# when CLOUDFLARE_ACCOUNTS is empty.
_cf_account_list() {
    local raw="${CLOUDFLARE_ACCOUNTS:-}"
    if [[ -n "$raw" ]]; then
        echo "$raw" | tr ',\n' '  ' | xargs -n1 | awk 'NF'
        return 0
    fi
    if [[ -n "${CLOUDFLARE_API_TOKEN:-}" || -n "${CLOUDFLARE_ORIGIN_CA_KEY:-}" ]]; then
        echo "default"
    fi
}

# $1 = account name, $2 = API_TOKEN | ORIGIN_CA_KEY
# Returns the per-account env var, with legacy fallback for "default".
_cf_account_var() {
    local account="$1" what="$2"
    local suffixed="CLOUDFLARE_${what}_${account}"
    local v="${!suffixed:-}"
    if [[ -z "$v" && "$account" == "default" ]]; then
        local legacy="CLOUDFLARE_${what}"
        v="${!legacy:-}"
    fi
    echo "$v"
}

# Walk configured accounts and echo "<account> <zone_id> <zone_name>" for
# the first one whose zones cover $domain.
_resolve_cf_account() {
    local domain="$1"
    local account token resolved
    while IFS= read -r account; do
        [[ -z "$account" ]] && continue
        token=$(_cf_account_var "$account" "API_TOKEN")
        if [[ -z "$token" ]]; then
            log_warn "Cloudflare account '${account}' has no API token (CLOUDFLARE_API_TOKEN_${account}); skipping."
            continue
        fi
        if resolved=$(_resolve_cf_zone "$domain" "$token"); then
            echo "${account} ${resolved}"
            return 0
        fi
    done < <(_cf_account_list)
    return 1
}

# Persist the matched Cloudflare account name into a site's .dockweb.conf
# so later operations know which credentials produced the cert.
_persist_cf_account() {
    local domain="$1" account="$2"
    local conf="${DOCKWEB_ROOT}/sites/${domain}/.dockweb.conf"
    [[ -f "$conf" ]] || return 0
    if grep -q '^CLOUDFLARE_ACCOUNT=' "$conf"; then
        sed -i "s|^CLOUDFLARE_ACCOUNT=.*|CLOUDFLARE_ACCOUNT=${account}|" "$conf"
    else
        echo "CLOUDFLARE_ACCOUNT=${account}" >> "$conf"
    fi
}

cloudflare_api_install_cert() {
    local domain="$1"
    local cert_dir="$2"

    load_env

    if [[ -z "$(_cf_account_list)" ]]; then
        log_error "No Cloudflare accounts configured in .env."
        log_info "Set CLOUDFLARE_ACCOUNTS (e.g. 'personal,work') plus CLOUDFLARE_API_TOKEN_<name>"
        log_info "and CLOUDFLARE_ORIGIN_CA_KEY_<name> for each. See .env.example."
        return 1
    fi

    log_info "Checking Cloudflare accounts for ${domain}..."
    local matched account rest zone_id zone_name
    if ! matched=$(_resolve_cf_account "$domain"); then
        log_error "No configured Cloudflare account owns a zone covering ${domain}."
        log_info "Accounts tried: $(_cf_account_list | paste -sd',' -)"
        return 1
    fi
    account="${matched%% *}"
    rest="${matched#* }"
    zone_id="${rest%% *}"
    zone_name="${rest#* }"
    log_success "Matched account '${account}' (zone ${zone_name} / ${zone_id})"

    # Origin CA Key is required for the certificates API (different from the API token).
    local origin_ca_key
    origin_ca_key=$(_cf_account_var "$account" "ORIGIN_CA_KEY")
    if [[ -z "$origin_ca_key" ]]; then
        log_error "CLOUDFLARE_ORIGIN_CA_KEY_${account} not set in .env"
        log_info "Get it from: https://dash.cloudflare.com/profile/api-tokens > Origin CA Key"
        log_info "(This is different from a regular API token)"
        return 1
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
    log_info "  Cert:    cloudflare-certs/${domain}/origin.pem"
    log_info "  Key:     cloudflare-certs/${domain}/origin.key"
    log_info "  Account: ${account}"
    log_info "  Valid for: 15 years"

    _persist_cf_account "$domain" "$account"
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
    [[ -n "$(_cf_account_list)" ]] && has_api="true"

    echo ""
    if [[ "$has_api" == "true" ]]; then
        echo "  How to provide the certificate:"
        echo "    1) Auto-generate via Cloudflare API (recommended)"
        echo "    2) Paste certificate content"
        echo "    3) Provide file paths"
        echo ""
        echo -ne "  Choose [1-3]: "
    else
        echo -e "  ${DIM}Tip: Set CLOUDFLARE_ACCOUNTS + CLOUDFLARE_API_TOKEN_<name> in .env to auto-generate certs${NC}"
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

    local SSL_MODE="" PHP_CONTAINER="" DB_NAME="" DB_USER="" DB_PASS="" \
          DOMAIN="" CACHE_ENABLED=""
    if get_site_conf "$domain" && [[ "$SSL_MODE" == "cloudflare" ]]; then
        generate_nginx_conf "$DOMAIN" "$SSL_MODE" "$PHP_CONTAINER" "${CACHE_ENABLED:-true}"
    fi

    if docker ps --format '{{.Names}}' | grep -q '^gateway_nginx$' || \
       docker ps -a --format '{{.Names}}' | grep -q '^gateway_nginx$'; then
        _reload_or_start_nginx
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

    local SSL_MODE="" PHP_CONTAINER="" DB_NAME="" DB_USER="" DB_PASS="" \
          DOMAIN="" CACHE_ENABLED=""
    if get_site_conf "$domain" && [[ "$SSL_MODE" == "letsencrypt" ]]; then
        generate_nginx_conf "$DOMAIN" "$SSL_MODE" "$PHP_CONTAINER" "${CACHE_ENABLED:-true}"
    fi

    # Ensure nginx is running with the temporary HTTP-only config so the
    # ACME challenge can be served before the real certificate exists.
    log_info "Starting nginx..."
    $cmd up -d nginx

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

    if get_site_conf "$domain" && [[ "$SSL_MODE" == "letsencrypt" ]]; then
        generate_nginx_conf "$DOMAIN" "$SSL_MODE" "$PHP_CONTAINER" "${CACHE_ENABLED:-true}"
    fi

    log_info "Reloading nginx..."
    _reload_or_start_nginx

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

    local SSL_MODE="" PHP_CONTAINER="" DB_NAME="" DB_USER="" DB_PASS="" \
          DOMAIN="" CACHE_ENABLED=""
    if get_site_conf "$domain" && [[ "$SSL_MODE" == "dev-ssl" ]]; then
        generate_nginx_conf "$DOMAIN" "$SSL_MODE" "$PHP_CONTAINER" "${CACHE_ENABLED:-true}"
    fi

    if docker ps --format '{{.Names}}' | grep -q '^gateway_nginx$' || \
       docker ps -a --format '{{.Names}}' | grep -q '^gateway_nginx$'; then
        _reload_or_start_nginx
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

    # Regenerate nginx config — preserve the site's FastCGI cache preference.
    generate_nginx_conf "$domain" "$new_mode" "$PHP_CONTAINER" "${CACHE_ENABLED:-true}"

    if [[ "$new_mode" == "cloudflare" || "$new_mode" == "letsencrypt" ]] && \
       ! ssl_mode_cert_ready "$domain" "$new_mode"; then
        log_warn "Certificate not installed yet. Using temporary HTTP-only config for ${domain}."
        if [[ "$new_mode" == "cloudflare" ]]; then
            log_info "Run 'dockweb ssl install-cf ${domain}' to enable HTTPS."
        else
            log_info "Run 'dockweb ssl install-le ${domain}' to enable HTTPS."
        fi
    fi

    # Reload nginx if running
    if docker exec gateway_nginx nginx -t 2>/dev/null; then
        docker exec gateway_nginx nginx -s reload 2>/dev/null
        log_success "Nginx reloaded with $new_mode config."
    else
        _reload_or_start_nginx || {
            log_warn "Nginx config test failed. Check certificate files exist."
            log_info "For cloudflare: run 'dockweb ssl install-cf $domain'"
            log_info "For letsencrypt: run 'dockweb ssl install-le $domain'"
        }
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

# ============================================================
# Cloudflare account management (add/list/remove/verify)
# ============================================================

# Verify an API token is active and has zone access. The /user/tokens/verify
# endpoint returns success+status=active for any working token; we additionally
# probe /zones to make sure the token has at least Zone:Read.
_cf_verify_token() {
    local token="$1"
    local resp success
    # /zones?per_page=1 alone proves the token is valid, active, and has
    # Zone:Read. We deliberately don't gate on /user/tokens/verify first —
    # that endpoint only accepts user-profile tokens and rejects valid
    # account-owned tokens with code 1000 "Invalid API Token".
    resp=$(curl -sS --max-time 10 \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/zones?per_page=1" 2>/dev/null) || return 1
    success=$(echo "$resp" | _extract_json_bool "success")
    [[ "$success" == "true" ]]
}

# Verify an Origin CA Key by listing existing certificates (read-only).
# Cloudflare returns success:false on bad keys, success:true on valid ones
# even if the result list is empty.
_cf_verify_origin_ca_key() {
    local key="$1"
    local resp success
    resp=$(curl -sS --max-time 10 \
        -H "X-Auth-User-Service-Key: ${key}" \
        -H "Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/certificates" 2>/dev/null) || return 1
    success=$(echo "$resp" | _extract_json_bool "success")
    [[ "$success" == "true" ]]
}

# Read KEY=... from .env. Strips outer matching quotes and a trailing CR
# so values written as KEY="abc" or saved with CRLF endings parse the same
# way `source .env` would see them.
_cf_env_get() {
    local key="$1"
    local env_file="${DOCKWEB_ROOT}/.env"
    [[ -f "$env_file" ]] || { echo ""; return 0; }
    awk -v key="$key" '
        index($0, key "=") == 1 {
            val = substr($0, length(key) + 2)
            sub(/\r$/, "", val)
            first = substr(val, 1, 1)
            last  = substr(val, length(val), 1)
            if ((first == "\"" && last == "\"") || (first == "\047" && last == "\047")) {
                val = substr(val, 2, length(val) - 2)
            }
            print val
            exit
        }
    ' "$env_file"
}

# Set or replace KEY=value in .env, preserving line position.
# Appends at end of file when KEY isn't present yet.
_cf_env_set() {
    local key="$1"
    local value="$2"
    local env_file="${DOCKWEB_ROOT}/.env"

    if [[ ! -f "$env_file" ]]; then
        log_error ".env file not found at ${env_file}. Run 'cp .env.example .env' first."
        return 1
    fi

    if grep -q "^${key}=" "$env_file"; then
        local tmp
        tmp=$(mktemp)
        # ENVIRON avoids awk's -v backslash-escape interpretation, so token
        # values containing literal backslashes survive intact.
        K="$key" V="$value" awk '
            BEGIN { set = 0; k = ENVIRON["K"]; v = ENVIRON["V"] }
            !set && index($0, k "=") == 1 { print k "=" v; set = 1; next }
            { print }
        ' "$env_file" > "$tmp" && mv "$tmp" "$env_file"
    else
        echo "${key}=${value}" >> "$env_file"
    fi
}

# Delete a KEY=... line entirely. No-op if missing.
_cf_env_unset() {
    local key="$1"
    local env_file="${DOCKWEB_ROOT}/.env"
    [[ -f "$env_file" ]] || return 0
    grep -q "^${key}=" "$env_file" || return 0
    local tmp
    tmp=$(mktemp)
    grep -v "^${key}=" "$env_file" > "$tmp" || true
    mv "$tmp" "$env_file"
}

# True if NAME is in CLOUDFLARE_ACCOUNTS (whitespace-tolerant).
_cf_env_accounts_has() {
    local name="$1"
    local current
    current=$(_cf_env_get "CLOUDFLARE_ACCOUNTS")
    [[ -z "$current" ]] && return 1
    local -a accounts=()
    IFS=',' read -ra accounts <<< "$current"
    local a
    for a in "${accounts[@]}"; do
        a="${a// /}"
        [[ "$a" == "$name" ]] && return 0
    done
    return 1
}

# Append NAME to CLOUDFLARE_ACCOUNTS (idempotent, normalizes whitespace).
_cf_env_accounts_add() {
    local name="$1"
    _cf_env_accounts_has "$name" && return 0
    local current
    current=$(_cf_env_get "CLOUDFLARE_ACCOUNTS")
    local -a kept=()
    if [[ -n "$current" ]]; then
        local -a tokens=()
        IFS=',' read -ra tokens <<< "$current"
        local t
        for t in "${tokens[@]}"; do
            t="${t// /}"
            [[ -n "$t" ]] && kept+=("$t")
        done
    fi
    kept+=("$name")
    local joined
    joined=$(IFS=','; echo "${kept[*]}")
    _cf_env_set "CLOUDFLARE_ACCOUNTS" "$joined"
}

# Remove NAME from CLOUDFLARE_ACCOUNTS. Leaves the var set to "" if list empties.
_cf_env_accounts_remove() {
    local name="$1"
    local current
    current=$(_cf_env_get "CLOUDFLARE_ACCOUNTS")
    [[ -z "$current" ]] && return 0
    local -a tokens=() kept=()
    IFS=',' read -ra tokens <<< "$current"
    local t
    for t in "${tokens[@]}"; do
        t="${t// /}"
        [[ -z "$t" ]] && continue
        [[ "$t" == "$name" ]] && continue
        kept+=("$t")
    done
    local joined=""
    [[ ${#kept[@]} -gt 0 ]] && joined=$(IFS=','; echo "${kept[*]}")
    _cf_env_set "CLOUDFLARE_ACCOUNTS" "$joined"
}

# Display a credential safely: show first 6 chars + last 2, mask the rest.
_cf_mask() {
    local v="$1"
    if [[ ${#v} -le 8 ]]; then
        echo "***"
    else
        echo "${v:0:6}…${v: -2}"
    fi
}

# Move legacy CLOUDFLARE_API_TOKEN/CLOUDFLARE_ORIGIN_CA_KEY into a named
# "default" account before we add a second account — otherwise the legacy
# fallback in _cf_account_list (which only triggers on empty CLOUDFLARE_ACCOUNTS)
# would silently orphan the existing creds.
#
# Returns: 0 = migrated, 1 = nothing to migrate, 2 = legacy creds invalid.
_cf_migrate_legacy_if_needed() {
    local acc legacy_token legacy_key
    acc=$(_cf_env_get "CLOUDFLARE_ACCOUNTS")
    legacy_token=$(_cf_env_get "CLOUDFLARE_API_TOKEN")
    legacy_key=$(_cf_env_get "CLOUDFLARE_ORIGIN_CA_KEY")

    if [[ -n "$acc" ]]; then return 1; fi
    if [[ -z "$legacy_token" && -z "$legacy_key" ]]; then return 1; fi

    log_info "Found legacy single-account Cloudflare config in .env."
    log_info "Migrating to named account 'default' so it isn't orphaned when you add new accounts."

    if [[ -n "$legacy_token" ]] && ! _cf_verify_token "$legacy_token"; then
        log_error "Legacy CLOUDFLARE_API_TOKEN failed verification (invalid or expired)."
        log_info "Either fix or clear CLOUDFLARE_API_TOKEN in .env, then retry."
        return 2
    fi
    if [[ -n "$legacy_key" ]] && ! _cf_verify_origin_ca_key "$legacy_key"; then
        log_error "Legacy CLOUDFLARE_ORIGIN_CA_KEY failed verification."
        log_info "Either fix or clear CLOUDFLARE_ORIGIN_CA_KEY in .env, then retry."
        return 2
    fi

    [[ -n "$legacy_token" ]] && _cf_env_set "CLOUDFLARE_API_TOKEN_default" "$legacy_token"
    [[ -n "$legacy_key" ]]   && _cf_env_set "CLOUDFLARE_ORIGIN_CA_KEY_default" "$legacy_key"
    _cf_env_accounts_add "default"
    _cf_env_set "CLOUDFLARE_API_TOKEN" ""
    _cf_env_set "CLOUDFLARE_ORIGIN_CA_KEY" ""

    log_success "Migrated legacy config to account 'default'."
    return 0
}

# Interactive submenu (entered from the SSL menu).
cmd_cloudflare_menu() {
    while true; do
        header "Manage Cloudflare accounts"
        echo "    1) List accounts"
        echo "    2) Add account"
        echo "    3) Remove account"
        echo "    4) Verify accounts"
        echo "    0) Back"
        echo ""
        echo -ne "  Choose: "
        read -r choice
        case "$choice" in
            1) cmd_cloudflare_list ;;
            2) cmd_cloudflare_add ;;
            3)
                echo -ne "  Account name: "
                read -r rm_name
                [[ -z "$rm_name" ]] && { log_error "Name required."; continue; }
                cmd_cloudflare_remove "$rm_name"
                ;;
            4) cmd_cloudflare_verify ;;
            0) return 0 ;;
            *) log_error "Invalid choice." ;;
        esac
        echo ""
        echo -ne "  ${DIM}Press Enter to continue...${NC}"
        read -r
    done
}

# Top-level dispatcher for `dockweb cloudflare ...`.
cmd_cloudflare() {
    local sub="${1:-}"
    [[ $# -gt 0 ]] && shift
    case "$sub" in
        add)         cmd_cloudflare_add "$@" ;;
        list|ls)     cmd_cloudflare_list ;;
        remove|rm)   cmd_cloudflare_remove "${1:-}" ;;
        verify)      cmd_cloudflare_verify "${1:-}" ;;
        ""|help|--help|-h)
            echo "  Usage: dockweb cloudflare {add|list|remove|verify} [args]"
            echo ""
            echo "    add [--name N --token T --origin-ca-key K]"
            echo "                          Add a Cloudflare account (interactive if flags omitted)"
            echo "    list                  List configured accounts (credentials masked)"
            echo "    remove <name>         Remove an account from .env"
            echo "    verify [<name>]       Verify credentials for one or all accounts"
            ;;
        *)
            log_error "Unknown subcommand: cloudflare ${sub}"
            echo "  Run 'dockweb cloudflare' for usage."
            return 1
            ;;
    esac
}

# Add a new Cloudflare account: prompt for name + token + origin-ca-key,
# verify each against the Cloudflare API (hard-fail), then persist to .env.
cmd_cloudflare_add() {
    local name="" token="" origin_ca_key=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)           name="$2"; shift 2 ;;
            --token)          token="$2"; shift 2 ;;
            --origin-ca-key)  origin_ca_key="$2"; shift 2 ;;
            *) log_error "Unknown flag: $1"; return 1 ;;
        esac
    done

    header "Add Cloudflare account"

    if [[ ! -f "${DOCKWEB_ROOT}/.env" ]]; then
        log_error ".env file not found. Run 'cp .env.example .env' first."
        return 1
    fi

    # Migrate legacy single-account form before mutating .env so we don't
    # orphan its creds when CLOUDFLARE_ACCOUNTS becomes non-empty.
    local mig=0
    _cf_migrate_legacy_if_needed || mig=$?
    if [[ $mig -eq 2 ]]; then return 1; fi

    if [[ -z "$name" ]]; then
        echo -ne "  Account name (letters/digits/underscore only, e.g. 'personal'): "
        read -r name
    fi
    if ! [[ "$name" =~ ^[A-Za-z0-9_]+$ ]]; then
        log_error "Invalid account name '${name}'. Use only [A-Za-z0-9_] (no hyphens, dots, or spaces)."
        return 1
    fi
    if _cf_env_accounts_has "$name"; then
        log_error "Account '${name}' already exists in CLOUDFLARE_ACCOUNTS."
        log_info "Use 'dockweb cloudflare remove ${name}' first, or pick a different name."
        return 1
    fi

    if [[ -z "$token" ]]; then
        echo -ne "  Cloudflare API token (Zone:Read scope; input hidden): "
        read -rs token
        echo ""
    fi
    if [[ -z "$token" ]]; then
        log_error "API token cannot be empty."
        return 1
    fi
    log_info "Verifying API token..."
    if ! _cf_verify_token "$token"; then
        log_error "API token verification failed (invalid, expired, or missing Zone:Read)."
        log_info "Create or fix at: https://dash.cloudflare.com/profile/api-tokens"
        return 1
    fi
    log_success "API token verified."

    if [[ -z "$origin_ca_key" ]]; then
        echo ""
        log_info "Origin CA Key is a separate credential (looks like 'v1.0-…')."
        log_info "Get it at: https://dash.cloudflare.com/profile/api-tokens > Origin CA Key"
        echo -ne "  Origin CA Key (input hidden): "
        read -rs origin_ca_key
        echo ""
    fi
    if [[ -z "$origin_ca_key" ]]; then
        log_error "Origin CA Key cannot be empty."
        return 1
    fi
    log_info "Verifying Origin CA Key..."
    if ! _cf_verify_origin_ca_key "$origin_ca_key"; then
        log_error "Origin CA Key verification failed."
        log_info "Make sure you copied the global Origin CA Key, not a regular API token."
        return 1
    fi
    log_success "Origin CA Key verified."

    _cf_env_set "CLOUDFLARE_API_TOKEN_${name}" "$token"
    _cf_env_set "CLOUDFLARE_ORIGIN_CA_KEY_${name}" "$origin_ca_key"
    _cf_env_accounts_add "$name"

    echo ""
    log_success "Cloudflare account '${name}' added to .env."
    log_info "  Token:          $(_cf_mask "$token")"
    log_info "  Origin CA Key:  $(_cf_mask "$origin_ca_key")"
}

cmd_cloudflare_list() {
    header "Cloudflare accounts"
    load_env

    local accounts
    accounts=$(_cf_account_list)
    if [[ -z "$accounts" ]]; then
        echo -e "  ${DIM}(none configured)${NC}"
        echo ""
        echo "  Add one with: dockweb cloudflare add"
        return 0
    fi

    local a token key
    while IFS= read -r a; do
        [[ -z "$a" ]] && continue
        token=$(_cf_account_var "$a" "API_TOKEN")
        key=$(_cf_account_var "$a" "ORIGIN_CA_KEY")
        echo ""
        echo -e "  ${BOLD}${a}${NC}"
        if [[ -n "$token" ]]; then
            echo "    API token:      $(_cf_mask "$token")"
        else
            echo -e "    API token:      ${RED}MISSING${NC}"
        fi
        if [[ -n "$key" ]]; then
            echo "    Origin CA Key:  $(_cf_mask "$key")"
        else
            echo -e "    Origin CA Key:  ${RED}MISSING${NC}"
        fi
    done <<< "$accounts"
    echo ""
}

cmd_cloudflare_remove() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        log_error "Usage: dockweb cloudflare remove <name>"
        return 1
    fi

    local current
    current=$(_cf_env_get "CLOUDFLARE_ACCOUNTS")

    # Special case: removing the implicit "default" account when only legacy
    # single-account vars are set (CLOUDFLARE_ACCOUNTS is still empty).
    if [[ "$name" == "default" && -z "$current" ]]; then
        local legacy_token legacy_key
        legacy_token=$(_cf_env_get "CLOUDFLARE_API_TOKEN")
        legacy_key=$(_cf_env_get "CLOUDFLARE_ORIGIN_CA_KEY")
        if [[ -n "$legacy_token" || -n "$legacy_key" ]]; then
            confirm "Clear the legacy single-account Cloudflare config?" "n" \
                || { log_info "Aborted."; return 1; }
            _cf_env_set "CLOUDFLARE_API_TOKEN" ""
            _cf_env_set "CLOUDFLARE_ORIGIN_CA_KEY" ""
            log_success "Cleared legacy Cloudflare config."
            return 0
        fi
    fi

    if ! _cf_env_accounts_has "$name"; then
        log_error "Account '${name}' not found in CLOUDFLARE_ACCOUNTS."
        return 1
    fi

    confirm "Remove Cloudflare account '${name}' from .env?" "n" \
        || { log_info "Aborted."; return 1; }

    _cf_env_accounts_remove "$name"
    _cf_env_unset "CLOUDFLARE_API_TOKEN_${name}"
    _cf_env_unset "CLOUDFLARE_ORIGIN_CA_KEY_${name}"

    log_success "Cloudflare account '${name}' removed from .env."
    log_warn "Already-installed Origin certs keep working (15-year validity)."
    log_warn "Re-issuing a cert for sites that used this account will need a new account."
}

cmd_cloudflare_verify() {
    local name="${1:-}"
    load_env

    local accounts
    if [[ -n "$name" ]]; then
        accounts="$name"
    else
        accounts=$(_cf_account_list)
    fi
    if [[ -z "$accounts" ]]; then
        log_error "No Cloudflare accounts configured."
        log_info "Add one with: dockweb cloudflare add"
        return 1
    fi

    header "Verify Cloudflare accounts"

    local a token key fail=0
    while IFS= read -r a; do
        [[ -z "$a" ]] && continue
        echo ""
        echo -e "  ${BOLD}${a}${NC}"
        token=$(_cf_account_var "$a" "API_TOKEN")
        key=$(_cf_account_var "$a" "ORIGIN_CA_KEY")

        if [[ -z "$token" ]]; then
            echo -e "    API token:      ${RED}MISSING${NC}"
            fail=1
        elif _cf_verify_token "$token"; then
            echo -e "    API token:      ${GREEN}OK${NC}"
        else
            echo -e "    API token:      ${RED}INVALID${NC}"
            fail=1
        fi

        if [[ -z "$key" ]]; then
            echo -e "    Origin CA Key:  ${RED}MISSING${NC}"
            fail=1
        elif _cf_verify_origin_ca_key "$key"; then
            echo -e "    Origin CA Key:  ${GREEN}OK${NC}"
        else
            echo -e "    Origin CA Key:  ${RED}INVALID${NC}"
            fail=1
        fi
    done <<< "$accounts"
    echo ""
    return $fail
}
