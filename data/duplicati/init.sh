#!/bin/bash
# =============================================================================
# DUPLICATI IaC INITIALIZATION
# Run this once to set up the directory structure
# =============================================================================

set -euo pipefail

BASE_DIR="./data/duplicati"

echo "Creating Duplicati IaC directory structure..."

# Create directories
mkdir -p "$BASE_DIR"/{scripts,jobs,config,staging,logs}

# Set permissions
chmod +x "$BASE_DIR/scripts/"*.sh 2>/dev/null || true

# Verify structure
echo ""
echo "Directory structure:"
find "$BASE_DIR" -type d | head -20

echo ""
echo "Scripts:"
ls -la "$BASE_DIR/scripts/"

echo ""
echo "Job definitions:"
ls -la "$BASE_DIR/jobs/"

echo ""
echo "✅ Initialization complete!"
echo ""
echo "Next steps:"
echo "1. Add HA_LONG_LIVED_TOKEN to .env"
echo "2. Run: docker-compose up -d duplicati"
echo "3. Check logs: docker logs -f hass-duplicati"
echo "4. Verify jobs in UI: http://localhost:8200"
