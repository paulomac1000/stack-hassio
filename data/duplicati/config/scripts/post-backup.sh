#!/bin/bash
set -euo pipefail
LOG="/config/logs/backup-hooks.log"

RESULT="${DUPLICATI__PARSED_RESULT:-unknown}"
JOB="${DUPLICATI__BACKUP_NAME:-unknown}"
TIMESTAMP=$(date -Iseconds)

echo "[$(date '+%Y-%m-%d %H:%M:%S')] [POST-BACKUP] $JOB: $RESULT" >> "$LOG"

if [ -n "${HA_URL:-}" ] && [ -n "${HA_TOKEN:-}" ]; then
    case "$RESULT" in
        Success)
            STATUS="success"
            curl -s -X POST \
                -H "Authorization: Bearer $HA_TOKEN" \
                -H "Content-Type: application/json" \
                -d "{\"state\": \"$TIMESTAMP\", \"attributes\": {\"job_name\": \"$JOB\", \"friendly_name\": \"Last Successful Backup\"}}" \
                "${HA_URL}/api/states/sensor.backup_last_success" >/dev/null 2>&1 || true
            ;;
        Warning)
            STATUS="warning"
            ;;
        Error|Fatal)
            STATUS="failed"
            # Send notification
            curl -s -X POST \
                -H "Authorization: Bearer $HA_TOKEN" \
                -H "Content-Type: application/json" \
                -d "{\"title\": \"❌ Backup Failed\", \"message\": \"Job '$JOB' failed\"}" \
                "${HA_URL}/api/services/persistent_notification/create" >/dev/null 2>&1 || true
            ;;
        *)
            STATUS="unknown"
            ;;
    esac

    curl -s -X POST \
        -H "Authorization: Bearer $HA_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"state\": \"$STATUS\", \"attributes\": {\"job_name\": \"$JOB\", \"completed_at\": \"$TIMESTAMP\", \"result\": \"$RESULT\", \"friendly_name\": \"Backup Status\"}}" \
        "${HA_URL}/api/states/sensor.backup_status" >/dev/null 2>&1 || true
fi

# Cleanup old snapshots
find /staging -type f -mtime +1 -delete 2>/dev/null || true

echo "[$(date '+%Y-%m-%d %H:%M:%S')] [POST-BACKUP] Hooks complete" >> "$LOG"
exit 0
