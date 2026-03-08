#!/bin/bash
# =============================================================================
# DUPLICATI PRE-BACKUP HOOK
# =============================================================================
# Called by Duplicati BEFORE each backup job starts
#
# Available Duplicati environment variables:
#   DUPLICATI__BACKUP_NAME        - Name of the backup job
#   DUPLICATI__BACKUP_ID          - ID of the backup job
#   DUPLICATI__OPERATIONNAME      - Operation type (Backup, Restore, etc.)
#   DUPLICATI__REMOTEURL          - Target URL
#   DUPLICATI__LOCALPATH          - Source paths (semicolon separated)
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
LOG_FILE="/config/logs/backup-hooks.log"
STAGING_DIR="/staging"
HA_URL="${HA_URL:-}"
HA_TOKEN="${HA_TOKEN:-}"

# =============================================================================
# LOGGING
# =============================================================================
mkdir -p "$(dirname "$LOG_FILE")" "$STAGING_DIR"

log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [PRE-BACKUP] [$level] $*" | tee -a "$LOG_FILE"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# =============================================================================
# HOME ASSISTANT API
# =============================================================================
ha_api_available() {
    [ -n "$HA_URL" ] && [ -n "$HA_TOKEN" ]
}

ha_update_sensor() {
    if ! ha_api_available; then
        return 0
    fi

    local entity_id="$1"
    local state="$2"
    local attributes="${3:-{}}"

    curl -s -X POST \
        -H "Authorization: Bearer $HA_TOKEN" \
        -H "Content-Type: application/json" \
        --connect-timeout 5 \
        --max-time 10 \
        -d "{\"state\": \"$state\", \"attributes\": $attributes}" \
        "${HA_URL}/api/states/$entity_id" >/dev/null 2>&1 || {
            log_warn "Failed to update HA sensor: $entity_id"
            return 1
        }

    log_info "Updated HA sensor: $entity_id = $state"
    return 0
}

ha_notify() {
    if ! ha_api_available; then
        return 0
    fi

    local title="$1"
    local message="$2"

    curl -s -X POST \
        -H "Authorization: Bearer $HA_TOKEN" \
        -H "Content-Type: application/json" \
        --connect-timeout 5 \
        --max-time 10 \
        -d "{\"title\": \"$title\", \"message\": \"$message\"}" \
        "${HA_URL}/api/services/persistent_notification/create" >/dev/null 2>&1 || true
}

# =============================================================================
# SAFETY CHECKS
# =============================================================================
check_disk_space() {
    local min_space_mb="${MIN_FREE_SPACE_MB:-2048}"

    for path in /backups /staging; do
        if [ -d "$path" ]; then
            local available_mb
            available_mb=$(df -BM "$path" 2>/dev/null | awk 'NR==2 {gsub("M",""); print $4}')

            if [ -n "$available_mb" ] && [ "$available_mb" -lt "$min_space_mb" ]; then
                log_error "Insufficient disk space on $path: ${available_mb}MB < ${min_space_mb}MB"
                ha_notify "⚠️ Backup Aborted" "Insufficient disk space on $path (${available_mb}MB free)"
                return 1
            fi
            log_info "Disk space OK: $path has ${available_mb}MB free"
        fi
    done

    return 0
}

check_system_load() {
    local max_load="${MAX_LOAD_AVERAGE:-2.0}"
    local load_1m

    load_1m=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0")

    if command -v bc &>/dev/null; then
        if echo "$load_1m > $max_load" | bc -l 2>/dev/null | grep -q 1; then
            log_warn "System load is high: $load_1m (max: $max_load)"
            log_info "Waiting 60 seconds for load to decrease..."
            sleep 60

            load_1m=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0")
            if echo "$load_1m > $max_load" | bc -l 2>/dev/null | grep -q 1; then
                log_error "System load still too high: $load_1m"
                return 1
            fi
        fi
    fi

    log_info "System load OK: $load_1m"
    return 0
}

