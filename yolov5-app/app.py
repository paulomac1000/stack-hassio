#!/usr/bin/env python3
"""
YOLOv5 Object Detection Service
Production-ready API and MQTT interface for object detection.

Optimized for low-end hardware (AMD G-T56N, 2 cores, 3.4GB RAM).
Supports custom models trained on Windows, running on Linux.

BACKWARD COMPATIBLE with old MQTT message format.

Author: AI Assistant
Version: 2.1.0
"""

import os
import sys
import time
import json
import logging
import gc
import signal
import pathlib
import platform
from datetime import datetime
from typing import Dict, List, Optional, Tuple, Any
from collections import defaultdict
from io import BytesIO
from dataclasses import dataclass
from enum import Enum

# ==============================================================================
# CONFIGURATION CLASSES
# ==============================================================================

class ModelSize(Enum):
    """Available YOLO model sizes with their torch hub names."""
    NANO = "yolov5n"
    SMALL = "yolov5s"
    MEDIUM = "yolov5m"
    LARGE = "yolov5l"
    XLARGE = "yolov5x"

    @classmethod
    def from_string(cls, value: str) -> 'ModelSize':
        """Convert string to ModelSize enum."""
        mapping = {
            'nano': cls.NANO, 'n': cls.NANO,
            'small': cls.SMALL, 's': cls.SMALL,
            'medium': cls.MEDIUM, 'm': cls.MEDIUM,
            'large': cls.LARGE, 'l': cls.LARGE,
            'xlarge': cls.XLARGE, 'x': cls.XLARGE,
        }
        return mapping.get(value.lower(), cls.NANO)


class MemoryMode(Enum):
    """Memory management aggressiveness."""
    GENTLE = "gentle"
    MODERATE = "moderate"
    AGGRESSIVE = "aggressive"


@dataclass
class Config:
    """Application configuration loaded from environment variables."""

    # Hardware
    cpu_threads: int = 1
    memory_mode: MemoryMode = MemoryMode.AGGRESSIVE
    use_half_precision: bool = False

    # Model
    model_size: ModelSize = ModelSize.NANO
    use_custom_model: bool = False
    custom_model_path: str = "/data/best.pt"

    # Inference
    image_size: int = 320
    confidence_threshold: float = 0.25
    iou_threshold: float = 0.45
    max_detections: int = 50

    # MQTT
    enable_mqtt: bool = True
    mqtt_broker: str = "localhost"
    mqtt_port: int = 1883
    mqtt_username: Optional[str] = None
    mqtt_password: Optional[str] = None
    mqtt_client_id: str = "yolov5-detector"
    mqtt_topic_subscribe: str = "yolov5/detect"
    mqtt_topic_publish: str = "yolov5/results"
    mqtt_qos: int = 1

    # API
    enable_api: bool = True
    api_host: str = "0.0.0.0"
    api_port: int = 8071

    # Logging
    log_level: str = "INFO"
    log_timing: bool = True
    log_memory: bool = True

    # Network
    request_timeout: int = 15

    @classmethod
    def from_env(cls) -> 'Config':
        """Load configuration from environment variables."""

        def get_bool(key: str, default: bool = False) -> bool:
            return os.getenv(key, str(default)).lower() in ('true', '1', 'yes', 'on')

        def get_int(key: str, default: int) -> int:
            try:
                return int(os.getenv(key, str(default)))
            except ValueError:
                return default

        def get_float(key: str, default: float) -> float:
            try:
                return float(os.getenv(key, str(default)))
            except ValueError:
                return default

        memory_mode_str = os.getenv('MEMORY_MODE', 'aggressive').lower()
        memory_mode = MemoryMode(memory_mode_str) if memory_mode_str in [m.value for m in MemoryMode] else MemoryMode.AGGRESSIVE

        # Support old DETECTION_SIZE variable name for backward compatibility
        image_size = get_int('IMAGE_SIZE', 0) or get_int('DETECTION_SIZE', 320)

        return cls(
            # Hardware
            cpu_threads=get_int('CPU_THREADS', 1),
            memory_mode=memory_mode,
            use_half_precision=get_bool('USE_HALF_PRECISION', False),

            # Model
            model_size=ModelSize.from_string(os.getenv('MODEL_SIZE', 'nano')),
            use_custom_model=get_bool('USE_CUSTOM_MODEL', False),
            custom_model_path=os.getenv('CUSTOM_MODEL_PATH', '/data/best.pt'),

            # Inference
            image_size=image_size,
            confidence_threshold=get_float('CONFIDENCE_THRESHOLD', 0.25),
            iou_threshold=get_float('IOU_THRESHOLD', 0.45),
            max_detections=get_int('MAX_DETECTIONS', 50),

            # MQTT
            enable_mqtt=get_bool('ENABLE_MQTT', True),
            mqtt_broker=os.getenv('MQTT_BROKER', 'localhost'),
            mqtt_port=get_int('MQTT_PORT', 1883),
            mqtt_username=os.getenv('MQTT_USERNAME') or None,
            mqtt_password=os.getenv('MQTT_PASSWORD') or None,
            mqtt_client_id=os.getenv('MQTT_CLIENT_ID', 'yolov5-detector'),
            mqtt_topic_subscribe=os.getenv('MQTT_TOPIC_SUBSCRIBE', 'yolov5/detect'),
            mqtt_topic_publish=os.getenv('MQTT_TOPIC_PUBLISH', 'yolov5/results'),
            mqtt_qos=get_int('MQTT_QOS', 1),

            # API
            enable_api=get_bool('ENABLE_API', True),
            api_host=os.getenv('API_HOST', '0.0.0.0'),
            api_port=get_int('API_PORT', 8071),

            # Logging
            log_level=os.getenv('LOG_LEVEL', 'INFO').upper(),
            log_timing=get_bool('LOG_TIMING', True),
            log_memory=get_bool('LOG_MEMORY', True),

            # Network
            request_timeout=get_int('REQUEST_TIMEOUT', 15),
        )


