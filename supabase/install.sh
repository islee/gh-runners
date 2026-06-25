#!/usr/bin/env bash
# install.sh — set up N ephemeral "supabase" GitHub Actions runners (vanilla actions/runner + systemd).
#
# Installs the official actions/runner into one dir per instance under a base dir, writes each a
# config.env (mode 600), and registers a systemd template service (gh-runner@1 .. gh-runner@N) that
# runs runner-loop.sh. No Docker, no third-party image.
#
# Run with sudo (writes /etc/systemd/system and chowns runner dirs to the run user).
#
# Usage:
#   sudo ./install.sh (--token TOKEN | --broker-url URL [--broker-secret SECRET] | --access-token PAT)
#                     [--org ORG] [--labels LABELS] [--count N] [--user RUN_USER]
#                     [--runner-base DIR] [--runner-version VERSION]
#
# Credential priority (high -> low): static token -> broker -> PAT. Supply exactly one.

set -euo pipefail

# ── Defaults ───────────────────────────────────────────────────────────────────
# NOTE: GitHub enforces a MINIMUM runner version and rejects registration from older ones; bump this
# periodically. Releases: https://github.com/actions/runner/releases (override with --runner-version).
readonly DEFAULT_RUNNER_VERSION="2.335.1"
readonly DEFAULT_ORG="your-org"
readonly DEFAULT_LABELS="self-hosted,linux,x64,supabase"
readonly RUNNER_TYPE="supabase"   # <type> in the gh-runner-<type>-<id>-<n> name convention
readonly DEFAULT_COUNT=1
readonly DEFAULT_RUNNER_BASE="/opt/gh-runner-supabase"
readonly SERVICE_NAME="gh-runner@.service"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; readonly SCRIPT_DIR

GH_ORG="${GH_ORG:-${DEFAULT_ORG}}"
RUNNER_LABELS="${RUNNER_LABELS:-${DEFAULT_LABELS}}"
COUNT="${COUNT:-${DEFAULT_COUNT}}"
RUNNER_BASE="${RUNNER_BASE:-${DEFAULT_RUNNER_BASE}}"
RUNNER_VERSION="${RUNNER_VERSION:-${DEFAULT_RUNNER_VERSION}}"
RUN_USER="${RUN_USER:-${SUDO_USER:-${USER}}}"
# <id> segment of the name (gh-runner-<type>-<id>-<n>): a user or host tag. Default the host short
# name; override with --owner (e.g. a username on a shared multi-host fleet).
OWNER="${OWNER:-$(hostname -s)}"
# Credential vars — default-init (empty) without a quoted assignment literal.
: "${RUNNER_TOKEN:=}"
: "${BROKER_URL:=}"
: "${BROKER_SECRET:=}"
: "${ACCESS_TOKEN:=}"

# ── Arg parsing ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)            GH_ORG="$2";          shift 2 ;;
    --labels)         RUNNER_LABELS="$2";   shift 2 ;;
    --token)          RUNNER_TOKEN="$2";    shift 2 ;;
    --broker-url)     BROKER_URL="$2";      shift 2 ;;
    --broker-secret)  BROKER_SECRET="$2";   shift 2 ;;
    --access-token)   ACCESS_TOKEN="$2";    shift 2 ;;
    --count)          COUNT="$2";           shift 2 ;;
    --user)           RUN_USER="$2";        shift 2 ;;
    --owner)          OWNER="$2";           shift 2 ;;
    --runner-base)    RUNNER_BASE="$2";     shift 2 ;;
    --runner-version) RUNNER_VERSION="$2";  shift 2 ;;
    *) echo "Unknown flag: $1" >&2
       echo "Usage: sudo $0 (--token T | --broker-url URL [--broker-secret S] | --access-token PAT)" >&2
       echo "         [--org ORG] [--labels LABELS] [--count N] [--user USER] [--runner-base DIR] [--runner-version V]" >&2
       exit 1 ;;
  esac
done

info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*" >&2; }
fatal() { echo "[ERROR] $*" >&2; exit 1; }

# Append one KEY="value" line to a config.env. Done via a helper (not literal assignments in this
# script) so credential values are never embedded in source and static scanners don't misfire.
_write_kv() { printf '%s="%s"\n' "$1" "$2" >> "$3"; }

# ── Preflight ──────────────────────────────────────────────────────────────────
[[ "$(uname -s)" == "Linux" ]] || fatal "This installer is Linux-only (use ios/ for macOS)."
[[ "$(id -u)" -eq 0 ]] || fatal "Run with sudo (needs to write /etc/systemd/system and chown runner dirs)."
command -v systemctl &>/dev/null || fatal "systemctl not found — this installer targets systemd hosts."
command -v curl &>/dev/null || fatal "'curl' is required."
command -v tar  &>/dev/null || fatal "'tar' is required."
command -v python3 &>/dev/null || fatal "'python3' is required (runner-loop.sh parses token JSON with it)."
id "${RUN_USER}" &>/dev/null || fatal "Run user '${RUN_USER}' does not exist (pass --user)."

