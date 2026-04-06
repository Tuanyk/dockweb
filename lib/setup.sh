#!/bin/bash
# dockweb - server setup and provisioning

cmd_setup() {
    header "Server Setup"
    echo "  This will configure your server for production use."
    echo ""
    echo "  What to set up:"
    echo "    1) Everything (recommended for fresh server)"
    echo "    2) Install Docker only"
    echo "    3) Configure firewall (UFW + Cloudflare IPs)"
    echo "    4) Create swap"
    echo "    5) Apply kernel optimizations"
    echo "    6) Setup unattended security updates"
    echo "    0) Back"
    echo ""
    echo -ne "  Choose: "
    read -r choice

    case "$choice" in
        1)
            setup_docker
            setup_firewall
            setup_swap
            setup_sysctl
            setup_unattended_upgrades
            echo ""
            log_success "Server setup complete!"
            echo ""
            log_info "Next steps:"
            echo "  1. Edit .env with secure passwords"
            echo "  2. Run 'dockweb site add' to add your first site"
            echo "  3. Run 'dockweb start' to launch services"
            ;;
        2) setup_docker ;;
        3) setup_firewall ;;
        4) setup_swap ;;
        5) setup_sysctl ;;
        6) setup_unattended_upgrades ;;
        0) return 0 ;;
        *) log_error "Invalid choice." ;;
    esac
}

setup_docker() {
    header "Installing Docker"

    if command -v docker &>/dev/null; then
        log_info "Docker already installed: $(docker --version)"
        if ! docker compose version &>/dev/null; then
            log_info "Installing Docker Compose plugin..."
            sudo apt-get install -y docker-compose-plugin
        fi
    else
        log_info "Installing Docker..."
        curl -fsSL https://get.docker.com | sudo sh

        log_info "Adding current user to docker group..."
        sudo usermod -aG docker "$USER"
        log_warn "Log out and back in for group changes to take effect."
    fi

    # Enable Docker on boot
    sudo systemctl enable docker
    sudo systemctl start docker

    log_success "Docker ready: $(docker --version)"
    docker compose version
}

setup_firewall() {
    header "Configuring Firewall (UFW)"

    if ! command -v ufw &>/dev/null; then
        log_info "Installing UFW..."
        sudo apt-get install -y ufw
    fi

    log_info "Setting default policies..."
    sudo ufw default deny incoming
    sudo ufw default allow outgoing

    # SSH
    log_info "Allowing SSH (port 22)..."
    sudo ufw allow 22/tcp

    echo ""
    echo "  Restrict HTTP/HTTPS to Cloudflare IPs only?"
    echo "    1) Yes - Only Cloudflare can reach ports 80/443 (recommended with CF)"
    echo "    2) No  - Allow all traffic on 80/443 (for Let's Encrypt only setups)"
    echo ""
    echo -ne "  Choose [1-2]: "
    read -r fw_choice

    case "$fw_choice" in
        1)
            log_info "Allowing HTTP/HTTPS from Cloudflare IPs only..."
            # Remove any existing rules for 80/443
            sudo ufw delete allow 80/tcp 2>/dev/null
            sudo ufw delete allow 443/tcp 2>/dev/null

            local cf_ips=(
                173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22
                141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20
                197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13
                104.24.0.0/14 172.64.0.0/13 131.0.72.0/22
            )
            for ip in "${cf_ips[@]}"; do
                sudo ufw allow from "$ip" to any port 80,443 proto tcp
            done
            log_success "Firewall restricted to Cloudflare IPs."
            ;;
        2)
            log_info "Allowing all traffic on 80/443..."
            sudo ufw allow 80/tcp
            sudo ufw allow 443/tcp
            log_success "Ports 80/443 open to all."
            ;;
        *)
            log_warn "Skipping HTTP/HTTPS rules."
            ;;
    esac

    # Enable
    log_info "Enabling firewall..."
    echo "y" | sudo ufw enable
    sudo ufw status numbered

    log_success "Firewall configured."
}

