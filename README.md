# Smart Home Stack - Home Assistant

Infrastructure as Code dla systemu automatyki domowej opartego na Home Assistant.

## 🏗️ Architektura

Stack oparty na Docker Compose zawierający:

- **Home Assistant** - Główny system automatyki domowej
- **Zigbee2MQTT** - Obsługa urządzeń Zigbee
- **Mosquitto** - Broker MQTT
- **Vosk** - Rozpoznawanie mowy (speech-to-text)
- **YOLO** - Detekcja obiektów (machine learning)
- **Duplicati** - Backup
- **Filebrowser** - Zarządzanie plikami

## 📋 Wymagania

- Docker & Docker Compose
- Linux host (testowane na Debian/Ubuntu)
- Min. 4GB RAM
- Min. 32GB wolnego miejsca na dysku

## 🚀 Instalacja

### 1. Sklonuj repozytorium

```bash
git clone git@github.com:paulomac1000/stack-hassio.git
cd stack-hassio
```

### 2. Skonfiguruj zmienne środowiskowe

```bash
cp .env.example .env
nano .env
```

### 3. Skonfiguruj sekrety Home Assistant

```bash
cp data/hassio/secrets.example.yaml data/hassio/secrets.yaml
nano data/hassio/secrets.yaml
```

### 4. Uruchom stack

```bash
docker-compose up -d
```

### 5. Otwórz Home Assistant

```
http://your-host-ip:8123
```

## 📁 Struktura projektu

```
.
├── docker-compose.yml          # Główna konfiguracja Docker Compose
├── .env.example                # Szablon zmiennych środowiskowych
├── yolov5-app/                 # Aplikacja YOLO do detekcji obiektów
│   ├── Dockerfile
│   ├── app.py
│   └── requirements.txt
└── data/                       # Dane i konfiguracje usług
    ├── hassio/                 # Home Assistant
    │   ├── configuration.yaml
    │   ├── automations.yaml
    │   ├── scripts.yaml
    │   ├── secrets.yaml        # NIE commitowane (secrets!)
    │   ├── themes/
    │   ├── blueprints/
    │   └── custom_components/
    ├── z2m/                    # Zigbee2MQTT
    │   ├── configuration.yaml
    │   └── devices.yaml
    ├── mqtt/                   # Mosquitto
    ├── vosk/                   # Vosk STT
    ├── satellite/              # Wyoming satellite
    └── duplicati/              # Backup
```

## 🔒 Bezpieczeństwo

### Pliki NIE commitowane do repozytorium:

- `.env` - zmienne środowiskowe (zawiera tokeny)
- `data/hassio/secrets.yaml` - sekrety HA
- `data/hassio/.storage/` - tokeny, auth, certyfikaty
- `*.db` - bazy danych
- `*.log` - logi
- `data/hassio/backups/` - kopie zapasowe
- `data/hassio/www/archive/` - nagrania z kamer
- Modele ML (`.pt`, `.mdl`)

### Szablony do konfiguracji:

- `.env.example` - wzór zmiennych środowiskowych
- `data/hassio/secrets.example.yaml` - wzór sekretów

## 🛠️ Zarządzanie

### Sprawdź status usług

```bash
docker-compose ps
```

### Restart usługi

```bash
docker-compose restart homeassistant
```

### Logi

```bash
docker-compose logs -f homeassistant
```

### Backup

Duplicati automatycznie tworzy backup codziennie o 2:00.

Ręczny backup:
```bash
cd data/hassio
tar -czf backup-$(date +%Y%m%d).tar.gz \
  configuration.yaml automations.yaml scripts.yaml \
  themes/ blueprints/ custom_components/
```

## 🧪 Testowanie

Projekt zawiera testy jednostkowe i integracyjne.

### 1. Testy w VS Code
Dzięki dodanej konfiguracji `.vscode/settings.json`, testy są automatycznie wykrywane w karcie **Testing** (ikona probówki) w VS Code.

### 2. Automatyczne testy przy starcie
Podczas uruchamiania stacka (`docker compose up`), automatycznie uruchamia się usługa `unit-tests`, która sprawdza poprawność logiki w kontenerze. Wyniki zobaczysz w logach.

### 3. Ręczne uruchamianie testów
```bash
# Wszystkie testy (wymaga kontenera testowego)
./scripts/run-tests.sh --unit

# Testy integracyjne (wymaga działających usług, np. Mosquitto)
./scripts/run-tests.sh --integration
```

## 📝 Konwencje

### Commitowanie zmian

Tylko pliki konfiguracyjne i kod:

```bash
git add data/hassio/configuration.yaml
git add data/hassio/automations.yaml
git commit -m "feat: add new automation for lights"
git push
```

### Nazewnictwo commitów

- `feat:` - nowa funkcjonalność
- `fix:` - poprawka błędu
- `chore:` - zmiany infrastrukturalne
- `docs:` - dokumentacja

## 🔧 Konfiguracja zaawansowana

### Cloudflare Tunnel

W `.env` ustaw:
```bash
TUNNEL_TOKEN=your_cloudflare_tunnel_token
```

### MQTT

Domyślnie:
- Host: `mosquitto`
- Port: `1883`
- Username/Password: w `.env`

## 🤝 Kontrybuowanie

1. Fork repozytorium
2. Stwórz branch (`git checkout -b feature/amazing-feature`)
3. Commit zmian (`git commit -m 'feat: add amazing feature'`)
4. Push do brancha (`git push origin feature/amazing-feature`)
5. Otwórz Pull Request

## 📄 Licencja

MIT License - możesz swobodnie używać, modyfikować i dystrybuować.

## 🙏 Podziękowania

- [Home Assistant](https://www.home-assistant.io/)
- [Zigbee2MQTT](https://www.zigbee2mqtt.io/)
- Społeczność open source

---

**Uwaga:** To repozytorium zawiera tylko konfigurację (Infrastructure as Code).
Runtime data (bazy danych, logi, nagrania) są ignorowane przez `.gitignore`.