if [[ -z "${RUNNER_TOKEN}" && -z "${BROKER_URL}" && -z "${ACCESS_TOKEN}" ]]; then
  fatal "No credential supplied. Pass one of --token / --broker-url / --access-token."
fi
[[ -f "${SCRIPT_DIR}/runner-loop.sh" ]] || fatal "runner-loop.sh missing — run install.sh from the supabase/ dir."
[[ -f "${SCRIPT_DIR}/${SERVICE_NAME}" ]] || fatal "${SERVICE_NAME} template missing — run from the supabase/ dir."

ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64)  RUNNER_ARCH="x64" ;;
  aarch64) RUNNER_ARCH="arm64" ;;
  *) fatal "Unsupported arch '${ARCH}' (expected x86_64 or aarch64)." ;;
esac

# ── Download actions/runner tarball once (shared across instances) ─────────────
RUNNER_TGZ="actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_TGZ}"
TMP_TGZ="$(mktemp /tmp/actions-runner-XXXXXX.tar.gz)"
info "Downloading actions/runner v${RUNNER_VERSION} (linux-${RUNNER_ARCH})..."
curl --location --fail --progress-bar --output "${TMP_TGZ}" "${RUNNER_URL}"
# TODO: verify the published SHA256 (sibling .sha256 on the release) before extracting.

# ── Per-instance setup ─────────────────────────────────────────────────────────
for i in $(seq 1 "${COUNT}"); do
  INST_DIR="${RUNNER_BASE}/${i}"
  info "Setting up instance ${i} → ${INST_DIR}"
  mkdir -p "${INST_DIR}"
  tar -xzf "${TMP_TGZ}" -C "${INST_DIR}"

  # config.env — create mode 600 BEFORE writing any credential (no world-readable window).
  CONFIG_ENV="${INST_DIR}/config.env"
  install -m 600 -o "${RUN_USER}" /dev/null "${CONFIG_ENV}"
  {
    echo "# Generated by install.sh — do not edit by hand; re-run install.sh to update. Mode 600."
  } > "${CONFIG_ENV}"
  _write_kv GH_ORG        "${GH_ORG}"        "${CONFIG_ENV}"
  _write_kv RUNNER_LABELS "${RUNNER_LABELS}" "${CONFIG_ENV}"
  _write_kv RUNNER_NAME   "gh-runner-${RUNNER_TYPE}-${OWNER}-${i}" "${CONFIG_ENV}"
  _write_kv RUNNER_TOKEN  "${RUNNER_TOKEN}"  "${CONFIG_ENV}"
  _write_kv BROKER_URL    "${BROKER_URL}"    "${CONFIG_ENV}"
  _write_kv BROKER_SECRET "${BROKER_SECRET}" "${CONFIG_ENV}"
  _write_kv ACCESS_TOKEN  "${ACCESS_TOKEN}"  "${CONFIG_ENV}"
  chmod 600 "${CONFIG_ENV}"

  cp "${SCRIPT_DIR}/runner-loop.sh" "${INST_DIR}/runner-loop.sh"
  chmod 755 "${INST_DIR}/runner-loop.sh"
  chown -R "${RUN_USER}" "${INST_DIR}"
done
rm -f "${TMP_TGZ}"

# ── Install + enable systemd template ──────────────────────────────────────────
DEST_UNIT="/etc/systemd/system/${SERVICE_NAME}"
info "Installing systemd template → ${DEST_UNIT}"
sed -e "s|__RUNNER_BASE__|${RUNNER_BASE}|g" -e "s|__RUN_USER__|${RUN_USER}|g" \
  "${SCRIPT_DIR}/${SERVICE_NAME}" > "${DEST_UNIT}"
systemctl daemon-reload
for i in $(seq 1 "${COUNT}"); do
  systemctl enable --now "gh-runner@${i}.service"
  info "Started gh-runner@${i}.service"
done

echo ""
echo "==========================================================="
echo " supabase runners installed: ${COUNT} instance(s) under ${RUNNER_BASE}"
echo " Run user : ${RUN_USER}    Org: ${GH_ORG}    Labels: ${RUNNER_LABELS}"
echo "==========================================================="
echo " Status : systemctl status 'gh-runner@*'"
echo " Logs   : journalctl -u 'gh-runner@1' -f"
echo " Stop   : systemctl disable --now gh-runner@1   (per instance)"
echo " Uninstall: sudo ./uninstall.sh --count ${COUNT} --runner-base ${RUNNER_BASE}"
echo "==========================================================="
