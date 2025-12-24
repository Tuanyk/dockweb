# Production Deployment Guide

This guide will help you securely deploy the Docker Web Server stack to production.

## Pre-Deployment Checklist

### 1. Update Configuration

**Critical: Change all default passwords in `.env`:**

```bash
# Generate strong passwords
openssl rand -base64 32  # Use for DB_ROOT_PASSWORD
openssl rand -base64 32  # Use for RESTIC_PASSWORD
openssl rand -base64 24  # Use for GLANCES_PASSWORD
```

Update `.env` file:
```ini
DB_ROOT_PASSWORD=<your-strong-password>
RESTIC_PASSWORD=<your-strong-password>
GLANCES_PASSWORD=<your-strong-password>
CERTBOT_EMAIL=your-email@example.com
ALERT_EMAIL=alerts@example.com  # Optional
```

**Update MySQL user password:**
Edit `mysql/init/01-create-users.sql` and change:
```sql
IDENTIFIED BY 'CHANGE_THIS_PASSWORD_123'
```

### 2. Configure Your Domain

Update `init-letsencrypt.sh`:
```bash
domains=(kairoxbuild.com www.kairoxbuild.com)  # Change to your domains
email="your-email@example.com"
```

Update `nginx/conf.d/kairoxbuild.com.conf`:
- Change `server_name` to your domain
- Update paths if needed

### 3. Server Setup

**Update system:**
```bash
sudo apt update && sudo apt upgrade -y
```

**Install Docker & Docker Compose:**
```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
```

**Configure firewall:**
```bash
sudo ufw allow 22/tcp   # SSH
sudo ufw allow 80/tcp   # HTTP
sudo ufw allow 443/tcp  # HTTPS
sudo ufw enable
```

## Deployment Steps

### Step 1: Start Services

```bash
./start.sh
```

This will:
- Create all required directories
- Calculate optimal resource allocation
- Build and start all containers

### Step 2: Setup SSL Certificates

```bash
./init-letsencrypt.sh
```

This will:
- Download SSL configuration files
- Create temporary certificates
- Request real Let's Encrypt certificates
- Configure auto-renewal (every 12 hours)

**IMPORTANT:** Ensure DNS records point to your server before running this!

### Step 3: Verify Services

```bash
# Check container status
docker-compose ps

# All containers should be "healthy" or "running"
docker ps --format "table {{.Names}}\t{{.Status}}"

# Test Nginx configuration
docker exec gateway_nginx nginx -t

# Test SSL
curl -I https://your-domain.com
```

### Step 4: Setup Monitoring

```bash
./monitoring/setup-monitoring.sh
```

This creates a cron job that checks container health every 5 minutes.

**Access Glances monitoring:**
```bash
# Create SSH tunnel from your local machine
ssh -L 61208:localhost:61208 user@your-server

# Then open in browser: http://localhost:61208
# Login: admin / <your-glances-password>
```

### Step 5: Test Backup System

```bash
# Run manual backup
docker exec -it backup_service /scripts/backup.sh

# Verify backup
docker exec -it backup_service restic snapshots

# Test restoration (recommended!)
docker exec -it backup_service /scripts/test-restore.sh
```

Backups run automatically daily at 3:00 AM.

### Step 6: Database Setup

```bash
# Connect to MySQL
docker exec -it shared_mysql mysql -u root -p

# Verify app user was created
SELECT User, Host FROM mysql.user;

# Test connection with app user
mysql -h localhost -u kairoxbuild_user -p kairoxbuild_db
```

Update your application config to use:
- Host: `shared_mysql` (from within containers) or `localhost:3306` (from host)
- Database: `kairoxbuild_db`
- User: `kairoxbuild_user`
- Password: (the one you set in `mysql/init/01-create-users.sql`)

## Post-Deployment

### Security Hardening

1. **Disable root SSH login:**
```bash
sudo sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
sudo systemctl restart sshd
```

2. **Setup Fail2Ban monitoring:**
```bash
# Check banned IPs
docker exec fail2ban fail2ban-client status nginx-http-auth
```

3. **Enable ModSecurity WAF (optional):**

Update your firewall to route public traffic through WAF:
```bash
sudo ufw delete allow 80/tcp
sudo ufw delete allow 443/tcp
sudo ufw allow 8080/tcp
```

Update Nginx to listen on localhost only, and access site via port 8080.

