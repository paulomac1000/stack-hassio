# Hassio — Agents & AI Workflows

This repository is optimized for AI coding agents. All workflow documentation is located in [`.agents/workflows/`](.agents/workflows/).

## Start Here Every Session

Read [`.agents/workflows/onboarding.md`](.agents/workflows/onboarding.md) first — it contains the project overview, key files, and mandatory first steps.

## Workflow Index

| File | Purpose |
|------|---------|
| [`onboarding.md`](.agents/workflows/onboarding.md) | Project overview, key services, and startup sequence |
| [`development.md`](.agents/workflows/development.md) | Architecture rules, git workflow, and verification steps |

## Project Architecture: What, Where & Why?

### 1. The Home Assistant Core (`/data/hassio`)
- **What**: The central controller.
- **Where**: `/data/hassio` mirrors `/config` in the container.
- **Why**: Keeps all your YAML configuration, scripts, and automations decoupled from the container image.

### 2. The MQTT Backbone (`/data/mqtt`)
- **What**: Mosquitto Broker.
- **Where**: `/data/mqtt/config` and `/data/mqtt/data`.
- **Why**: Handles communication between Zigbee2MQTT, YOLOv5, and Home Assistant. It's the "central nervous system".

### 3. Hardware Access (`Zigbee2MQTT`)
- **What**: Bridge between Zigbee devices and MQTT.
- **Where**: `/data/z2m`.
- **Why**: Allows controlling smart bulbs, sensors, and switches without vendor-specific clouds.

### 4. AI Voice Intelligence (`Vosk` & `Porcupine`)
- **What**: Speech-to-Text (STT) and Wake Word detection.
- **Where**: `rhasspy/wyoming-*` images in `docker-compose.yml`.
- **Why**: Provides local, private voice control for the home.

### 5. AI Vision (`YOLOv5`)
- **What**: Real-time object detection service.
- **Where**: Source in `./yolov5-app`, data in `/data/yolo`.
- **Why**: Detects people, cars, or custom objects to trigger automation (e.g., "turn on porch light if person detected").

## Key Paths

| Path | Description |
|------|-------------|
| `/media/MyBook/apps/hassio` | Project root (Host) |
| `./data/` | Persistent volumes (gitignored) |
| `.env` | API keys and secrets (gitignored) — See `.env.example` |
| `scripts/` | Tooling and validation scripts |

## Verification Plan

Always run `./scripts/run-tests.sh` before finalizing any changes to ensure no regressions in connectivity or configuration.
