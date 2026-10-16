# ghr-rescuer: re-routes runs stranded on self-hosted labels (see rescue.py). Stdlib python + openssl.
# Base pinned by index digest (python:3.13-alpine, resolved 2026-10-16); bump deliberately.
FROM python:3.13-alpine@sha256:2d9aefe2fef018a7eb2c13064c89c71929800fd2e5dccdbf52ea5da5bb8d929a

# hadolint ignore=DL3018
RUN apk add --no-cache openssl

WORKDIR /app
COPY rescue.py .

# Unprivileged by default; compose may override `user:` so a host-owned 0400 key stays readable.
USER 65534:65534
ENV HEARTBEAT_FILE=/tmp/rescuer.last-ok PYTHONUNBUFFERED=1

# Healthy while the last successful pass is younger than 3 intervals (INTERVAL_SEC, default 300).
HEALTHCHECK --interval=60s --timeout=5s --start-period=300s CMD \
  python3 -c "import os,sys,time; i=int(os.environ.get('INTERVAL_SEC','300')); sys.exit(0 if time.time()-os.path.getmtime(os.environ['HEARTBEAT_FILE'])<3*max(i,60) else 1)"

ENTRYPOINT ["python3", "/app/rescue.py"]
