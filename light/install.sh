#!/usr/bin/env bash
# install.sh — set up N ephemeral "light" GitHub Actions runners (vanilla actions/runner + systemd).
#
# Installs the official actions/runner into one dir per instance under a base dir, writes each a
# config.env (mode 600), and registers a systemd template service (gh-runner-light@1 .. gh-runner-light@N)
# that runs runner-loop.sh. No Docker, no third-party image.
#
# Run with sudo (writes /etc/systemd/system and chowns runner dirs to the run user).
#
# Usage:
#   sudo ./install.sh (--token TOKEN | --broker-url URL [--broker-secret SECRET] | --access-token PAT)
#                     [--org ORG] [--runner-type TYPE] [--labels LABELS] [--count N] [--user RUN_USER]
#                     [--runner-base DIR] [--runner-version VERSION]
#                     [--extra-packages "p1 p2"] [--skip-job-deps]
#                     [--toolcache-dir DIR] [--skip-toolcache] [--stage-python VER ...]
#                     [--with-playwright] [--playwright-version V] [--playwright-browser B]
#                     [--playwright-browsers-path DIR]
#                     [--no-auto-update] [--update-repo SLUG] [--update-ref REF]
#                     [--update-min-interval SECONDS]
#
# Credential priority (high -> low): static token -> broker -> PAT. Supply exactly one.
#
# Hosted-runner parity: by default this installs a baseline of job-runtime OS packages
# (unzip/zip/xz-utils/zstd) and points the runner at a shared tool cache via AGENT_TOOLSDIRECTORY.
# Pass --stage-python 3.13 (repeatable) to pre-stage a Python there — REQUIRED for actions/setup-python
# on non-Ubuntu hosts (Debian etc.), which cannot download a prebuilt Python and otherwise error.
#
# Playwright capability: --with-playwright installs Chromium's system libraries (root apt, via
# `playwright install-deps`) and points jobs at a shared, persistent browser cache
# (PLAYWRIGHT_BROWSERS_PATH, baked into the unit) so `playwright install` is a fast cache hit needing
# no root. It also appends the `playwright` label so browser jobs can target this runner. See
# docs/fleet-design.md. Consumers drop `--with-deps` and target the `playwright` capability.

set -euo pipefail

# ── Defaults ───────────────────────────────────────────────────────────────────
# NOTE: GitHub enforces a MINIMUM runner version and rejects registration from older ones; bump this
# periodically. Releases: https://github.com/actions/runner/releases (override with --runner-version).
readonly DEFAULT_RUNNER_VERSION="2.335.1"
readonly DEFAULT_ORG="your-org"
readonly DEFAULT_RUNNER_TYPE="light"   # <type> in gh-runner-<type>-<id>-<n>; override with --runner-type
readonly DEFAULT_COUNT=2
readonly SERVICE_NAME="gh-runner@.service"
# RUNNER_TYPE selects the per-type label, base dir, registered name, and systemd unit name (all derived
# AFTER arg parsing so --runner-type is known). Default "light"; --runner-type playwright stands up a
# dedicated browser runner (with --with-playwright) whose unit (gh-runner-playwright@.service), base
# (/opt/gh-runner-playwright), and name won't collide with the plain light runners. SERVICE_NAME is the
# generic source template; UNIT_NAME is the installed, per-type unit so co-hosted types don't clash.
RUNNER_TYPE="${RUNNER_TYPE:-${DEFAULT_RUNNER_TYPE}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; readonly SCRIPT_DIR

GH_ORG="${GH_ORG:-${DEFAULT_ORG}}"
RUNNER_LABELS="${RUNNER_LABELS:-}"   # type-derived default (self-hosted,linux,x64,<type>) filled in post-parse
COUNT="${COUNT:-${DEFAULT_COUNT}}"
RUNNER_BASE="${RUNNER_BASE:-}"       # type-derived default (/opt/gh-runner-<type>) filled in post-parse
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
# Fleet self-update knobs. AUTO_UPDATE=1 enables automatic fleet-code updates between jobs;
# set 0 via --no-auto-update to disable on this host (operator opt-out is permanent until reinstall).
AUTO_UPDATE="1"
UPDATE_REPO="islee/gh-runners"
UPDATE_REF=""           # empty = broker-driven per cycle (recommended); set to pin a specific ref
UPDATE_MIN_INTERVAL="300"

