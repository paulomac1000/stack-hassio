"""
Unit tests for yolov5-app/app.py

Tests focus on configuration loading and Flask endpoint logic.
Does NOT require torch, ultralytics, or GPU — all heavy dependencies are mocked.
Run with: pytest yolov5-app/test_app.py -v
"""
import json
import os
import sys
import unittest
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Prevent app.py from importing heavy ML libraries at module load time.
# We mock them before importing the module under test.
# ---------------------------------------------------------------------------
sys.modules.setdefault('torch', MagicMock())
sys.modules.setdefault('torchvision', MagicMock())
sys.modules.setdefault('cv2', MagicMock())
sys.modules.setdefault('ultralytics', MagicMock())
sys.modules.setdefault('psutil', MagicMock())
sys.modules.setdefault('paho', MagicMock())
sys.modules.setdefault('paho.mqtt', MagicMock())
sys.modules.setdefault('paho.mqtt.client', MagicMock())

# Add yolov5-app dir to path so we can import app directly
sys.path.insert(0, os.path.dirname(__file__))

from app import Config, ModelSize, MemoryMode  # noqa: E402


# ===========================================================================
# ModelSize tests
# ===========================================================================

class TestModelSize(unittest.TestCase):

    def test_from_string_full_names(self):
        assert ModelSize.from_string('nano') == ModelSize.NANO
        assert ModelSize.from_string('small') == ModelSize.SMALL
        assert ModelSize.from_string('medium') == ModelSize.MEDIUM
        assert ModelSize.from_string('large') == ModelSize.LARGE
        assert ModelSize.from_string('xlarge') == ModelSize.XLARGE

    def test_from_string_short_names(self):
        assert ModelSize.from_string('n') == ModelSize.NANO
        assert ModelSize.from_string('s') == ModelSize.SMALL
        assert ModelSize.from_string('m') == ModelSize.MEDIUM
        assert ModelSize.from_string('l') == ModelSize.LARGE
        assert ModelSize.from_string('x') == ModelSize.XLARGE

    def test_from_string_case_insensitive(self):
        assert ModelSize.from_string('NANO') == ModelSize.NANO
        assert ModelSize.from_string('Large') == ModelSize.LARGE

    def test_from_string_unknown_defaults_to_nano(self):
        assert ModelSize.from_string('unknown') == ModelSize.NANO
        assert ModelSize.from_string('') == ModelSize.NANO

    def test_enum_values(self):
        assert ModelSize.NANO.value == 'yolov5n'
        assert ModelSize.SMALL.value == 'yolov5s'


# ===========================================================================
# MemoryMode tests
# ===========================================================================

class TestMemoryMode(unittest.TestCase):

    def test_valid_values(self):
        assert MemoryMode('gentle') == MemoryMode.GENTLE
        assert MemoryMode('moderate') == MemoryMode.MODERATE
        assert MemoryMode('aggressive') == MemoryMode.AGGRESSIVE

    def test_enum_values(self):
        assert MemoryMode.AGGRESSIVE.value == 'aggressive'


# ===========================================================================
# Config.from_env() tests
# ===========================================================================

