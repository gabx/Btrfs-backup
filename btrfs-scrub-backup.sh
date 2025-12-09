#!/bin/bash
set -e

TARGET="/backup"
LOG_DIR="/backup/analysis_daily"
mkdir -p "$LOG_DIR"

LOG="$LOG_DIR/scrub-$(date +%Y-%m-%d-%H%M).log"

echo "=== BTRFS SCRUB START ===" | tee "$LOG"
echo "Date: $(date)" | tee -a "$LOG"
echo | tee -a "$LOG"

btrfs scrub start -B "$TARGET" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "=== SCRUB FINISHED ===" | tee -a "$LOG"