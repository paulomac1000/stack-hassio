#!/bin/bash
# =============================================================================
# DUPLICATI POST-BACKUP HOOK
# =============================================================================
# Called by Duplicati AFTER each backup job completes
#
# Available Duplicati environment variables:
#   DUPLICATI__BACKUP_NAME        - Name of the backup job
#   DUPLICATI__BACKUP_ID          - ID of the backup job
#   DUPLICATI__OPERATIONNAME      - Operation type (Backup, Restore, etc.)
#   DUPLICATI__REMOTEURL          - Target URL
#   DUPLICATI__LOCALPATH          - Source paths (semicolon separated)
#   DUPLICATI__PARSED_RESULT      - Result: Success, Warning, Error, Fatal
#   DUPLICATI__MAIN_ACTION        - Main action performed
#   DUPLICATI__MAIN_RESULT        - Detailed result message
#   DUPLICATI__EXTRA_EXITCODE     - Exit code (if error)
#
# Backup statistics (only for backup operations):
#   DUPLICATI__RESULTS_ADDEDFILES          - Number of new files
#   DUPLICATI__RESULTS_ADDEDFOLDERS        - Number of new folders
#   DUPLICATI__RESULTS_ADDEDSIZE           - Size of added data (bytes)
#   DUPLICATI__RESULTS_DELETEDFILES        - Number of deleted files
#   DUPLICATI__RESULTS_DELETEDFOLDERS      - Number of deleted folders
#   DUPLICATI__RESULTS_EXAMINEDFILES       - Total files examined
#   DUPLICATI__RESULTS_MODIFIEDFILES       - Number of modified files
#   DUPLICATI__RESULTS_SIZEOFADDEDFILES    - Total size of added files
#   DUPLICATI__RESULTS_SIZEOFEXAMINEDFILES - Total size examined
#   DUPLICATI__RESULTS_SIZEOFMODIFIEDFILES - Size of modified files
#   DUPLICATI__RESULTS_SIZEOFOPENDFILES    - Size of opened files
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
LOG_FILE="/config/logs/backup-hooks.log"
STAGING_DIR="/staging"
BACKUP_DIR="/backups"
HA_URL="${HA_URL:-}"
HA_TOKEN="${HA_TOKEN:-}"

# =============================================================================
# LOGGING
# =============================================================================
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [POST-BACKUP] [$level] $*" | tee -a "$LOG_FILE"
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
    local notification_id="${3:-backup_notification}"

    curl -s -X POST \
        -H "Authorization: Bearer $HA_TOKEN" \
        -H "Content-Type: application/json" \
        --connect-timeout 5 \
        --max-time 10 \
        -d "{\"title\": \"$title\", \"message\": \"$message\", \"notification_id\": \"$notification_id\"}" \
        "${HA_URL}/api/services/persistent_notification/create" >/dev/null 2>&1 || {
            log_warn "Failed to send HA notification"
            return 1
        }

    log_info "Sent HA notification: $title"
    return 0
}

