#!/bin/bash

# dockweb health monitoring
# Run from cron to alert on confirmed container, resource, site, SSL, and traffic issues.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKWEB_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

load_env_file() {
    local env_file="${DOCKWEB_ROOT}/.env"
    if [ ! -f "$env_file" ] && [ -f /app/.env ]; then
        env_file="/app/.env"
    fi

    if [ -f "$env_file" ]; then
        set -a
        set -f
        # shellcheck disable=SC1090
        source <(grep -v '^[[:space:]]*#' "$env_file" | grep -v '^[[:space:]]*$')
        set +f
        set +a
    fi
}

is_true() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON|enabled|ENABLED) return 0 ;;
        *) return 1 ;;
    esac
}

safe_key() {
    printf '%s' "$1" | sed 's/[^A-Za-z0-9_.-]/_/g'
}

read_int_file() {
    local file="$1"
    if [ -f "$file" ]; then
        awk 'NR==1 && $0 ~ /^[0-9]+$/ { print; found=1 } END { if (!found) print 0 }' "$file"
    else
        echo 0
    fi
}

num_or_default() {
    local value="$1"
    local default="$2"

    case "$value" in
        ''|*[!0-9]*) echo "$default" ;;
        *) echo "$value" ;;
    esac
}

send_telegram() {
    local text="$1"

    is_true "$TELEGRAM_ALERTS_ENABLED" || return 0
    [ -n "$TELEGRAM_BOT_TOKEN" ] || return 0
    [ -n "$TELEGRAM_CHAT_ID" ] || return 0

    if ! command -v curl >/dev/null 2>&1; then
        echo "WARNING: curl is not installed; cannot send Telegram alert"
        return 0
    fi

    curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${text}" \
        >/dev/null 2>&1 || echo "WARNING: Telegram notification failed"
}

send_email() {
    local subject="$1"
    local message="$2"

    [ -n "$ALERT_EMAIL" ] || return 0
    command -v mail >/dev/null 2>&1 || return 0

    echo "$message" | mail -s "$subject" "$ALERT_EMAIL" 2>/dev/null || true
}

send_notification() {
    local severity="$1"
    local title="$2"
    local message="$3"
    local subject="${severity}: ${title}"
    local body

    body="${subject}

Host: ${HEALTHCHECK_NOTIFY_NAME}
Server: ${HOSTNAME_SHORT}
${message}

Time: $(date -Is)"

    echo "[$severity] $title"
    send_telegram "$body"
    send_email "$subject" "$body"
}

record_alert() {
    local key raw_bad required title message recovery_message counter_file active_file counter
    key=$(safe_key "$1")
    raw_bad="$2"
    required="${3:-1}"
    title="$4"
    message="$5"
    recovery_message="${6:-Recovered.}"
    counter_file="${STATE_DIR}/${key}.count"
    active_file="${STATE_DIR}/${key}.active"

    required=$(num_or_default "$required" 1)
    [ "$required" -lt 1 ] && required=1

    if [ "$raw_bad" = "1" ]; then
        ISSUES_DETECTED=1
        counter=$(read_int_file "$counter_file")
        counter=$((counter + 1))
        echo "$counter" > "$counter_file"

        if [ ! -f "$active_file" ] && [ "$counter" -ge "$required" ]; then
            printf '%s\t%s\n' "$(date -Is)" "$title" > "$active_file"
            send_notification "ALERT" "$title" "$message"
        elif [ -f "$active_file" ]; then
            echo "ACTIVE: $title"
        else
            echo "PENDING: $title (${counter}/${required})"
        fi
    else
        rm -f "$counter_file"
        if [ -f "$active_file" ]; then
            rm -f "$active_file"
            send_notification "RECOVERY" "$title" "$recovery_message"
        fi
    fi
}

docker_available() {
    command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1
}

