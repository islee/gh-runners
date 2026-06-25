#!/usr/bin/env bash
# runner-loop.sh — ephemeral relaunch loop for a vanilla actions/runner on Linux.
#
# Driven by systemd (gh-runner@.service). Loops forever:
#   1. Acquire a fresh registration token each cycle (ephemeral runners expire it after one job).
#   2. Register (--ephemeral) and run exactly one job (run.sh exits after it).
#   3. Re-register clean. Repeat.
#
# Token priority (checked in order): RUNNER_TOKEN (static) → BROKER_URL (broker) → ACCESS_TOKEN (PAT).
# config.env (mode 600, written by install.sh) lives in this script's dir and supplies the values.
#
# Graceful shutdown: SIGTERM (systemd stop) / SIGINT deregisters before exit.

set -euo pipefail

# ── Bootstrap — config.env sits next to this script (its instance runner dir) ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_ENV="${SCRIPT_DIR}/config.env"
[[ -f "${CONFIG_ENV}" ]] || { echo "[ERROR] config.env not found at ${CONFIG_ENV}. Run install.sh first." >&2; exit 1; }
# shellcheck source=/dev/null
source "${CONFIG_ENV}"

# ── Defaults / derived ─────────────────────────────────────────────────────────
GH_ORG="${GH_ORG:-your-org}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,x64,supabase}"
# Display name: install.sh writes the gh-runner-<type>-<id>-<n> name into config.env. If absent
# (hand-rolled config), fall back to a host+uuid name. Fixed per instance — re-register with --replace.
RUNNER_NAME="${RUNNER_NAME:-$(hostname -s)-$(uuidgen | tr -d - | cut -c1-8)}"
RUNNER_TOKEN="${RUNNER_TOKEN:-}"
BROKER_URL="${BROKER_URL:-}"
ACCESS_TOKEN="${ACCESS_TOKEN:-}"
: "${BROKER_SECRET:=}"   # default-assign to satisfy `set -u`
RUNNER_DIR="${SCRIPT_DIR}"
REGISTRATION_RETRY_SECONDS=30

# ── Logging — ALL logs to STDERR ───────────────────────────────────────────────
# Load-bearing: token acquisition returns its value via a global (REG_TOKEN), not $(...) capture.
# Keeping logs off stdout prevents any accidental capture from polluting a token value.
log()   { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [INFO]  $*" >&2; }
warn()  { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [WARN]  $*" >&2; }
fatal() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [ERROR] $*" >&2; exit 1; }

# Mask credentials embedded in a URL authority (https://user:secret@host → https://***@host).
_mask_url() { echo "$1" | sed -E 's#://[^@/]+@#://***@#'; }
# Extract a top-level string field from a JSON object on stdin.
_json_field() { python3 -c "import sys,json; print(json.load(sys.stdin)['$1'])"; }

# ── Graceful shutdown — deregister before exit ─────────────────────────────────
_CURRENT_REG_TOKEN=""
_shutdown() {
  log "Caught signal — deregistering runner and exiting."
  # Best-effort: a removal needs a remove-token. Reuse the broker/PAT to mint one when possible;
  # fall back to the current registration token. Never fail the trap (token may be expired already).
  local _rm=""
  if [[ -n "${BROKER_URL}" ]]; then
    _rm="$(curl --silent --fail --max-time 10 -X POST \
      -H "Authorization: Bearer ${BROKER_SECRET}" -H "X-Runner-Name: $(hostname -s)" \
      "${BROKER_URL%/}/remove-token" | _json_field token 2>/dev/null)" || _rm=""
  elif [[ -n "${ACCESS_TOKEN}" ]]; then
    _rm="$(curl --silent --fail --max-time 10 \
      --config <(printf 'header = "Authorization: Bearer %s"\n' "${ACCESS_TOKEN}") -X POST \
      -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/orgs/${GH_ORG}/actions/runners/remove-token" | _json_field token 2>/dev/null)" || _rm=""
  fi
  [[ -z "${_rm}" ]] && _rm="${_CURRENT_REG_TOKEN}"
  if [[ -f "${RUNNER_DIR}/config.sh" && -n "${_rm}" ]]; then
    "${RUNNER_DIR}/config.sh" remove --token "${_rm}" 2>/dev/null || true
  fi
  exit 0
}
trap '_shutdown' SIGTERM SIGINT

# ── Token acquisition — sets the global REG_TOKEN; 0 on success, 1 on retryable failure ────────────
REG_TOKEN=""
_acquire_reg_token() {
  REG_TOKEN=""

  # Priority 1: static RUNNER_TOKEN (model A). WARNING: a bare registration token expires ~1h after
  # minting, so it survives only the FIRST cycle of this re-registering loop. Unattended → use B/PAT.
  if [[ -n "${RUNNER_TOKEN}" ]]; then
    log "Using static RUNNER_TOKEN (one-off; expires ~1h — see README on sustainable creds)."
    REG_TOKEN="${RUNNER_TOKEN}"; return 0
  fi

  # Priority 2: token-broker (model B). No GitHub credential lives on this host.
  if [[ -n "${BROKER_URL}" ]]; then
    log "Fetching registration token from broker: $(_mask_url "${BROKER_URL}")"
    REG_TOKEN="$(curl --silent --fail --max-time 15 -X POST \
      -H "Authorization: Bearer ${BROKER_SECRET}" -H "X-Runner-Name: $(hostname -s)" \
      "${BROKER_URL%/}/token" | _json_field token)" || { warn "Broker request failed (BROKER_URL/BROKER_SECRET?)."; return 1; }
    [[ -n "${REG_TOKEN}" ]] || { warn "Broker returned an empty token."; return 1; }
    return 0
  fi

  # Priority 3: mint from ACCESS_TOKEN — a fine-grained PAT scoped to organization_self_hosted_runners.
  # NOT an org-admin PAT.
  if [[ -n "${ACCESS_TOKEN}" ]]; then
    log "Minting registration token via GitHub REST API."
    # Pass the PAT via --config (printf process substitution) so the Bearer header never appears in
    # `ps` argv. printf is a bash builtin → no separate process exposes it either.
    REG_TOKEN="$(curl --silent --fail --max-time 10 \
      --config <(printf 'header = "Authorization: Bearer %s"\n' "${ACCESS_TOKEN}") -X POST \
      -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/orgs/${GH_ORG}/actions/runners/registration-token" \
      | _json_field token)" || { warn "GitHub REST API call failed."; return 1; }
    [[ -n "${REG_TOKEN}" ]] || { warn "GitHub returned an empty token."; return 1; }
    return 0
  fi

  fatal "No credential available (RUNNER_TOKEN, BROKER_URL, ACCESS_TOKEN all unset). Fix config.env."
}

