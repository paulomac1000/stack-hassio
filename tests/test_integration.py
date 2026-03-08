"""
Integration tests for the hassio Docker Compose stack.

These tests require running Docker services and are executed separately in CI
(only on push to main, after unit tests pass).

Prerequisites:
  - Docker and docker compose installed
  - Run from project root: pytest tests/test_integration.py -v --timeout=120

Services tested:
  - docker compose config validation
  - Mosquitto MQTT broker (must be running: docker compose up -d mosquitto)
  - Home Assistant config check (via Docker, uses secrets.example.yaml)
  - YOLOv5 service health endpoint (if running: docker compose up -d yolov5-service)
"""
import json
import os
import socket
import subprocess
import time

import pytest

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOSQUITTO_HOST = os.getenv('MOSQUITTO_HOST', '127.0.0.1')
MOSQUITTO_PORT = int(os.getenv('MOSQUITTO_PORT', '1883'))
YOLO_HOST = os.getenv('YOLO_HOST', '127.0.0.1')
YOLO_PORT = int(os.getenv('YOLO_PORT', '8071'))


# ===========================================================================
# Docker Compose validation (no services needed)
# ===========================================================================

class TestDockerComposeConfig:

    def test_compose_config_is_valid(self):
        """docker compose config must exit 0 (YAML syntax + env var substitution valid)."""
        result = subprocess.run(
            ['docker', 'compose', 'config', '--quiet'],
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, (
            f"docker compose config failed:\n{result.stderr}"
        )

    def test_compose_lists_expected_services(self):
        """All critical services must be defined in docker-compose.yml."""
        result = subprocess.run(
            ['docker', 'compose', 'config', '--services'],
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0
        services = result.stdout.strip().splitlines()
        for expected in ('mosquitto', 'homeassistant', 'zigbee2mqtt', 'yolov5-service'):
            assert expected in services, f"Service '{expected}' missing from docker-compose.yml"


# ===========================================================================
# Mosquitto MQTT broker
# ===========================================================================

@pytest.mark.integration
class TestMosquittoConnectivity:

    def test_tcp_connect(self):
        """Mosquitto must accept TCP connections on port 1883."""
        with socket.create_connection((MOSQUITTO_HOST, MOSQUITTO_PORT), timeout=5) as sock:
            assert sock is not None

    def test_mqtt_publish_subscribe(self):
        """Basic MQTT publish/subscribe round-trip."""
        paho_mqtt = pytest.importorskip('paho.mqtt.client')

        received = []
        topic = 'ci/test/integration'

        def on_message(client, userdata, msg):
            received.append(msg.payload.decode())

        client = paho_mqtt.Client(client_id='ci-test-sub')
        client.on_message = on_message
        client.connect(MOSQUITTO_HOST, MOSQUITTO_PORT, keepalive=10)
        client.subscribe(topic)
        client.loop_start()

        time.sleep(0.5)

        pub = paho_mqtt.Client(client_id='ci-test-pub')
        pub.connect(MOSQUITTO_HOST, MOSQUITTO_PORT)
        pub.publish(topic, 'hello-ci', qos=1)
        pub.disconnect()

        # Wait up to 5 seconds for message delivery
        deadline = time.time() + 5
        while not received and time.time() < deadline:
            time.sleep(0.1)

        client.loop_stop()
        client.disconnect()

        assert received == ['hello-ci'], f"Expected ['hello-ci'], got {received}"


# ===========================================================================
# Home Assistant config check
# ===========================================================================

@pytest.mark.integration
class TestHomeAssistantConfig:

    def test_ha_config_check(self):
        """
        Run HA's built-in config checker using the official Docker image.
        Uses secrets.example.yaml as a stub so no real secrets are needed.
        """
        config_dir = os.path.join(PROJECT_ROOT, 'data', 'hassio')
        secrets_example = os.path.join(config_dir, 'secrets.example.yaml')
        secrets_target = os.path.join(config_dir, 'secrets.yaml')

        # Use example file as stub if real secrets.yaml doesn't exist
        stub_created = False
        if not os.path.exists(secrets_target) and os.path.exists(secrets_example):
            import shutil
            shutil.copy(secrets_example, secrets_target)
            stub_created = True

        try:
            result = subprocess.run(
                [
                    'docker', 'run', '--rm',
                    '-v', f'{config_dir}:/config',
                    'ghcr.io/home-assistant/home-assistant:stable',
                    'python3', '-m', 'homeassistant',
                    '--script', 'check_config', '-c', '/config',
                ],
                capture_output=True,
                text=True,
                timeout=120,
            )
            # HA check_config outputs to stderr; exit 0 = valid
            assert result.returncode == 0, (
                f"HA config check failed (exit {result.returncode}):\n"
                f"stdout: {result.stdout}\n"
                f"stderr: {result.stderr}"
            )
        finally:
            if stub_created and os.path.exists(secrets_target):
                os.remove(secrets_target)


# ===========================================================================
# YOLOv5 service health endpoint
# ===========================================================================

@pytest.mark.integration
class TestYolov5Service:

    def _is_running(self) -> bool:
        try:
            with socket.create_connection((YOLO_HOST, YOLO_PORT), timeout=2):
                return True
        except (ConnectionRefusedError, OSError):
            return False

    def test_health_endpoint(self):
        """GET /health must return HTTP 200 with status=healthy."""
        if not self._is_running():
            pytest.skip(f"YOLOv5 service not running on {YOLO_HOST}:{YOLO_PORT}")

        import urllib.request
        url = f'http://{YOLO_HOST}:{YOLO_PORT}/health'
        with urllib.request.urlopen(url, timeout=10) as resp:
            assert resp.status == 200
            data = json.loads(resp.read())
        assert data.get('status') == 'healthy'
        assert 'model' in data

    def test_detect_missing_url_returns_400(self):
        """POST /detect without URL must return 400."""
        if not self._is_running():
            pytest.skip(f"YOLOv5 service not running on {YOLO_HOST}:{YOLO_PORT}")

        import urllib.error
        import urllib.request
        req = urllib.request.Request(
            f'http://{YOLO_HOST}:{YOLO_PORT}/detect',
            data=b'{}',
            headers={'Content-Type': 'application/json'},
            method='POST',
        )
        try:
            urllib.request.urlopen(req, timeout=10)
            pytest.fail("Expected HTTP 400, got 200")
        except urllib.error.HTTPError as e:
            assert e.code == 400