# ==============================================================================
# LOGGING SETUP
# ==============================================================================

def setup_logging(level: str) -> logging.Logger:
    """Configure application logging (matching old format for compatibility)."""

    logging.basicConfig(
        level=getattr(logging, level, logging.INFO),
        format='%(asctime)s - %(levelname)s - %(message)s',
        datefmt='%Y-%m-%d %H:%M:%S',
        stream=sys.stdout
    )

    logger = logging.getLogger('yolov5-service')
    return logger


# ==============================================================================
# SYSTEM UTILITIES
# ==============================================================================

class SystemMonitor:
    """Monitor system resources."""

    def __init__(self):
        import psutil
        self.psutil = psutil
        self.process = psutil.Process()

    def get_memory_info(self) -> Dict[str, Any]:
        """Get current memory usage."""
        mem = self.psutil.virtual_memory()
        proc_mem = self.process.memory_info()

        return {
            'system_total_mb': round(mem.total / 1024 / 1024),
            'system_used_percent': round(mem.percent, 1),
            'system_available_mb': round(mem.available / 1024 / 1024),
            'process_rss_mb': round(proc_mem.rss / 1024 / 1024),
        }

    def format_stats(self) -> str:
        """Format system stats as a string."""
        mem = self.get_memory_info()
        return f"RAM: {mem['process_rss_mb']}MB process, {mem['system_available_mb']}MB available"


def cleanup_memory(mode: MemoryMode, logger: logging.Logger):
    """Force garbage collection based on memory mode."""
    if mode == MemoryMode.GENTLE:
        gc.collect()
    elif mode == MemoryMode.MODERATE:
        gc.collect()
        gc.collect()
    else:  # AGGRESSIVE
        gc.collect()
        gc.collect()
        try:
            import ctypes
            libc = ctypes.CDLL("libc.so.6")
            libc.malloc_trim(0)
        except Exception:
            pass


# ==============================================================================
# YOLO MODEL MANAGER
# ==============================================================================

