# ghr-rescuer: re-routes runs stranded on self-hosted labels (see rescue.py); the same image also runs
# the minutes ledger (usage.py, selected by the compose `entrypoint`). Stdlib python + openssl.
# Base pinned by index digest (python:3.13-alpine, resolved 2026-10-16); bump deliberately.
FROM python:3.13-alpine@sha256:2d9aefe2fef018a7eb2c13064c89c71929800fd2e5dccdbf52ea5da5bb8d929a

# hadolint ignore=DL3018
RUN apk add --no-cache openssl

WORKDIR /app
COPY rescue.py usage.py ./

# Unprivileged by default; compose may override `user:` so a host-owned 0400 key stays readable.
USER 65534:65534
ENV HEARTBEAT_FILE=/tmp/rescuer.last-ok PYTHONUNBUFFERED=1

# Healthy while the last clean pass is younger than 3 intervals (INTERVAL_SEC, default 300).
HEALTHCHECK --interval=60s --timeout=5s --start-period=300s CMD ["python3", "/app/rescue.py", "--healthcheck"]

ENTRYPOINT ["python3", "/app/rescue.py"]