# Job-runtime parity (see install_job_deps / provision_toolcache). GitHub-hosted runners ship a
# baseline of tools that setup-* actions and typical jobs assume; a bare host has none, so jobs fail
# at runtime. We declare them here and install ahead of time.
#   - DEFAULT_JOB_PACKAGES: hosted-runner baseline that setup-* actions shell out to —
#     unzip (setup-deno/cmdline-tools), zip, xz-utils/zstd (actions/cache compression),
#     lsb-release (setup-python OS detection), ca-certificates (TLS). Extend with --extra-packages.
#   - TOOLCACHE_DIR: shared, persistent tool cache the runner is pointed at via AGENT_TOOLSDIRECTORY.
#   - STAGE_PYTHON_VERSIONS: Python versions to pre-stage there (required for setup-python on
#     non-Ubuntu hosts, which cannot download a prebuilt Python). Populate with --stage-python.
readonly DEFAULT_JOB_PACKAGES="unzip zip xz-utils zstd lsb-release ca-certificates"
readonly DEFAULT_TOOLCACHE_DIR="/opt/hostedtoolcache"
JOB_PACKAGES="${JOB_PACKAGES:-${DEFAULT_JOB_PACKAGES}}"
EXTRA_PACKAGES=""
SKIP_JOB_DEPS=0
TOOLCACHE_DIR="${TOOLCACHE_DIR:-${DEFAULT_TOOLCACHE_DIR}}"
SKIP_TOOLCACHE=0
STAGE_PYTHON_VERSIONS=()

# Playwright capability (opt-in via --with-playwright). PLAYWRIGHT_BROWSERS_PATH is a shared,
# persistent cache pointed at by every job via the systemd unit; install-deps installs the system
# libraries for PLAYWRIGHT_BROWSER (the root-requiring part). Empty version = latest.
readonly DEFAULT_PLAYWRIGHT_BROWSERS_PATH="/opt/ms-playwright"
WITH_PLAYWRIGHT=0
PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-${DEFAULT_PLAYWRIGHT_BROWSERS_PATH}}"
PLAYWRIGHT_VERSION=""        # empty = latest published @playwright/test
PLAYWRIGHT_BROWSER="chromium"

# ── Arg parsing ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)            GH_ORG="$2";          shift 2 ;;
    --runner-type)    RUNNER_TYPE="$2";     shift 2 ;;   # type segment: label/base/unit/name (default light)
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
    --extra-packages) EXTRA_PACKAGES="$2";  shift 2 ;;   # extra apt packages to install ahead of time
    --skip-job-deps)  SKIP_JOB_DEPS=1;      shift   ;;   # do not install job-runtime OS packages
    --toolcache-dir)  TOOLCACHE_DIR="$2";   shift 2 ;;   # shared tool cache dir (AGENT_TOOLSDIRECTORY)
    --skip-toolcache) SKIP_TOOLCACHE=1;     shift   ;;   # do not create/stage the tool cache
    --stage-python)         STAGE_PYTHON_VERSIONS+=("$2"); shift 2 ;;  # repeatable: pre-stage Python <ver> (e.g. 3.13)
    --with-playwright)          WITH_PLAYWRIGHT=1;             shift   ;;   # provision the Playwright browser capability
    --playwright-version)       PLAYWRIGHT_VERSION="$2";       shift 2 ;;   # pin the playwright npm version (empty = latest)
    --playwright-browser)       PLAYWRIGHT_BROWSER="$2";       shift 2 ;;   # browser to deps/pre-warm (default chromium)
    --playwright-browsers-path) PLAYWRIGHT_BROWSERS_PATH="$2"; shift 2 ;;   # shared browser cache dir (PLAYWRIGHT_BROWSERS_PATH)
    --no-auto-update)       AUTO_UPDATE="0";        shift   ;;   # disable fleet-code auto-update on this host
    --update-repo)          UPDATE_REPO="$2";       shift 2 ;;   # source repo for raw.githubusercontent fetches
    --update-ref)           UPDATE_REF="$2";        shift 2 ;;   # pin a specific ref (empty = broker-driven)
    --update-min-interval)  UPDATE_MIN_INTERVAL="$2"; shift 2 ;; # seconds floor between update checks
    *) echo "Unknown flag: $1" >&2
       echo "Usage: sudo $0 (--token T | --broker-url URL [--broker-secret S] | --access-token PAT)" >&2
       echo "         [--org ORG] [--runner-type TYPE] [--labels LABELS] [--count N] [--user USER] [--runner-base DIR] [--runner-version V]" >&2
       echo "         [--extra-packages \"p1 p2\"] [--skip-job-deps] [--toolcache-dir DIR] [--skip-toolcache] [--stage-python VER ...]" >&2
       echo "         [--with-playwright] [--playwright-version V] [--playwright-browser B] [--playwright-browsers-path DIR]" >&2
       echo "         [--no-auto-update] [--update-repo SLUG] [--update-ref REF] [--update-min-interval SECONDS]" >&2
       exit 1 ;;
  esac
