#!/bin/bash
set -euo pipefail

DATE="$(date +%Y-%m-%d)"
LOG="/backup/analysis_daily/scrub-$DATE.txt"

echo "=== BTRFS SCRUB START ===" > "$LOG"
echo "Date: $DATE" >> "$LOG"
echo "----------------------------" >> "$LOG"

# Scrub only critical systems :
#  - / (nvmeXnypz)
#  - /backup (sdaX)
# please adapt according to your setup setup

echo "[SCRUB] Scrubbing / (nvme0n1p2)" >> "$LOG"
sudo btrfs scrub start -Bd / >> "$LOG" 2>&1

echo "" >> "$LOG"
echo "[SCRUB] Scrubbing /backup (sda1)" >> "$LOG"
sudo btrfs scrub start -Bd /backup >> "$LOG" 2>&1

echo "" >> "$LOG"
echo "=== SCRUB FINISHED ===" >> "$LOG"