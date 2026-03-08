#!/bin/bash
# =============================================================================
# DUPLICATI JOB CONFIGURATOR
# =============================================================================
# Automatically imports backup job definitions from JSON files
# Uses Duplicati REST API for programmatic configuration
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
DUPLICATI_API="http://127.0.0.1:8200/api/v1"
JOBS_DIR="/config/jobs"
LOG_FILE="/config/logs/job-configurator.log"
MAX_RETRIES=30
RETRY_INTERVAL=5

# =============================================================================
# LOGGING
# =============================================================================
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# =============================================================================
# API FUNCTIONS
# =============================================================================
api_ready() {
    curl -sf "${DUPLICATI_API}/systeminfo" >/dev/null 2>&1
}

wait_for_api() {
    log_info "Waiting for Duplicati API to become available..."

    local attempt=1
    while [ $attempt -le $MAX_RETRIES ]; do
        if api_ready; then
            log_info "Duplicati API is ready (attempt $attempt)"
            return 0
        fi

        log_info "  Attempt $attempt/$MAX_RETRIES - API not ready, waiting ${RETRY_INTERVAL}s..."
        sleep $RETRY_INTERVAL
        attempt=$((attempt + 1))
    done

    log_error "Duplicati API did not become available after $MAX_RETRIES attempts"
    return 1
}

api_get() {
    local endpoint="$1"
    curl -sf "${DUPLICATI_API}/${endpoint}" 2>/dev/null
}

api_post() {
    local endpoint="$1"
    local data="$2"

    curl -sf -X POST \
        -H "Content-Type: application/json" \
        -d "$data" \
        "${DUPLICATI_API}/${endpoint}" 2>/dev/null
}

api_put() {
    local endpoint="$1"
    local data="$2"

    curl -sf -X PUT \
        -H "Content-Type: application/json" \
        -d "$data" \
        "${DUPLICATI_API}/${endpoint}" 2>/dev/null
}

api_delete() {
    local endpoint="$1"
    curl -sf -X DELETE "${DUPLICATI_API}/${endpoint}" 2>/dev/null
}

# =============================================================================
# JOB MANAGEMENT
# =============================================================================
get_existing_jobs() {
    api_get "backups" | grep -o '"Name":"[^"]*"' | cut -d'"' -f4 || echo ""
}

job_exists() {
    local job_name="$1"
    local existing
    existing=$(get_existing_jobs)

    echo "$existing" | grep -q "^${job_name}$"
}

get_job_id_by_name() {
    local job_name="$1"

    api_get "backups" | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
for backup in data:
    if backup.get('Backup', {}).get('Name') == '$job_name':
        print(backup.get('Backup', {}).get('ID', ''))
        break
" 2>/dev/null || echo ""
}

import_job() {
    local job_file="$1"
    local job_name
    local job_id

    if [ ! -f "$job_file" ]; then
        log_error "Job file not found: $job_file"
        return 1
    fi

    # Extract job name from JSON
    job_name=$(python3 -c "import json; print(json.load(open('$job_file'))['Backup']['Name'])" 2>/dev/null)

    if [ -z "$job_name" ]; then
        log_error "Could not extract job name from $job_file"
        return 1
    fi

    log_info "Processing job: $job_name"

    # Check if job already exists
    if job_exists "$job_name"; then
        log_info "  Job '$job_name' already exists, updating..."

        job_id=$(get_job_id_by_name "$job_name")
        if [ -n "$job_id" ]; then
            # Update existing job
            if api_put "backup/${job_id}" "$(cat "$job_file")"; then
                log_info "  Job '$job_name' updated successfully"
                return 0
            else
                log_warn "  Failed to update job '$job_name', will recreate"
                api_delete "backup/${job_id}" || true
            fi
        fi
    fi

    # Create new job
    log_info "  Creating job '$job_name'..."

    if api_post "backups" "$(cat "$job_file")"; then
        log_info "  Job '$job_name' created successfully"
        return 0
    else
        log_error "  Failed to create job '$job_name'"
        return 1
    fi
}

# =============================================================================
# ALTERNATIVE: Direct SQLite Configuration
# =============================================================================
# Duplicati stores everything in SQLite. We can configure jobs directly
# if the API approach fails. This is more fragile but works offline.

configure_via_sqlite() {
    local db_file="/config/Duplicati-server.sqlite"

    if [ ! -f "$db_file" ]; then
        log_warn "Duplicati database not found, skipping SQLite configuration"
        return 1
    fi

    log_info "Configuring jobs via SQLite (fallback method)..."

    # This requires understanding Duplicati's schema
    # Tables: Backup, Schedule, Filter, Option, etc.
    # Complex relationships - API is preferred

    log_warn "SQLite direct configuration not implemented (use API instead)"
    return 1
}

# =============================================================================
# ALTERNATIVE: CLI-based Backup Definitions
# =============================================================================
# Create wrapper scripts that call duplicati-cli directly