class YOLOModelManager:
    """Manages YOLO model loading and inference."""

    def __init__(self, config: Config, logger: logging.Logger):
        self.config = config
        self.logger = logger
        self.model = None
        self.model_name = None
        self.model_classes: List[str] = []

        # Configure torch
        self._configure_torch()

    def _configure_torch(self):
        """Configure PyTorch for optimal CPU performance."""
        import torch

        torch.set_num_threads(self.config.cpu_threads)
        os.environ["OMP_NUM_THREADS"] = str(self.config.cpu_threads)
        os.environ["MKL_NUM_THREADS"] = str(self.config.cpu_threads)

        torch.set_grad_enabled(False)

        self.logger.info(f"PyTorch configured: {self.config.cpu_threads} thread(s)")

    def _fix_windows_paths(self):
        """Fix pathlib issue when loading models trained on Windows."""
        if platform.system() != 'Windows':
            pathlib.WindowsPath = pathlib.PosixPath
            self.logger.debug("Applied Windows path compatibility fix")

    def load(self) -> bool:
        """Load the YOLO model with fallback logic."""
        from ultralytics import YOLO

        self.logger.info("=" * 60)
        self.logger.info("INITIALIZING YOLO MODEL")
        self.logger.info("=" * 60)

        # Try custom model first if enabled
        if self.config.use_custom_model:
            model_path = self.config.custom_model_path
            self.logger.info(f"Attempting to load custom model: {model_path}")

            if os.path.exists(model_path):
                try:
                    self._fix_windows_paths()

                    self.model = YOLO(model_path)
                    self.model_name = f"custom:{os.path.basename(model_path)}"
                    self.logger.info(f"SUCCESS: Custom model loaded")
                    self._configure_model()
                    return True

                except Exception as e:
                    self.logger.error(f"Failed to load custom model: {e}")
                    self.logger.warning("Falling back to standard model...")
            else:
                self.logger.warning(f"Custom model file not found: {model_path}")
                self.logger.warning("Falling back to standard model...")

        # Load standard model based on size config
        model_map = {
            ModelSize.NANO: "yolov5nu.pt",
            ModelSize.SMALL: "yolov5su.pt",
            ModelSize.MEDIUM: "yolov5mu.pt",
            ModelSize.LARGE: "yolov5lu.pt",
            ModelSize.XLARGE: "yolov5xu.pt",
        }

        model_file = model_map.get(self.config.model_size, "yolov5nu.pt")
        self.logger.info(f"Loading standard model: {model_file}")

        try:
            self.model = YOLO(model_file)
            self.model_name = model_file.replace(".pt", "")
            self.logger.info(f"SUCCESS: Standard model {model_file} loaded")
            self._configure_model()
            return True

        except Exception as e:
            self.logger.critical(f"FATAL: Could not load model: {e}")
            return False

    def _configure_model(self):
        """Configure loaded model parameters."""
        # Get class names from model
        if hasattr(self.model, 'names'):
            if isinstance(self.model.names, dict):
                self.model_classes = list(self.model.names.values())
            else:
                self.model_classes = list(self.model.names)

        self.logger.info(f"Model configured: confidence={self.config.confidence_threshold}, "
                        f"image_size={self.config.image_size}, classes={len(self.model_classes)}")

    def detect(self, image_source) -> Tuple[List[Dict], List[Dict], Dict[str, Any]]:
        """
        Run object detection on an image.

        Returns:
            Tuple of (
                legacy_detections: List[Dict] - old format [{"name": "...", "confidence": 0.xx}],
                extended_detections: List[Dict] - new format with bboxes and instances,
                timing_info: Dict - detailed timing information
            )
        """
        import torch

        start_time = time.time()
        timing = {
            'download_ms': 0,
            'inference_ms': 0,
            'postprocess_ms': 0,
            'total_ms': 0
        }

        self.logger.info(f"Starting detection for image URL: {image_source}")

        try:
            # Download if URL
            download_start = time.time()
            if isinstance(image_source, str) and image_source.startswith(('http://', 'https://')):
                image = self._download_image(image_source)
                timing['download_ms'] = round((time.time() - download_start) * 1000)
            else:
                image = image_source

            # Inference using ultralytics
            inference_start = time.time()
            results = self.model.predict(
                source=image,
                imgsz=self.config.image_size,
                conf=self.config.confidence_threshold,
                iou=self.config.iou_threshold,
                max_det=self.config.max_detections,
                verbose=False
            )
            timing['inference_ms'] = round((time.time() - inference_start) * 1000)

            # Postprocess
            postprocess_start = time.time()

            # Process results
            detection_results = []
            if len(results) > 0 and results[0].boxes is not None:
                boxes = results[0].boxes
                for i in range(len(boxes)):
                    box = boxes[i]
                    detection_results.append({
                        'name': self.model_classes[int(box.cls[0])] if self.model_classes else str(int(box.cls[0])),
                        'confidence': float(box.conf[0]),
                        'class': int(box.cls[0]),
                        'xmin': float(box.xyxy[0][0]),
                        'ymin': float(box.xyxy[0][1]),
                        'xmax': float(box.xyxy[0][2]),
                        'ymax': float(box.xyxy[0][3]),
                    })

            self.logger.info(f"Raw detection results: {detection_results}")

            # === BUILD LEGACY FORMAT (backward compatible) ===
            combined_results = defaultdict(list)
            for obj in detection_results:
                combined_results[obj['name']].append(obj['confidence'])

            legacy_detections = []
            for name, confidences in combined_results.items():
                self.logger.info(f"Object: {name}, Confidences: {confidences}")

                # Calculate probability of at least one detection
                prob_no_detection = 1.0
                for confidence in confidences:
                    prob_no_detection *= (1 - confidence)
                prob_at_least_one_detection = 1 - prob_no_detection

                legacy_detections.append({
                    "name": name,
                    "confidence": prob_at_least_one_detection
                })
                self.logger.info(f"Object: {name}, Combined Confidence: {prob_at_least_one_detection}")

            # Sort by confidence descending
            legacy_detections.sort(key=lambda x: x["confidence"], reverse=True)

            # === BUILD EXTENDED FORMAT (new features) ===
            extended_by_class = defaultdict(list)
            for obj in detection_results:
                extended_by_class[obj['name']].append({
                    'confidence': round(float(obj['confidence']), 4),
                    'bbox': {
                        'x1': round(float(obj['xmin'])),
                        'y1': round(float(obj['ymin'])),
                        'x2': round(float(obj['xmax'])),
                        'y2': round(float(obj['ymax'])),
                        'width': round(float(obj['xmax'] - obj['xmin'])),
                        'height': round(float(obj['ymax'] - obj['ymin']))
                    },
                    'class_id': int(obj['class'])
                })

            extended_detections = []
            for name, instances in extended_by_class.items():
                # Calculate combined confidence
                prob_none = 1.0
                for inst in instances:
                    prob_none *= (1.0 - inst['confidence'])
                combined_conf = 1.0 - prob_none

                extended_detections.append({
                    'name': name,
                    'count': len(instances),
                    'confidence': round(combined_conf, 4),
                    'max_confidence': round(max(i['confidence'] for i in instances), 4),
                    'min_confidence': round(min(i['confidence'] for i in instances), 4),
                    'instances': instances
                })

            extended_detections.sort(key=lambda x: x['confidence'], reverse=True)

            timing['postprocess_ms'] = round((time.time() - postprocess_start) * 1000)
            timing['total_ms'] = round((time.time() - start_time) * 1000)

            processing_time = time.time() - start_time
            self.logger.info(f"Image processing time: {processing_time} seconds")

            # Cleanup
            del results

            return legacy_detections, extended_detections, timing

        except Exception as e:
            self.logger.error(f"Error in detecting objects: {e}")
            import traceback
            self.logger.error(traceback.format_exc())
            return [], [], timing

    def _download_image(self, url: str):
        """Download image from URL with timeout."""
        import requests
        from PIL import Image

        self.logger.debug(f"Downloading image from: {url}")

        response = requests.get(
            url,
            timeout=self.config.request_timeout,
            headers={'User-Agent': 'YOLOv5-Detector/2.1'}
        )
        response.raise_for_status()

        return Image.open(BytesIO(response.content))


