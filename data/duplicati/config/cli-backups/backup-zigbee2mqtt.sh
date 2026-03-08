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
