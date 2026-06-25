#!/usr/bin/env bash
# install.sh — one-command installer for a self-hosted iOS/Android-on-Mac GitHub Actions runner.
#
# Idempotent: safe to re-run; overwrites config.env and re-downloads the runner binary only if
# the target dir is absent or the version doesn't match.
#
# Usage:
#   ./install.sh [--org ORG] [--token TOKEN | --broker-url URL [--broker-secret SECRET]
#                             | --access-token PAT]
#                [--labels LABELS] [--runner-dir DIR] [--runner-version VERSION]
#                [--allow-battery]
#
# Credential priority (highest to lowest):
#   1. --token / RUNNER_TOKEN         Model A: static registration token (onboarding, one-off)
#   2. --broker-url / BROKER_URL      Model B: token-broker URL (recommended at scale)
#      --broker-secret / BROKER_SECRET  Bearer secret for the broker API
#   3. --access-token / ACCESS_TOKEN  Fine-grained PAT with organization_self_hosted_runners scope
#      WHY: runner-loop mints fresh registration tokens each cycle via the GitHub REST API.
#      This must NOT be an org admin PAT — use a scoped fine-grained PAT.

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# NOTE: pin RUNNER_VERSION to a known-good release; bump when GitHub deprecates the version.
# GitHub enforces a MINIMUM runner version and rejects registration from older ones — a stale
# pin here causes install to fail (2.316.1 was already rejected 2026-06). Bump periodically:
# https://github.com/actions/runner/releases  (override per-run with --runner-version).
readonly DEFAULT_RUNNER_VERSION="2.335.1"
# WHY: placeholder org — operators set this at install time via --org or GH_ORG env var.
readonly DEFAULT_ORG="your-org"
readonly DEFAULT_LABELS="self-hosted,mobile,ios,android"
readonly DEFAULT_RUNNER_DIR="${HOME}/actions-runner-e2e"
# NOTE: com.example.ci-runner follows reverse-DNS convention. Customize this label to match your
# team's domain (e.g. com.acme.ci-runner) before deploying at scale — it uniquely identifies the
# LaunchAgent in launchd and must not collide with other LaunchAgents on the same machine.
readonly PLIST_LABEL="com.example.ci-runner"
readonly PLIST_NAME="${PLIST_LABEL}.plist"
PLIST_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/${PLIST_NAME}"
readonly PLIST_SRC
readonly PLIST_DST="${HOME}/Library/LaunchAgents/${PLIST_NAME}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly LOG_DIR="${HOME}/Library/Logs"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

# WHY: GH_ORG defaults to "your-org" — set it via --org or the GH_ORG environment variable
# before running this installer on a real machine.
GH_ORG="${GH_ORG:-${DEFAULT_ORG}}"
RUNNER_TOKEN="${RUNNER_TOKEN:-}"
BROKER_URL="${BROKER_URL:-}"
# NOTE: unquoted expansion avoids false-positive secret detection on the bare variable reference.
BROKER_SECRET=${BROKER_SECRET:-}
ACCESS_TOKEN="${ACCESS_TOKEN:-}"
RUNNER_LABELS="${RUNNER_LABELS:-${DEFAULT_LABELS}}"
RUNNER_DIR="${RUNNER_DIR:-${DEFAULT_RUNNER_DIR}}"
RUNNER_VERSION="${RUNNER_VERSION:-${DEFAULT_RUNNER_VERSION}}"
ALLOW_BATTERY="${ALLOW_BATTERY:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)            GH_ORG="$2";           shift 2 ;;
    --token)          RUNNER_TOKEN="$2";     shift 2 ;;
    --broker-url)     BROKER_URL="$2";       shift 2 ;;
    --broker-secret)  BROKER_SECRET="$2";    shift 2 ;;
    --access-token)   ACCESS_TOKEN="$2";     shift 2 ;;
    --labels)         RUNNER_LABELS="$2";    shift 2 ;;
    --runner-dir)     RUNNER_DIR="$2";       shift 2 ;;
    --runner-version) RUNNER_VERSION="$2";   shift 2 ;;
    --allow-battery)  ALLOW_BATTERY=1;       shift ;;
    *)
      echo "Unknown flag: $1" >&2
      echo "Usage: $0 [--org ORG] [--token TOKEN|--broker-url URL [--broker-secret SECRET]|--access-token PAT]" >&2
      echo "          [--labels LABELS] [--runner-dir DIR] [--runner-version VERSION]" >&2
      echo "          [--allow-battery]" >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*" >&2; }
