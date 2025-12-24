#!/bin/bash

# Load biến từ .env nếu có (để lấy PHP_CONTAINER_COUNT)
if [ -f .env ]; then
  export $(cat .env | xargs)
fi

# Mặc định là 1 site nếu không khai báo
PHP_CONTAINERS=${PHP_CONTAINER_COUNT:-1}

# 1. Lấy tổng RAM (MB)
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
RESERVED_RAM=600 # Dành cho OS + Nginx + Redis + Backup overhead
AVAILABLE_RAM=$((TOTAL_RAM - RESERVED_RAM))

if [ $AVAILABLE_RAM -le 0 ]; then AVAILABLE_RAM=500; fi

echo "--- Resource Calculation ---"
echo "Total RAM: ${TOTAL_RAM}MB"
echo "Number of PHP Containers: ${PHP_CONTAINERS}"

# 2. MySQL (Dành 30% RAM khả dụng cho DB chung)
MYSQL_RAM=$((AVAILABLE_RAM * 30 / 100))
export MYSQL_INNODB_BUFFER_POOL_SIZE="${MYSQL_RAM}M"

# 3. PHP (Dành 70% RAM khả dụng chia đều cho các container)
TOTAL_PHP_RAM=$((AVAILABLE_RAM * 70 / 100))
RAM_PER_CONTAINER=$((TOTAL_PHP_RAM / PHP_CONTAINERS))

# Giả sử mỗi process PHP ăn khoảng 60MB
PHP_AVG_PROC_SIZE=60
CALCULATED_CHILDREN=$((RAM_PER_CONTAINER / PHP_AVG_PROC_SIZE))

# Đảm bảo tối thiểu
if [ $CALCULATED_CHILDREN -lt 4 ]; then CALCULATED_CHILDREN=4; fi

# Xuất biến cho docker-compose dùng chung
export PHP_PM_MAX_CHILDREN=$CALCULATED_CHILDREN

echo "MySQL Buffer Pool: $MYSQL_INNODB_BUFFER_POOL_SIZE"
echo "RAM per PHP Container: ~${RAM_PER_CONTAINER}MB"
echo "Max Children per Container: $PHP_PM_MAX_CHILDREN"

# 4. Start
docker-compose up -d
