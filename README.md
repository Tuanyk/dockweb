# dockweb

> Multi-site Docker stack for PHP — managed by a single CLI tool.

**Nginx + PHP-FPM 8.3 + MySQL 8.0 + Redis.** Each site gets its own PHP container, database, and SSL configuration. Works on production VPS and local dev machine.

---

## Why dockweb?

Setting up a VPS to host multiple PHP sites usually means:
- Writing docker-compose files from scratch every time
- Manually wiring up Nginx configs, PHP containers, databases
- Figuring out SSL for each site separately
- No standard way to add a second (or tenth) site

dockweb solves this with a CLI wizard. One command to add a site — it creates the PHP container, Nginx config, database, and user automatically. SSL modes (Cloudflare, Let's Encrypt, local mkcert) switch with one command.

**vs Coolify / CapRover:** Those are full platforms with web UIs. dockweb is a shell script you own and understand, with no extra services running.

---

## Quick Start

```bash
# 1. Setup server (Docker, firewall, swap, kernel tuning)
./dockweb setup

# 2. Set passwords
./dockweb config passwords

# 3. Add your first site
./dockweb site add

# 4. Start everything
./dockweb start

# 5. Install SSL
./dockweb ssl install-cf example.com      # Cloudflare (recommended)
./dockweb ssl install-le example.com      # Let's Encrypt
./dockweb ssl install-local example.com   # mkcert (local dev HTTPS)
```

---

## Local Development

Test the full stack on your laptop before pushing to production:

```bash
# HTTP only
./dockweb site add     # choose SSL mode: dev
./dockweb start
# Visit http://mysite.local

# HTTPS with trusted cert (for Firebase Auth, OAuth, etc.)
./dockweb site add     # choose SSL mode: dev-ssl
./dockweb start
# Visit https://mysite.local

# Add to /etc/hosts
echo "127.0.0.1 mysite.local" | sudo tee -a /etc/hosts

# Ready for production? Switch SSL mode:
./dockweb ssl mysite.com cloudflare
```

Local HTTPS requires [mkcert](https://github.com/FiloSottile/mkcert): `sudo apt install mkcert && mkcert -install`

---

## dockweb Commands

```
./dockweb                    Interactive menu (recommended)
./dockweb help               Show all commands

Services:
  dockweb start              Start all containers
  dockweb stop               Stop all containers
  dockweb restart            Restart all containers
  dockweb status             Show status + resource usage
  dockweb update             Pull latest images and rebuild

Sites:
  dockweb site list          List all sites
  dockweb site add           Add site (interactive wizard)
  dockweb site remove <domain>

SSL:
  dockweb ssl                         SSL management menu
  dockweb ssl <domain> <mode>         Switch mode (cloudflare|letsencrypt|local|dev|dev-ssl)
  dockweb ssl install-cf <domain>     Install Cloudflare Origin Certificate
  dockweb ssl install-le <domain>     Install Let's Encrypt certificate
  dockweb ssl install-local <domain>  Install local dev cert (mkcert)
  dockweb ssl update-cf-ips           Refresh Cloudflare IP allowlist

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

---

## Architecture

```
Internet -> Cloudflare (CDN/WAF/SSL) -> Server:443 -> Nginx -> PHP-FPM -> MySQL
                                                        |
                                                        +-> Redis (cache)
```

| Service | Purpose |
|---------|---------|
| Nginx | Reverse proxy, static files, FastCGI cache |
| PHP-FPM 8.3 | One isolated container per site |
| MySQL 8.4 | Shared instance, per-site users |
| Redis | Shared cache (sessions, objects) |
| Restic | Scheduled backups with restore testing |
| Fail2Ban | Auto-ban malicious IPs |
| Certbot | Let's Encrypt auto-renewal |
| Adminer | Database UI (localhost:8888 via SSH tunnel) |
| Glances | System monitoring (localhost:61208 via SSH tunnel) |

---

## File Structure

```
dockweb                      CLI tool
lib/                         CLI modules
templates/                   Nginx / PHP / SQL templates
docker-compose.yml           Core services
docker-compose.sites.yml     Auto-generated per-site PHP containers
nginx/conf.d/                Per-site Nginx configs (auto-generated)
sites/<domain>/              Website files (untracked, your own git repos)
.env                         Passwords, backup schedule, resource limits
```

---

## Requirements

- Ubuntu 22.04+ or Debian (other distros may work)
- Minimum 2 GB RAM (4 GB+ recommended for multiple sites)
- Docker + Docker Compose plugin

`./dockweb setup` installs Docker, configures firewall, sets up swap, and tunes kernel parameters.

---

## Production Deployment

### 1. Clone and setup

```bash
git clone https://github.com/Tuanyk/dockweb.git
cd dockweb
cp .env.example .env
./dockweb setup        # installs Docker, firewall, swap, kernel tuning
./dockweb config passwords
```

### 2. Cloudflare setup (recommended)

1. Add domain to Cloudflare, set DNS A record → server IP (orange cloud = proxied)
2. SSL/TLS → **Full (Strict)**
3. SSL/TLS → Origin Server → **Create Certificate** (15-year, free)
4. Download the certificate and key, then:

```bash
./dockweb ssl install-cf yourdomain.com
```

5. Recommended settings: Bot Fight Mode ON, Brotli ON, Browser Cache TTL = Respect Existing Headers

### 3. Restrict port 80/443 to Cloudflare IPs only

During `dockweb setup`, choose to restrict HTTP/HTTPS ports to Cloudflare IP ranges. This prevents anyone from bypassing Cloudflare to hit your server directly.

### 4. Add sites and start

```bash
./dockweb site add
./dockweb start
./dockweb status
```

### 5. Access admin tools (SSH tunnel)

Adminer and Glances are bound to localhost — access via SSH tunnel:

```bash
ssh -L 8888:localhost:8888 -L 61208:localhost:61208 user@your-server
# Adminer:  http://localhost:8888
# Glances:  http://localhost:61208
```

### 6. Ongoing maintenance

```bash
./dockweb monitor         # health check
./dockweb log nginx       # view logs
./dockweb backup now      # manual backup
./dockweb backup test     # test restore (non-destructive)
./dockweb update          # pull latest Docker images
```

---

## License

MIT
