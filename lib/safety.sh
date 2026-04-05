#!/bin/bash
# dockweb - safety confirmation for dangerous actions

# Require typing "yes" for high-risk actions
# Shows: action, impact, estimated downtime
confirm_dangerous() {
    local action="$1"
    local impact="$2"
    local downtime="$3"
    echo ""
    echo -e "  ${RED}${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "  ${RED}${BOLD}║        DANGEROUS ACTION              ║${NC}"
    echo -e "  ${RED}${BOLD}╚══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Action:${NC}   $action"
    echo -e "  ${BOLD}Impact:${NC}   $impact"
    echo -e "  ${BOLD}Downtime:${NC} $downtime"
    echo ""
    echo -ne "  ${RED}Type 'yes' to confirm:${NC} "
    read -r answer
    [[ "$answer" == "yes" ]]
}

# Yellow warning for medium-risk actions
warn_action() {
    local action="$1"
    local note="$2"
    echo ""
    echo -e "  ${YELLOW}${BOLD}Warning: ${action}${NC}"
    echo -e "  ${note}"
    echo ""
    confirm "  Continue?" "n"
}
