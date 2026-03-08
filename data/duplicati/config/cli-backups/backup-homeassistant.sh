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
