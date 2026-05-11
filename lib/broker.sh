#!/bin/bash
# dockweb - clau-broker sidecar management
#
# Each registered "broker" is one container running clau-broker:latest on the
# dockweb_web_network bridge, holding API credentials for one site. The
# site's PHP container reaches it as http://<alias>:8080 with a bearer token.
#
# State lives in three places (all managed by this module):
#   dockweb/.env                                   BROKER_<SITE>_AUTH_TOKEN
#   sites/<site>/.env                              BROKER_URL, BROKER_AUTH_TOKEN
#   ${CLAU_SECRETS_DIR}/<site>/broker.remote.env   read by clau to skip
#                                                  spawning its own broker
# Provider credential files live at:
#   ${CLAU_SECRETS_DIR}/<site>/broker/*.env, *.json
# Per-site outbound allowlist lives at:
#   dockweb/brokers/<site>/allowlist.txt

BROKER_COMPOSE_FILE="${DOCKWEB_ROOT}/docker-compose.brokers.yml"
BROKER_TEMPLATES_DIR="${DOCKWEB_ROOT}/templates"

_broker_secrets_root() {
    load_env
    echo "${CLAU_SECRETS_DIR:-$HOME/.clau/secrets}"
}

_broker_clau_repo() {
    load_env
    echo "${CLAU_REPO_PATH:-}"
}

# Match the sanitization clau applies to PROJECT_NAME (clau:285):
#   lower-case, then any char outside [a-z0-9-] -> '-', then trim leading/
#   trailing dashes. Required so `dockweb broker add adsmanager.kairoxbuild.com`
#   writes to the same path clau reads: secrets/adsmanager-kairoxbuild-com/.
_broker_clau_project_name() {
    local sanitized
    sanitized="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')"
    sanitized="${sanitized##-}"
    sanitized="${sanitized%%-}"
    echo "$sanitized"
}

_broker_secrets_dir() {
    echo "$(_broker_secrets_root)/$(_broker_clau_project_name "$1")/broker"
}

_broker_remote_env_path() {
    echo "$(_broker_secrets_root)/$(_broker_clau_project_name "$1")/broker.remote.env"
}

_broker_brokers_dir() {
    echo "${DOCKWEB_ROOT}/brokers/$1"
}

# Service / container / alias / env-var naming derived from the site domain.
# Examples for adsmanager.kairoxbuild.com:
#   service name = broker_adsmanager_kairoxbuild_com
#   alias        = broker-adsmanager-kairoxbuild-com
#   token var    = BROKER_ADSMANAGER_KAIROXBUILD_COM_AUTH_TOKEN
_broker_service_name() {
    echo "broker_$(echo "$1" | sed 's/[.\-]/_/g')"
}

_broker_alias() {
    echo "broker-$(echo "$1" | sed 's/[._]/-/g')"
}

_broker_token_var() {
    echo "BROKER_$(echo "$1" | sed 's/[.\-]/_/g' | tr '[:lower:]' '[:upper:]')_AUTH_TOKEN"
}

_broker_validate_site() {
    local site="$1"
    if [[ ! -d "${DOCKWEB_ROOT}/sites/${site}" ]]; then
        log_error "Site '$site' does not exist (no sites/${site}/ directory)."
        return 1
    fi
    return 0
}

# Single source of truth for the docker-compose project name used by the
# `web_network` external reference. dockweb's compose project is the
# basename of DOCKWEB_ROOT, so the bridge is `<project>_web_network`.
_broker_external_network_name() {
    echo "$(basename "$DOCKWEB_ROOT")_web_network"
}

# ─── Env editing helpers ────────────────────────────────────

_env_set_kv() {
    local file="$1" key="$2" value="$3"
    local tmp
    tmp=$(mktemp)
    if [[ -f "$file" ]]; then
        grep -v "^${key}=" "$file" > "$tmp" || true
    fi
    # Ensure file ends with newline before appending.
    if [[ -s "$tmp" ]] && [[ "$(tail -c1 "$tmp" | od -An -tx1 | tr -d ' \n')" != "0a" ]]; then
        printf '\n' >> "$tmp"
    fi
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$file"
}

