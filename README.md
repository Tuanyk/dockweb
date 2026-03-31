# dockweb

> Multi-site Docker stack for PHP — managed by a single CLI tool.

**Nginx + PHP-FPM 8.3 + MySQL 8.0 + Redis.** Each site gets its own PHP container, database, and SSL configuration. Works on production VPS and local dev machine.

---

## Why dockweb?

I'm a freelancer. Every time a client needed a PHP site hosted, I'd spin up a VPS and do the same thing over and over:

1. Write a `docker-compose.yml` from scratch
2. Write an Nginx config, get the `fastcgi_pass` and `server_name` right
3. Create a MySQL database and user with proper permissions
4. Figure out SSL — Cloudflare origin cert? Let's Encrypt? Copy-paste from the last project?
5. Set up backups, monitoring, fail2ban...
6. Client needs a second site? Do it all again on the same server, but now worry about conflicts

After the fifth or sixth time, I automated it. That's dockweb.

**One command to add a site.** It creates the PHP container, Nginx config, database, user, and SSL — all wired up. Need a second site? Run the same command. Resources auto-scale based on your server's RAM.

### vs writing docker-compose yourself

You *can* do everything dockweb does manually. But you'll spend hours on each server, and the setup won't be consistent across projects. dockweb gives you a production-ready stack with security hardening (rate limiting, Fail2Ban, Cloudflare IP allowlisting), automated backups with restore testing, and health monitoring — all preconfigured.

### vs Coolify / CapRover / Dokku

Those are full platforms with web UIs, background services, and their own update cycles. If one breaks, you're debugging *their* stack on top of yours. dockweb is a single shell script — no daemon, no web UI, no database of its own. You can read every line of it. If something breaks, it's just Docker and Nginx underneath.

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
