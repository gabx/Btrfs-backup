#!/bin/bash

LOG_DIR="/backup/analysis_daily"

LATEST="$(ls -1t "$LOG_DIR" | head -n 1)"
FILE="$LOG_DIR/$LATEST"

if grep -q "❌" "$FILE"; then
    SUBJECT="❌ Backup VERIFY FAILED"
else
    SUBJECT="✅ Backup VERIFY OK"
fi

mail -s "$SUBJECT" myemailadress < "$FILE"