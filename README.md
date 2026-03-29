# Docker Web Server

Multi-site Docker stack: Nginx + PHP-FPM 8.3 + MySQL 8.0 + Redis. Managed by **dockweb** CLI.

Each site gets its own PHP container, database, and SSL mode (Cloudflare or Let's Encrypt).

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
./dockweb ssl install-cf example.com   # Cloudflare
./dockweb ssl install-le example.com   # Let's Encrypt
```

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
  dockweb ssl                 SSL management menu
  dockweb ssl <domain> <mode> Switch mode (cloudflare|letsencrypt)
  dockweb ssl install-cf <d>  Install Cloudflare Origin Certificate
  dockweb ssl install-le <d>  Install Let's Encrypt certificate
  dockweb ssl update-cf-ips   Refresh Cloudflare IP ranges

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
| MySQL 8.0 | Shared database, per-site users |
| Redis | Shared cache (sessions, objects) |
| Restic | Daily backup at 03:00 (7d/4w/6m retention) |
| Fail2Ban | Auto-ban malicious IPs |
| Certbot | Let's Encrypt auto-renewal |
| Glances | Monitoring (localhost:61208, SSH tunnel) |

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
.env                 Passwords and settings
```

## Server Requirements

- Ubuntu/Debian (tested on Ubuntu 22.04+)
- Minimum 2GB RAM (4GB+ recommended)
- Docker + Docker Compose plugin

## Cloudflare Setup

1. Add domain to Cloudflare, set DNS A record (proxied)
2. SSL/TLS > set **Full (Strict)**
3. Origin Server > Create Certificate (15-year, free)
4. `./dockweb ssl install-cf yourdomain.com` (paste cert + key)
5. Firewall restricts 80/443 to Cloudflare IPs only (`dockweb setup` option 3)