### Performance Tuning

**Monitor cache hit rate:**
```bash
# Check FastCGI cache
curl -I https://your-domain.com
# Look for: X-FastCGI-Cache: HIT

# Check Redis
docker exec -it shared_redis redis-cli INFO stats
```

**Monitor resource usage:**
```bash
# Via Glances (web UI)
# Or via CLI:
docker stats
```

### Maintenance

**View logs:**
```bash
tail -f logs/nginx/error.log
tail -f logs/mysql/error.log
docker-compose logs -f php_kairoxbuild
```

**Clear FastCGI cache:**
```bash
docker exec gateway_nginx rm -rf /var/cache/nginx/*
```

**Deploy code changes:**
```bash
# Since opcache.validate_timestamps=0, restart PHP containers:
docker-compose restart php_kairoxbuild
```

**Update containers:**
```bash
docker-compose pull
docker-compose up -d
```

## Monitoring & Alerts

### Health Checks

View health check logs:
```bash
tail -f logs/healthcheck.log
```

Manual health check:
```bash
./monitoring/healthcheck.sh
```

### Backup Monitoring

Check backup logs:
```bash
docker logs backup_service

# Or check backup status
docker exec backup_service restic snapshots
```

## Troubleshooting

### SSL Certificate Issues

```bash
# Check certificate status
docker exec certbot certbot certificates

# Force renewal
docker exec certbot certbot renew --force-renewal

# Check Nginx SSL config
docker exec gateway_nginx nginx -t
```

### Container Not Starting

```bash
# View logs
docker-compose logs <container_name>

# Check resource usage
docker stats

# Rebuild container
docker-compose up -d --build <container_name>
```

### Performance Issues

```bash
# Check MySQL slow queries
docker exec shared_mysql mysql -u root -p -e "SHOW PROCESSLIST;"

# Check PHP-FPM status
docker exec php_kairoxbuild ps aux | grep php-fpm

# Monitor with Glances
# Access via SSH tunnel: http://localhost:61208
```

## Scaling

### Adding a New Site

1. **Add PHP service to `docker-compose.yml`:**
```yaml
php_newsite:
  <<: *php-template
  container_name: php_newsite
  environment:
    PM_MAX_CHILDREN: ${PHP_PM_MAX_CHILDREN:-5}
    SITE_NAME: "newsite.com"
  volumes:
    - ./sites/newsite.com:/var/www/sites/newsite.com
    - ./logs/php/newsite.com:/var/log
```

2. **Update `.env`:**
```ini
PHP_CONTAINER_COUNT=3  # Increment
```

3. **Create Nginx config:**
```bash
cp nginx/conf.d/kairoxbuild.com.conf nginx/conf.d/newsite.com.conf
# Edit and update server_name, root path, fastcgi_pass
```

4. **Update SSL script:**
Add domain to `init-letsencrypt.sh` domains array.

5. **Restart:**
```bash
./start.sh
./init-letsencrypt.sh  # For new SSL cert
```

## Backup & Recovery

### Manual Backup

```bash
docker exec backup_service /scripts/backup.sh
```

### Restore from Backup

```bash
# List snapshots
docker exec backup_service restic snapshots

# Restore specific snapshot
docker exec backup_service restic restore <snapshot-id> --target /restore/path

# Restore latest
docker exec backup_service restic restore latest --target /var/restore
```

### Database Restore

```bash
# Restore database from backup
docker exec -i shared_mysql mysql -u root -p < /path/to/backup.sql
```

## Performance Metrics

Expected improvements after optimization:

- **Page Load Time:** 50-80% faster (with FastCGI cache)
- **Static Assets:** 60-90% fewer requests (browser caching)
- **CPU Usage:** 10-15% reduction (opcache optimization)
- **Memory:** Stable under load (resource limits)
- **Security:** Protected from common attacks (rate limiting, WAF, Fail2Ban)

## Support

For issues or questions:
1. Check logs: `docker-compose logs`
2. Review health status: `./monitoring/healthcheck.sh`
3. Verify configuration: `docker exec gateway_nginx nginx -t`

## Maintenance Schedule

- **Daily:** Automated backups (3:00 AM)
- **Weekly:** Review logs and health checks
- **Monthly:** Test backup restoration
- **Quarterly:** Update Docker images
- **As needed:** Review and adjust resource limits
