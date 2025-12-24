# Docker Web Server (Nginx, PHP-FPM, MySQL, Redis)

A high-performance, secure Docker stack optimized for a **6GB RAM** server. Includes automatic resource tuning, backups, and monitoring.

## 🚀 Quick Start

1. **Setup Environment**
   ```bash
   cp .env.example .env  # (If you haven't already)
   chmod +x start.sh
   ```

2. **Start Server**
   ```bash
   ./start.sh
   ```
   *This script automatically calculates optimal RAM settings (MySQL Buffer Pool & PHP Child Workers) based on your specific server size.*

## 🌐 Adding a New Website

1. **Add PHP Service**
   Open `docker-compose.yml` and add a new service (copy the template):
   ```yaml
   php_mysite:
     <<: *php-template
     container_name: php_mysite
     environment:
       PM_MAX_CHILDREN: ${PHP_PM_MAX_CHILDREN:-5}
       SITE_NAME: "mysite.com"
     volumes:
       - ./sites/mysite.com:/var/www/sites/mysite.com
       - ./logs/php/mysite.com:/var/log
   ```

2. **Add Nginx Config**
   Create `nginx/conf.d/mysite.com.conf`. Ensure `fastcgi_pass` points to your new service name (e.g., `php_mysite:9000`).

3. **Update Resource Counter**
   Open `.env` and increment the site counter. **This prevents Out-Of-Memory crashes.**
   ```ini
   PHP_CONTAINER_COUNT=2  # Changed from 1 to 2
   ```

4. **Apply Changes**
   ```bash
   ./start.sh
   ```

## 🛡️ Features

- **Security**: 
  - Nginx hardened (HSTS, XSS Protection, hidden versions).
  - PHP hidden (`expose_php = Off`).
  - **Fail2Ban**: Automatically bans IPs showing malicious behavior in Nginx logs.
- **Performance**:
  - **Opcache + JIT**: PHP 8.3 configured for max speed.
  - **Redis**: Ready for object caching.
  - **Dynamic Tuning**: RAM allocation adjusts automatically if you add more sites.
- **Backups**:
  - **Restic**: Incremental, deduplicated backups running daily at 03:00 AM.
  - Location: `./backups`
- **Monitoring**:
  - **Glances**: Web UI at `http://YOUR_IP:61208`.

## 🛠️ Management Commands

**View Backups:**
```bash
docker exec -it backup_service restic snapshots
```

**Manual Backup:**
```bash
docker exec -it backup_service /scripts/backup.sh
```

**Check Logs:**
```bash
tail -f logs/nginx/error.log
```
