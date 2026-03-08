# ==============================================================================
# YOLOv5 CPU-Optimized Docker Image
# FOR OLD CPUs WITHOUT AVX (AMD G-T56N, Intel Atom, etc.)
# ==============================================================================

FROM python:3.9-slim-bullseye

# ==============================================================================
# ENVIRONMENT CONFIGURATION
# ==============================================================================
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONFAULTHANDLER=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    MALLOC_TRIM_THRESHOLD_=100000 \
    TORCH_HOME=/root/.cache/torch \
    CUDA_VISIBLE_DEVICES="" \
    OMP_NUM_THREADS=1 \
    MKL_NUM_THREADS=1

WORKDIR /app

# ==============================================================================
# SYSTEM DEPENDENCIES
# ==============================================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgl1-mesa-glx \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 \
    libgomp1 \
    curl \
    wget \
    ca-certificates \
    git \
    tini \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ==============================================================================
# PYTHON DEPENDENCIES - PYTORCH 1.13 (last version without AVX requirement)
# ==============================================================================
COPY requirements.txt .

# Install PyTorch 1.13.1 CPU version (works on old CPUs without AVX!)
RUN pip install --no-cache-dir \
    torch==1.13.1+cpu \
    torchvision==0.14.1+cpu \
    --extra-index-url https://download.pytorch.org/whl/cpu

# Install remaining dependencies (including ultralytics)
RUN pip install --no-cache-dir -r requirements.txt

# ==============================================================================
# PRE-DOWNLOAD YOLO MODEL
# ==============================================================================
RUN python -c "from ultralytics import YOLO; print('Downloading YOLOv5n...'); model = YOLO('yolov5n.pt'); print('Model downloaded successfully!')"

# ==============================================================================
# APPLICATION CODE
# ==============================================================================
COPY app.py .
COPY healthcheck.py .

# Create data directory for custom models
RUN mkdir -p /data

# ==============================================================================
# RUNTIME
# ==============================================================================
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["python", "-u", "app.py"]
EXPOSE 8071