dockweb_containers() {
    local conf php_container

    printf '%s\n' \
        gateway_nginx \
        shared_mysql \
        shared_redis \
        backup_service \
        adminer \
        monitor_glances \
        fail2ban \
        logrotate \
        certbot

    for conf in "${DOCKWEB_ROOT}"/sites/*/.dockweb.conf; do
        [ -f "$conf" ] || continue
        php_container=$(awk -F= '$1 == "PHP_CONTAINER" { print $2; exit }' "$conf")
        [ -n "$php_container" ] && printf '%s\n' "$php_container"
    done | sort -u
}

check_containers() {
    local unhealthy exited restarting oom missing message bad=0
    local container status health oom_killed

    is_true "$ALERT_CONTAINER_CHECKS_ENABLED" || return

    if ! docker_available; then
        record_alert "docker_unavailable" 1 1 \
            "Docker unavailable" \
            "The Docker daemon could not be queried by healthcheck.sh." \
            "Docker is responding again."
        return
    fi

    record_alert "docker_unavailable" 0 1 \
        "Docker unavailable" "" \
        "Docker is responding again."

    unhealthy=""
    exited=""
    restarting=""
    oom=""
    missing=""

    while IFS= read -r container; do
        [ -n "$container" ] || continue
        if ! docker inspect "$container" >/dev/null 2>&1; then
            missing="${missing}
${container}"
            continue
        fi

        status=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || echo unknown)
        health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || echo unknown)
        oom_killed=$(docker inspect --format '{{.State.OOMKilled}}' "$container" 2>/dev/null || echo false)

        [ "$health" = "unhealthy" ] && unhealthy="${unhealthy}
${container}"

        case "$status" in
            exited|dead|created)
                exited="${exited}
${container} (${status})"
                ;;
            restarting)
                restarting="${restarting}
${container}"
                ;;
        esac

        [ "$oom_killed" = "true" ] && oom="${oom}
${container}"
    done < <(dockweb_containers)

    message=""
    if [ -n "$missing" ]; then
        bad=1
        message="${message}
Missing containers:
${missing}"
    fi
    if [ -n "$unhealthy" ]; then
        bad=1
        message="${message}
Unhealthy containers:
${unhealthy}"
    fi
    if [ -n "$exited" ]; then
        bad=1
        message="${message}
Exited containers:
${exited}"
    fi
    if [ -n "$restarting" ]; then
        bad=1
        message="${message}
Restarting containers:
${restarting}"
    fi
    if [ -n "$oom" ]; then
        bad=1
        message="${message}
OOM-killed containers:
${oom}"
    fi

    record_alert "containers" "$bad" 1 \
        "Container health problem" \
        "${message:-No container issue details available.}" \
        "All dockweb containers are present and no longer unhealthy, exited, restarting, or marked OOM-killed."
}

check_disk() {
    local usage bad=0
    usage=$(df -P / | awk 'NR==2 { gsub("%", "", $5); print $5 }')
    [ -z "$usage" ] && return

    if [ "$usage" -ge "$ALERT_DISK_PERCENT" ]; then
        bad=1
    fi

    record_alert "disk_root" "$bad" "$ALERT_DISK_CHECKS" \
        "Disk usage high" \
        "Root disk usage is ${usage}% (threshold: ${ALERT_DISK_PERCENT}%)." \
        "Root disk usage is back below threshold (${usage}%)."
}

memory_usage_percent() {
    if command -v free >/dev/null 2>&1; then
        free | awk '/^Mem:/ { printf "%.0f", $3 / $2 * 100 }'
        return
    fi

    awk '
        /^MemTotal:/ { total=$2 }
        /^MemAvailable:/ { available=$2 }
        END {
            if (total > 0) printf "%.0f", (total - available) / total * 100
        }
    ' /proc/meminfo
}

swap_usage_percent() {
    if command -v free >/dev/null 2>&1; then
        free | awk '/^Swap:/ {
            if ($2 > 0) printf "%.0f", $3 / $2 * 100
        }'
        return
    fi

    awk '
        /^SwapTotal:/ { total=$2 }
        /^SwapFree:/ { free=$2 }
        END {
            if (total > 0) printf "%.0f", (total - free) / total * 100
        }
    ' /proc/meminfo
}

check_memory() {
    local usage bad=0
    usage=$(memory_usage_percent)
    [ -z "$usage" ] && return

    if [ "$usage" -ge "$ALERT_MEMORY_PERCENT" ]; then
        bad=1
    fi

    record_alert "memory" "$bad" "$ALERT_SUSTAINED_CHECKS" \
        "Memory usage high" \
        "RAM usage is ${usage}% (threshold: ${ALERT_MEMORY_PERCENT}%, checks required: ${ALERT_SUSTAINED_CHECKS})." \
        "RAM usage is back below threshold (${usage}%)."
}

check_swap() {
    local usage bad=0
    usage=$(swap_usage_percent)
    [ -z "$usage" ] && return

    if [ "$usage" -ge "$ALERT_SWAP_PERCENT" ]; then
        bad=1
    fi

    record_alert "swap" "$bad" "$ALERT_SUSTAINED_CHECKS" \
        "Swap usage high" \
        "Swap usage is ${usage}% (threshold: ${ALERT_SWAP_PERCENT}%, checks required: ${ALERT_SUSTAINED_CHECKS})." \
        "Swap usage is back below threshold (${usage}%)."
}

read_cpu_totals() {
    awk '/^cpu / {
        idle=$5 + $6
        total=0
        for (i=2; i<=NF; i++) total += $i
        print total, idle
    }' /proc/stat
}

check_cpu() {
    local t1 i1 t2 i2 delta_total delta_idle usage bad=0
    read -r t1 i1 < <(read_cpu_totals)
    sleep "$ALERT_CPU_SAMPLE_SECONDS"
    read -r t2 i2 < <(read_cpu_totals)

    delta_total=$((t2 - t1))
    delta_idle=$((i2 - i1))
    usage=$(awk -v total="$delta_total" -v idle="$delta_idle" 'BEGIN {
        if (total <= 0) print 0
        else printf "%.0f", (total - idle) / total * 100
    }')

    if [ "$usage" -ge "$ALERT_CPU_PERCENT" ]; then
        bad=1
    fi

    record_alert "cpu" "$bad" "$ALERT_SUSTAINED_CHECKS" \
        "CPU usage high" \
        "CPU usage is ${usage}% (threshold: ${ALERT_CPU_PERCENT}%, checks required: ${ALERT_SUSTAINED_CHECKS})." \
        "CPU usage is back below threshold (${usage}%)."
}

site_url() {
    local domain="$1"
    local ssl_mode="$2"
    local path="${ALERT_SITE_PATH:-/health}"
    local local_domain="${domain%.*}.local"

    [ "${path#/}" = "$path" ] && path="/${path}"

    case "$ssl_mode" in
        letsencrypt|cloudflare)
            printf 'https://%s%s\n' "$domain" "$path"
            ;;
        dev-ssl)
            printf 'https://%s%s\n' "$local_domain" "$path"
            ;;
        local|dev)
            printf 'http://%s%s\n' "$local_domain" "$path"
            ;;
        *)
            printf 'http://%s%s\n' "$domain" "$path"
            ;;
    esac
}

check_sites() {
    local conf domain ssl_mode url http_code bad

    is_true "$ALERT_SITE_CHECKS_ENABLED" || return
    command -v curl >/dev/null 2>&1 || {
        echo "WARNING: curl is not installed; skipping site checks"
        return
    }

    for conf in "${DOCKWEB_ROOT}"/sites/*/.dockweb.conf; do
        [ -f "$conf" ] || continue
        DOMAIN=""
        SSL_MODE=""
        # shellcheck disable=SC1090
        source "$conf"
        domain="$DOMAIN"
        ssl_mode="$SSL_MODE"
        [ -n "$domain" ] || continue

        if is_true "$ALERT_SKIP_LOCAL_SITES"; then
            case "$ssl_mode" in
                local|dev|dev-ssl) continue ;;
            esac
        fi

        url=$(site_url "$domain" "$ssl_mode")
        http_code=$(curl -k -L -sS -o /dev/null -w "%{http_code}" --max-time "$ALERT_SITE_TIMEOUT" "$url" 2>/dev/null || echo "000")
        bad=0
        case "$http_code" in
            2*|3*) bad=0 ;;
            *) bad=1 ;;
        esac

        record_alert "site_${domain}" "$bad" "$ALERT_SITE_FAILURE_CHECKS" \
            "Site down: ${domain}" \
            "Site check failed for ${url} with HTTP ${http_code} (checks required: ${ALERT_SITE_FAILURE_CHECKS})." \
            "Site check recovered for ${url} with HTTP ${http_code}."
    done
}