_env_unset_kv() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 0
    local tmp
    tmp=$(mktemp)
    grep -v "^${key}=" "$file" > "$tmp" || true
    mv "$tmp" "$file"
}

_env_get_kv() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 1
    local line
    line=$(grep "^${key}=" "$file" | tail -n1)
    [[ -n "$line" ]] || return 1
    echo "${line#${key}=}"
}

_managed_block_strip() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    local tmp
    tmp=$(mktemp)
    awk '
        /^# === managed by dockweb broker/ { skip=1; next }
        skip && /^# === end dockweb broker/ { skip=0; next }
        !skip { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

_managed_block_write() {
    local file="$1" url="$2" token="$3"
    mkdir -p "$(dirname "$file")"
    touch "$file"
    _managed_block_strip "$file"
    if [[ -s "$file" ]] && [[ "$(tail -c1 "$file" | od -An -tx1 | tr -d ' \n')" != "0a" ]]; then
        printf '\n' >> "$file"
    fi
    cat >> "$file" <<EOF
# === managed by dockweb broker (do not edit between markers) ===
BROKER_URL=$url
BROKER_AUTH_TOKEN=$token
# === end dockweb broker ===
EOF
}

# ─── Discovery ──────────────────────────────────────────────

# List sites that have a BROKER_*_AUTH_TOKEN in dockweb/.env. One per line.
_broker_list_configured() {
    local env="${DOCKWEB_ROOT}/.env"
    [[ -f "$env" ]] || return 0
    # Walk every site we know about; print those with a token recorded.
    local site var
    while IFS= read -r site; do
        [[ -z "$site" ]] && continue
        var=$(_broker_token_var "$site")
        if grep -q "^${var}=" "$env" 2>/dev/null; then
            echo "$site"
        fi
    done < <(list_all_sites)
}

# ─── Compose file regeneration ──────────────────────────────

_broker_generate_compose() {
    local sites
    sites=$(_broker_list_configured)

    if [[ -z "$sites" ]]; then
        # No brokers configured — remove the compose file entirely so the
        # chain helper skips it.
        rm -f "$BROKER_COMPOSE_FILE"
        return 0
    fi

    local tmp
    tmp=$(mktemp)
    cat > "$tmp" <<'HEADER'
# Auto-generated by dockweb broker - DO NOT EDIT MANUALLY
# Regenerate with: dockweb broker add/remove <site>

services:
HEADER

    local site
    while IFS= read -r site; do
        [[ -z "$site" ]] && continue
        _broker_emit_service "$site" >> "$tmp"
        echo "" >> "$tmp"
    done <<< "$sites"

    local ext_net
    ext_net=$(_broker_external_network_name)
    cat >> "$tmp" <<FOOTER
networks:
  web_network:
    external: true
    name: ${ext_net}
FOOTER

    mv "$tmp" "$BROKER_COMPOSE_FILE"
}

_broker_emit_service() {
    local site="$1"
    local service alias token_var secrets_root clau_project
    service=$(_broker_service_name "$site")
    alias=$(_broker_alias "$site")
    token_var=$(_broker_token_var "$site")
    secrets_root=$(_broker_secrets_root)
    clau_project=$(_broker_clau_project_name "$site")

    # Render the template with sed. Token-var placeholder must produce
    # `${VAR_NAME}` in the output (docker-compose env interpolation).
    # @@CLAU_PROJECT@@ is the dashes-only form clau uses for its secrets
    # path; @@SITE@@ is the literal domain used for dockweb-internal paths.
    sed \
        -e "s|@@SERVICE_NAME@@|${service}|g" \
        -e "s|@@ALIAS@@|${alias}|g" \
        -e "s|@@TOKEN_ENV_VAR@@|${token_var}|g" \
        -e "s|@@SECRETS_DIR@@|${secrets_root}|g" \
        -e "s|@@CLAU_PROJECT@@|${clau_project}|g" \
        -e "s|@@SITE@@|${site}|g" \
        "${BROKER_TEMPLATES_DIR}/broker-compose-service.yml.tpl"
}

# ─── Image build ────────────────────────────────────────────

_broker_ensure_image() {
    if docker image inspect clau-broker:latest &>/dev/null; then
        return 0
    fi
    return 1
}

cmd_broker_build() {
    local no_cache=0
    [[ "${1:-}" == "--no-cache" ]] && no_cache=1

    local clau_repo
    clau_repo=$(_broker_clau_repo)
    if [[ -z "$clau_repo" ]]; then
        log_error "CLAU_REPO_PATH is not set in ${DOCKWEB_ROOT}/.env."
        log_info  "Add: CLAU_REPO_PATH=/path/to/clau   (where broker/Dockerfile lives)"
        return 1
    fi
    if [[ ! -f "${clau_repo}/broker/Dockerfile" ]]; then
        log_error "broker/Dockerfile not found at ${clau_repo}/broker/Dockerfile."
        log_info  "Fix CLAU_REPO_PATH or clone the clau repo there."
        return 1
    fi

    header "Building clau-broker:latest"
    local args=(build -t clau-broker:latest -f "${clau_repo}/broker/Dockerfile" "${clau_repo}")
    [[ $no_cache -eq 1 ]] && args=(build --no-cache -t clau-broker:latest -f "${clau_repo}/broker/Dockerfile" "${clau_repo}")
    docker "${args[@]}"
    log_success "Image clau-broker:latest built."
}

# ─── Subcommand: add ────────────────────────────────────────

cmd_broker_add() {
    local site="${1:-}"
    if [[ -z "$site" ]]; then
        echo -ne "  Site domain (e.g. adsmanager.kairoxbuild.com): "
        read -r site
    fi

    _broker_validate_site "$site" || return 1

    if ! _broker_ensure_image; then
        log_error "Image clau-broker:latest is not built."
        log_info  "Run: dockweb broker build"
        return 1
    fi

    local service alias token_var token secrets_dir allowlist_file remote_env_file site_env_file
    service=$(_broker_service_name "$site")
    alias=$(_broker_alias "$site")
    token_var=$(_broker_token_var "$site")
    secrets_dir=$(_broker_secrets_dir "$site")
    allowlist_file="$(_broker_brokers_dir "$site")/allowlist.txt"
    remote_env_file=$(_broker_remote_env_path "$site")
    site_env_file="${DOCKWEB_ROOT}/sites/${site}/.env"

    header "Adding broker for ${site}"

    # 1) Secrets dir + provider templates.
    mkdir -p "$secrets_dir"
    chmod 700 "$secrets_dir" "$(dirname "$secrets_dir")" 2>/dev/null || true
    local seeded=0
    if [[ ! -f "${secrets_dir}/meta.env" ]]; then
        cp "${BROKER_TEMPLATES_DIR}/broker-provider-meta.env.tpl" "${secrets_dir}/meta.env"
        chmod 600 "${secrets_dir}/meta.env"
        seeded=1
    fi
    if [[ ! -f "${secrets_dir}/google-ads.env" ]]; then
        cp "${BROKER_TEMPLATES_DIR}/broker-provider-google-ads.env.tpl" "${secrets_dir}/google-ads.env"
        chmod 600 "${secrets_dir}/google-ads.env"
        seeded=1
    fi
    if [[ ! -f "${secrets_dir}/gcp-sa.json" ]]; then
        cp "${BROKER_TEMPLATES_DIR}/broker-provider-gcp-sa.json.tpl" "${secrets_dir}/gcp-sa.json"
        chmod 600 "${secrets_dir}/gcp-sa.json"
        seeded=1
    fi
    if [[ $seeded -eq 1 ]]; then
        log_info "Seeded provider templates in ${secrets_dir}/"
        log_warn "Edit them with real credentials, then run: dockweb broker restart ${site}"
    else
        log_info "Provider files already exist in ${secrets_dir}/ (left unchanged)."
    fi

    # 2) Per-site allowlist.
    mkdir -p "$(dirname "$allowlist_file")"
    if [[ ! -f "$allowlist_file" ]]; then
        cp "${BROKER_TEMPLATES_DIR}/broker-allowlist-default.txt" "$allowlist_file"
        log_info "Seeded outbound allowlist at ${allowlist_file}"
    fi

    # 3) Stable auth token. Preserve existing one if already set.
    local existing_token
    existing_token=$(_env_get_kv "${DOCKWEB_ROOT}/.env" "$token_var" || true)
    if [[ -n "$existing_token" ]]; then
        token="$existing_token"
        log_info "Reusing existing ${token_var} from .env"
    else
        token=$(openssl rand -hex 32)
        _env_set_kv "${DOCKWEB_ROOT}/.env" "$token_var" "$token"
        log_success "Generated ${token_var} and stored in dockweb/.env"
    fi

    # 4) Regenerate brokers compose.
    _broker_generate_compose
    log_success "docker-compose.brokers.yml regenerated."

    # 5) Site .env: managed marker block.
    local broker_url="http://${alias}:8080"
    _managed_block_write "$site_env_file" "$broker_url" "$token"
    log_success "Wrote managed BROKER_URL/BROKER_AUTH_TOKEN block to sites/${site}/.env"

    # 6) Clau remote-env pointer.
    mkdir -p "$(dirname "$remote_env_file")"
    chmod 700 "$(dirname "$remote_env_file")" 2>/dev/null || true
    cat > "$remote_env_file" <<EOF
# Auto-generated by dockweb broker - clau reads this and skips spawning
# its own broker, joining the named docker network instead.
BROKER_URL=$broker_url
BROKER_AUTH_TOKEN=$token
BROKER_NETWORK=$(_broker_external_network_name)
EOF
    chmod 600 "$remote_env_file"
    log_success "Wrote ${remote_env_file} (clau will auto-discover this broker)."

    # 7) Bring up the container.
    local cmd
    cmd="$(docker_compose_cmd)"
    log_info "Starting ${service}..."
    if ! $cmd up -d "$service"; then
        log_error "Failed to start ${service}."
        return 1
    fi

    # 8) Wait for /health.
    local i=0 healthy=0
    while (( i < 20 )); do
        if docker exec "$service" sh -c \
            "curl -fs -m 1 -H \"Authorization: Bearer \$BROKER_AUTH_TOKEN\" http://127.0.0.1:8080/health" \
            &>/dev/null; then
            healthy=1
            break
        fi
        sleep 0.5
        i=$((i+1))
    done
    if (( healthy != 1 )); then
        log_warn "Broker did not pass /health within 10s. Inspect with: dockweb broker logs ${site}"
    fi

    cmd_broker_status "$site"
}

# ─── Subcommand: remove ─────────────────────────────────────

cmd_broker_remove() {
    local site="${1:-}"
    local purge=0
    if [[ "${2:-}" == "--purge" ]]; then
        purge=1
    fi
    if [[ -z "$site" ]]; then
        log_error "Usage: dockweb broker remove <site> [--purge]"
        return 1
    fi

    _broker_validate_site "$site" || return 1

    local service token_var remote_env_file site_env_file secrets_dir brokers_subdir
    service=$(_broker_service_name "$site")
    token_var=$(_broker_token_var "$site")
    remote_env_file=$(_broker_remote_env_path "$site")
    site_env_file="${DOCKWEB_ROOT}/sites/${site}/.env"
    secrets_dir=$(_broker_secrets_dir "$site")
    brokers_subdir=$(_broker_brokers_dir "$site")

    if ! confirm "Remove broker for '${site}'? Container will be stopped." "n"; then
        log_info "Cancelled."
        return 0
    fi

    docker rm -f "$service" &>/dev/null || true
    log_success "Container ${service} removed."

    _env_unset_kv "${DOCKWEB_ROOT}/.env" "$token_var"
    log_success "Stripped ${token_var} from dockweb/.env"

    _managed_block_strip "$site_env_file"
    log_success "Stripped managed broker block from sites/${site}/.env"

    rm -f "$remote_env_file"
    log_success "Removed ${remote_env_file}"

    _broker_generate_compose
    log_success "docker-compose.brokers.yml regenerated."

    if (( purge )); then
        if confirm "Also delete secrets dir ${secrets_dir} and allowlist ${brokers_subdir}?" "n"; then
            rm -rf "$secrets_dir" "$brokers_subdir"
            log_success "Secrets and allowlist purged."
        fi
    else
        log_info "Secrets kept at ${secrets_dir} (pass --purge to remove)."
    fi
}

# ─── Subcommand: list ───────────────────────────────────────

cmd_broker_list() {
    local sites
    sites=$(_broker_list_configured)
    if [[ -z "$sites" ]]; then
        log_info "No brokers configured."
        log_info "Add one with: dockweb broker add <site>"
        return 0
    fi
    header "Configured brokers"
    printf "  %-40s  %-22s  %s\n" "SITE" "ALIAS" "STATUS"
    local site service alias status
    while IFS= read -r site; do
        [[ -z "$site" ]] && continue
        service=$(_broker_service_name "$site")
        alias=$(_broker_alias "$site")
        if docker ps --format '{{.Names}}' | grep -qx "$service"; then
            status="running"
        elif docker ps -a --format '{{.Names}}' | grep -qx "$service"; then
            status="stopped"
        else
            status="not-created"
        fi
        printf "  %-40s  %-22s  %s\n" "$site" "$alias" "$status"
    done <<< "$sites"
}

# ─── Subcommand: status ─────────────────────────────────────

cmd_broker_status() {
    local site="${1:-}"
    local sites
    if [[ -n "$site" ]]; then
        sites="$site"
    else
        sites=$(_broker_list_configured)
    fi
    if [[ -z "$sites" ]]; then
        log_info "No brokers configured."
        return 0
    fi

    while IFS= read -r site; do
        [[ -z "$site" ]] && continue
        local service token
        service=$(_broker_service_name "$site")
        token=$(_env_get_kv "${DOCKWEB_ROOT}/.env" "$(_broker_token_var "$site")" || true)
        header "${site}"
        if ! docker ps --format '{{.Names}}' | grep -qx "$service"; then
            log_warn "  ${service} is not running."
            continue
        fi
        if [[ -z "$token" ]]; then
            log_warn "  No token recorded in dockweb/.env."
            continue
        fi
        local resp
        resp=$(docker exec "$service" sh -c \
            "curl -fs -m 2 -H \"Authorization: Bearer ${token}\" http://127.0.0.1:8080/health" 2>/dev/null || true)
        if [[ -z "$resp" ]]; then
            log_warn "  /health did not respond."
        else
            echo "  $resp"
        fi
    done <<< "$sites"
}

# ─── Subcommand: logs ───────────────────────────────────────

cmd_broker_logs() {
    local site="${1:-}"
    local follow="${2:-}"
    if [[ -z "$site" ]]; then
        log_error "Usage: dockweb broker logs <site> [-f]"
        return 1
    fi
    local service
    service=$(_broker_service_name "$site")
    if [[ "$follow" == "-f" || "$follow" == "--follow" ]]; then
        docker logs -f "$service"
    else
        docker logs --tail 100 "$service"
    fi
}

# ─── Subcommand: token ──────────────────────────────────────

cmd_broker_token() {
    local site="${1:-}"
    local action="${2:-show}"
    if [[ -z "$site" ]]; then
        log_error "Usage: dockweb broker token <site> [rotate]"
        return 1
    fi
    _broker_validate_site "$site" || return 1
    local token_var
    token_var=$(_broker_token_var "$site")

    case "$action" in
        show)
            local token
            token=$(_env_get_kv "${DOCKWEB_ROOT}/.env" "$token_var" || true)
            if [[ -z "$token" ]]; then
                log_error "No broker configured for ${site}."
                return 1
            fi
            if ! confirm "Print the broker token for ${site}? It will appear on stdout." "n"; then
                return 0
            fi
            echo "$token"
            ;;
        rotate)
            if ! confirm "Rotate broker token for ${site}? Container will be recreated." "n"; then
                return 0
            fi
            local new_token
            new_token=$(openssl rand -hex 32)
            _env_set_kv "${DOCKWEB_ROOT}/.env" "$token_var" "$new_token"

            local alias broker_url remote_env_file site_env_file service
            alias=$(_broker_alias "$site")
            broker_url="http://${alias}:8080"
            remote_env_file=$(_broker_remote_env_path "$site")
            site_env_file="${DOCKWEB_ROOT}/sites/${site}/.env"
            service=$(_broker_service_name "$site")

            _managed_block_write "$site_env_file" "$broker_url" "$new_token"
            cat > "$remote_env_file" <<EOF