done

info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*" >&2; }
fatal() { echo "[ERROR] $*" >&2; exit 1; }

# Append one KEY="value" line to a config.env. Done via a helper (not literal assignments in this
# script) so credential values are never embedded in source and static scanners don't misfire.
_write_kv() { printf '%s="%s"\n' "$1" "$2" >> "$3"; }

# Derive type-based defaults now that --runner-type is known. RUNNER_TYPE feeds the unit name and
# filesystem paths, so validate it to a safe charset first.
[[ "${RUNNER_TYPE}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fatal "Invalid --runner-type '${RUNNER_TYPE}' (lowercase alnum + dashes)."
: "${RUNNER_LABELS:=self-hosted,linux,x64,${RUNNER_TYPE}}"
: "${RUNNER_BASE:=/opt/gh-runner-${RUNNER_TYPE}}"
UNIT_NAME="gh-runner-${RUNNER_TYPE}@.service"

# When provisioning the Playwright capability, append the `playwright` label so browser jobs can
# target this runner (idempotent — skip if already present). Done after arg parsing so an explicit
# --labels is respected and merely extended.
if (( WITH_PLAYWRIGHT )) && [[ ",${RUNNER_LABELS}," != *",playwright,"* ]]; then
  RUNNER_LABELS="${RUNNER_LABELS},playwright"
fi

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
[[ -f "${SCRIPT_DIR}/runner-loop.sh" ]]     || fatal "runner-loop.sh missing — run install.sh from the light/ dir."
[[ -f "${SCRIPT_DIR}/runner-bootstrap.sh" ]] || fatal "runner-bootstrap.sh missing — run install.sh from the light/ dir."
[[ -f "${SCRIPT_DIR}/self-update.sh" ]]      || fatal "self-update.sh missing — run install.sh from the light/ dir."
[[ -f "${SCRIPT_DIR}/${SERVICE_NAME}" ]]     || fatal "${SERVICE_NAME} template missing — run from the light/ dir."

ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64)  RUNNER_ARCH="x64" ;;
  aarch64) RUNNER_ARCH="arm64" ;;
  *) fatal "Unsupported arch '${ARCH}' (expected x86_64 or aarch64)." ;;
esac

# ── Job-runtime dependencies — install ahead of time (hosted-runner parity) ─────
# WHY here (before the runner download): a missing tool surfaces only mid-job as a confusing
# "Unable to locate executable file: <tool>" failure. Declaring + installing the baseline up front
# turns that runtime surprise into a deterministic provisioning step.
install_job_deps() {
  (( SKIP_JOB_DEPS )) && { info "Skipping job-runtime dependency install (--skip-job-deps)."; return 0; }
  local pkgs="${JOB_PACKAGES} ${EXTRA_PACKAGES}"
  if command -v apt-get &>/dev/null; then
    info "Installing job-runtime dependencies ahead of time: ${pkgs}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    # shellcheck disable=SC2086  # word-splitting is intentional — pkgs is a space-separated list.
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${pkgs}
  else
    warn "apt-get not found — install these job-runtime deps yourself before running jobs: ${pkgs}"
  fi
}

