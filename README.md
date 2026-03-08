# Smart Home Stack — Home Assistant

Infrastructure as Code for a Docker-based home automation system built on Home Assistant.

## Architecture

Docker Compose stack containing:

- **Home Assistant** — Core home automation platform
- **Zigbee2MQTT** — Zigbee device bridge
- **Mosquitto** — MQTT broker
- **Vosk** — Speech-to-text (Wyoming protocol)
- **Porcupine** — Wake word detection
- **Wyoming Satellite** — Voice satellite
- **YOLO** — Object detection (ML)
- **Filebrowser** — File management UI
- **Cloudflared** — Cloudflare Tunnel for remote access

## Requirements

- Docker & Docker Compose
- Linux host (tested on Debian/Ubuntu)
- Min. 4 GB RAM
- Min. 32 GB free disk space

## Installation

### 1. Clone the repository

```bash
git clone git@github.com:paulomac1000/stack-hassio.git
cd stack-hassio
```

### 2. Configure environment variables

```bash
cp .env.example .env
nano .env
```

### 3. Configure Home Assistant secrets

```bash
cp data/hassio/secrets.example.yaml data/hassio/secrets.yaml
nano data/hassio/secrets.yaml
```

### 4. Start the stack

```bash
docker-compose up -d
```

### 5. Open Home Assistant

```text
http://your-host-ip:8123
```

## Project Structure

```text
.
├── docker-compose.yml          # Main Docker Compose configuration
├── .env.example                # Environment variable template
├── yolov5-app/                 # YOLO object detection service
│   ├── Dockerfile
│   ├── app.py
│   └── requirements.txt
└── data/                       # Service data and configuration
    ├── hassio/                 # Home Assistant
    │   ├── configuration.yaml
    │   ├── automations.yaml
    │   ├── scripts.yaml
    │   ├── secrets.yaml        # NOT committed (contains secrets)
    │   ├── themes/
    │   ├── blueprints/
    │   └── custom_components/
    ├── z2m/                    # Zigbee2MQTT
    │   ├── configuration.yaml
    │   └── devices.yaml
    ├── mqtt/                   # Mosquitto
    ├── satellite/              # Wyoming satellite
    └── filebrowser/            # Filebrowser config
```

## Security

### Files NOT committed to the repository

- `.env` — environment variables (contains tokens)
- `data/hassio/secrets.yaml` — HA secrets
- `data/hassio/.storage/` — tokens, auth, certificates
- `*.db` — databases
- `*.log` — logs
- `data/hassio/backups/` — backups
- `data/hassio/www/archive/` — camera recordings
- ML models (`.pt`, `.mdl`)

### Configuration templates

- `.env.example` — environment variable template
- `data/hassio/secrets.example.yaml` — secrets template

## Management

### Check service status

```bash
docker-compose ps
```

### Restart a service

```bash
docker-compose restart homeassistant
```

### View logs

```bash
docker-compose logs -f homeassistant
```

### Manual backup

```bash
cd data/hassio
tar -czf backup-$(date +%Y%m%d).tar.gz \
  configuration.yaml automations.yaml scripts.yaml \
  themes/ blueprints/ custom_components/
```

## Testing

The project includes unit and integration tests.

### 1. Tests in VS Code

With the included `.vscode/settings.json`, tests are automatically discovered in the **Testing** tab (flask icon).

### 2. Run tests manually

```bash
# Unit tests
pytest tests/test_heating_macros.py yolov5-app/test_app.py -v

# Integration tests (requires running services)
pytest tests/test_integration.py -v
```

### 3. CI script

```bash
./scripts/run-tests.sh --unit
./scripts/run-tests.sh --integration
```

## Commit Conventions

- `feat:` — new feature
- `fix:` — bug fix
- `chore:` — infrastructure changes
- `docs:` — documentation

## Advanced Configuration

### Cloudflare Tunnel

In `.env` set:

```bash
TUNNEL_TOKEN=your_cloudflare_tunnel_token
```

### MQTT

Default settings:

- Host: `mosquitto`
- Port: `1883`
- Username/Password: configured in `.env`

## Contributing

1. Fork the repository
2. Create a branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'feat: add amazing feature'`)
4. Push the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

MIT License — free to use, modify, and distribute.

## Credits

- [Home Assistant](https://www.home-assistant.io/)
- [Zigbee2MQTT](https://www.zigbee2mqtt.io/)
- Open source community

---

**Note:** This repository contains only configuration (Infrastructure as Code).
Runtime data (databases, logs, recordings) is excluded via `.gitignore`.
