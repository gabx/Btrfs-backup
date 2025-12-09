#!/bin/bash
set -euo pipefail

DATE="$(date +%Y-%m-%d-%H%M)"
DATE_SHORT="$(date +%Y-%m-%d)"

SRC_HOME="/home/username"
SRC_HOME_SNAPS="/home/username/.local-snapshots"

SRC_DEV="/development"
SRC_DEV_SNAPS="/development/.local-snapshots"

DEST_HOME="/backup/home/snaps"
DEST_DEV="/backup/development/snaps"
ANALYSIS_DIR="/backup/analysis_daily"

mkdir -p "$DEST_HOME" "$DEST_DEV" "$ANALYSIS_DIR"

LOGFILE="$ANALYSIS_DIR/${DATE_SHORT}.txt"
echo "Backup report – $DATE" > "$LOGFILE"
echo "----------------------------------------" >> "$LOGFILE"

############################################
### FUNCTION: retain last 7 snapshots
############################################
retain_last_7() {
    local DIR="$1"

    echo "[Retention] Checking $DIR" >> "$LOGFILE"

    # List snapshots sorted by date
    MAPFILE -t snaps < <(ls -1 "$DIR" | sort)

    local count="${#snaps[@]}"
    if (( count <= 7 )); then
        echo "[Retention] Nothing to delete (count=$count)." >> "$LOGFILE"
        return
    fi

    local to_delete=$((count - 7))

    echo "[Retention] Deleting $to_delete old snapshots" >> "$LOGFILE"

    for ((i=0; i<to_delete; i++)); do
        snap="${DIR}/${snaps[$i]}"
        echo "[Retention] Removing $snap" >> "$LOGFILE"
        sudo btrfs subvolume delete "$snap"
    done
}

############################################
### HOME BACKUP
############################################
echo "=== HOME BACKUP START ===" >> "$LOGFILE"

SRC_HOME_LATEST="$SRC_HOME_SNAPS/home-latest"

sudo btrfs property set "$SRC_HOME_LATEST" ro true

SNAP_NAME="home-$DATE"
DEST_SNAP="$DEST_HOME/$SNAP_NAME"

echo "[HOME] Sending FULL snapshot → $DEST_SNAP" >> "$LOGFILE"
sudo btrfs send "$SRC_HOME_LATEST" | sudo btrfs receive "$DEST_HOME"

retain_last_7 "$DEST_HOME"

############################################
### DEVELOPMENT BACKUP
############################################
echo "=== DEVELOPMENT BACKUP START ===" >> "$LOGFILE"

SRC_DEV_LATEST="$SRC_DEV_SNAPS/dev-latest"

sudo btrfs property set "$SRC_DEV_LATEST" ro true

SNAP_NAME_DEV="dev-$DATE"
DEST_DEV_SNAP="$DEST_DEV/$SNAP_NAME_DEV"

echo "[DEV] Sending FULL snapshot → $DEST_DEV_SNAP" >> "$LOGFILE"
sudo btrfs send "$SRC_DEV_LATEST" | sudo btrfs receive "$DEST_DEV"

retain_last_7 "$DEST_DEV"

############################################
### ANALYSIS SECTION
############################################
echo "" >> "$LOGFILE"
echo "=== Disk usage (df -h) ===" >> "$LOGFILE"
df -h /backup >> "$LOGFILE"

echo "" >> "$LOGFILE"
echo "=== Completed successfully ===" >> "$LOGFILE"

exit 0