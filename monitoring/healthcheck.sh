#!/bin/bash

# Container Health Monitoring Script
# Run this via cron to get alerts when containers are unhealthy

# Load environment
if [ -f /app/.env ]; then
  export $(cat /app/.env | grep -v '^#' | xargs)
fi

ALERT_EMAIL="${ALERT_EMAIL:-}"
FAILED_CONTAINERS=""

echo "=== Docker Container Health Check - $(date) ==="
echo ""

# Get all unhealthy containers
UNHEALTHY=$(docker ps --filter "health=unhealthy" --format "{{.Names}}")

if [ -n "$UNHEALTHY" ]; then
    echo "⚠️  UNHEALTHY CONTAINERS DETECTED:"
    echo "$UNHEALTHY"
    FAILED_CONTAINERS="$UNHEALTHY"
fi

# Get all containers that exited
EXITED=$(docker ps -a --filter "status=exited" --format "{{.Names}}")

if [ -n "$EXITED" ]; then
    echo "⚠️  STOPPED CONTAINERS DETECTED:"
    echo "$EXITED"
    FAILED_CONTAINERS="$FAILED_CONTAINERS $EXITED"
fi

# Check disk space
DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')

if [ "$DISK_USAGE" -gt 85 ]; then
    echo "⚠️  DISK USAGE HIGH: ${DISK_USAGE}%"
    FAILED_CONTAINERS="$FAILED_CONTAINERS DISK_HIGH"
fi

# Check memory usage
MEM_USAGE=$(free | awk '/Mem:/ {printf "%.0f", $3/$2 * 100}')

if [ "$MEM_USAGE" -gt 90 ]; then
    echo "⚠️  MEMORY USAGE HIGH: ${MEM_USAGE}%"
    FAILED_CONTAINERS="$FAILED_CONTAINERS MEMORY_HIGH"
fi

# Send alert if there are issues
if [ -n "$FAILED_CONTAINERS" ]; then
    echo ""
    echo "❌ ISSUES DETECTED - Sending alert..."

    if [ -n "$ALERT_EMAIL" ]; then
        MESSAGE="Docker Health Check Alert - $(hostname)

The following issues were detected:

$FAILED_CONTAINERS

Disk Usage: ${DISK_USAGE}%
Memory Usage: ${MEM_USAGE}%

Please investigate immediately.

Time: $(date)
"
        echo "$MESSAGE" | mail -s "⚠️ Server Health Alert - $(hostname)" "$ALERT_EMAIL" 2>/dev/null || {
            echo "Failed to send email alert"
        }
    fi

    exit 1
else
    echo "✅ All containers healthy"
    echo "💾 Disk: ${DISK_USAGE}%"
    echo "🧠 Memory: ${MEM_USAGE}%"
    exit 0
fi