# Auto-generated by dockweb broker - clau reads this and skips spawning
# its own broker, joining the named docker network instead.
BROKER_URL=$broker_url
BROKER_AUTH_TOKEN=$new_token
BROKER_NETWORK=$(_broker_external_network_name)
EOF
            chmod 600 "$remote_env_file"

            local cmd
            cmd="$(docker_compose_cmd)"
            $cmd up -d --force-recreate "$service"
            log_success "Token rotated for ${site}."
            ;;
        *)
            log_error "Usage: dockweb broker token <site> [rotate]"
            return 1
            ;;
    esac
}

# ─── Subcommand: secret ─────────────────────────────────────

cmd_broker_secret() {
    local site="${1:-}"
    local provider="${2:-}"
    if [[ -z "$site" ]]; then
        log_error "Usage: dockweb broker secret <site> [meta|google-ads|gcp-sa]"
        return 1
    fi
    _broker_validate_site "$site" || return 1
    local dir
    dir=$(_broker_secrets_dir "$site")
    if [[ ! -d "$dir" ]]; then
        log_error "No broker configured for ${site}. Run: dockweb broker add ${site}"
        return 1
    fi
    if [[ -z "$provider" ]]; then
        header "Secrets for ${site}"
        ls -la "$dir"
        return 0
    fi
    local target
    case "$provider" in
        meta)        target="$dir/meta.env" ;;
        google-ads)  target="$dir/google-ads.env" ;;
        gcp-sa|gcp)  target="$dir/gcp-sa.json" ;;
        *)
            log_error "Unknown provider '$provider'. Try: meta, google-ads, gcp-sa"
            return 1
            ;;
    esac
    if [[ ! -f "$target" ]]; then
        log_warn "${target} does not exist; creating from template."
        case "$provider" in
            meta)       cp "${BROKER_TEMPLATES_DIR}/broker-provider-meta.env.tpl" "$target" ;;
            google-ads) cp "${BROKER_TEMPLATES_DIR}/broker-provider-google-ads.env.tpl" "$target" ;;
            gcp-sa|gcp) cp "${BROKER_TEMPLATES_DIR}/broker-provider-gcp-sa.json.tpl" "$target" ;;
        esac
        chmod 600 "$target"
    fi
    "${EDITOR:-vi}" "$target"
    log_info "After editing, run: dockweb broker restart ${site}"
}

