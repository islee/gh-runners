#!/usr/bin/env bash
# uninstall.sh — remove the iOS/Android-on-Mac self-hosted runner from this Mac.
#
# Steps:
#   1. Unload the launchd agent (stops the runner loop).
#   2. Best-effort deregister from GitHub (frees the runner slot immediately).
#   3. Optionally purge the runner directory (--purge flag or interactive prompt).
#
# Usage:
#   ./uninstall.sh [--runner-dir DIR] [--purge] [--yes]

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

readonly DEFAULT_RUNNER_DIR="${HOME}/actions-runner-e2e"

RUNNER_DIR="${RUNNER_DIR:-${DEFAULT_RUNNER_DIR}}"
# LaunchAgent label — must match the value used at install time (--service-label / SERVICE_LABEL).
# Default matches install.sh's default; override if you installed with a custom label.
SERVICE_LABEL="${SERVICE_LABEL:-com.example.gh-runner}"
PURGE=0
YES=0   # skip interactive prompts

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runner-dir)     RUNNER_DIR="$2";    shift 2 ;;
    --service-label)  SERVICE_LABEL="$2"; shift 2 ;;
    --purge)          PURGE=1;            shift ;;
    --yes)            YES=1;              shift ;;
    *)
      echo "Unknown flag: $1" >&2
      echo "Usage: $0 [--runner-dir DIR] [--service-label LABEL] [--purge] [--yes]" >&2
      exit 1
      ;;
  esac
done

# Derive plist path from the (possibly overridden) service label.
PLIST_LABEL="${SERVICE_LABEL}"
PLIST_DST="${HOME}/Library/LaunchAgents/${PLIST_LABEL}.plist"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*" >&2; }

# ---------------------------------------------------------------------------
# 1. Unload launchd agent
# ---------------------------------------------------------------------------

if [[ -f "${PLIST_DST}" ]]; then
  info "Stopping LaunchAgent ${PLIST_LABEL}..."
  # bootout (modern) rather than legacy unload — see install.sh for the rationale.
  launchctl bootout "gui/$(id -u)/${PLIST_LABEL}" 2>/dev/null || warn "launchctl bootout failed (may already be stopped)."
  rm -f "${PLIST_DST}"
  info "Plist removed: ${PLIST_DST}"
else
  warn "Plist not found at ${PLIST_DST} — skipping unload."
fi

# ---------------------------------------------------------------------------
# 1b. Clear stale local runner registration files
# ---------------------------------------------------------------------------

# WHY: removes the local registration state so a future reinstall into the same dir starts clean.
# config.sh errors "already configured" if these exist — clearing them here is safe because the
# runner is about to be removed and will re-register fresh on next install.
if [[ -f "${RUNNER_DIR}/.runner" || -f "${RUNNER_DIR}/.credentials" || -f "${RUNNER_DIR}/.credentials_rsaparams" ]]; then
  info "Clearing local runner registration files in ${RUNNER_DIR}."
  rm -f "${RUNNER_DIR}/.runner" "${RUNNER_DIR}/.credentials" "${RUNNER_DIR}/.credentials_rsaparams" || true
fi

# ---------------------------------------------------------------------------
# 2. Best-effort deregister from GitHub
# ---------------------------------------------------------------------------

CONFIG_ENV="${RUNNER_DIR}/config.env"
CONFIG_SH="${RUNNER_DIR}/config.sh"

if [[ -f "${CONFIG_SH}" && -f "${CONFIG_ENV}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_ENV}"

  GH_ORG="${GH_ORG:-your-org}"
  RUNNER_TOKEN="${RUNNER_TOKEN:-}"
  BROKER_URL="${BROKER_URL:-}"
  # NOTE: unquoted expansion — satisfies set -u when config.env pre-dates the BROKER_SECRET field.
  : "${BROKER_SECRET:=}"
  ACCESS_TOKEN="${ACCESS_TOKEN:-}"

  # Obtain a removal token using the same priority as runner-loop.sh.
  REMOVAL_TOKEN=""

  if [[ -n "${RUNNER_TOKEN}" ]]; then
    info "Using static RUNNER_TOKEN for deregistration."
    REMOVAL_TOKEN="${RUNNER_TOKEN}"

  elif [[ -n "${BROKER_URL}" ]]; then
    # Broker API: POST /remove-token with Authorization: Bearer <BROKER_SECRET>
    # Returns a GitHub runner remove token; same response shape as /token.
    info "Fetching removal token from broker: $(echo "${BROKER_URL}" | sed -E 's#://[^@/]+@#://***@#')"
    REMOVAL_TOKEN="$(curl --silent --fail --max-time 10 \
      -X POST \
      -H "Authorization: Bearer ${BROKER_SECRET}" \
      "${BROKER_URL%/}/remove-token" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")" \
      || warn "Broker request failed — skipping deregister."

  elif [[ -n "${ACCESS_TOKEN}" ]]; then
    info "Minting removal token via GitHub REST API."
    # --config (printf process substitution) keeps the Bearer header out of `ps` argv.
    REMOVAL_TOKEN="$(curl --silent --fail --max-time 10 \
      --config <(printf 'header = "Authorization: Bearer %s"\n' "${ACCESS_TOKEN}") \
      -X POST \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/orgs/${GH_ORG}/actions/runners/remove-token" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")" \
      || warn "GitHub REST API call failed — skipping deregister."

  else
    warn "No credential in config.env — cannot deregister from GitHub."
    warn "Remove the runner manually at: https://github.com/organizations/${GH_ORG}/settings/actions/runners"
  fi

  if [[ -n "${REMOVAL_TOKEN}" ]]; then
    info "Deregistering runner..."
    # NOTE: using a remove token here, not a registration token. The runner may already be
    # offline/ephemeral-expired; failures are non-fatal.
    if "${CONFIG_SH}" remove --token "${REMOVAL_TOKEN}" 2>/dev/null; then
      info "Runner deregistered from GitHub."
    else
      warn "config.sh remove failed (runner may have already been deregistered — this is safe)."
    fi
  fi
else
  warn "Runner dir or config.sh not found at ${RUNNER_DIR} — skipping deregistration."
  warn "If the runner is still listed in GitHub, remove it manually:"
  warn "  https://github.com/organizations/${GH_ORG:-your-org}/settings/actions/runners"
fi

# ---------------------------------------------------------------------------
# 3. Optionally purge the runner directory
# ---------------------------------------------------------------------------

if [[ -d "${RUNNER_DIR}" ]]; then
  if [[ "${PURGE}" -eq 0 && "${YES}" -eq 0 ]]; then
    echo ""
    read -r -p "Remove runner directory ${RUNNER_DIR}? [y/N] " ANSWER
    [[ "${ANSWER}" =~ ^[Yy]$ ]] && PURGE=1
  fi

  if [[ "${PURGE}" -eq 1 ]]; then
    info "Removing runner directory: ${RUNNER_DIR}"
    rm -rf "${RUNNER_DIR}"
    info "Runner directory removed."
  else
    info "Runner directory kept at ${RUNNER_DIR}."
  fi
fi

echo ""
echo "==========================================================="
echo " iOS/Android-on-Mac self-hosted runner uninstalled."
echo "==========================================================="
