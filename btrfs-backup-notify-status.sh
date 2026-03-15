SERVICE="$1"
STATUS="$(systemctl show -p ExecMainStatus "$SERVICE" | cut -d= -f2)"
DATE="$(date +%Y-%m-%d-%H%M)"
LOGFILE="$(ls -t /backup/analysis_daily/*.txt 2>/dev/null | head -1)"

if [[ "$STATUS" == "0" ]]; then
    SUBJECT="[OK] Backup magnolia — $DATE"
else
    SUBJECT="[ECHEC] Backup magnolia — $DATE"
fi

if [[ -f "$LOGFILE" ]]; then
    mail -s "$SUBJECT" -a "$LOGFILE" arnaud.gaboury@gmail.com < "$LOGFILE"
else
    echo "Backup status: $STATUS — log file not found." \
        | mail -s "$SUBJECT" arnaud.gaboury@gmail.com
fi