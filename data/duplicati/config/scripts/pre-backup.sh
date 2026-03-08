#!/bin/bash
set -euo pipefail
LOG="/config/logs/backup-hooks.log"
STAGING="/staging"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] [PRE-BACKUP] Started: ${DUPLICATI__BACKUP_NAME:-unknown}" >> "$LOG"

# Update HA sensor
if [ -n "${HA_URL:-}" ] && [ -n "${HA_TOKEN:-}" ]; then
    curl -s -X POST \
        -H "Authorization: Bearer $HA_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"state\": \"running\", \"attributes\": {\"job_name\": \"${DUPLICATI__BACKUP_NAME:-unknown}\", \"started_at\": \"$(date -Iseconds)\", \"friendly_name\": \"Backup Status\"}}" \
        "${HA_URL}/api/states/sensor.backup_status" >/dev/null 2>&1 || true
fi

# Create fresh snapshots
mkdir -p "$STAGING"

if [ -f "/source/homeassistant/home-assistant_v2.db" ]; then
    if command -v sqlite3 &>/dev/null; then
        sqlite3 "/source/homeassistant/home-assistant_v2.db" ".backup '$STAGING/home-assistant_v2.db'" 2>/dev/null || \
            cp "/source/homeassistant/home-assistant_v2.db" "$STAGING/" 2>/dev/null
    else
        cp "/source/homeassistant/home-assistant_v2.db" "$STAGING/" 2>/dev/null
    fi
fi

if [ -f "/source/zigbee2mqtt/database.db" ]; then
    cp "/source/zigbee2mqtt/database.db" "$STAGING/zigbee2mqtt-database.db" 2>/dev/null
fi

chown -R "${PUID:-1000}:${PGID:-1000}" "$STAGING" 2>/dev/null || true

echo "[$(date '+%Y-%m-%d %H:%M:%S')] [PRE-BACKUP] Complete" >> "$LOG"
exit 0
