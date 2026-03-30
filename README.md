# Docker Web Server

Multi-site Docker stack: Nginx + PHP-FPM 8.3 + MySQL 8.0 + Redis. Managed by **dockweb** CLI.

Each site gets its own PHP container, database, and SSL mode (Cloudflare, Let's Encrypt, local HTTP, or local HTTPS with mkcert).

## Quick Start

```bash
# 1. Setup server (Docker, firewall, swap, kernel tuning)
./dockweb setup

# 2. Edit passwords
nano .env

# 3. Add your first site
./dockweb site add

# 4. Start everything
./dockweb start

# 5. Install SSL certificate
./dockweb ssl install-cf example.com      # Cloudflare (production)
./dockweb ssl install-le example.com      # Let's Encrypt (production)
./dockweb ssl install-local example.com   # mkcert (local dev HTTPS)
```

## Local Development

Test the full stack on your laptop:

```bash
# Option A: HTTP only (simple)
./dockweb site add          # SSL mode: dev
./dockweb start
# Visit http://mysite.local

# Option B: HTTPS with trusted cert (for Firebase Auth, OAuth, etc.)
./dockweb site add          # SSL mode: dev-ssl
./dockweb start
# Visit https://mysite.local

# Add domain to /etc/hosts
echo "127.0.0.1 mysite.local" | sudo tee -a /etc/hosts

# When ready for production, switch SSL mode:
./dockweb ssl mysite.com cloudflare
```

Local HTTPS requires [mkcert](https://github.com/FiloSottile/mkcert). Install with `sudo apt install mkcert && mkcert -install`.

## dockweb Commands

```
./dockweb                    Interactive menu (recommended)
./dockweb help               Show all commands

Services:
  dockweb start              Start all containers
  dockweb stop               Stop all containers
  dockweb restart             Restart all containers
  dockweb status              Show status + resource usage
  dockweb update              Pull latest images and rebuild

Sites:
  dockweb site list           List all sites
  dockweb site add            Add site (interactive wizard)
  dockweb site remove <domain>

SSL:
  dockweb ssl                    SSL management menu
  dockweb ssl <domain> <mode>    Switch mode (cloudflare|letsencrypt|local|dev|dev-ssl)
  dockweb ssl install-cf <d>     Install Cloudflare Origin Certificate
  dockweb ssl install-le <d>     Install Let's Encrypt certificate
  dockweb ssl install-local <d>  Install local dev cert (mkcert)
  dockweb ssl update-cf-ips      Refresh Cloudflare IP ranges

Config:
  dockweb config                 Show all settings
  dockweb config backup          Edit backup schedule & retention
  dockweb config passwords       Edit passwords & credentials
  dockweb config resources       Edit resource limits (MySQL, PHP, Redis)

Backup:
  dockweb backup now          Run backup immediately
  dockweb backup list         List snapshots
  dockweb backup restore      Interactive restore
  dockweb backup test         Test restore (non-destructive)

Monitoring:
  dockweb log [service]       View logs (nginx, mysql, php, etc.)
  dockweb monitor             Health check dashboard
```

## Adding a Site

```bash
./dockweb site add
```

The wizard will:
1. Ask for domain name
2. Ask SSL mode (Cloudflare or Let's Encrypt)
3. Auto-create: PHP container, nginx config, database + user
4. Print WordPress-ready DB credentials

## Architecture

```
Internet -> Cloudflare (CDN/WAF/SSL) -> Server:443 -> Nginx -> PHP-FPM -> MySQL
                                                         |
                                                         +-> Redis (cache)
```

| Service | Purpose |
|---------|---------|
| Nginx | Reverse proxy, static files, FastCGI cache |
| PHP-FPM 8.3 | One container per site (isolated) |
| MySQL 8.4 | Shared database, per-site users |
| Redis | Shared cache (sessions, objects) |
| Restic | Scheduled backup (configurable via `dockweb config backup`) |
| Fail2Ban | Auto-ban malicious IPs |
| Certbot | Let's Encrypt auto-renewal |
| Adminer | Database UI (localhost:8888, SSH tunnel) |
| Glances | System monitoring (localhost:61208, SSH tunnel) |

## File Structure

```
dockweb              CLI tool
lib/                 CLI modules
templates/           Nginx/PHP/SQL templates
docker-compose.yml   Core services (nginx, mysql, redis, etc.)
docker-compose.sites.yml   Auto-generated PHP containers
nginx/conf.d/        Per-site nginx configs (auto-generated)
sites/<domain>/      Website files (managed separately)
cloudflare-certs/    Origin certificates
local-certs/         Local dev certificates (mkcert)
.env                 Passwords, backup, and resource settings
```

## Server Requirements

- Ubuntu/Debian (tested on Ubuntu 22.04+)
- Minimum 2GB RAM (4GB+ recommended)
- Docker + Docker Compose plugin

## Production Deployment Guide

### 1. Initial Server Setup

```bash
# SSH into your server
ssh user@your-server-ip

# Clone the project
git clone <your-repo> docker-web2
cd docker-web2

# Run server setup (installs Docker, firewall, swap, kernel tuning)
./dockweb setup
# Choose option 1 (Everything) for fresh server

# Generate and set secure passwords
./dockweb config passwords    # Interactive password setup
# Or manually: nano .env
```

### 2. Configure Firewall

During `dockweb setup`, choose to restrict ports 80/443 to Cloudflare IPs only.
This means no one can bypass Cloudflare to hit your server directly.

SSH (port 22) is always open and unaffected by Cloudflare.

```
SSH:   Your laptop ────────────────────> Server:22    (direct, always works)
HTTP:  Browser ──> Cloudflare:443 ────> Server:443   (proxied through CF)
```

### 3. Cloudflare Setup

1. Add domain to Cloudflare, set DNS A record to server IP (orange cloud = proxied)
2. SSL/TLS > set mode to **Full (Strict)**
3. SSL/TLS > Origin Server > **Create Certificate** (15-year validity, free)
4. Download the Origin Certificate (.pem) and Private Key (.key)
5. Install on your server:
   ```bash
   ./dockweb ssl install-cf yourdomain.com
   # Choose option 2 (file paths) or 1 (paste content)
   ```
6. Recommended Cloudflare settings:
   - Security > Bot Fight Mode: ON
   - Speed > Auto Minify: JS, CSS, HTML
   - Speed > Brotli: ON
   - Caching > Browser Cache TTL: Respect Existing Headers

### 4. Add Sites and Start

```bash
# Add your site
./dockweb site add
# Domain: yourdomain.com
# SSL: 1 (Cloudflare)

# Start all services
./dockweb start

# Verify everything is healthy
./dockweb status
```

### 5. Access Admin Tools (via SSH tunnel)

Adminer and Glances are bound to localhost only (not exposed to internet).
Access them from your laptop through SSH tunnels:

```bash
# Adminer (database UI) on http://localhost:8888
ssh -L 8888:localhost:8888 user@your-server-ip

# Glances (system monitoring) on http://localhost:61208
ssh -L 61208:localhost:61208 user@your-server-ip

# Both at once
ssh -L 8888:localhost:8888 -L 61208:localhost:61208 user@your-server-ip
```

Adminer login:
- Server: `shared_mysql` (pre-filled)
- Username: `root`
- Password: (your DB_ROOT_PASSWORD from .env)

### 6. Ongoing Maintenance

```bash
# Check health
./dockweb monitor

# View logs
./dockweb log nginx
./dockweb log mysql

# Manual backup
./dockweb backup now

# List backup snapshots
./dockweb backup list

# Test backup restore (non-destructive)
./dockweb backup test

# Update Docker images
./dockweb update

# Switch SSL mode if needed
./dockweb ssl yourdomain.com letsencrypt   # Switch away from Cloudflare
./dockweb ssl yourdomain.com cloudflare    # Switch back
```

### 7. Adding More Sites

```bash
./dockweb site add
# Each site gets: own PHP container, own database, own SSL mode
# Resources auto-calculated based on RAM and number of sites
```