create_cli_wrappers() {
    log_info "Creating CLI wrapper scripts..."

    local wrapper_dir="/config/cli-backups"
    mkdir -p "$wrapper_dir"

    # HomeAssistant backup wrapper
    cat > "$wrapper_dir/backup-homeassistant.sh" << 'WRAPPER_EOF'
#!/bin/bash
# Direct CLI backup for Home Assistant

set -euo pipefail

# Pre-backup: create snapshots
/config/scripts/pre-backup.sh

# Run backup
mono /app/duplicati/Duplicati.CommandLine.exe backup \
    "file:///backups/homeassistant" \
    "/staging/home-assistant_v2.db" \
    "/source/homeassistant/" \
    --backup-name="HomeAssistant-CLI" \
    --dbpath="/config/homeassistant-backup.sqlite" \
    --exclude="*/home-assistant_v2.db*" \
    --exclude="*/deps/" \
    --exclude="*/tts/" \
    --exclude="*/__pycache__/" \
    --exclude="*/.cache/" \
    --exclude="*.log" \
    --exclude="*.log.*" \
    --zip-compression-level=1 \
    --blocksize=50kb \
    --concurrency-max-threads=1 \
    --asynchronous-upload=false \
    --retention-policy="1W:1D,4W:1W,12M:1M" \
    --disable-module=console-password-input \
    "$@"

# Post-backup: cleanup and notify
/config/scripts/post-backup.sh
WRAPPER_EOF

    chmod +x "$wrapper_dir/backup-homeassistant.sh"

    # Zigbee2MQTT backup wrapper
    cat > "$wrapper_dir/backup-zigbee2mqtt.sh" << 'WRAPPER_EOF'
#!/bin/bash
# Direct CLI backup for Zigbee2MQTT

set -euo pipefail

mono /app/duplicati/Duplicati.CommandLine.exe backup \
    "file:///backups/zigbee2mqtt" \
    "/source/zigbee2mqtt/" \
    --backup-name="Zigbee2MQTT-CLI" \
    --dbpath="/config/zigbee2mqtt-backup.sqlite" \
    --exclude="*.log" \
    --exclude="log/" \
    --zip-compression-level=1 \
    --blocksize=50kb \
    --concurrency-max-threads=1 \
    --keep-versions=10 \
    --disable-module=console-password-input \
    "$@"
WRAPPER_EOF

    chmod +x "$wrapper_dir/backup-zigbee2mqtt.sh"

    log_info "CLI wrappers created in $wrapper_dir"
}

# =============================================================================
# CRON SCHEDULER SETUP
# =============================================================================
setup_cron_schedule() {
    log_info "Setting up cron schedules..."

    local cron_file="/etc/crontabs/root"
    local cron_dir="/config/cron"

    mkdir -p "$cron_dir"

    # Create crontab entries
    cat > "$cron_dir/backup-schedule" << 'CRON_EOF'
# =============================================================================
# DUPLICATI BACKUP SCHEDULE
# Generated automatically - do not edit manually
# =============================================================================

# HomeAssistant: Daily at 3:00 AM
0 3 * * * /config/cli-backups/backup-homeassistant.sh >> /config/logs/cron-ha.log 2>&1

# Zigbee2MQTT: Wednesday at 4:00 AM
0 4 * * 3 /config/cli-backups/backup-zigbee2mqtt.sh >> /config/logs/cron-z2m.log 2>&1

# Mosquitto: 1st of month at 4:30 AM
30 4 1 * * /config/cli-backups/backup-mosquitto.sh >> /config/logs/cron-mqtt.log 2>&1

# HA Config Only: Every 6 hours
0 */6 * * * /config/cli-backups/backup-ha-config.sh >> /config/logs/cron-config.log 2>&1

# Cleanup old logs: Weekly on Sunday at 5:00 AM
0 5 * * 0 find /config/logs -name "*.log" -mtime +30 -delete 2>/dev/null
CRON_EOF

    log_info "Cron schedule created at $cron_dir/backup-schedule"
    log_info "Note: LinuxServer container manages cron internally via Duplicati scheduler"
}

# =============================================================================
# MAIN CONFIGURATION FLOW
# =============================================================================
configure_all_jobs() {
    log_info "============================================================"
    log_info "DUPLICATI JOB CONFIGURATOR - Starting"
    log_info "============================================================"

    # Ensure directories exist
    mkdir -p "$JOBS_DIR" "$(dirname "$LOG_FILE")"

    # Check for job definition files
    local job_count
    job_count=$(find "$JOBS_DIR" -name "*.json" 2>/dev/null | wc -l)

    if [ "$job_count" -eq 0 ]; then
        log_warn "No job definition files found in $JOBS_DIR"
        log_info "Creating CLI wrappers as fallback..."
        create_cli_wrappers
        return 0
    fi

    log_info "Found $job_count job definition(s)"

    # Wait for API
    if ! wait_for_api; then
        log_warn "API not available, falling back to CLI wrappers"
        create_cli_wrappers
        setup_cron_schedule
        return 0
    fi

    # Import all jobs
    local success_count=0
    local fail_count=0

    for job_file in "$JOBS_DIR"/*.json; do
        if [ -f "$job_file" ]; then
            if import_job "$job_file"; then
                success_count=$((success_count + 1))
            else
                fail_count=$((fail_count + 1))
            fi
        fi
    done

    log_info "============================================================"
    log_info "Job import complete: $success_count success, $fail_count failed"
    log_info "============================================================"

    # Also create CLI wrappers as backup option
    create_cli_wrappers

    return 0
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    configure_all_jobs
fi