# ─── Subcommand: allowlist ──────────────────────────────────

cmd_broker_allowlist() {
    local site="${1:-}"
    if [[ -z "$site" ]]; then
        log_error "Usage: dockweb broker allowlist <site>"
        return 1
    fi
    _broker_validate_site "$site" || return 1
    local file
    file="$(_broker_brokers_dir "$site")/allowlist.txt"
    if [[ ! -f "$file" ]]; then
        mkdir -p "$(dirname "$file")"
        cp "${BROKER_TEMPLATES_DIR}/broker-allowlist-default.txt" "$file"
        log_info "Seeded allowlist at ${file}"
    fi
    "${EDITOR:-vi}" "$file"
    log_info "After editing, run: dockweb broker restart ${site}"
}

# ─── Subcommand: restart ────────────────────────────────────

cmd_broker_restart() {
    local site="${1:-}"
    if [[ -z "$site" ]]; then
        log_error "Usage: dockweb broker restart <site>"
        return 1
    fi
    _broker_validate_site "$site" || return 1
    local service
    service=$(_broker_service_name "$site")
    local cmd
    cmd="$(docker_compose_cmd)"
    $cmd up -d --force-recreate "$service"
    log_success "Broker ${service} recreated."
    cmd_broker_status "$site"
}

# ─── Dispatcher ─────────────────────────────────────────────