setup_swap() {
    header "Configuring Swap"

    local total_ram
    total_ram=$(free -m | awk '/^Mem:/{print $2}')
    local total_ram_h
    total_ram_h=$(awk "BEGIN {printf \"%.1f\", $total_ram / 1024}")

    # Show current state
    local current_swap=""
    if swapon --show | grep -q '/'; then
        current_swap=$(swapon --show --noheadings --bytes | awk '{total+=$3} END {printf "%.0f", total/1048576}')
        local current_swap_h
        current_swap_h=$(awk "BEGIN {printf \"%.1f\", $current_swap / 1024}")
        echo -e "  RAM: ${total_ram_h} GB | Current swap: ${current_swap_h} GB"
        swapon --show
        echo ""
    else
        echo -e "  RAM: ${total_ram_h} GB | Current swap: none"
        echo ""
    fi

    # Recommend swap size based on RAM
    local recommended="2G"
    [[ $total_ram -le 1024 ]] && recommended="2G"
    [[ $total_ram -gt 1024 && $total_ram -le 2048 ]] && recommended="2G"
    [[ $total_ram -gt 2048 && $total_ram -le 4096 ]] && recommended="4G"
    [[ $total_ram -gt 4096 && $total_ram -le 8192 ]] && recommended="4G"
    [[ $total_ram -gt 8192 ]] && recommended="4G"

    echo "  Choose swap size (recommended: ${recommended}):"
    echo "    1) 1 GB"
    echo "    2) 2 GB"
    echo "    3) 4 GB"
    echo "    4) 8 GB"
    echo "    5) Custom size"
    if [[ -n "$current_swap" ]]; then
        echo "    6) Remove swap"
    fi
    echo "    0) Cancel"
    echo ""
    echo -ne "  Choose: "
    read -r swap_choice

    local swap_size=""
    case "$swap_choice" in
        1) swap_size="1G" ;;
        2) swap_size="2G" ;;
        3) swap_size="4G" ;;
        4) swap_size="8G" ;;
        5)
            echo -ne "  Enter swap size (e.g. 1G, 2G, 512M): "
            read -r swap_size
            if [[ ! "$swap_size" =~ ^[0-9]+(G|M)$ ]]; then
                log_error "Invalid size. Use format like 2G or 512M."
                return 1
            fi
            ;;
        6)
            if [[ -n "$current_swap" ]]; then
                _swap_remove
                return
            fi
            log_error "No swap to remove."
            return 1
            ;;
        0) return 0 ;;
        *) log_error "Invalid choice."; return 1 ;;
    esac

    # Remove existing swap first if present
    if [[ -n "$current_swap" ]]; then
        log_info "Removing existing swap..."
        _swap_remove_quiet
    fi

    _swap_create "$swap_size"
}

# Create swap file and configure swappiness
_swap_create() {
    local swap_size="$1"

    log_info "Creating ${swap_size} swap file..."
    sudo fallocate -l "$swap_size" /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile

    # Make permanent
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
    fi

    # Optimize swappiness for web servers
    sudo sysctl -q vm.swappiness=10
    if ! grep -q 'vm.swappiness' /etc/sysctl.conf; then
        echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf > /dev/null
    fi

    echo ""
    log_success "Swap configured: ${swap_size}"
    swapon --show
}

# Remove swap silently (used when resizing)
_swap_remove_quiet() {
    sudo swapoff /swapfile 2>/dev/null || true
    sudo rm -f /swapfile
    sudo sed -i '\|/swapfile|d' /etc/fstab 2>/dev/null || true
}

# Remove swap with confirmation
_swap_remove() {
    echo -ne "  ${RED}Remove swap entirely? This cannot be undone. [y/N]:${NC} "
    read -r confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        _swap_remove_quiet
        log_success "Swap removed."
    else
        log_info "Cancelled."
    fi
}

setup_sysctl() {
    header "Applying Kernel Optimizations"

    local sysctl_conf="/etc/sysctl.d/99-dockweb.conf"

    log_info "Writing kernel parameters..."
    sudo tee "$sysctl_conf" > /dev/null <<'EOF'
# dockweb - performance tuning

# Network
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 1024 65535

# Memory
vm.swappiness = 10
vm.overcommit_memory = 1

# File system
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
EOF

    sudo sysctl -p "$sysctl_conf"

    # File descriptor limits
    if ! grep -q '65535' /etc/security/limits.conf 2>/dev/null; then
        echo "* soft nofile 65535" | sudo tee -a /etc/security/limits.conf
        echo "* hard nofile 65535" | sudo tee -a /etc/security/limits.conf
    fi

    log_success "Kernel optimizations applied."
}

setup_unattended_upgrades() {
    header "Setting Up Automatic Security Updates"

    if dpkg -l | grep -q unattended-upgrades; then
        log_info "Unattended upgrades already installed."
    else
        log_info "Installing unattended-upgrades..."
        sudo apt-get install -y unattended-upgrades
    fi

    sudo dpkg-reconfigure -plow unattended-upgrades

    log_success "Automatic security updates configured."
}
