#!/usr/bin/env bash
# uninstall.sh — remove the "light" systemd runners installed by install.sh.
#
# Stops + disables each gh-runner@<i> instance, removes the systemd template, and optionally purges
# the runner dirs. Deregistration from GitHub is handled by runner-loop.sh's SIGTERM trap when
# systemd stops it; if that misses (expired token), remove the runner manually in org settings.
#
# Run with sudo. Usage:
#   sudo ./uninstall.sh [--count N] [--runner-base DIR] [--purge]

set -euo pipefail

readonly DEFAULT_COUNT=2
readonly DEFAULT_RUNNER_BASE="/opt/gh-runner-light"
readonly SERVICE_NAME="gh-runner@.service"

COUNT="${COUNT:-${DEFAULT_COUNT}}"
RUNNER_BASE="${RUNNER_BASE:-${DEFAULT_RUNNER_BASE}}"
PURGE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --count)       COUNT="$2";       shift 2 ;;
    --runner-base) RUNNER_BASE="$2"; shift 2 ;;
    --purge)       PURGE=1;          shift ;;
    *) echo "Unknown flag: $1" >&2
       echo "Usage: sudo $0 [--count N] [--runner-base DIR] [--purge]" >&2; exit 1 ;;
  esac
done

info() { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }

[[ "$(id -u)" -eq 0 ]] || { echo "[ERROR] Run with sudo." >&2; exit 1; }

for i in $(seq 1 "${COUNT}"); do
  if systemctl list-unit-files "gh-runner@.service" &>/dev/null; then
    info "Stopping + disabling gh-runner@${i} (SIGTERM lets the loop deregister)..."
    systemctl disable --now "gh-runner@${i}.service" 2>/dev/null || warn "gh-runner@${i} was not active."
  fi
done

DEST_UNIT="/etc/systemd/system/${SERVICE_NAME}"
if [[ -f "${DEST_UNIT}" ]]; then
  rm -f "${DEST_UNIT}"
  systemctl daemon-reload
  info "Removed ${DEST_UNIT}."
fi

if [[ -d "${RUNNER_BASE}" ]]; then
  if [[ "${PURGE}" -eq 1 ]]; then
    info "Purging runner dirs under ${RUNNER_BASE}..."
    rm -rf "${RUNNER_BASE}"
  else
    info "Runner dirs kept at ${RUNNER_BASE} (pass --purge to delete)."
  fi
fi

echo ""
echo "light runners uninstalled. If any still show in org → Settings → Actions → Runners,"
echo "remove them manually (they were likely mid-job or had an expired token)."