check_ssl_certificates() {
    local conf domain ssl_mode cert_file bad days_left

    is_true "$ALERT_SSL_CHECKS_ENABLED" || return
    command -v openssl >/dev/null 2>&1 || {
        echo "WARNING: openssl is not installed; skipping SSL checks"
        return
    }

    for conf in "${DOCKWEB_ROOT}"/sites/*/.dockweb.conf; do
        [ -f "$conf" ] || continue
        DOMAIN=""
        SSL_MODE=""
        # shellcheck disable=SC1090
        source "$conf"
        domain="$DOMAIN"
        ssl_mode="$SSL_MODE"
        [ -n "$domain" ] || continue

        case "$ssl_mode" in
            letsencrypt) cert_file="${DOCKWEB_ROOT}/certbot/conf/live/${domain}/fullchain.pem" ;;
            cloudflare) cert_file="${DOCKWEB_ROOT}/cloudflare-certs/${domain}/origin.pem" ;;
            *) continue ;;
        esac

        bad=0
        days_left="unknown"
        if [ ! -f "$cert_file" ]; then
            bad=1
        elif ! openssl x509 -checkend "$((ALERT_SSL_EXPIRY_DAYS * 86400))" -noout -in "$cert_file" >/dev/null 2>&1; then
            bad=1
            days_left=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2-)
        fi

        record_alert "ssl_${domain}" "$bad" 1 \
            "SSL certificate problem: ${domain}" \
            "Certificate file: ${cert_file}
Expires/expiry state: ${days_left}
Threshold: ${ALERT_SSL_EXPIRY_DAYS} day(s)." \
            "SSL certificate for ${domain} is present and not within the expiry threshold."
    done
}

check_nginx_traffic() {
    local log_file domain key offset_file current_size offset tmp total five_xx four_xx top_line top_ip top_count
    local traffic_limit rpm bad reasons checks

    is_true "$ALERT_TRAFFIC_CHECKS_ENABLED" || return

    traffic_limit=$((ALERT_TRAFFIC_RPM * ALERT_TRAFFIC_WINDOW_MINUTES))
    checks="${ALERT_TRAFFIC_CHECKS:-1}"

    for log_file in "${DOCKWEB_ROOT}"/logs/nginx/*-access.log; do
        [ -f "$log_file" ] || continue
        domain=$(basename "$log_file")
        domain="${domain%-access.log}"
        key=$(safe_key "traffic_${domain}")
        offset_file="${STATE_DIR}/${key}.offset"
        current_size=$(wc -c < "$log_file" 2>/dev/null || echo 0)

        if [ ! -f "$offset_file" ]; then
            echo "$current_size" > "$offset_file"
            echo "Initialized traffic baseline for ${domain}"
            continue
        fi

        offset=$(read_int_file "$offset_file")
        if [ "$offset" -gt "$current_size" ]; then
            offset=0
        fi

        tmp=$(mktemp)
        tail -c +"$((offset + 1))" "$log_file" > "$tmp" 2>/dev/null || true
        echo "$current_size" > "$offset_file"

        total=$(wc -l < "$tmp" | awk '{print $1}')
        five_xx=$(awk '$9 ~ /^5/ { c++ } END { print c + 0 }' "$tmp")
        four_xx=$(awk '$9 ~ /^4/ { c++ } END { print c + 0 }' "$tmp")
        top_line=$(awk '{ c[$1]++ } END {
            top="-"; max=0
            for (ip in c) {
                if (c[ip] > max) { max=c[ip]; top=ip }
            }
            print top, max
        }' "$tmp")
        rm -f "$tmp"

        top_ip=$(printf '%s\n' "$top_line" | awk '{print $1}')
        top_count=$(printf '%s\n' "$top_line" | awk '{print $2 + 0}')
        rpm=$(( (total + ALERT_TRAFFIC_WINDOW_MINUTES - 1) / ALERT_TRAFFIC_WINDOW_MINUTES ))

        bad=0
        reasons=""
        if [ "$total" -ge "$traffic_limit" ]; then
            bad=1
            reasons="${reasons}
- Requests: ${total} (~${rpm}/min, threshold: ${ALERT_TRAFFIC_RPM}/min)"
        fi
        if [ "$top_count" -ge "$ALERT_TOP_IP_REQS_PER_INTERVAL" ]; then
            bad=1
            reasons="${reasons}
- Top IP: ${top_ip} made ${top_count} request(s) (threshold: ${ALERT_TOP_IP_REQS_PER_INTERVAL})"
        fi
        if [ "$five_xx" -ge "$ALERT_5XX_PER_INTERVAL" ]; then
            bad=1
            reasons="${reasons}
- 5xx responses: ${five_xx} (threshold: ${ALERT_5XX_PER_INTERVAL})"
        fi
        if [ "$four_xx" -ge "$ALERT_4XX_PER_INTERVAL" ]; then
            bad=1
            reasons="${reasons}
- 4xx responses: ${four_xx} (threshold: ${ALERT_4XX_PER_INTERVAL})"
        fi

        record_alert "traffic_${domain}" "$bad" "$checks" \
            "Possible traffic attack: ${domain}" \
            "Nginx access log spike for ${domain}:${reasons}

Window: new log lines since previous healthcheck (configured as ${ALERT_TRAFFIC_WINDOW_MINUTES} minute(s))." \
            "Traffic for ${domain} is back below configured thresholds. Last interval: ${total} requests, ${five_xx} 5xx, ${four_xx} 4xx."
    done
}

load_env_file

ALERT_EMAIL="${ALERT_EMAIL:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
TELEGRAM_ALERTS_ENABLED="${TELEGRAM_ALERTS_ENABLED:-false}"
HEALTHCHECK_NOTIFY_NAME="${HEALTHCHECK_NOTIFY_NAME:-${BACKUP_NOTIFY_NAME:-dockweb}}"
HOSTNAME_SHORT="$(hostname -f 2>/dev/null || hostname)"

ALERT_CONTAINER_CHECKS_ENABLED="${ALERT_CONTAINER_CHECKS_ENABLED:-true}"
ALERT_CPU_PERCENT=$(num_or_default "${ALERT_CPU_PERCENT:-}" 85)
ALERT_CPU_SAMPLE_SECONDS=$(num_or_default "${ALERT_CPU_SAMPLE_SECONDS:-}" 1)
ALERT_MEMORY_PERCENT=$(num_or_default "${ALERT_MEMORY_PERCENT:-}" 90)
ALERT_SWAP_PERCENT=$(num_or_default "${ALERT_SWAP_PERCENT:-}" 50)
ALERT_DISK_PERCENT=$(num_or_default "${ALERT_DISK_PERCENT:-}" 85)
ALERT_DISK_CHECKS=$(num_or_default "${ALERT_DISK_CHECKS:-}" 1)
ALERT_SUSTAINED_CHECKS=$(num_or_default "${ALERT_SUSTAINED_CHECKS:-}" 2)

ALERT_SITE_CHECKS_ENABLED="${ALERT_SITE_CHECKS_ENABLED:-true}"
ALERT_SITE_FAILURE_CHECKS=$(num_or_default "${ALERT_SITE_FAILURE_CHECKS:-}" 2)
ALERT_SITE_TIMEOUT=$(num_or_default "${ALERT_SITE_TIMEOUT:-}" 8)
ALERT_SITE_PATH="${ALERT_SITE_PATH:-/health}"
ALERT_SKIP_LOCAL_SITES="${ALERT_SKIP_LOCAL_SITES:-true}"

ALERT_SSL_CHECKS_ENABLED="${ALERT_SSL_CHECKS_ENABLED:-true}"
ALERT_SSL_EXPIRY_DAYS=$(num_or_default "${ALERT_SSL_EXPIRY_DAYS:-}" 14)

ALERT_TRAFFIC_CHECKS_ENABLED="${ALERT_TRAFFIC_CHECKS_ENABLED:-true}"
ALERT_TRAFFIC_WINDOW_MINUTES=$(num_or_default "${ALERT_TRAFFIC_WINDOW_MINUTES:-}" 5)
ALERT_TRAFFIC_RPM=$(num_or_default "${ALERT_TRAFFIC_RPM:-}" 300)
ALERT_TRAFFIC_CHECKS=$(num_or_default "${ALERT_TRAFFIC_CHECKS:-}" 1)
ALERT_TOP_IP_REQS_PER_INTERVAL=$(num_or_default "${ALERT_TOP_IP_REQS_PER_INTERVAL:-}" 500)
ALERT_5XX_PER_INTERVAL=$(num_or_default "${ALERT_5XX_PER_INTERVAL:-}" 20)
ALERT_4XX_PER_INTERVAL=$(num_or_default "${ALERT_4XX_PER_INTERVAL:-}" 200)

[ "$ALERT_CPU_SAMPLE_SECONDS" -lt 1 ] && ALERT_CPU_SAMPLE_SECONDS=1
[ "$ALERT_TRAFFIC_WINDOW_MINUTES" -lt 1 ] && ALERT_TRAFFIC_WINDOW_MINUTES=5

STATE_DIR="${HEALTHCHECK_STATE_DIR:-${DOCKWEB_ROOT}/logs/healthcheck-state}"
mkdir -p "$STATE_DIR" "${DOCKWEB_ROOT}/logs"

ISSUES_DETECTED=0

echo "=== dockweb health check - $(date -Is) ==="
echo "Host: ${HOSTNAME_SHORT}"
echo ""

check_containers
check_disk
check_memory
check_swap
check_cpu
check_sites
check_ssl_certificates
check_nginx_traffic

echo ""
echo "Disk: $(df -h / | awk 'NR==2 {print $5}')"
memory_summary=$(memory_usage_percent)
if [ -n "$memory_summary" ]; then
    echo "Memory: ${memory_summary}%"
else
    echo "Memory: unknown"
fi

if [ "$ISSUES_DETECTED" -eq 1 ]; then
    echo "Issues detected."
    exit 1
fi

echo "All monitored checks are within configured thresholds."
exit 0