# ─── Interactive submenu ────────────────────────────────────

_menu_broker_pick_site() {
    local prompt="${1:-Site}"
    local sites
    sites=$(list_all_sites)
    if [[ -z "$sites" ]]; then
        log_error "No sites configured."
        return 1
    fi
    local -a arr=()
    local i=1
    while IFS= read -r s; do
        [[ -z "$s" ]] && continue
        arr+=("$s")
        echo "    $i) $s"
        i=$((i+1))
    done <<< "$sites"
    echo "    0) Back"
    echo ""
    echo -ne "  ${prompt}: "
    local choice
    read -r choice
    [[ "$choice" == "0" || -z "$choice" ]] && return 1
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#arr[@]} )); then
        log_error "Invalid choice."
        return 1
    fi
    printf '%s\n' "${arr[$((choice-1))]}"
    return 0
}

_menu_broker_pick_configured() {
    local prompt="${1:-Site}"
    local sites
    sites=$(_broker_list_configured)
    if [[ -z "$sites" ]]; then
        log_error "No brokers configured. Use 'Add a broker' first."
        return 1
    fi
    local -a arr=()
    local i=1
    while IFS= read -r s; do
        [[ -z "$s" ]] && continue
        arr+=("$s")
        echo "    $i) $s"
        i=$((i+1))
    done <<< "$sites"
    echo "    0) Back"
    echo ""
    echo -ne "  ${prompt}: "
    local choice
    read -r choice
    [[ "$choice" == "0" || -z "$choice" ]] && return 1
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#arr[@]} )); then
        log_error "Invalid choice."
        return 1
    fi
    printf '%s\n' "${arr[$((choice-1))]}"
    return 0
}

