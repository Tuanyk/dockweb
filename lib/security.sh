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
    echo "    dockweb security dashboard [domain] [lines] [interval]"
    echo ""
    echo "  Defaults:"
    echo "    lines:    10000   (dashboard: 2000)"
    echo "    jail:     nginx-limit-req"
    echo "    interval: 3       (dashboard refresh seconds)"
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
        menu)
            cmd_security_menu
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
        dashboard|dash|live)
            cmd_security_dashboard "${2:-}" "${3:-2000}" "${4:-3}"
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

cmd_security_menu() {
    header "Security & Traffic"

    echo ""
    echo "  1) Traffic summary (all sites)"
    echo "  2) Traffic summary (one domain)"
    echo "  3) Live dashboard"
    echo "  4) Watch live access log (tail -f)"
    echo "  5) Inspect IP"
    echo "  6) Fail2ban status"
    echo "  7) Ban IP"
    echo "  8) Unban IP"
    echo "  0) Back"
    echo ""
    echo -ne "  Choose: "
    local choice domain ip jail
    read -r choice

    case "$choice" in
        1)
            cmd_security_summary "" 10000
            ;;
        2)
            echo -ne "  Domain: "
            read -r domain
            [[ -n "$domain" ]] && cmd_security_summary "$domain" 10000
            ;;
        3)
            cmd_security_dashboard "" 2000 3
            ;;
        4)
            echo -ne "  Domain: "
            read -r domain
            [[ -n "$domain" ]] && cmd_security_watch "$domain"
            ;;
        5)
            echo -ne "  IP: "
            read -r ip
            echo -ne "  Domain (empty for all): "
            read -r domain
            [[ -n "$ip" ]] && cmd_security_ip "$ip" "$domain"
            ;;
        6)
            cmd_security_fail2ban
            ;;
        7)
            echo -ne "  IP to ban: "
            read -r ip
            echo -ne "  Jail [nginx-limit-req]: "
            read -r jail
            jail="${jail:-nginx-limit-req}"
            [[ -n "$ip" ]] && cmd_security_ban "$ip" "$jail"
            ;;
        8)
            echo -ne "  IP to unban: "
            read -r ip
            echo -ne "  Jail [nginx-limit-req]: "
            read -r jail
            jail="${jail:-nginx-limit-req}"
            [[ -n "$ip" ]] && cmd_security_unban "$ip" "$jail"
            ;;
        0)
            return 0
            ;;
        *)
            log_error "Invalid choice."
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

# ---- Live dashboard --------------------------------------------------------

_dashboard_cleanup() {
    tput cnorm 2>/dev/null || true
    tput rmcup 2>/dev/null || true
}

