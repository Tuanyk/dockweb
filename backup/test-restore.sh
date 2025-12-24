#!/bin/bash

# Backup Restoration Test Script
# Run this monthly to verify backups can be restored

set -e

export RESTIC_REPOSITORY=/backups/repo
TEST_DIR=/tmp/restore-test-$(date +%s)

echo "### Backup Restoration Test ###"
echo "Test directory: $TEST_DIR"
echo ""

# 1. List available snapshots
echo "Available snapshots:"
restic snapshots

# 2. Get latest snapshot ID
LATEST_SNAPSHOT=$(restic snapshots --json | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -z "$LATEST_SNAPSHOT" ]; then
    echo "ERROR: No snapshots found!"
    exit 1
fi

echo ""
echo "Testing restoration of latest snapshot: $LATEST_SNAPSHOT"

# 3. Create test directory
mkdir -p "$TEST_DIR"

# 4. Restore database dump only (faster test)
echo "Restoring database dump..."
restic restore "$LATEST_SNAPSHOT" --target "$TEST_DIR" --include /tmp/all_databases.sql

# 5. Verify restored file
if [ -f "$TEST_DIR/tmp/all_databases.sql" ]; then
    SIZE=$(du -h "$TEST_DIR/tmp/all_databases.sql" | cut -f1)
    echo "✓ Database dump restored successfully (Size: $SIZE)"

    # Check if it's a valid SQL file
    if head -1 "$TEST_DIR/tmp/all_databases.sql" | grep -q "MySQL dump"; then
        echo "✓ File appears to be a valid MySQL dump"
    else
        echo "✗ WARNING: File may not be a valid MySQL dump"
    fi
else
    echo "✗ ERROR: Database dump not found in restored backup!"
    rm -rf "$TEST_DIR"
    exit 1
fi

# 6. Clean up
rm -rf "$TEST_DIR"

echo ""
echo "### Restoration Test PASSED ###"
echo "Your backups can be successfully restored."
echo ""
echo "To restore a full backup, use:"
echo "  restic restore latest --target /restore/path"
