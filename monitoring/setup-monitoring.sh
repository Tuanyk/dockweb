#!/bin/bash

# Setup monitoring cron job
# Run this script once to enable automated health checks

echo "Setting up Docker health monitoring..."

# Create cron job to run every 5 minutes
CRON_JOB="*/5 * * * * cd $(pwd) && ./monitoring/healthcheck.sh >> logs/healthcheck.log 2>&1"

# Check if cron job already exists
(crontab -l 2>/dev/null | grep -q "healthcheck.sh") && {
    echo "Monitoring cron job already exists"
    exit 0
}

# Add cron job
(crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -

echo "✓ Health monitoring enabled"
echo "✓ Checks will run every 5 minutes"
echo "✓ Logs: $(pwd)/logs/healthcheck.log"
echo ""
echo "To view logs: tail -f logs/healthcheck.log"
echo "To test now: ./monitoring/healthcheck.sh"
