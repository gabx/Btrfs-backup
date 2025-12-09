#!/bin/bash

SERVICE="$1"
LOG_DIR="/backup/analysis_daily"

LATEST="$(ls -1t $LOG_DIR/scrub-* | head -n 1)"
FILE="$LATEST"

if grep -qi "error" "$FILE"; then
    SUBJECT="❌ BTRFS SCRUB FOUND ERRORS — $SERVICE"
else
    SUBJECT="✅ BTRFS SCRUB OK — $SERVICE"
fi

mail -s "$SUBJECT" myemailadress < "$FILE"