# ── Tool cache for setup-python (and -node/-deno) — non-Ubuntu native hosts ──────
# actions/setup-python only publishes prebuilt Pythons for Ubuntu; on Debian/other distros it cannot
# download one and errors ("version 'X' ... was not found for this operating system") UNLESS the
# version is already in the runner tool cache. We point the runner at a shared, persistent cache via
# AGENT_TOOLSDIRECTORY (baked into the systemd unit) and pre-stage requested versions here using
# actions/python-versions' own setup.sh — the same mechanism GitHub uses to build hosted images.
stage_python_toolcache() {
  local spec="$1"   # e.g. 3.13 or 3.13.14
  info "Staging Python '${spec}' into tool cache ${TOOLCACHE_DIR} ..."
  local manifest full url
  manifest="$(curl -fsSL https://raw.githubusercontent.com/actions/python-versions/main/versions-manifest.json)" \
    || fatal "Could not fetch the python-versions manifest."
  # Resolve the highest stable build matching <spec> that has a linux/<arch> asset; prefer newer
  # Ubuntu (binaries are forward-compatible with newer glibc, so 24.04 runs fine on Debian 13).
  read -r full url < <(printf '%s' "${manifest}" | python3 -c '
import json, sys
spec, arch = sys.argv[1], sys.argv[2]
data = json.load(sys.stdin)                       # manifest is newest-first
def match(v): return v == spec or v.startswith(spec + ".")
for rel in data:
    if rel.get("stable") is not True or not match(rel["version"]):
        continue
    files = {f["platform_version"]: f for f in rel["files"]
             if f["platform"] == "linux" and f["arch"] == arch}
    for pv in ("24.04", "22.04", "20.04"):
        if pv in files:
            print(rel["version"], files[pv]["download_url"]); sys.exit(0)
sys.exit(1)
' "${spec}" "${RUNNER_ARCH}") \
    || fatal "No linux/${RUNNER_ARCH} python-versions build matches '${spec}'."
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL "${url}" -o "${tmp}/py.tgz" || fatal "Download failed: ${url}"
  tar -xzf "${tmp}/py.tgz" -C "${tmp}"
  # setup.sh reads AGENT_TOOLSDIRECTORY, lays out Python/<ver>/<arch>, and writes the .complete marker.
  ( cd "${tmp}" && AGENT_TOOLSDIRECTORY="${TOOLCACHE_DIR}" bash ./setup.sh )
  rm -rf "${tmp}"
  info "Staged Python ${full} → ${TOOLCACHE_DIR}/Python/${full}/${RUNNER_ARCH}"
}

provision_toolcache() {
  (( SKIP_TOOLCACHE )) && { info "Skipping tool-cache provisioning (--skip-toolcache)."; return 0; }
  mkdir -p "${TOOLCACHE_DIR}"
  local v
  for v in "${STAGE_PYTHON_VERSIONS[@]:-}"; do
    [[ -n "${v}" ]] && stage_python_toolcache "${v}"
  done
  # Runner must read/write the cache (setup-node/-deno populate it on first use).
  chown -R "${RUN_USER}" "${TOOLCACHE_DIR}"
}

# ── Playwright capability — system libs (root) + shared browser cache ────────────
# Splits Playwright's two costs (see docs/fleet-design.md): the OS browser libraries need root and
# change rarely → install once here; the browser binaries are per-version → cache them in a shared,
# persistent PLAYWRIGHT_BROWSERS_PATH (baked into the unit) so each job is a cache hit needing no root.
# Drives the official `playwright` CLI so the apt set tracks the OS, rather than hardcoding a fragile
# package list. Failures warn (not fatal): a job can still self-install at runtime, just slower.
provision_playwright() {
  (( WITH_PLAYWRIGHT )) || return 0
  local pkgspec="playwright"
  [[ -n "${PLAYWRIGHT_VERSION}" ]] && pkgspec="playwright@${PLAYWRIGHT_VERSION}"

  # npx drives install-deps/install. Prefer an existing Node; apt-install nodejs/npm if absent.
  if ! command -v npx &>/dev/null; then
    if command -v apt-get &>/dev/null; then
      info "Installing nodejs/npm (needed to drive 'playwright install-deps')."
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs npm
    fi
  fi
  command -v npx &>/dev/null || { warn "npx unavailable — skipping Playwright provisioning (install Node, then re-run)."; return 0; }

  # 1. System libraries (root). install-deps resolves the correct apt set for this OS.
  info "Installing Playwright system dependencies (${pkgspec} install-deps ${PLAYWRIGHT_BROWSER}) ..."
  npx --yes "${pkgspec}" install-deps "${PLAYWRIGHT_BROWSER}" \
    || warn "playwright install-deps failed — browser jobs may miss system libs."

  # 2. Shared, persistent browser cache; pre-warm the browser binary into it.
  mkdir -p "${PLAYWRIGHT_BROWSERS_PATH}"
  info "Pre-warming ${PLAYWRIGHT_BROWSER} into ${PLAYWRIGHT_BROWSERS_PATH} ..."
  PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH}" npx --yes "${pkgspec}" install "${PLAYWRIGHT_BROWSER}" \
    || warn "Playwright browser pre-warm failed — first job will populate the cache instead."
  # The runner (RUN_USER) must read/write the shared cache; later jobs add their own pinned versions.
  chown -R "${RUN_USER}" "${PLAYWRIGHT_BROWSERS_PATH}"
}

