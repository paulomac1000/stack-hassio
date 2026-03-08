FROM python:3.11-slim

WORKDIR /app

# Install test dependencies (pinned for reproducibility)
RUN pip install --no-cache-dir \
    pytest==8.3.5 \
    pytest-cov==6.1.0 \
    flask==3.1.0 \
    paho-mqtt==2.1.0 \
    psutil==6.1.1 \
    jinja2==3.1.6

# Source is mounted at runtime — no COPY needed
# docker run --rm -v $(pwd):/app:ro hassio-tests pytest ...

CMD ["pytest", "yolov5-app/test_app.py", "tests/test_heating_macros.py", \
     "-v", "--tb=short"]