# ==============================================================================
# MQTT CLIENT
# ==============================================================================

class MQTTClient:
    """MQTT client - backward compatible with extended fields."""

    def __init__(self, config: Config, logger: logging.Logger, detector: YOLOModelManager, monitor: SystemMonitor):
        self.config = config
        self.logger = logger
        self.detector = detector
        self.monitor = monitor
        self.client = None

    def connect(self):
        """Establish MQTT connection."""
        import paho.mqtt.client as mqtt

        self.client = mqtt.Client()

        if self.config.mqtt_username and self.config.mqtt_password:
            self.client.username_pw_set(
                self.config.mqtt_username,
                self.config.mqtt_password
            )

        self.client.on_connect = self._on_connect
        self.client.on_message = self._on_message
        self.client.on_disconnect = self._on_disconnect

        # Auto-reconnect settings
        self.client.reconnect_delay_set(min_delay=1, max_delay=60)

        self.client.connect(self.config.mqtt_broker, self.config.mqtt_port, 60)
        self.client.loop_start()

    def _on_connect(self, client, userdata, flags, rc):
        """Handle MQTT connection - same log format as old code."""
        self.logger.info(f"Connected to MQTT Broker: {self.config.mqtt_broker} with result code {rc}")
        client.subscribe(self.config.mqtt_topic_subscribe)

    def _on_disconnect(self, client, userdata, rc):
        """Handle MQTT disconnection."""
        if rc != 0:
            self.logger.warning(f"MQTT disconnected unexpectedly (rc={rc}). Reconnecting...")
        else:
            self.logger.info("MQTT disconnected")

    def _on_message(self, client, userdata, msg):
        """Handle MQTT message - backward compatible with extended fields."""
        self.logger.info(f"Received MQTT message: {msg.payload.decode()} on topic {msg.topic}")

        try:
            data = json.loads(msg.payload)
            img_url = data.get('url', None)
            camera_name = data.get('camera', 'Unknown')
            request_id = data.get('request_id', None)  # Optional new field

            if img_url:
                # Run detection
                legacy_detections, extended_detections, timing = self.detector.detect(img_url)

                # Get memory stats
                mem_info = self.monitor.get_memory_info()

                processing_time_seconds = timing['total_ms'] / 1000.0

                response = {
                    # === LEGACY FIELDS (backward compatible - same order) ===
                    "url": img_url,
                    "camera": camera_name,
                    "processing_time": processing_time_seconds,
                    "detections": legacy_detections,

                    # === NEW EXTENDED FIELDS ===
                    "timestamp": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S.") + \
                                 f"{datetime.utcnow().microsecond // 1000:03d}Z",
                    "request_id": request_id,
                    "model": {
                        "name": self.detector.model_name,
                        "classes_count": len(self.detector.model_classes)
                    },
                    "image_size": self.config.image_size,
                    "timing": {
                        "download_ms": timing['download_ms'],
                        "inference_ms": timing['inference_ms'],
                        "postprocess_ms": timing['postprocess_ms'],
                        "total_ms": timing['total_ms']
                    },
                    "detections_extended": extended_detections,
                    "objects_count": {
                        "unique_classes": len(legacy_detections),
                        "total_instances": sum(d['count'] for d in extended_detections) if extended_detections else 0
                    },
                    "system": {
                        "memory_process_mb": mem_info['process_rss_mb'],
                        "memory_available_mb": mem_info['system_available_mb'],
                        "memory_used_percent": mem_info['system_used_percent']
                    }
                }

                self.logger.info(f"Detection results: {json.dumps(response)}")
                client.publish(self.config.mqtt_topic_publish, json.dumps(response))
                self.logger.info(f"Detection results published to {self.config.mqtt_topic_publish}.")

                cleanup_memory(self.config.memory_mode, self.logger)
            else:
                error_message = {"error": "No URL provided"}
                client.publish(self.config.mqtt_topic_publish, json.dumps(error_message))
                self.logger.error("No URL provided in MQTT message")

        except json.JSONDecodeError:
            self.logger.error("Invalid JSON in MQTT message")
        except Exception as e:
            self.logger.error(f"Error processing message: {e}")
            import traceback
            self.logger.error(traceback.format_exc())

    def disconnect(self):
        """Disconnect from MQTT."""
        if self.client:
            self.client.loop_stop()
            self.client.disconnect()


# ==============================================================================
# REST API
# ==============================================================================

class APIServer:
    """Flask REST API - backward compatible with extended response."""

    def __init__(self, config: Config, logger: logging.Logger, detector: YOLOModelManager, monitor: SystemMonitor):
        self.config = config
        self.logger = logger
        self.detector = detector
        self.monitor = monitor
        self.app = self._create_app()

    def _create_app(self):
        """Create Flask application."""
        from flask import Flask, request, jsonify

        app = Flask(__name__)

        @app.route('/detect', methods=['POST'])
        def detect():
            """Detection endpoint - backward compatible with extended fields."""
            data = request.json
            self.logger.info(f"Received API request: {data} on route /detect")

            img_url = data.get('url', None) if data else None
            camera_name = data.get('camera', 'Unknown') if data else 'Unknown'
            request_id = data.get('request_id', None) if data else None

            if img_url is None:
                self.logger.error("No URL provided in API request")
                return jsonify({"error": "No URL provided"}), 400

            legacy_detections, extended_detections, timing = self.detector.detect(img_url)
            mem_info = self.monitor.get_memory_info()

            processing_time_seconds = timing['total_ms'] / 1000.0

            response = {
                # === LEGACY FIELDS ===
                "url": img_url,
                "camera": camera_name,
                "processing_time": processing_time_seconds,
                "detections": legacy_detections,

                # === EXTENDED FIELDS ===
                "timestamp": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S.") + \
                             f"{datetime.utcnow().microsecond // 1000:03d}Z",
                "request_id": request_id,
                "model": {
                    "name": self.detector.model_name,
                    "classes_count": len(self.detector.model_classes)
                },
                "image_size": self.config.image_size,
                "timing": timing,
                "detections_extended": extended_detections,
                "objects_count": {
                    "unique_classes": len(legacy_detections),
                    "total_instances": sum(d['count'] for d in extended_detections) if extended_detections else 0
                },
                "system": {
                    "memory_process_mb": mem_info['process_rss_mb'],
                    "memory_available_mb": mem_info['system_available_mb']
                }
            }

            self.logger.info(f"Detection results: {json.dumps(response)}")
            cleanup_memory(self.config.memory_mode, self.logger)

            return jsonify(response)

        @app.route('/health', methods=['GET'])
        def health():
            """Health check endpoint."""
            mem_info = self.monitor.get_memory_info()
            return jsonify({
                "status": "healthy",
                "timestamp": datetime.utcnow().isoformat() + 'Z',
                "model": {
                    "name": self.detector.model_name,
                    "classes": self.detector.model_classes,
                    "classes_count": len(self.detector.model_classes)
                },
                "config": {
                    "image_size": self.config.image_size,
                    "confidence_threshold": self.config.confidence_threshold,
                    "iou_threshold": self.config.iou_threshold
                },
                "system": mem_info
            })

        @app.route('/info', methods=['GET'])
        def info():
            """Service information endpoint."""
            return jsonify({
                "service": "YOLOv5 Object Detection",
                "version": "2.1.0",
                "model": {
                    "name": self.detector.model_name,
                    "classes": self.detector.model_classes,
                    "classes_count": len(self.detector.model_classes)
                },
                "config": {
                    "image_size": self.config.image_size,
                    "confidence_threshold": self.config.confidence_threshold,
                    "iou_threshold": self.config.iou_threshold,
                    "max_detections": self.config.max_detections,
                    "cpu_threads": self.config.cpu_threads,
                    "memory_mode": self.config.memory_mode.value
                },
                "endpoints": {
                    "POST /detect": "Run detection on image URL",
                    "GET /health": "Health check with system stats",
                    "GET /info": "Service information"
                }
            })

        return app

    def run(self):
        """Start API server."""
        from waitress import serve

        self.logger.info(f"Starting API on {self.config.api_host}:{self.config.api_port}")
        serve(
            self.app,
            host=self.config.api_host,
            port=self.config.api_port,
            threads=1
        )


# ==============================================================================
# MAIN APPLICATION
# ==============================================================================

class Application:
    """Main application orchestrator."""

    def __init__(self):
        self.config = Config.from_env()
        self.logger = setup_logging(self.config.log_level)
        self.monitor = SystemMonitor()
        self.detector = None
        self.mqtt_client = None
        self.running = True

        signal.signal(signal.SIGTERM, self._shutdown)
        signal.signal(signal.SIGINT, self._shutdown)

    def _shutdown(self, signum, frame):
        """Graceful shutdown."""
        self.logger.info("Shutting down...")
        self.running = False
        if self.mqtt_client:
            self.mqtt_client.disconnect()
        sys.exit(0)

    def _log_config(self):
        """Log configuration on startup - same format as old code for compatibility."""
        self.logger.info(
            f"Configuration: MQTT_BROKER={self.config.mqtt_broker}, "
            f"MQTT_PORT={self.config.mqtt_port}, "
            f"MQTT_TOPIC_SUBSCRIBE={self.config.mqtt_topic_subscribe}, "
            f"MQTT_TOPIC_PUBLISH={self.config.mqtt_topic_publish}, "
            f"ENABLE_API={self.config.enable_api}, "
            f"ENABLE_MQTT={self.config.enable_mqtt}, "
            f"DETECTION_SIZE={self.config.image_size}"
        )
        if self.config.mqtt_username:
            self.logger.info(f"MQTT_USERNAME={self.config.mqtt_username}")

        # Additional new config logging
        self.logger.info(
            f"Extended config: MODEL_SIZE={self.config.model_size.value}, "
            f"USE_CUSTOM_MODEL={self.config.use_custom_model}, "
            f"CPU_THREADS={self.config.cpu_threads}, "
            f"MEMORY_MODE={self.config.memory_mode.value}"
        )

    def run(self):
        """Run the application."""
        self.logger.info("=" * 60)
        self.logger.info("YOLOv5 OBJECT DETECTION SERVICE v2.1.0")
        self.logger.info("=" * 60)

        self._log_config()

        # Log system info
        mem_info = self.monitor.get_memory_info()
        self.logger.info(f"System: {mem_info['system_total_mb']}MB total RAM, "
                        f"{mem_info['system_available_mb']}MB available")

        # Initialize detector
        self.detector = YOLOModelManager(self.config, self.logger)
        if not self.detector.load():
            self.logger.critical("Failed to load model. Exiting.")
            sys.exit(1)

        # Initialize MQTT
        if self.config.enable_mqtt:
            try:
                self.mqtt_client = MQTTClient(
                    self.config, self.logger, self.detector, self.monitor
                )
                self.mqtt_client.connect()
            except Exception as e:
                self.logger.error(f"MQTT connection failed: {e}")
                if not self.config.enable_api:
                    self.logger.critical("MQTT failed and API disabled. Exiting.")
                    sys.exit(1)

        # Run API or keep alive
        if self.config.enable_api:
            api = APIServer(self.config, self.logger, self.detector, self.monitor)
            api.run()
        else:
            if not self.config.enable_mqtt:
                self.logger.info("Both API and MQTT are disabled. Exiting.")
                sys.exit(0)
            self.logger.info("Running in MQTT-only mode. Press Ctrl+C to exit.")
            while self.running:
                time.sleep(1)


# ==============================================================================
# ENTRY POINT
# ==============================================================================

if __name__ == '__main__':
    app = Application()
    app.run()
