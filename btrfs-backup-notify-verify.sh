#!/bin/bash

FILE="$1"

if [[ -z "$FILE" || ! -f "$FILE" ]]; then
    echo "No log file provided or file not found: $FILE" >&2
    exit 1
fi

if grep -q "❌" "$FILE"; then
    SUBJECT="❌ Backup VERIFY FAILED"
else
    SUBJECT="✅ Backup VERIFY OK"
fi

mail -s "$SUBJECT" arnaud.gaboury@gmail.com < "$FILE"