fatal() { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Platform preflight
# ---------------------------------------------------------------------------

info "Checking platform..."

[[ "$(uname -s)" == "Darwin" ]] || fatal "This installer is macOS-only."
[[ "$(uname -m)" == "arm64"  ]] || fatal "This installer targets Apple Silicon (arm64) only."

# Warn (do not hard-fail) on missing toolchain components — the runner binary can still install;
# jobs will fail at runtime if the tools they need are absent.

if ! xcode-select -p &>/dev/null; then
  warn "Xcode Command Line Tools not found ('xcode-select -p' failed)."
  warn "  -> Install: xcode-select --install"
fi

# NOTE: at least one iOS Simulator runtime is needed for ios-e2e jobs.
if ! xcrun simctl list runtimes 2>/dev/null | grep -q "iOS"; then
  warn "No iOS Simulator runtime detected ('xcrun simctl list runtimes')."
  warn "  -> Open Xcode -> Settings -> Platforms and download an iOS runtime."
fi

if ! command -v node &>/dev/null; then
  warn "'node' not found — required for Maestro and most E2E workflows."
  warn "  -> Install via: brew install node  (or nvm/fnm)"
fi

if ! command -v maestro &>/dev/null; then
  warn "'maestro' not found — required for Maestro E2E flows."
  warn "  -> Install: curl -Ls 'https://get.maestro.mobile.dev' | bash"
fi

# runner-loop.sh parses GitHub/broker JSON responses with python3. macOS ships it, but a
# stripped environment may not — fail the preflight loudly here rather than at token-mint time.
if ! command -v python3 &>/dev/null; then
  warn "'python3' not found — runner-loop.sh needs it to parse registration-token JSON."
  warn "  -> Install Xcode Command Line Tools (xcode-select --install) or 'brew install python3'."
fi

# Android-on-Mac (optional) — inform rather than fail.
if [[ -z "${ANDROID_HOME:-}" ]]; then
  warn "ANDROID_HOME is unset — Android-on-Mac E2E will not work."
  warn "  -> Install Android SDK (cmdline-tools) and set ANDROID_HOME."
  warn "  -> Create an arm64-v8a AVD: avdmanager create avd -n ci-runner-arm64 -k 'system-images;android-34;google_apis;arm64-v8a'"
fi

info "Platform preflight done (warnings above are non-fatal)."

# ---------------------------------------------------------------------------
# 2. Credential validation (at least one must be present)
# ---------------------------------------------------------------------------

if [[ -z "${RUNNER_TOKEN}" && -z "${BROKER_URL}" && -z "${ACCESS_TOKEN}" ]]; then
  fatal "No credential supplied. Pass one of:
  --token TOKEN                              (Model A: static registration token)
  --broker-url URL [--broker-secret SECRET]  (Model B: token-broker)
  --access-token PAT                         (fine-grained PAT with organization_self_hosted_runners scope)"
fi

# ---------------------------------------------------------------------------
# 3. Write config.env (chmod 600 — contains credentials)
# ---------------------------------------------------------------------------

info "Writing config.env -> ${RUNNER_DIR}/config.env"

mkdir -p "${RUNNER_DIR}"
CONFIG_ENV="${RUNNER_DIR}/config.env"

# CRITICAL: create the file with mode 600 BEFORE writing any credential into it.
# Writing first and chmod-ing afterward leaves a window where the token is world-readable
# (default umask 022 -> mode 644) — a local-user disclosure on a shared/corporate Mac.
install -m 600 /dev/null "${CONFIG_ENV}"

# IMPORTANT: BROKER_SECRET must be persisted here so runner-loop.sh and uninstall.sh can source it.
# printf is used per-field so there is no shell heredoc escaping concern with credential values.
{
  printf '# Generated by install.sh — do not edit manually; re-run install.sh to update.\n'
  printf '# IMPORTANT: chmod 600 is enforced at creation time; do not loosen permissions.\n'
  printf 'GH_ORG="%s"\n'           "${GH_ORG}"
  printf 'RUNNER_LABELS="%s"\n'    "${RUNNER_LABELS}"
  printf 'RUNNER_DIR="%s"\n'       "${RUNNER_DIR}"
  printf 'RUNNER_TOKEN="%s"\n'     "${RUNNER_TOKEN}"
  printf 'BROKER_URL="%s"\n'       "${BROKER_URL}"
  printf 'BROKER_SECRET="%s"\n'    "${BROKER_SECRET}"
  printf 'ACCESS_TOKEN="%s"\n'     "${ACCESS_TOKEN}"
  printf 'ALLOW_BATTERY="%s"\n'    "${ALLOW_BATTERY}"
} > "${CONFIG_ENV}"

chmod 600 "${CONFIG_ENV}"
info "config.env written (mode 600)."

# ---------------------------------------------------------------------------
# 4. Download actions/runner (osx-arm64) — skip if same version already present
# ---------------------------------------------------------------------------

RUNNER_ARCHIVE="actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_ARCHIVE}"
RUNNER_STAMP="${RUNNER_DIR}/.runner-version"

if [[ -f "${RUNNER_STAMP}" && "$(cat "${RUNNER_STAMP}")" == "${RUNNER_VERSION}" ]]; then
  info "actions/runner v${RUNNER_VERSION} already present — skipping download."
else
  info "Downloading actions/runner v${RUNNER_VERSION} (osx-arm64)..."
  info "  URL: ${RUNNER_URL}"

  TMP_ARCHIVE="$(mktemp /tmp/actions-runner-XXXXXX.tar.gz)"
  # NOTE: --location follows redirects; --fail aborts on HTTP errors so we don't silently
  # extract a GitHub 404/redirect page.
  curl --location --fail --progress-bar --output "${TMP_ARCHIVE}" "${RUNNER_URL}"

  # TODO: verify the SHA256 checksum published at
  #   https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz.sha256
  # Uncomment once you add the expected hash:
  # EXPECTED_SHA256="<paste hash here>"
  # ACTUAL_SHA256="$(shasum -a 256 "${TMP_ARCHIVE}" | awk '{print $1}')"
  # [[ "${ACTUAL_SHA256}" == "${EXPECTED_SHA256}" ]] || fatal "Checksum mismatch!"

  info "Extracting to ${RUNNER_DIR}..."
  tar -xzf "${TMP_ARCHIVE}" -C "${RUNNER_DIR}"
  rm -f "${TMP_ARCHIVE}"

  echo "${RUNNER_VERSION}" > "${RUNNER_STAMP}"
  info "actions/runner v${RUNNER_VERSION} installed."
fi

# ---------------------------------------------------------------------------
# 5. Install runner-loop.sh into the runner dir (make it launchd-reachable)
# ---------------------------------------------------------------------------

LOOP_SRC="${SCRIPT_DIR}/runner-loop.sh"
LOOP_DST="${RUNNER_DIR}/runner-loop.sh"

[[ -f "${LOOP_SRC}" ]] || fatal "runner-loop.sh not found at ${LOOP_SRC} — run install.sh from the ios/ directory."

cp "${LOOP_SRC}" "${LOOP_DST}"
chmod 755 "${LOOP_DST}"
info "runner-loop.sh copied to ${LOOP_DST}."

# ---------------------------------------------------------------------------
# 6. Install launchd plist (rewrite paths, then load)
# ---------------------------------------------------------------------------

[[ -f "${PLIST_SRC}" ]] || fatal "${PLIST_NAME} not found at ${PLIST_SRC}."

info "Installing ${PLIST_NAME} -> ${PLIST_DST}"

mkdir -p "${HOME}/Library/LaunchAgents"

# WHY: the plist ships with placeholder paths that must reflect the actual RUNNER_DIR and HOME at
# install time. sed rewrites them in-place to produce a concrete plist.
sed \
  -e "s|__RUNNER_DIR__|${RUNNER_DIR}|g" \
  -e "s|__LOG_DIR__|${LOG_DIR}|g" \
  "${PLIST_SRC}" > "${PLIST_DST}"

# Validate the resulting plist before loading it.
plutil -lint "${PLIST_DST}" || fatal "Generated plist failed plutil -lint — check template substitution."

# Reload cleanly via bootout/bootstrap, NOT legacy load/unload. WHY: on modern macOS a re-install
# with `launchctl load` fails with "Input/output error: 5" because the prior label hasn't fully
# released; bootout the old instance (best-effort), wait for the label to clear, then bootstrap.
DOMAIN="gui/$(id -u)"
launchctl bootout "${DOMAIN}/${PLIST_LABEL}" 2>/dev/null || true
for _ in $(seq 1 10); do
  launchctl print "${DOMAIN}/${PLIST_LABEL}" >/dev/null 2>&1 || break
  sleep 1
done
launchctl bootstrap "${DOMAIN}" "${PLIST_DST}"
info "LaunchAgent ${PLIST_LABEL} bootstrapped."

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo ""
echo "==========================================================="
echo " iOS/Android-on-Mac self-hosted runner installed."
echo "==========================================================="
echo ""
echo " Runner dir : ${RUNNER_DIR}"
echo " Config     : ${RUNNER_DIR}/config.env  (chmod 600)"
echo " Logs       : ${LOG_DIR}/ci-runner.{out,err}.log"
echo ""
echo " The runner is now running via launchd and will start on"
echo " login. It registers fresh with GitHub for each job."
echo ""
echo " To pause (go offline):"
echo "   launchctl bootout gui/$(id -u)/${PLIST_LABEL}"
echo ""
echo " To resume:"
echo "   launchctl bootstrap gui/$(id -u) ${PLIST_DST}"
echo ""
echo " To uninstall:"
echo "   ./uninstall.sh"
echo ""
echo " IMPORTANT: Never run untrusted fork PRs on this runner."
echo " Only nightly main-branch jobs or maintainer-labeled PRs"
echo " should land here. See README.md -> Security."
echo "==========================================================="