_menu_broker_pick_provider() {
    echo "    1) meta"
    echo "    2) google-ads"
    echo "    3) gcp-sa"
    echo "    0) Back"
    echo ""
    echo -ne "  Provider: "
    local choice
    read -r choice
    case "$choice" in
        1) echo "meta" ;;
        2) echo "google-ads" ;;
        3) echo "gcp-sa" ;;
        *) return 1 ;;
    esac
}

menu_broker() {
    header "Broker Management"

    # Inline summary.
    local image_status="missing"
    docker image inspect clau-broker:latest &>/dev/null && image_status="built"
    echo -e "  Image clau-broker:latest: ${image_status}"

    local sites
    sites=$(_broker_list_configured)
    if [[ -z "$sites" ]]; then
        echo -e "  Configured brokers: ${DIM}none${NC}"
    else
        echo "  Configured brokers:"
        while IFS= read -r s; do
            [[ -z "$s" ]] && continue
            local svc=$(_broker_service_name "$s") status="not-created"
            if docker ps --format '{{.Names}}' | grep -qx "$svc"; then
                status="running"
            elif docker ps -a --format '{{.Names}}' | grep -qx "$svc"; then
                status="stopped"
            fi
            printf "    %-40s  %s\n" "$s" "$status"
        done <<< "$sites"
    fi

    echo ""
    echo "  Action?"
    echo "    1) Build clau-broker image"
    echo "    2) Add a broker (for a site)"
    echo "    3) Show /health status"
    echo "    4) Tail logs"
    echo "    5) Restart a broker"
    echo "    6) Edit provider secret (meta / google-ads / gcp-sa)"
    echo "    7) Edit outbound allowlist"
    echo "    8) Rotate auth token"
    echo "    9) Print auth token"
    echo "   10) Remove a broker"
    echo "    0) Back"
    echo ""
    echo -ne "  Choose [0-10]: "
    local choice
    read -r choice

    local site provider
    case "$choice" in
        1) cmd_broker_build ;;
        2)
            site=$(_menu_broker_pick_site "Site to add broker for") || return
            cmd_broker_add "$site"
            ;;
        3) cmd_broker_status ;;
        4)
            site=$(_menu_broker_pick_configured "Site") || return
            cmd_broker_logs "$site"
            ;;
        5)
            site=$(_menu_broker_pick_configured "Site to restart") || return
            cmd_broker_restart "$site"
            ;;
        6)
            site=$(_menu_broker_pick_configured "Site") || return
            provider=$(_menu_broker_pick_provider) || return
            cmd_broker_secret "$site" "$provider"
            ;;
        7)
            site=$(_menu_broker_pick_configured "Site") || return
            cmd_broker_allowlist "$site"
            ;;
        8)
            site=$(_menu_broker_pick_configured "Site to rotate token for") || return
            cmd_broker_token "$site" rotate
            ;;
        9)
            site=$(_menu_broker_pick_configured "Site") || return
            cmd_broker_token "$site"
            ;;
        10)
            site=$(_menu_broker_pick_configured "Site to remove broker for") || return
            cmd_broker_remove "$site"
            ;;
        0) return ;;
        *) log_error "Invalid choice." ;;
    esac
}

