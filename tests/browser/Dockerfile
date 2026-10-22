# Headless Chromium that can reach the local stack on the host as localhost:8080-8082 (the addresses
# baked into the web build), so the real page, WebGL and WebSocket path are exercised.
FROM mcr.microsoft.com/playwright/python:v1.49.1-noble
RUN apt-get update && apt-get install -y --no-install-recommends socat \
    && rm -rf /var/lib/apt/lists/*
RUN pip3 install --no-cache-dir --break-system-packages playwright==1.49.1
WORKDIR /t
COPY entrypoint.sh run.py /t/
RUN chmod +x /t/entrypoint.sh
ENTRYPOINT ["/t/entrypoint.sh"]
