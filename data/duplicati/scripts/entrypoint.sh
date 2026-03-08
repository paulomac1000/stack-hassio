#!/bin/bash
# =============================================================================
# DUPLICATI ENTRYPOINT - FULL IaC INTEGRATION
# =============================================================================
# Features:
# - HA API integration for monitoring
# - Automatic job configuration from JSON files
# - SQLite snapshot management
# - Safety checks before backups
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
HA_URL="${HA_URL:-}"
HA_TOKEN="${HA_TOKEN:-}"
MIN_FREE_SPACE_MB="${MIN_FREE_SPACE_MB:-2048}"
MAX_LOAD_AVERAGE="${MAX_LOAD_AVERAGE:-1.5}"
MIN_FREE_MEMORY_MB="${MIN_FREE_MEMORY_MB:-256}"

STAGING_DIR="/staging"
SCRIPTS_DIR="/config/scripts"
JOBS_DIR="/config/jobs"
LOG_DIR="/config/logs"
LOG_FILE="$LOG_DIR/entrypoint.log"

# =============================================================================
# SETUP
# =============================================================================
mkdir -p "$STAGING_DIR" "$SCRIPTS_DIR" "$JOBS_DIR" "$LOG_DIR"

log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# =============================================================================
# INSTALL DEPENDENCIES
# =============================================================================
install_dependencies() {
    if [ -f "/config/.deps_installed_v2" ]; then
        return 0
    fi

    log_info "Installing dependencies..."

    # Detect package manager
    if command -v apt-get &>/dev/null; then
        apt-get update -qq 2>/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            sqlite3 bc procps curl python3 cron >/dev/null 2>&1 || true
    elif command -v apk &>/dev/null; then
        apk add --no-cache sqlite bc procps curl python3 >/dev/null 2>&1 || true
    fi

    touch "/config/.deps_installed_v2"
    log_info "Dependencies installed"
}