class TestConfigFromEnv(unittest.TestCase):

    def test_defaults(self):
        with patch.dict(os.environ, {}, clear=True):
            config = Config.from_env()
        assert config.cpu_threads == 1
        assert config.model_size == ModelSize.NANO
        assert config.memory_mode == MemoryMode.AGGRESSIVE
        assert config.confidence_threshold == 0.25
        assert config.iou_threshold == 0.45
        assert config.max_detections == 50
        assert config.api_port == 8071
        assert config.mqtt_port == 1883
        assert config.enable_mqtt is True
        assert config.enable_api is True

    def test_override_from_env(self):
        env = {
            'CPU_THREADS': '4',
            'MODEL_SIZE': 'small',
            'MEMORY_MODE': 'gentle',
            'CONFIDENCE_THRESHOLD': '0.5',
            'IOU_THRESHOLD': '0.3',
            'MAX_DETECTIONS': '10',
            'API_PORT': '9000',
            'MQTT_PORT': '1884',
            'ENABLE_MQTT': 'false',
            'ENABLE_API': 'true',
            'LOG_LEVEL': 'debug',
        }
        with patch.dict(os.environ, env, clear=True):
            config = Config.from_env()
        assert config.cpu_threads == 4
        assert config.model_size == ModelSize.SMALL
        assert config.memory_mode == MemoryMode.GENTLE
        assert config.confidence_threshold == 0.5
        assert config.iou_threshold == 0.3
        assert config.max_detections == 10
        assert config.api_port == 9000
        assert config.mqtt_port == 1884
        assert config.enable_mqtt is False
        assert config.log_level == 'DEBUG'

    def test_bool_env_variants(self):
        for truthy in ('true', 'True', '1', 'yes', 'on'):
            with patch.dict(os.environ, {'ENABLE_MQTT': truthy}, clear=True):
                assert Config.from_env().enable_mqtt is True
        for falsy in ('false', 'False', '0', 'no', 'off'):
            with patch.dict(os.environ, {'ENABLE_MQTT': falsy}, clear=True):
                assert Config.from_env().enable_mqtt is False

    def test_mqtt_credentials_none_when_empty(self):
        with patch.dict(os.environ, {'MQTT_USERNAME': '', 'MQTT_PASSWORD': ''}, clear=True):
            config = Config.from_env()
        assert config.mqtt_username is None
        assert config.mqtt_password is None

    def test_mqtt_credentials_set(self):
        with patch.dict(os.environ, {'MQTT_USERNAME': 'pablo', 'MQTT_PASSWORD': 'secret'}, clear=True):
            config = Config.from_env()
        assert config.mqtt_username == 'pablo'
        assert config.mqtt_password == 'secret'

    def test_invalid_int_uses_default(self):
        with patch.dict(os.environ, {'CPU_THREADS': 'notanumber'}, clear=True):
            config = Config.from_env()
        assert config.cpu_threads == 1

    def test_invalid_float_uses_default(self):
        with patch.dict(os.environ, {'CONFIDENCE_THRESHOLD': 'bad'}, clear=True):
            config = Config.from_env()
        assert config.confidence_threshold == 0.25

    def test_custom_model_path(self):
        with patch.dict(os.environ, {'CUSTOM_MODEL_PATH': '/models/custom.pt', 'USE_CUSTOM_MODEL': 'true'}, clear=True):
            config = Config.from_env()
        assert config.custom_model_path == '/models/custom.pt'
        assert config.use_custom_model is True

    def test_image_size_legacy_var(self):
        """IMAGE_SIZE=0 falls back to DETECTION_SIZE (backward compat)."""
        with patch.dict(os.environ, {'IMAGE_SIZE': '0', 'DETECTION_SIZE': '640'}, clear=True):
            config = Config.from_env()
        assert config.image_size == 640

    def test_unknown_memory_mode_defaults_to_aggressive(self):
        with patch.dict(os.environ, {'MEMORY_MODE': 'turbo'}, clear=True):
            config = Config.from_env()
        assert config.memory_mode == MemoryMode.AGGRESSIVE


# ===========================================================================
# Flask /health endpoint — mocked detector + monitor
# ===========================================================================

class TestHealthEndpoint(unittest.TestCase):

    def _make_api_server(self):
        """Build an APIServer with mocked detector/monitor (no model loaded)."""
        from app import APIServer  # noqa: PLC0415

        config = Config()
        logger = MagicMock()

        detector = MagicMock()
        detector.model_name = 'yolov5n'
        detector.model_classes = ['person', 'car', 'dog']

        monitor = MagicMock()
        monitor.get_memory_info.return_value = {
            'system_total_mb': 4096,
            'system_used_percent': 55.0,
            'system_available_mb': 1800,
            'process_rss_mb': 300,
        }

        server = APIServer.__new__(APIServer)
        server.config = config
        server.logger = logger
        server.detector = detector
        server.monitor = monitor
        server.app = server._create_app()
        return server

    def test_health_returns_200(self):
        server = self._make_api_server()
        client = server.app.test_client()
        response = client.get('/health')
        assert response.status_code == 200

    def test_health_returns_json(self):
        server = self._make_api_server()
        client = server.app.test_client()
        response = client.get('/health')
        data = json.loads(response.data)
        assert data['status'] == 'healthy'
        assert 'timestamp' in data
        assert data['model']['name'] == 'yolov5n'
        assert data['model']['classes_count'] == 3

    def test_health_config_fields(self):
        server = self._make_api_server()
        client = server.app.test_client()
        data = json.loads(client.get('/health').data)
        assert data['config']['confidence_threshold'] == 0.25
        assert data['config']['iou_threshold'] == 0.45

    def test_detect_missing_url_returns_400(self):
        server = self._make_api_server()
        client = server.app.test_client()
        response = client.post('/detect', json={})
        assert response.status_code == 400
        data = json.loads(response.data)
        assert 'error' in data

    def test_info_endpoint(self):
        server = self._make_api_server()
        client = server.app.test_client()
        response = client.get('/info')
        assert response.status_code == 200
        data = json.loads(response.data)
        assert data['service'] == 'YOLOv5 Object Detection'


if __name__ == '__main__':
    unittest.main()
