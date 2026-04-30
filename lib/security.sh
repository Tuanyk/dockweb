#!/bin/bash
# dockweb - traffic/security inspection helpers

_security_usage() {
    echo "  Usage:"
    echo "    dockweb security [summary] [domain] [lines]"
    echo "    dockweb security ip <ip> [domain]"
    echo "    dockweb security fail2ban [jail]"
    echo "    dockweb security ban <ip> [jail]"
    echo "    dockweb security unban <ip> [jail]"
    echo "    dockweb security watch <domain>"
    echo ""
    echo "  Defaults:"
    echo "    lines: 10000"
    echo "    jail:  nginx-limit-req"
}

_security_log_dir() {
    printf '%s/logs/nginx\n' "$DOCKWEB_ROOT"
}

_security_access_logs() {
    local domain="${1:-}"
    local log_dir
    log_dir="$(_security_log_dir)"

    [[ -d "$log_dir" ]] || return 0

    if [[ -n "$domain" ]]; then
        printf '%s/%s-access.log\n' "$log_dir" "$domain"
    else
        find "$log_dir" -maxdepth 1 -type f -name '*-access.log' | sort
    fi
}

_security_domain_from_log() {
    local base
    base="$(basename "$1")"
    printf '%s\n' "${base%-access.log}"
}

_security_lines_or_default() {
    local lines="${1:-10000}"
    if [[ "$lines" =~ ^[0-9]+$ && "$lines" -gt 0 ]]; then
        printf '%s\n' "$lines"
    else
        printf '10000\n'
    fi
}

_security_print_top_ips() {
    local sample="$1"

    awk '{ c[$1]++ } END { for (ip in c) print c[ip], ip }' "$sample" \
        | sort -nr \
        | head -10 \
        | awk '{ printf "    %7s  %s\n", $1, $2 }'
}

_security_print_statuses() {
    local sample="$1"

    awk '$9 != "" { c[$9]++ } END { for (status in c) print c[status], status }' "$sample" \
        | sort -nr \
        | head -12 \
        | awk '{ printf "    %7s  %s\n", $1, $2 }'
}

_security_print_top_paths() {
    local sample="$1"

    awk -F\" 'NF >= 2 {
        split($2, req, " ")
        path=req[2]
        if (path != "") c[path]++
    } END {
        for (path in c) print c[path], path
    }' "$sample" \
        | sort -nr \
        | head -15 \
        | awk '{ count=$1; $1=""; sub(/^ /, ""); printf "    %7s  %s\n", count, $0 }'
}

_security_print_user_agents() {
    local sample="$1"

    awk -F\" 'NF >= 6 && $6 != "" { c[$6]++ } END { for (ua in c) print c[ua], ua }' "$sample" \
        | sort -nr \
        | head -10 \
        | awk '{ count=$1; $1=""; sub(/^ /, ""); printf "    %7s  %s\n", count, $0 }'
}

_security_require_fail2ban() {
    if ! command -v docker >/dev/null 2>&1; then
        log_error "Docker is not available on this machine."
        return 1
    fi

    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'fail2ban'; then
        log_error "The fail2ban container is not running."
        log_info "Start services first: dockweb start"
        return 1
    fi
}

_security_validate_ip_arg() {
    local ip="$1"

    if [[ -z "$ip" || "$ip" == -* || ! "$ip" =~ ^[0-9A-Fa-f:./]+$ ]]; then
        log_error "Provide a valid IP address."
        return 1
    fi
}

cmd_security() {
    local subcmd="${1:-summary}"

    case "$subcmd" in
        ""|summary|status)
            cmd_security_summary "${2:-}" "${3:-10000}"
            ;;
        ip)
            cmd_security_ip "${2:-}" "${3:-}"
            ;;
        fail2ban|f2b)
            cmd_security_fail2ban "${2:-}"
            ;;
        ban)
            cmd_security_ban "${2:-}" "${3:-nginx-limit-req}"
            ;;
        unban)
            cmd_security_unban "${2:-}" "${3:-nginx-limit-req}"
            ;;
        watch)
            cmd_security_watch "${2:-}"
            ;;
        help|--help|-h)
            _security_usage
            ;;
        *)
            # Convenience: `dockweb security example.com`
            cmd_security_summary "$subcmd" "${2:-10000}"
            ;;
    esac
}

