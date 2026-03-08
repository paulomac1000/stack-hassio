#!/usr/bin/env bash
# ==============================================================================
# Hassio Stack — Test Runner
# Runs tests inside a Docker container so the host needs no Python packages.
#
# Usage:
#   ./scripts/run-tests.sh            # unit tests (default)
#   ./scripts/run-tests.sh --unit     # unit tests only (fast, no services)
#   ./scripts/run-tests.sh --integration  # integration tests (needs services)
#   ./scripts/run-tests.sh --all      # unit + integration
#
# Prerequisites: Docker must be running.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE="hassio-tests:latest"
DOCKERFILE="$PROJECT_ROOT/tests/Dockerfile"

cd "$PROJECT_ROOT"

# ─── helpers ──────────────────────────────────────────────────────────────────

log()  { echo "▶ $*"; }
fail() { echo "✗ $*" >&2; exit 1; }

_build_image() {
    log "Building test image (uses layer cache — fast if deps unchanged)..."
    docker build -q -f "$DOCKERFILE" -t "$IMAGE" . || fail "Docker build failed"
    log "Image ready: $IMAGE"
}

_run_unit() {
    log "Running unit tests..."
    docker run --rm \
        -v "$PROJECT_ROOT:/app:ro" \
        -w /app \
        "$IMAGE" \
        pytest yolov5-app/test_app.py tests/test_heating_macros.py \
            -v --tb=short -p no:cacheprovider
}

_run_integration() {
    log "Starting Mosquitto for integration tests..."
    docker compose up -d mosquitto

    # Wait for mosquitto to be healthy (max 30s)
    log "Waiting for Mosquitto to be healthy..."
    for i in $(seq 1 30); do
        docker compose ps mosquitto 2>/dev/null | grep -q "healthy" && break
        [ "$i" -eq 30 ] && fail "Mosquitto did not become healthy in time"
        sleep 1
    done

    log "Running integration tests..."
    # Use host network so the container can reach mosquitto on 127.0.0.1:1883
    docker run --rm \
        --network host \
        -v "$PROJECT_ROOT:/app:ro" \
        -e MOSQUITTO_HOST=127.0.0.1 \
        -e MOSQUITTO_PORT=1883 \
        -w /app \
        "$IMAGE" \
        pytest tests/test_integration.py -v --tb=short -m integration \
            --timeout=60 -p no:cacheprovider

    log "Stopping Mosquitto..."
    docker compose stop mosquitto
}

# ─── mode selection ────────────────────────────────────────────────────────────

MODE="${1:---unit}"

case "$MODE" in
    --unit|-u)
        _build_image
        _run_unit
        ;;
    --integration|-i)
        _build_image
        _run_integration
        ;;
    --all|-a)
        _build_image
        _run_unit
        _run_integration
        ;;
    --help|-h)
        sed -n '2,12p' "$0" | sed 's/^# //'
        exit 0
        ;;
    *)
        fail "Unknown mode: $MODE. Use --unit, --integration, --all, or --help."
        ;;
esac

log "Done."
