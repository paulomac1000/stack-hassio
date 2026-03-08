---
description: How to develop features or modify Hassio code safely
---

# Hassio — Development Rules

Follow these guidelines to maintain a stable smart-home environment.

## Architecture Invariants

> [!IMPORTANT]
> These rules are non-negotiable.

| Invariant | Rule |
|-----------|------|
| **YAML LINTING** | All `.yaml` files must pass `yamllint`. Use `.yamllint.yml` for configuration. |
| **DOCKER COMPOSE** | Never break the `2.4` version requirement. It is needed for CPU/Memory limits. |
| **LOGGING** | All services should log to `stdout` for `vector` or `docker logs` collection. |
| **SECURITY** | Never commit `.env` or plain-text secrets. Use `${VARIABLE}` syntax and update `.env.example`. |

## Mandatory Verification

Before committing changes, run:

```bash
# Verify YAML syntax
yamllint .

# Verify Docker Compose config
docker compose config --quiet

# Run the test suite
./scripts/run-tests.sh
```

## Git Workflow

- **Branching**: Use feature branches. Never push directly to `main`.
- **Commits**: Summarize changes clearly. Always get user approval before committing/pushing.
- **Secrets**: Check `git status` to ensure `.env` or other sensitive files are not staged.

## Common Pitfalls

- **Path Mismatch**: Ensure volume mounts in `docker-compose.yml` use relative paths (`./data/...`) unless absolute paths are required for system access (e.g., `/run/udev`).
- **Healthcheck Overheads**: AI model loading (Vosk, YOLO) can take several minutes. Ensure `start_period` in healthchecks is generous.
- **CPU Saturation**: Avoid simultaneous startup of multiple heavy services (Vosk, YOLO, HA). Use `depends_on` as an artificial delay mechanism.

## Testing & Troubleshooting

If a service fails to start:
1. Check logs: `docker compose logs <service_name>`
2. Verify hardware: `ls -l /dev/serial/by-id/` (for Zigbee)
3. Check memory: `free -m` (AI models are RAM intensive)