# ── Main loop ──────────────────────────────────────────────────────────────────
cd "${RUNNER_DIR}"
log "gh-runner loop starting. Org=${GH_ORG}, Labels=${RUNNER_LABELS}"

# nice lowers scheduling priority so a CPU-heavy job doesn't starve the host. Loop runs at normal
# priority; only the runner child processes are niced.
NICE_PRIORITY="${NICE_PRIORITY:-10}"
RETRY_ATTEMPT=0

while true; do
  log "Acquiring registration token..."
  if ! _acquire_reg_token; then
    RETRY_ATTEMPT=$(( RETRY_ATTEMPT + 1 ))
    # Exponential backoff with jitter, capped at 300s. Jitter decorrelates many hosts hitting the
    # GitHub rate-limit at once (thundering herd). Exponent capped to avoid overflow on long outages.
    exp=$(( RETRY_ATTEMPT - 1 )); (( exp > 6 )) && exp=6
    backoff=$(( REGISTRATION_RETRY_SECONDS * (2 ** exp) )); (( backoff > 300 )) && backoff=300
    backoff=$(( backoff + (RANDOM % 15) ))
    warn "Token acquisition failed (attempt ${RETRY_ATTEMPT}) — retrying in ${backoff}s."
    sleep "${backoff}"; continue
  fi
  RETRY_ATTEMPT=0
  _CURRENT_REG_TOKEN="${REG_TOKEN}"

  # Fixed per-instance name (gh-runner-<type>-<id>-<n> from config.env). --replace re-claims this
  # instance's own prior registration each ephemeral cycle; the <id>+<n> keep it unique across hosts.
  log "Registering runner: ${RUNNER_NAME}"

  # --ephemeral: deregister after exactly one job. --replace: clear a stale same-name registration.
  if ! nice -n "${NICE_PRIORITY}" "${RUNNER_DIR}/config.sh" \
      --unattended --ephemeral --replace \
      --url "https://github.com/${GH_ORG}" \
      --token "${REG_TOKEN}" \
      --labels "${RUNNER_LABELS}" \
      --name "${RUNNER_NAME}"; then
    warn "config.sh failed — will retry in ${REGISTRATION_RETRY_SECONDS}s."
    _CURRENT_REG_TOKEN=""
    # WHY: config.sh fails with "already configured" when stale local registration files (.runner,
    # .credentials*) remain from a prior cycle or reinstall. Clearing them self-heals the loop.
    # A prior registration may linger OFFLINE in GitHub until pruned or the next --replace cycle.
    rm -f "${RUNNER_DIR}/.runner" "${RUNNER_DIR}/.credentials" "${RUNNER_DIR}/.credentials_rsaparams" || true
    sleep "${REGISTRATION_RETRY_SECONDS}"; continue
  fi

  log "Runner registered as ${RUNNER_NAME}. Waiting for a job..."
  # run.sh blocks until exactly one job completes (--ephemeral), then exits. Loop regardless so the
  # runner re-registers rather than staying stuck on a job error.
  if ! nice -n "${NICE_PRIORITY}" "${RUNNER_DIR}/run.sh"; then
    warn "run.sh exited non-zero — looping to re-register."
  else
    log "Job complete. Re-registering for next job."
  fi
  _CURRENT_REG_TOKEN=""
done