# ─── Dispatcher ─────────────────────────────────────────────

cmd_broker() {
    local sub="${1:-}"
    shift || true
    case "$sub" in
        add)        cmd_broker_add "$@" ;;
        remove|rm)  cmd_broker_remove "$@" ;;
        list|ls)    cmd_broker_list ;;
        status)     cmd_broker_status "$@" ;;
        logs|log)   cmd_broker_logs "$@" ;;
        token)      cmd_broker_token "$@" ;;
        secret)     cmd_broker_secret "$@" ;;
        allowlist)  cmd_broker_allowlist "$@" ;;
        build)      cmd_broker_build "$@" ;;
        restart)    cmd_broker_restart "$@" ;;
        ""|help|-h|--help)
            cat <<USAGE
  Usage: dockweb broker <subcommand>

  Setup:
    build [--no-cache]           Build clau-broker:latest from \$CLAU_REPO_PATH
    add <site>                   Add a broker for <site> (idempotent)
    remove <site> [--purge]      Remove broker; --purge also deletes secrets

  Inspect:
    list                         Show configured brokers and status
    status [<site>]              Live /health output
    logs <site> [-f]             docker logs broker_<site>

  Credentials:
    secret <site>                List secret files for the broker
    secret <site> <provider>     Edit secret file (meta|google-ads|gcp-sa)
    allowlist <site>             Edit outbound allowlist
    token <site>                 Print auth token (with confirm)
    token <site> rotate          Rotate auth token and recreate container

  Lifecycle:
    restart <site>               Recreate the broker container
USAGE
            ;;
        *)
            log_error "Unknown broker subcommand: $sub"
            log_info  "Run: dockweb broker help"
            return 1
            ;;
    esac
}