ha_call_service() {
    if ! ha_api_available; then
        return 0
    fi

    local domain="$1"
    local service="$2"
    local data="${3:-{}}"

    curl -s -X POST \
        -H "Authorization: Bearer $HA_TOKEN" \
        -H "Content-Type: application/json" \
        --connect-timeout 5 \
        --max-time 10 \
        -d "$data" \
        "${HA_URL}/api/services/$domain/$service" >/dev/null 2>&1 || return 1

    return 0
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================
bytes_to_human() {
    local bytes="${1:-0}"

    if [ "$bytes" -lt 1024 ]; then
        echo "${bytes}B"
    elif [ "$bytes" -lt 1048576 ]; then
        echo "$((bytes / 1024))KB"
    elif [ "$bytes" -lt 1073741824 ]; then
        echo "$((bytes / 1048576))MB"
    else
        echo "$((bytes / 1073741824))GB"
    fi
}

get_backup_storage_info() {
    if [ -d "$BACKUP_DIR" ]; then
        local used total free percent

        used=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo "unknown")
        total=$(df -h "$BACKUP_DIR" 2>/dev/null | awk 'NR==2 {print $2}' || echo "unknown")
        free=$(df -h "$BACKUP_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo "unknown")
        percent=$(df "$BACKUP_DIR" 2>/dev/null | awk 'NR==2 {gsub("%",""); print $5}' || echo "0")

        echo "{\"used\": \"$used\", \"total\": \"$total\", \"free\": \"$free\", \"percent_used\": $percent, \"path\": \"$BACKUP_DIR\"}"
    else
        echo "{\"error\": \"backup directory not found\"}"
    fi
}

# =============================================================================
# CLEANUP FUNCTIONS
# =============================================================================
cleanup_staging() {
    log_info "Cleaning up staging directory..."

    if [ -d "$STAGING_DIR" ]; then
        # Remove snapshots older than 24 hours
        local deleted_count
        deleted_count=$(find "$STAGING_DIR" -type f -mtime +1 -delete -print 2>/dev/null | wc -l)

        if [ "$deleted_count" -gt 0 ]; then
            log_info "Deleted $deleted_count old snapshot(s)"
        fi

        # Show current staging usage
        local staging_size
        staging_size=$(du -sh "$STAGING_DIR" 2>/dev/null | cut -f1 || echo "unknown")
        log_info "Staging directory size: $staging_size"
    fi
}

cleanup_old_logs() {
    local log_dir="/config/logs"

    if [ -d "$log_dir" ]; then
        # Remove logs older than 30 days
        find "$log_dir" -name "*.log" -mtime +30 -delete 2>/dev/null || true

        # Rotate large log files
        for logfile in "$log_dir"/*.log; do
            if [ -f "$logfile" ]; then
                local size_kb
                size_kb=$(du -k "$logfile" 2>/dev/null | cut -f1 || echo "0")

                if [ "$size_kb" -gt 10240 ]; then  # > 10MB
                    log_info "Rotating large log file: $logfile (${size_kb}KB)"
                    mv "$logfile" "${logfile}.old" 2>/dev/null || true
                fi
            fi
        done
    fi
}

# =============================================================================
# RESULT PROCESSING
# =============================================================================
process_result() {
    local result="${DUPLICATI__PARSED_RESULT:-unknown}"
    local job_name="${DUPLICATI__BACKUP_NAME:-unknown}"
    local operation="${DUPLICATI__OPERATIONNAME:-unknown}"
    local timestamp
    timestamp=$(date -Iseconds)

    # Get backup statistics
    local added_files="${DUPLICATI__RESULTS_ADDEDFILES:-0}"
    local modified_files="${DUPLICATI__RESULTS_MODIFIEDFILES:-0}"
    local deleted_files="${DUPLICATI__RESULTS_DELETEDFILES:-0}"
    local examined_files="${DUPLICATI__RESULTS_EXAMINEDFILES:-0}"
    local added_size="${DUPLICATI__RESULTS_SIZEOFADDEDFILES:-0}"
    local examined_size="${DUPLICATI__RESULTS_SIZEOFEXAMINEDFILES:-0}"

    # Convert sizes to human-readable
    local added_size_human
    local examined_size_human
    added_size_human=$(bytes_to_human "$added_size")
    examined_size_human=$(bytes_to_human "$examined_size")

    # Get storage info
    local storage_info
    storage_info=$(get_backup_storage_info)

    log_info "=========================================="
    log_info "BACKUP RESULT: $result"
    log_info "=========================================="
    log_info "Job: $job_name"
    log_info "Operation: $operation"
    log_info "Files examined: $examined_files ($examined_size_human)"
    log_info "Files added: $added_files"
    log_info "Files modified: $modified_files"
    log_info "Files deleted: $deleted_files"
    log_info "Data added: $added_size_human"

    # Build attributes JSON
    local attributes
    attributes=$(cat <<EOF
{
    "job_name": "$job_name",
    "operation": "$operation",
    "result": "$result",
    "completed_at": "$timestamp",
    "files_examined": $examined_files,
    "files_added": $added_files,
    "files_modified": $modified_files,
    "files_deleted": $deleted_files,
    "data_added": "$added_size_human",
    "data_examined": "$examined_size_human",
    "friendly_name": "Backup Status",
    "icon": "mdi:backup-restore"
}
EOF
)

    case "$result" in
        Success)
            log_info "Backup completed successfully"

            # Update status sensor
            ha_update_sensor "sensor.backup_status" "success" "$attributes"

            # Update last success sensor
            ha_update_sensor "sensor.backup_last_success" "$timestamp" \
                "{\"job_name\": \"$job_name\", \"files_backed_up\": $((added_files + modified_files)), \"data_size\": \"$added_size_human\", \"friendly_name\": \"Last Successful Backup\", \"icon\": \"mdi:clock-check\"}"

            # Update storage sensor
            ha_update_sensor "sensor.backup_storage" \
                "$(echo "$storage_info" | grep -o '"used": "[^"]*"' | cut -d'"' -f4)" \
                "$storage_info"

            # Check if storage is getting low
            local percent_used
            percent_used=$(echo "$storage_info" | grep -o '"percent_used": [0-9]*' | cut -d: -f2 | tr -d ' ')

            if [ "${percent_used:-0}" -gt 85 ]; then
                log_warn "Backup storage is ${percent_used}% full!"
                ha_notify "⚠️ Backup Storage Low" \
                    "Backup drive is ${percent_used}% full. Consider cleaning up old backups." \
                    "backup_storage_warning"
            fi
            ;;

        Warning)
            log_warn "Backup completed with warnings"
            log_warn "Details: ${DUPLICATI__MAIN_RESULT:-no details}"

            ha_update_sensor "sensor.backup_status" "warning" "$attributes"

            ha_notify "⚠️ Backup Warning" \
                "Job '$job_name' completed with warnings. Check logs for details." \
                "backup_warning"
            ;;

        Error)
            log_error "Backup failed with error"
            log_error "Details: ${DUPLICATI__MAIN_RESULT:-no details}"
            log_error "Exit code: ${DUPLICATI__EXTRA_EXITCODE:-unknown}"

            ha_update_sensor "sensor.backup_status" "failed" "$attributes"

            ha_notify "❌ Backup Failed" \
                "Job '$job_name' failed: ${DUPLICATI__MAIN_RESULT:-unknown error}" \
                "backup_error"
            ;;

        Fatal)
            log_error "Backup failed with FATAL error"
            log_error "Details: ${DUPLICATI__MAIN_RESULT:-no details}"
            log_error "Exit code: ${DUPLICATI__EXTRA_EXITCODE:-unknown}"

            ha_update_sensor "sensor.backup_status" "fatal" "$attributes"

            ha_notify "🔴 Backup FATAL Error" \
                "Job '$job_name' encountered a fatal error and cannot continue: ${DUPLICATI__MAIN_RESULT:-unknown error}" \
                "backup_fatal"
            ;;

        *)
            log_warn "Unknown backup result: $result"

            ha_update_sensor "sensor.backup_status" "unknown" "$attributes"
            ;;
    esac
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    local job_name="${DUPLICATI__BACKUP_NAME:-unknown}"
    local result="${DUPLICATI__PARSED_RESULT:-unknown}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    log_info "=========================================="
    log_info "POST-BACKUP HOOK STARTED"
    log_info "=========================================="
    log_info "Job Name: $job_name"
    log_info "Result: $result"
    log_info "Timestamp: $timestamp"

    # Process the result and update HA
    process_result

    # Cleanup
    cleanup_staging
    cleanup_old_logs

    log_info "=========================================="
    log_info "POST-BACKUP HOOK COMPLETE"
    log_info "=========================================="

    # Always exit 0 so Duplicati doesn't consider the hook a failure
    exit 0
}

# Run main function
main "$@"
