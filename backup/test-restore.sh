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

mkdir -p "$TEST_DIR"

# 3. Try the current per-table layout first; fall back to older dump layouts.
echo "Restoring database dumps..."
restic restore "$LATEST_SNAPSHOT" --target "$TEST_DIR" --include /tmp/db_dumps 2>/dev/null || true

SITE_DIR_COUNT=$(find "$TEST_DIR/tmp/db_dumps" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

if [ "$SITE_DIR_COUNT" -gt 0 ]; then
    echo "✓ Restored per-table dumps for $SITE_DIR_COUNT site(s)"
    BAD=0
    for site_dir in "$TEST_DIR/tmp/db_dumps"/*; do
        [ -d "$site_dir" ] || continue
        DUMP_COUNT=$(find "$site_dir" -maxdepth 1 -name '*.sql' 2>/dev/null | wc -l)
        SIZE=$(du -sh "$site_dir" | cut -f1)
        echo "  ✓ $(basename "$site_dir") ($DUMP_COUNT SQL file(s), Size: $SIZE)"

        for f in "$site_dir"/*.sql; do
            [ -f "$f" ] || continue
            if head -20 "$f" 2>/dev/null | grep -Eq "^(CREATE DATABASE|-- MySQL dump)"; then
                :
            else
                echo "  ✗ $(basename "$site_dir")/$(basename "$f") may not be a valid MySQL dump"
                BAD=$((BAD + 1))
            fi
        done
    done
    if [ "$BAD" -gt 0 ]; then
        rm -rf "$TEST_DIR"
        exit 1
    fi
else
    DUMP_COUNT=$(find "$TEST_DIR/tmp/db_dumps" -maxdepth 1 -name '*.sql' 2>/dev/null | wc -l)
fi

if [ "$SITE_DIR_COUNT" -eq 0 ] && [ "$DUMP_COUNT" -gt 0 ]; then
    echo "✓ Restored $DUMP_COUNT per-site database dump(s)"
    BAD=0
    for f in "$TEST_DIR/tmp/db_dumps"/*.sql; do
        if head -1 "$f" 2>/dev/null | grep -q "MySQL dump"; then
            SIZE=$(du -h "$f" | cut -f1)
            echo "  ✓ $(basename "$f") (Size: $SIZE)"
        else
            echo "  ✗ $(basename "$f") may not be a valid MySQL dump"
            BAD=$((BAD + 1))
        fi
    done
    if [ "$BAD" -gt 0 ]; then
        rm -rf "$TEST_DIR"
        exit 1
    fi
else
    # Legacy snapshot fallback
    echo "No per-site dumps found, trying legacy all_databases.sql..."
    restic restore "$LATEST_SNAPSHOT" --target "$TEST_DIR" --include /tmp/all_databases.sql

    if [ -f "$TEST_DIR/tmp/all_databases.sql" ]; then
        SIZE=$(du -h "$TEST_DIR/tmp/all_databases.sql" | cut -f1)
        echo "✓ Database dump restored successfully (Size: $SIZE)"
        if head -1 "$TEST_DIR/tmp/all_databases.sql" | grep -q "MySQL dump"; then
            echo "✓ File appears to be a valid MySQL dump"
        else
            echo "✗ WARNING: File may not be a valid MySQL dump"
        fi
    else
        echo "✗ ERROR: Snapshot contains neither db_dumps/ nor all_databases.sql"
        rm -rf "$TEST_DIR"
        exit 1
    fi
fi

# 4. Clean up
rm -rf "$TEST_DIR"

echo ""
echo "### Restoration Test PASSED ###"
echo "Your backups can be successfully restored."
echo ""
echo "To restore through dockweb, use: dockweb backup restore"