install_job_deps
provision_toolcache
provision_playwright

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

  # WHY: config.sh refuses to register ("already configured") if stale local registration files
  # from a previous install exist in the instance dir. Clearing them makes reinstall idempotent.
  # Safe because every cycle re-registers fresh with --replace/--ephemeral; a prior entry may
  # linger as OFFLINE in GitHub until GitHub prunes it.
  if [[ -f "${INST_DIR}/.runner" || -f "${INST_DIR}/.credentials" || -f "${INST_DIR}/.credentials_rsaparams" ]]; then
    info "Clearing stale local runner registration files in ${INST_DIR} (idempotent reinstall)."
    rm -f "${INST_DIR}/.runner" "${INST_DIR}/.credentials" "${INST_DIR}/.credentials_rsaparams"
  fi

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
  _write_kv BROKER_URL           "${BROKER_URL}"           "${CONFIG_ENV}"
  _write_kv BROKER_SECRET        "${BROKER_SECRET}"        "${CONFIG_ENV}"
  _write_kv ACCESS_TOKEN         "${ACCESS_TOKEN}"         "${CONFIG_ENV}"
  # Fleet self-update knobs (see self-update.sh for semantics).
  _write_kv AUTO_UPDATE          "${AUTO_UPDATE}"          "${CONFIG_ENV}"
  _write_kv UPDATE_REPO          "${UPDATE_REPO}"          "${CONFIG_ENV}"
  _write_kv UPDATE_REF           "${UPDATE_REF}"           "${CONFIG_ENV}"
  _write_kv UPDATE_MIN_INTERVAL  "${UPDATE_MIN_INTERVAL}"  "${CONFIG_ENV}"
  chmod 600 "${CONFIG_ENV}"

  # Install fleet-code scripts (runner-loop.sh is the updatable payload; bootstrap is stable).
  for _script in runner-loop.sh runner-bootstrap.sh self-update.sh; do
    cp "${SCRIPT_DIR}/${_script}" "${INST_DIR}/${_script}"
    chmod 755 "${INST_DIR}/${_script}"
  done

  # Seed the local fleet manifest and version stamp from the source dir (if present).
  # WHY: the version stamp lets the runner report its baseline to the broker immediately,
  # even before the first update; the manifest provides the content-hash for comparison.
  if [[ -f "${SCRIPT_DIR}/.fleet-manifest" ]]; then
    cp "${SCRIPT_DIR}/.fleet-manifest" "${INST_DIR}/.fleet-manifest"
    _seed_ver="$(grep '^version=' "${SCRIPT_DIR}/.fleet-manifest" | head -1 | cut -d= -f2)"
    [[ -n "${_seed_ver}" ]] && printf '%s\n' "${_seed_ver}" > "${INST_DIR}/.fleet-version"
  fi

  chown -R "${RUN_USER}" "${INST_DIR}"
done
rm -f "${TMP_TGZ}"

# ── Install + enable systemd template ──────────────────────────────────────────
DEST_UNIT="/etc/systemd/system/${UNIT_NAME}"
info "Installing systemd template → ${DEST_UNIT}"
# Only Playwright-provisioned runners carry PLAYWRIGHT_BROWSERS_PATH; others get a blank line.
PLAYWRIGHT_ENV_LINE=""
(( WITH_PLAYWRIGHT )) && PLAYWRIGHT_ENV_LINE="Environment=PLAYWRIGHT_BROWSERS_PATH=${PLAYWRIGHT_BROWSERS_PATH}"
sed -e "s|__RUNNER_BASE__|${RUNNER_BASE}|g" -e "s|__RUN_USER__|${RUN_USER}|g" \
  -e "s|__TOOLCACHE_DIR__|${TOOLCACHE_DIR}|g" \
  -e "s|__PLAYWRIGHT_ENV__|${PLAYWRIGHT_ENV_LINE}|" \
  "${SCRIPT_DIR}/${SERVICE_NAME}" > "${DEST_UNIT}"
systemctl daemon-reload
for i in $(seq 1 "${COUNT}"); do
  systemctl enable --now "gh-runner-${RUNNER_TYPE}@${i}.service"
  info "Started gh-runner-${RUNNER_TYPE}@${i}.service"
done

echo ""
echo "==========================================================="
echo " ${RUNNER_TYPE} runners installed: ${COUNT} instance(s) under ${RUNNER_BASE}"
echo " Run user : ${RUN_USER}    Org: ${GH_ORG}    Labels: ${RUNNER_LABELS}"
(( WITH_PLAYWRIGHT )) && echo " Playwright: capability ON — browser cache ${PLAYWRIGHT_BROWSERS_PATH} (label 'playwright')"
echo "==========================================================="
echo " Status : systemctl status 'gh-runner-${RUNNER_TYPE}@*'"
echo " Logs   : journalctl -u 'gh-runner-${RUNNER_TYPE}@1' -f"
echo " Stop   : systemctl disable --now gh-runner-${RUNNER_TYPE}@1   (per instance)"
echo " Uninstall: sudo ./uninstall.sh --count ${COUNT} --runner-base ${RUNNER_BASE}"
echo "==========================================================="