# =============================================================================
# COPY JOB DEFINITIONS
# =============================================================================
copy_job_definitions() {
    log_info "Copying job definitions..."

    # Copy from mounted read-only jobs directory if it exists
    if [ -d "/custom-scripts/jobs" ]; then
        cp -r /custom-scripts/jobs/* "$JOBS_DIR/" 2>/dev/null || true
        log_info "Job definitions copied from /custom-scripts/jobs"
    fi

    # List jobs
    local count
    count=$(find "$JOBS_DIR" -name "*.json" 2>/dev/null | wc -l)
    log_info "Found $count job definition(s)"
}

# =============================================================================
# HA API FUNCTIONS
# =============================================================================
ha_api_available() {
    [ -n "$HA_URL" ] && [ -n "$HA_TOKEN" ]
}

ha_update_sensor() {
    [ -z "$HA_URL" ] || [ -z "$HA_TOKEN" ] && return 0

    local entity_id="$1"
    local state="$2"
    local attributes="${3:-{}}"

    curl -s -X POST \
        -H "Authorization: Bearer $HA_TOKEN" \
        -H "Content-Type: application/json" \
        --connect-timeout 5 \
        --max-time 10 \
        -d "{\"state\": \"$state\", \"attributes\": $attributes}" \
        "${HA_URL}/api/states/$entity_id" >/dev/null 2>&1 || true
}

init_ha_sensors() {
    if ! ha_api_available; then
        log_info "HA API not configured, skipping sensor init"
        return 0
    fi

    log_info "Initializing HA sensors..."

    ha_update_sensor "sensor.backup_status" "idle" \
        '{"friendly_name": "Backup Status", "icon": "mdi:backup-restore"}'

    ha_update_sensor "sensor.backup_last_success" "unknown" \
        '{"friendly_name": "Last Successful Backup", "icon": "mdi:clock-check"}'

    ha_update_sensor "sensor.backup_next_scheduled" "unknown" \
        '{"friendly_name": "Next Scheduled Backup", "icon": "mdi:calendar-clock"}'

    log_info "HA sensors initialized"
}

# =============================================================================
# SAFETY CHECKS
# =============================================================================
check_disk_space() {
    for path in /backups /staging /source; do
        if [ -d "$path" ]; then
            local available_mb
            available_mb=$(df -BM "$path" 2>/dev/null | awk 'NR==2 {gsub("M",""); print $4}')

            if [ -n "$available_mb" ] && [ "$available_mb" -lt "$MIN_FREE_SPACE_MB" ]; then
                log_error "Insufficient space on $path: ${available_mb}MB < ${MIN_FREE_SPACE_MB}MB"
                return 1
            fi
        fi
    done
    return 0
}

check_system_load() {
    local load_1m
    load_1m=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0")

    if command -v bc &>/dev/null; then
        if echo "$load_1m > $MAX_LOAD_AVERAGE" | bc -l 2>/dev/null | grep -q 1; then
            log_warn "System load high: $load_1m"
            return 1
        fi
    fi
    return 0
}

run_safety_checks() {
    log_info "Running safety checks..."

    local status="passed"

    if ! check_disk_space; then
        status="failed"
    fi

    if ! check_system_load; then
        status="warning"
    fi

    ha_update_sensor "sensor.backup_preflight_status" "$status" \
        "{\"last_check\": \"$(date -Iseconds)\", \"friendly_name\": \"Backup Pre-flight Status\"}"

    log_info "Safety checks: $status"
}

# =============================================================================
# SQLITE SNAPSHOTS
# =============================================================================
create_sqlite_snapshot() {
    local source_db="$1"
    local dest_db="$2"
    local name="$3"

    [ ! -f "$source_db" ] && return 1

    if command -v sqlite3 &>/dev/null; then
        if sqlite3 "$source_db" ".backup '$dest_db'" 2>/dev/null; then
            log_info "  $name: snapshot created (sqlite3)"
            return 0
        fi
    fi

    # Fallback: file copy
    cp "$source_db" "$dest_db" 2>/dev/null
    [ -f "${source_db}-wal" ] && cp "${source_db}-wal" "${dest_db}-wal" 2>/dev/null
    [ -f "${source_db}-shm" ] && cp "${source_db}-shm" "${dest_db}-shm" 2>/dev/null

    log_info "  $name: snapshot created (file copy)"
    return 0
}

create_all_snapshots() {
    log_info "Creating database snapshots..."

    mkdir -p "$STAGING_DIR"

    create_sqlite_snapshot \
        "/source/homeassistant/home-assistant_v2.db" \
        "$STAGING_DIR/home-assistant_v2.db" \
        "Home Assistant"

    create_sqlite_snapshot \
        "/source/zigbee2mqtt/database.db" \
        "$STAGING_DIR/zigbee2mqtt-database.db" \
        "Zigbee2MQTT"

    create_sqlite_snapshot \
        "/source/filebrowser/database.db" \
        "$STAGING_DIR/filebrowser-database.db" \
        "Filebrowser"

    # Fix permissions
    chown -R "${PUID:-1000}:${PGID:-1000}" "$STAGING_DIR" 2>/dev/null || true

    log_info "Database snapshots complete"
}

# =============================================================================
# CREATE HOOK SCRIPTS
# =============================================================================
create_hook_scripts() {
    log_info "Creating Duplicati hook scripts..."

    # Pre-backup hook
    cat > "$SCRIPTS_DIR/pre-backup.sh" << 'HOOK_EOF'
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
HOOK_EOF

    # Post-backup hook
    cat > "$SCRIPTS_DIR/post-backup.sh" << 'HOOK_EOF'
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
HOOK_EOF

    chmod +x "$SCRIPTS_DIR/pre-backup.sh" "$SCRIPTS_DIR/post-backup.sh"
    log_info "Hook scripts created"
}

# =============================================================================
# SET LOW PRIORITY
# =============================================================================
set_low_priority() {
    renice -n 19 $$ 2>/dev/null || true
    command -v ionice &>/dev/null && ionice -c 3 -p $$ 2>/dev/null || true
}

# =============================================================================
# BACKGROUND JOB CONFIGURATOR
# =============================================================================
start_job_configurator() {
    log_info "Starting background job configurator..."

    # Run in background after Duplicati starts
    (
        sleep 30  # Wait for Duplicati to fully start

        # Source the configure script
        if [ -f "/custom-scripts/configure-jobs.sh" ]; then
            bash /custom-scripts/configure-jobs.sh >> "$LOG_DIR/job-configurator.log" 2>&1
        elif [ -f "$SCRIPTS_DIR/configure-jobs.sh" ]; then
            bash "$SCRIPTS_DIR/configure-jobs.sh" >> "$LOG_DIR/job-configurator.log" 2>&1
        fi
    ) &

    log_info "Job configurator started in background (PID: $!)"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    log_info "============================================================"
    log_info "DUPLICATI IaC ENTRYPOINT"
    log_info "============================================================"

    install_dependencies
    set_low_priority
    copy_job_definitions
    create_hook_scripts
    run_safety_checks
    create_all_snapshots
    init_ha_sensors
    start_job_configurator

    log_info "============================================================"
    log_info "INITIALIZATION COMPLETE - Starting Duplicati..."
    log_info "============================================================"

    # Start Duplicati
    exec /init "$@"
}

main "$@"