_dashboard_pick_domain() {
    local logs=()
    local log
    while IFS= read -r log; do
        [[ -n "$log" ]] && logs+=("$(_security_domain_from_log "$log")")
    done < <(_security_access_logs)

    if [[ ${#logs[@]} -eq 0 ]]; then
        log_error "No access logs found under $(_security_log_dir)."
        return 1
    fi

    if [[ ${#logs[@]} -eq 1 ]]; then
        printf '%s\n' "${logs[0]}"
        return 0
    fi

    {
        echo "  Select domain to monitor:"
        local i=1
        for log in "${logs[@]}"; do
            printf "    %d) %s\n" "$i" "$log"
            ((i++))
        done
        echo -ne "  Choice [1-${#logs[@]}]: "
    } >&2

    local choice
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#logs[@]} ]]; then
        printf '%s\n' "${logs[$((choice - 1))]}"
        return 0
    fi
    log_error "Invalid choice."
    return 1
}

_dashboard_render() {
    local domain="$1"
    local log="$2"
    local lines="$3"
    local refresh_count="$4"
    local paused="$5"
    local interval="$6"
    local status_msg="${7:-}"

    local sample
    sample="$(mktemp)"
    tail -n "$lines" "$log" > "$sample" 2>/dev/null || true

    local total four_xx five_xx top_ip top_count
    total=$(wc -l < "$sample" 2>/dev/null | awk '{print $1+0}')
    four_xx=$(awk '$9 ~ /^4/ { c++ } END { print c+0 }' "$sample" 2>/dev/null || echo 0)
    five_xx=$(awk '$9 ~ /^5/ { c++ } END { print c+0 }' "$sample" 2>/dev/null || echo 0)
    read -r top_count top_ip < <(awk '{ c[$1]++ } END {
        top="-"; max=0
        for (ip in c) { if (c[ip] > max) { max=c[ip]; top=ip } }
        print max+0, top
    }' "$sample" 2>/dev/null || echo "0 -")

    printf '\033[2J\033[H'

    local now state five_disp
    now="$(date '+%Y-%m-%d %H:%M:%S')"
    if [[ "$paused" -eq 1 ]]; then
        state="${YELLOW}[PAUSED]${NC}"
    else
        state="${GREEN}[live ${interval}s]${NC}"
    fi

    if [[ "$five_xx" -gt 0 ]]; then
        five_disp="${RED}${five_xx}${NC}"
    else
        five_disp="${five_xx}"
    fi

    echo -e "  ${BOLD}${CYAN}dockweb security dashboard${NC}  ${state}  ${DIM}${now}${NC}"
    echo -e "  ${DIM}domain:${NC} ${BOLD}${domain}${NC}   ${DIM}sample:${NC} last ${lines} lines   ${DIM}refresh #${refresh_count}${NC}"
    echo ""
    echo -e "  ${BOLD}Requests${NC} ${total}    ${BOLD}4xx${NC} ${four_xx}    ${BOLD}5xx${NC} ${five_disp}    ${BOLD}Top IP${NC} ${top_ip} (${top_count} req)"
    echo ""

    echo -e "  ${BOLD}Top IPs${NC}"
    _security_print_top_ips "$sample" 2>/dev/null | head -5
    echo ""

    echo -e "  ${BOLD}Status Codes${NC}"
    _security_print_statuses "$sample" 2>/dev/null | head -8
    echo ""

    echo -e "  ${BOLD}Top Paths${NC}"
    _security_print_top_paths "$sample" 2>/dev/null | head -8
    echo ""

    if [[ "$five_xx" -gt 0 ]]; then
        echo -e "  ${BOLD}${RED}Top 5xx Paths${NC}"
        awk '$9 ~ /^5/ {
            path = $7
            sub(/\?.*/, "", path)
            if (path == "") next
            if (length(path) > 60) path = substr(path, 1, 57) "..."
            key = $9 "\t" path
            c[key]++
        } END {
            for (k in c) print c[k] "\t" k
        }' "$sample" 2>/dev/null \
            | sort -rn 2>/dev/null \
            | head -6 \
            | awk -F'\t' '{ printf "    %5d  %s  %s\n", $1, $2, $3 }' \
            || true
        echo ""
    fi

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'fail2ban'; then
        local banned
        banned=$(docker exec fail2ban fail2ban-client banned 2>/dev/null | head -3 || true)
        if [[ -n "$banned" ]]; then
            echo -e "  ${BOLD}Fail2ban — currently banned${NC}"
            echo "$banned" | sed 's/^/    /'
            echo ""
        fi
    fi

    rm -f "$sample"

    local rows
    rows=$(tput lines 2>/dev/null || echo 24)
    if [[ -n "$status_msg" ]]; then
        printf '\033[%d;1H' "$((rows - 1))"
        echo -ne "  ${DIM}status: ${status_msg}${NC}"
    fi
    printf '\033[%d;1H' "$rows"
    echo -ne "${DIM}  [q]uit  [r]efresh  [p]ause  [b]an top IP  [i]nspect IP  [w]atch live  [+/-] sample size${NC}"
}

_dashboard_ban_top_ip() {
    local log="$1"
    local lines="$2"
    local sample top_ip top_count

    sample="$(mktemp)"
    tail -n "$lines" "$log" > "$sample" 2>/dev/null || true
    read -r top_count top_ip < <(awk '{ c[$1]++ } END {
        top="-"; max=0
        for (ip in c) { if (c[ip] > max) { max=c[ip]; top=ip } }
        print max+0, top
    }' "$sample" 2>/dev/null || echo "0 -")
    rm -f "$sample"

    tput cnorm 2>/dev/null || true
    printf '\033[2J\033[H'

    if [[ "$top_ip" == "-" || -z "$top_ip" || "$top_count" -eq 0 ]]; then
        echo ""
        echo "  No top IP detected in current sample."
        echo ""
        echo -ne "  ${DIM}Press any key to return...${NC}"
        read -rsn1
        tput civis 2>/dev/null || true
        return
    fi

    echo ""
    echo "  Top IP: ${top_ip} (${top_count} requests in window)"
    echo ""
    if confirm "  Ban this IP in fail2ban?" n; then
        cmd_security_ban "$top_ip" || true
        echo ""
        echo -ne "  ${DIM}Press any key to return to dashboard...${NC}"
        read -rsn1
    fi
    tput civis 2>/dev/null || true
}

_dashboard_inspect_ip() {
    local log="$1"
    local domain
    domain="$(_security_domain_from_log "$log")"

    tput cnorm 2>/dev/null || true
    printf '\033[2J\033[H'
    echo ""
    echo -ne "  Enter IP to inspect (empty to cancel): "
    local ip
    read -r ip
    if [[ -n "$ip" ]]; then
        cmd_security_ip "$ip" "$domain" || true
        echo ""
        echo -ne "  ${DIM}Press any key to return to dashboard...${NC}"
        read -rsn1
    fi
    tput civis 2>/dev/null || true
}

_dashboard_live_tail() {
    local log="$1"

    tput cnorm 2>/dev/null || true
    tput rmcup 2>/dev/null || true

    log_info "Watching ${log} (Ctrl+C to return to dashboard)"

    trap - INT
    tail -f "$log" || true
    trap '_dashboard_cleanup; trap - INT TERM; exit 130' INT TERM

    tput smcup 2>/dev/null || true
    tput civis 2>/dev/null || true
}

cmd_security_dashboard() {
    local domain="${1:-}"
    local lines="${2:-2000}"
    local interval="${3:-3}"

    if [[ ! -t 0 || ! -t 1 ]]; then
        log_error "Dashboard requires an interactive terminal."
        return 1
    fi

    if [[ -z "$domain" ]]; then
        domain="$(_dashboard_pick_domain)" || return 1
    fi

    local log
    log="$(_security_log_dir)/${domain}-access.log"
    if [[ ! -f "$log" ]]; then
        log_error "No access log found for ${domain}: ${log}"
        return 1
    fi

    if [[ ! "$lines" =~ ^[0-9]+$ || "$lines" -lt 100 ]]; then
        lines=2000
    fi
    if [[ ! "$interval" =~ ^[0-9]+$ || "$interval" -lt 1 ]]; then
        interval=3
    fi

    local paused=0
    local refresh_count=0
    local status_msg=""

    trap '_dashboard_cleanup; trap - INT TERM; exit 130' INT TERM
    tput smcup 2>/dev/null || true
    tput civis 2>/dev/null || true

    while :; do
        if [[ "$paused" -eq 0 ]]; then
            refresh_count=$((refresh_count + 1))
        fi
        _dashboard_render "$domain" "$log" "$lines" "$refresh_count" "$paused" "$interval" "$status_msg"
        status_msg=""

        local key=""
        if read -rsn1 -t "$interval" key 2>/dev/null; then
            case "$key" in
                q|Q) break ;;
                r|R) status_msg="refreshed" ;;
                p|P)
                    paused=$((1 - paused))
                    [[ "$paused" -eq 1 ]] && status_msg="paused" || status_msg="resumed"
                    ;;
                b|B)
                    _dashboard_ban_top_ip "$log" "$lines"
                    ;;
                i|I)
                    _dashboard_inspect_ip "$log"
                    ;;
                w|W)
                    _dashboard_live_tail "$log"
                    ;;
                +|=)
                    lines=$((lines + 1000))
                    [[ "$lines" -gt 50000 ]] && lines=50000
                    status_msg="sample size: ${lines}"
                    ;;
                -|_)
                    lines=$((lines - 1000))
                    [[ "$lines" -lt 500 ]] && lines=500
                    status_msg="sample size: ${lines}"
                    ;;
            esac
        fi
    done

    _dashboard_cleanup
    trap - INT TERM
    return 0
}
