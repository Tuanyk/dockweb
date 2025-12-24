#!/bin/bash

set -e

# Load variables from .env
if [ -f .env ]; then
  export $(cat .env | grep -v '^#' | xargs)
fi

# Ensure all required directories exist
echo "Creating required directories..."
mkdir -p logs/nginx logs/mysql logs/php/kairoxbuild.com logs/modsecurity
mkdir -p backups certbot/conf certbot/www certbot/logs
mkdir -p nginx/cache mysql/data mysql/init monitoring

# Make scripts executable
chmod +x init-letsencrypt.sh 2>/dev/null || true
chmod +x backup/backup.sh backup/test-restore.sh 2>/dev/null || true
chmod +x monitoring/healthcheck.sh monitoring/setup-monitoring.sh 2>/dev/null || true

# Default settings
PHP_CONTAINERS=${PHP_CONTAINER_COUNT:-1}

# 1. Calculate Total RAM (MB)
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
RESERVED_RAM=800  # Increased for additional services (WAF, Certbot, etc.)
AVAILABLE_RAM=$((TOTAL_RAM - RESERVED_RAM))

if [ $AVAILABLE_RAM -le 0 ]; then AVAILABLE_RAM=500; fi

echo "========================================="
echo "   Docker Web Server - Starting Up"
echo "========================================="
echo ""
echo "--- Resource Calculation ---"
echo "Total RAM: ${TOTAL_RAM}MB"
echo "Reserved for System: ${RESERVED_RAM}MB"
echo "Available for Services: ${AVAILABLE_RAM}MB"

# 2. MySQL (30% of Available RAM)
MYSQL_RAM=$((AVAILABLE_RAM * 30 / 100))
export MYSQL_INNODB_BUFFER_POOL_SIZE="${MYSQL_RAM}M"

# 3. PHP (70% of Available RAM distributed)
TOTAL_PHP_RAM=$((AVAILABLE_RAM * 70 / 100))
RAM_PER_CONTAINER=$((TOTAL_PHP_RAM / PHP_CONTAINERS))

# Assume ~60MB per PHP process
PHP_AVG_PROC_SIZE=60
CALCULATED_CHILDREN=$((RAM_PER_CONTAINER / PHP_AVG_PROC_SIZE))

if [ $CALCULATED_CHILDREN -lt 4 ]; then CALCULATED_CHILDREN=4; fi

export PHP_PM_MAX_CHILDREN=$CALCULATED_CHILDREN

echo "MySQL Buffer Pool: $MYSQL_INNODB_BUFFER_POOL_SIZE"
echo "Max Children per PHP Container: $PHP_PM_MAX_CHILDREN"
echo ""

# 4. Check if SSL certificates exist
if [ ! -f "certbot/conf/live/kairoxbuild.com/fullchain.pem" ]; then
    echo "⚠️  WARNING: SSL certificates not found!"
    echo ""
    echo "After services start, run: ./init-letsencrypt.sh"
    echo "This will obtain Let's Encrypt SSL certificates."
    echo ""
fi

# 5. Security check
if grep -q "secret\|changeme\|CHANGE" .env 2>/dev/null; then
    echo "⚠️  WARNING: Default passwords detected in .env file!"
    echo "Please change all passwords before deploying to production."
    echo ""
fi

# 6. Start Docker Compose
echo "--- Starting Services ---"
docker-compose up -d --build

echo ""
echo "========================================="
echo "✅ Services Started Successfully!"
echo "========================================="
echo ""
echo "Container Status:"
docker-compose ps
echo ""
echo "Next Steps:"
echo "  1. Setup SSL: ./init-letsencrypt.sh"
echo "  2. Setup monitoring: ./monitoring/setup-monitoring.sh"
echo "  3. Test backup: docker exec -it backup_service /scripts/backup.sh"
echo "  4. Access Glances: http://localhost:61208 (SSH tunnel required)"
echo ""
echo "Security Reminders:"
echo "  - Change all passwords in .env file"
echo "  - Configure firewall to only allow 80, 443, and SSH"
echo "  - Update DNS to point to this server"
echo "  - Consider using ModSecurity WAF on port 8080"
echo ""
