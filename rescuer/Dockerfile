# ghr-rescuer: re-routes runs stranded on self-hosted labels (see rescue.py). Stdlib python + openssl.
# Base pinned by index digest (python:3.13-alpine, resolved 2026-10-16); bump deliberately.
FROM python:3.14-alpine@sha256:f6a589d43c42b9e7f7dc67a12d37132491f362859a5d750607710cc56da3bc72

# hadolint ignore=DL3018
RUN apk add --no-cache openssl

WORKDIR /app
COPY rescue.py .

# Unprivileged by default; compose may override `user:` so a host-owned 0400 key stays readable.
USER 65534:65534
ENV HEARTBEAT_FILE=/tmp/rescuer.last-ok PYTHONUNBUFFERED=1

# Healthy while the last clean pass is younger than 3 intervals (INTERVAL_SEC, default 300).
HEALTHCHECK --interval=60s --timeout=5s --start-period=300s CMD ["python3", "/app/rescue.py", "--healthcheck"]

ENTRYPOINT ["python3", "/app/rescue.py"]
