#!/bin/bash

# Load variables from .env
if [ -f .env ]; then
  export $(cat .env | xargs)
fi

# Ensure directories exist
mkdir -p logs/nginx
mkdir -p logs/mysql
mkdir -p logs/php/kairoxbuild.com
mkdir -p backups

# Default settings
PHP_CONTAINERS=${PHP_CONTAINER_COUNT:-1}

# 1. Calculate Total RAM (MB)
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
RESERVED_RAM=600 
AVAILABLE_RAM=$((TOTAL_RAM - RESERVED_RAM))

if [ $AVAILABLE_RAM -le 0 ]; then AVAILABLE_RAM=500; fi

echo "--- Resource Calculation ---"
echo "Total RAM: ${TOTAL_RAM}MB"

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

# 4. Start Docker Compose
echo "Starting services..."
docker-compose up -d --build
