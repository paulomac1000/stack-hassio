FROM python:3.11-slim-bookworm

# alsa-utils provides arecord and aplay for mic/speaker via --mic-command / --snd-command
RUN apt-get update && \
    apt-get install --yes --no-install-recommends \
        avahi-utils \
        alsa-utils \
        git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN git clone --depth 1 https://github.com/rhasspy/wyoming-satellite.git . && \
    pip install --no-cache-dir .

# Local sounds override upstream defaults
COPY sounds/ ./sounds/

ENTRYPOINT ["python3", "-m", "wyoming_satellite"]