# =============================================================================
# SQLITE SNAPSHOT FUNCTIONS
# =============================================================================
create_sqlite_snapshot() {
    local source_db="$1"
    local dest_db="$2"
    local name="$3"

    if [ ! -f "$source_db" ]; then
        log_warn "$name: Source database not found at $source_db"
        return 1
    fi

    log_info "$name: Creating snapshot..."

    # Method 1: SQLite backup API (safest, atomic)
    if command -v sqlite3 &>/dev/null; then
        if sqlite3 "$source_db" ".backup '$dest_db'" 2>/dev/null; then
            local size
            size=$(du -h "$dest_db" 2>/dev/null | cut -f1)
            log_info "$name: Snapshot created via sqlite3 ($size)"
            return 0
        else
            log_warn "$name: sqlite3 backup failed, falling back to file copy"
        fi
    fi

    # Method 2: File copy with WAL files
    if cp "$source_db" "$dest_db" 2>/dev/null; then
        # Also copy WAL and SHM files if they exist
        local wal_file="${source_db}-wal"
        local shm_file="${source_db}-shm"

        [ -f "$wal_file" ] && cp "$wal_file" "${dest_db}-wal" 2>/dev/null
        [ -f "$shm_file" ] && cp "$shm_file" "${dest_db}-shm" 2>/dev/null

        local size
        size=$(du -h "$dest_db" 2>/dev/null | cut -f1)
        log_info "$name: Snapshot created via file copy ($size)"
        return 0
    fi

    log_error "$name: Failed to create snapshot"
    return 1
}

create_all_snapshots() {
    log_info "=========================================="
    log_info "Creating database snapshots"
    log_info "=========================================="

    mkdir -p "$STAGING_DIR"

    local success_count=0
    local fail_count=0

    # Home Assistant database
    if create_sqlite_snapshot \
        "/source/homeassistant/home-assistant_v2.db" \
        "$STAGING_DIR/home-assistant_v2.db" \
        "Home Assistant DB"; then
        success_count=$((success_count + 1))
    else
        fail_count=$((fail_count + 1))
    fi

    # Zigbee2MQTT database
    if create_sqlite_snapshot \
        "/source/zigbee2mqtt/database.db" \
        "$STAGING_DIR/zigbee2mqtt-database.db" \
        "Zigbee2MQTT DB"; then
        success_count=$((success_count + 1))
    else
        fail_count=$((fail_count + 1))
    fi

    # Filebrowser database
    if create_sqlite_snapshot \
        "/source/filebrowser/database.db" \
        "$STAGING_DIR/filebrowser-database.db" \
        "Filebrowser DB"; then
        success_count=$((success_count + 1))
    else
        fail_count=$((fail_count + 1))
    fi

    # Fix permissions for Duplicati user
    chown -R "${PUID:-1000}:${PGID:-1000}" "$STAGING_DIR" 2>/dev/null || true

    log_info "Snapshots complete: $success_count success, $fail_count failed"

    return 0
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    local job_name="${DUPLICATI__BACKUP_NAME:-unknown}"
    local operation="${DUPLICATI__OPERATIONNAME:-Backup}"
    local timestamp
    timestamp=$(date -Iseconds)

    log_info "=========================================="
    log_info "PRE-BACKUP HOOK STARTED"
    log_info "=========================================="
    log_info "Job Name: $job_name"
    log_info "Operation: $operation"
    log_info "Timestamp: $timestamp"

    # Update HA sensor to "running"
    ha_update_sensor "sensor.backup_status" "running" \
        "{\"job_name\": \"$job_name\", \"operation\": \"$operation\", \"started_at\": \"$timestamp\", \"friendly_name\": \"Backup Status\", \"icon\": \"mdi:backup-restore\"}"

    # Run safety checks
    log_info "Running safety checks..."

    if ! check_disk_space; then
        log_error "Disk space check failed - aborting backup"
        ha_update_sensor "sensor.backup_status" "aborted" \
            "{\"job_name\": \"$job_name\", \"reason\": \"insufficient_disk_space\", \"friendly_name\": \"Backup Status\"}"
        exit 1
    fi

    if ! check_system_load; then
        log_warn "System load check failed - proceeding with caution"
        # Don't abort, just warn
    fi

    # Create fresh database snapshots
    create_all_snapshots

    log_info "=========================================="
    log_info "PRE-BACKUP HOOK COMPLETE"
    log_info "=========================================="

    exit 0
}

# Run main function
main "$@"
