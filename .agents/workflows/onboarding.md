---
description: Agent onboarding for Hassio — start here to understand the smart home stack
---

# Hassio — Agent Onboarding

Welcome! This repository manages a complex Home Assistant (Hassio) stack with AI-powered voice and object detection. Read this before modifying any configuration.

## What Is This Project?

A containerized Home Assistant ecosystem including:
- **Home Assistant**: The core automation engine.
- **Zigbee2MQTT**: Hardware interface for Zigbee devices.
- **Mosquitto**: MQTT broker for inter-service communication.
- **Vosk & Porcupine**: Local voice assistant (STT and Wake Word).
- **YOLOv5**: Real-time object detection via MQTT.
- **Cloudflared**: Secure remote access tunnel.

## Key Files & Directories

| Path | Purpose | Why? |
|------|---------|------|
| `docker-compose.yml` | Service orchestration | Defines dependencies and resource limits for the entire stack. |
| `data/` | Persistent storage | Keeps configuration and databases safe across container restarts. |
| `data/hassio/` | HA Configuration | Where `configuration.yaml` and YAML automations live. |
| `data/z2m/` | Zigbee2MQTT data | Device pairings and network map. |
| `yolov5-app/` | YOLO Service source | Custom Flask/Python wrapper for object detection. |
| `scripts/run-tests.sh` | Validation script | Ensures the environment and configuration are sound. |
| `agents.md` | Agent Index | This is your map for working with this repo. |

## Startup Sequence

The stack uses artificial dependencies (`depends_on`) in `docker-compose.yml` to prevent CPU spikes on startup (important for low-power hosts):

1. **Infrastructure**: Mosquitto (MQTT) and Filebrowser.
2. **AI Engines**: Vosk (Language model loading is heavy).
3. **Wake Word**: Porcupine (Waits for Vosk).
4. **Hardware**: Zigbee2MQTT.
5. **Services**: Satellite & YOLOv5.
6. **Core**: Home Assistant (Waits for all the above).

## Verification (ALWAYS do this first)

```bash
# Check service health
docker compose ps

# Run basic tests
./scripts/run-tests.sh
```

## Knowledge Retention

Store all new workflows or troubleshooting guides in `.agents/workflows/`. Subsequent agents rely on your documentation to stay productive.
