#!/bin/bash

SERVICE="$1"
STATUS="$(systemctl show -p ExecMainStatus "$SERVICE" | cut -d= -f2)"

if [[ "$STATUS" != "0" ]]; then
    {
        echo "❌ BTRFS BACKUP SERVICE FAILURE"
        echo "Service     : $SERVICE"
        echo "Exit status : $STATUS"
        echo "Date        : $(date)"
    } | mail -s "❌ Backup FAILED — $SERVICE" myemailadress
fi