cmd_security_summary() {
    local domain="${1:-}"
    local lines
    local logs=()
    local log
    local found=0

    lines="$(_security_lines_or_default "${2:-10000}")"

    header "Security Traffic Summary"
    echo ""
    echo "  Sample: last ${lines} line(s) per access log"
    [[ -n "$domain" ]] && echo "  Domain: ${domain}"
    echo ""

    while IFS= read -r log; do
        [[ -n "$log" ]] && logs+=("$log")
    done < <(_security_access_logs "$domain")

    if [[ ${#logs[@]} -eq 0 ]]; then
        log_warn "No Nginx access logs found under $(_security_log_dir)."
        return 0
    fi

    printf "  %-32s %9s %8s %8s  %s\n" "Domain" "Requests" "4xx" "5xx" "Top IP"
    printf "  %-32s %9s %8s %8s  %s\n" "------" "--------" "---" "---" "------"

    for log in "${logs[@]}"; do
        [[ -f "$log" ]] || continue

        local sample total four_xx five_xx top_ip top_count domain_name
        sample="$(mktemp)"
        tail -n "$lines" "$log" > "$sample" 2>/dev/null || true

        total=$(wc -l < "$sample" | awk '{ print $1 + 0 }')
        four_xx=$(awk '$9 ~ /^4/ { c++ } END { print c + 0 }' "$sample")
        five_xx=$(awk '$9 ~ /^5/ { c++ } END { print c + 0 }' "$sample")
        read -r top_count top_ip < <(awk '{ c[$1]++ } END {
            top="-"; max=0
            for (ip in c) {
                if (c[ip] > max) { max=c[ip]; top=ip }
            }
            print max, top
        }' "$sample")
        domain_name="$(_security_domain_from_log "$log")"
        found=1

        printf "  %-32s %9s %8s %8s  %s %s\n" \
            "$domain_name" "$total" "$four_xx" "$five_xx" "$top_count" "$top_ip"

        if [[ -n "$domain" ]]; then
            echo ""
            echo -e "  ${BOLD}Top IPs${NC}"
            _security_print_top_ips "$sample"
            echo ""
            echo -e "  ${BOLD}Status Codes${NC}"
            _security_print_statuses "$sample"
            echo ""
            echo -e "  ${BOLD}Top Paths${NC}"
            _security_print_top_paths "$sample"
            echo ""
            echo -e "  ${BOLD}Top User Agents${NC}"
            _security_print_user_agents "$sample"
        fi

        rm -f "$sample"
    done

    if [[ "$found" -eq 0 ]]; then
        if [[ -n "$domain" ]]; then
            log_warn "No access log found for ${domain}."
        else
            log_warn "No site access logs found."
        fi
        return 0
    fi

    echo ""
    echo "  Next:"
    echo "    dockweb security summary <domain>"
    echo "    dockweb security ip <ip> [domain]"
    echo "    dockweb security fail2ban"
    echo "    dockweb security ban <ip>"
}

cmd_security_ip() {
    local ip="$1"
    local domain="${2:-}"
    local logs=()
    local log
    local found=0

    _security_validate_ip_arg "$ip" || return 1

    while IFS= read -r log; do
        [[ -n "$log" ]] && logs+=("$log")
    done < <(_security_access_logs "$domain")

    header "IP Traffic Detail"
    echo ""
    echo "  IP: ${ip}"
    [[ -n "$domain" ]] && echo "  Domain: ${domain}"
    echo ""

    for log in "${logs[@]}"; do
        [[ -f "$log" ]] || continue

        local sample count domain_name
        sample="$(mktemp)"
        awk -v ip="$ip" '$1 == ip { print }' "$log" > "$sample"
        count=$(wc -l < "$sample" | awk '{ print $1 + 0 }')

        if [[ "$count" -eq 0 ]]; then
            rm -f "$sample"
            continue
        fi

        domain_name="$(_security_domain_from_log "$log")"
        found=1

        echo -e "  ${BOLD}${domain_name}${NC}: ${count} request(s)"
        echo ""
        echo "  Status codes:"
        _security_print_statuses "$sample"
        echo ""
        echo "  Top paths:"
        _security_print_top_paths "$sample"
        echo ""
        echo "  Last requests:"
        tail -n 10 "$sample" | awk -F\" '{
            split($1, left, "\\[")
            split(left[2], ts, "\\]")
            split($2, req, " ")
            split($3, meta, " ")
            printf "    %-26s %-6s %-4s %s\n", ts[1], req[1], meta[1], req[2]
        }'
        echo ""

        rm -f "$sample"
    done

    if [[ "$found" -eq 0 ]]; then
        log_warn "No requests from ${ip} found in the selected access logs."
    else
        echo "  Action:"
        echo "    dockweb security ban ${ip}"
    fi
}

cmd_security_fail2ban() {
    local jail="${1:-}"

    header "Fail2Ban Status"
    echo ""

    _security_require_fail2ban || return 1

    if [[ -n "$jail" ]]; then
        docker exec fail2ban fail2ban-client status "$jail"
        return
    fi

    docker exec fail2ban fail2ban-client status
    echo ""

    local jails
    jails=$(docker exec fail2ban fail2ban-client status 2>/dev/null \
        | awk -F: '/Jail list:/ { gsub(/,/, " ", $2); gsub(/^[ \t]+/, "", $2); print $2 }')

    if [[ -n "$jails" ]]; then
        echo "  Jail details:"
        local jail_name
        for jail_name in $jails; do
            echo ""
            docker exec fail2ban fail2ban-client status "$jail_name" | sed 's/^/    /'
        done
    fi

    echo ""
    echo "  Currently banned:"
    docker exec fail2ban fail2ban-client banned 2>/dev/null | sed 's/^/    /' || echo "    (not available from this fail2ban image)"
}

cmd_security_ban() {
    local ip="$1"
    local jail="${2:-nginx-limit-req}"

    _security_validate_ip_arg "$ip" || return 1
    _security_require_fail2ban || return 1

    docker exec fail2ban fail2ban-client set "$jail" banip "$ip"
    log_success "Banned ${ip} in fail2ban jail ${jail}."
}

cmd_security_unban() {
    local ip="$1"
    local jail="${2:-nginx-limit-req}"

    _security_validate_ip_arg "$ip" || return 1
    _security_require_fail2ban || return 1

    docker exec fail2ban fail2ban-client set "$jail" unbanip "$ip"
    log_success "Unbanned ${ip} from fail2ban jail ${jail}."
}

cmd_security_watch() {
    local domain="$1"
    local log

    if [[ -z "$domain" ]]; then
        log_error "Usage: dockweb security watch <domain>"
        return 1
    fi

    log="$(_security_log_dir)/${domain}-access.log"
    if [[ ! -f "$log" ]]; then
        log_error "No access log found for ${domain}: ${log}"
        return 1
    fi

    log_info "Watching ${log} (Ctrl+C to exit)"
    tail -f "$log"
}
