#!/bin/bash

LOG_DIR="/backup/analysis_daily"
mkdir -p "$LOG_DIR"

LOG="$LOG_DIR/verify-$(date +%Y-%m-%d-%H%M).log"

{
echo "=== BTRFS BACKUP VERIFY ==="
echo "Date: $(date)"
echo

echo "[CHECK] Listing HOME backup path..."
ls -lh /backup/home/snaps || echo "❌ HOME listing failed"

echo
echo "[CHECK] Listing DEV backup path..."
ls -lh /backup/development/snaps || echo "❌ DEV listing failed"

echo
echo "[CHECK] Subvolume health..."
btrfs subvolume list /backup || echo "❌ Could not list subvolumes"

echo
echo "=== END OF REPORT ==="
} > "$LOG"

echo "Analysis saved to $LOG"