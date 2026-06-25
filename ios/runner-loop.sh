#!/usr/bin/env bash
# runner-loop.sh — ephemeral re-registration loop for the iOS/Android-on-Mac self-hosted runner.
#
# Driven by launchd (com.example.ci-runner.plist) and loops forever:
#   1. Battery guard — skips a cycle if on battery and ALLOW_BATTERY != 1.
#   2. Mint a fresh registration token each cycle (ephemeral runners expire the token after one job).
#   3. Register + run one job (--ephemeral -> run.sh exits after one job).
#   4. Re-register clean. Repeat.
#
# Token acquisition priority (checked in order):
#   RUNNER_TOKEN (static)  ->  BROKER_URL (token-broker)  ->  ACCESS_TOKEN (PAT, mints via REST)
#
# Graceful shutdown: SIGTERM/SIGINT triggers deregistration before exit.

set -euo pipefail

# ---------------------------------------------------------------------------
# Bootstrap — locate config.env relative to this script's install dir
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_ENV="${SCRIPT_DIR}/config.env"

[[ -f "${CONFIG_ENV}" ]] || {
  echo "[ERROR] config.env not found at ${CONFIG_ENV}. Run install.sh first." >&2
  exit 1
}

# shellcheck source=/dev/null
source "${CONFIG_ENV}"

# ---------------------------------------------------------------------------
# Defaults and derived values
# ---------------------------------------------------------------------------

# WHY: these defaults are only reached if config.env is missing a field (e.g. manually edited).
# Normal installs always write all fields via install.sh.
GH_ORG="${GH_ORG:-your-org}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,mobile,ios,android}"
RUNNER_TOKEN="${RUNNER_TOKEN:-}"
BROKER_URL="${BROKER_URL:-}"
# NOTE: unquoted expansion — BROKER_SECRET is sourced from config.env above; the colon-assign
# here satisfies set -u in case an older config.env pre-dates the BROKER_SECRET field.
: "${BROKER_SECRET:=}"
ACCESS_TOKEN="${ACCESS_TOKEN:-}"
ALLOW_BATTERY="${ALLOW_BATTERY:-0}"

RUNNER_DIR="${SCRIPT_DIR}"
BATTERY_SLEEP_SECONDS=60
REGISTRATION_RETRY_SECONDS=30

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# All logging goes to STDERR. This is load-bearing: _acquire_reg_token returns the token via a
# global (not $(...) capture), and keeping logs off stdout prevents any accidental capture from
# ever polluting a token value. (An earlier version echoed [INFO] lines to stdout *and* returned
# the token via command substitution — the logs were captured INTO the token, yielding a multiline
# garbage value that broke every registration. Do not reintroduce stdout logging.)
log()   { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [INFO]  $*" >&2; }
warn()  { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [WARN]  $*" >&2; }
fatal() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [ERROR] $*" >&2; exit 1; }

# Mask credentials embedded in a URL authority (https://user:secret@host -> https://***@host) so a
# BROKER_URL with inline creds never lands verbatim in the launchd log files.
_mask_url() { echo "$1" | sed -E 's#://[^@/]+@#://***@#'; }

# Extract a top-level string field from a JSON object on stdin.
_json_field() { python3 -c "import sys,json; print(json.load(sys.stdin)['$1'])"; }

# ---------------------------------------------------------------------------
# Graceful shutdown — deregister before exit on SIGTERM / SIGINT
# ---------------------------------------------------------------------------

_CURRENT_REG_TOKEN=""

_shutdown() {
  log "Caught signal — deregistering runner and exiting."
  if [[ -f "${RUNNER_DIR}/config.sh" && -n "${_CURRENT_REG_TOKEN}" ]]; then
    # Best-effort: don't fail the trap if deregister fails (token may already be expired).
    # NOTE: config.sh only accepts the token as --token (no env/stdin), so it is briefly visible
    # in `ps`. The token is short-lived (~1h) and this is a single-user personal machine; accepted.
    "${RUNNER_DIR}/config.sh" remove --token "${_CURRENT_REG_TOKEN}" 2>/dev/null || true
  fi
  exit 0
}

trap '_shutdown' SIGTERM SIGINT

# ---------------------------------------------------------------------------
# Battery guard
# ---------------------------------------------------------------------------

_on_battery() {
  # "Battery Power" when on battery, "AC Power" when plugged in.
  # NOTE: fails OPEN — if pmset is absent/errors, grep returns 1 -> treated as "not on battery",
  # so the runner still works on a desktop Mac / non-laptop. Acceptable for a courtesy guard.
  pmset -g batt 2>/dev/null | grep -q "Battery Power"
}

# ---------------------------------------------------------------------------
# Token acquisition — sets global REG_TOKEN; returns 0 on success, 1 on retryable failure.
# Credential priority: RUNNER_TOKEN -> BROKER_URL -> ACCESS_TOKEN.
# ---------------------------------------------------------------------------

REG_TOKEN=""

_acquire_reg_token() {
  REG_TOKEN=""

  # Priority 1: static RUNNER_TOKEN (Model A, manual one-off).
  # WARNING: a bare registration token expires ~1h after minting, so it survives only the FIRST
  # cycle of this re-registering loop. For an unattended runner use ACCESS_TOKEN or BROKER_URL.
  if [[ -n "${RUNNER_TOKEN}" ]]; then
    log "Using static RUNNER_TOKEN (one-off; expires ~1h — see README on sustainable credentials)."
    REG_TOKEN="${RUNNER_TOKEN}"
    return 0
  fi

  # Priority 2: token-broker (Model B — no GitHub credential on this machine).
  # Broker API: POST /token with Authorization: Bearer <BROKER_SECRET>
  # Returns: {"token": "...", "expires_at": "...", "url": "..."}
  # See: https://github.com/islee/ci-runner-token-broker
  if [[ -n "${BROKER_URL}" ]]; then
    log "Fetching registration token from broker: $(_mask_url "${BROKER_URL}")"
    REG_TOKEN="$(curl --silent --fail --max-time 15 -X POST \
      -H "Authorization: Bearer ${BROKER_SECRET}" \
      -H "X-Runner-Name: $(hostname -s)" \
      "${BROKER_URL%/}/token" | _json_field token)" || {
      warn "Broker request failed (check BROKER_URL / BROKER_SECRET in config.env)."
      return 1
    }
    [[ -n "${REG_TOKEN}" ]] || { warn "Broker returned an empty token."; return 1; }
    return 0
  fi

  # Priority 3: mint from ACCESS_TOKEN — a fine-grained PAT scoped to
  # organization_self_hosted_runners. NOT the org admin PAT.
  if [[ -n "${ACCESS_TOKEN}" ]]; then
    log "Minting registration token via GitHub REST API."
    # Pass the PAT via --config (a printf process substitution) so the Bearer header never
    # appears in `ps` argv. printf is a bash builtin -> no separate process exposes it either.
    REG_TOKEN="$(curl --silent --fail --max-time 10 \
      --config <(printf 'header = "Authorization: Bearer %s"\n' "${ACCESS_TOKEN}") \
      -X POST \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/orgs/${GH_ORG}/actions/runners/registration-token" \
      | _json_field token)" || {
      warn "GitHub REST API call failed."
      return 1
    }
    [[ -n "${REG_TOKEN}" ]] || { warn "GitHub returned an empty token."; return 1; }
    return 0
  fi

  fatal "No credential available (RUNNER_TOKEN, BROKER_URL, ACCESS_TOKEN all unset). Fix config.env."
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

cd "${RUNNER_DIR}"

log "iOS/Android-on-Mac runner-loop starting. Org=${GH_ORG}, Labels=${RUNNER_LABELS}"

# WHY: nice lowers the runner's scheduling priority so it doesn't compete with foreground apps on
# the operator's machine. The loop itself runs at normal priority; only child processes are niced.
export NICE_PRIORITY=10

# Consecutive token-acquisition failures, for exponential backoff.
RETRY_ATTEMPT=0

while true; do

  # ------ Battery guard --------------------------------------------------
  if _on_battery && [[ "${ALLOW_BATTERY}" != "1" ]]; then
    warn "On battery power and ALLOW_BATTERY != 1 — skipping cycle (sleeping ${BATTERY_SLEEP_SECONDS}s)."
    sleep "${BATTERY_SLEEP_SECONDS}"
    continue
  fi

  # ------ Acquire a fresh registration token (capped backoff on failure) -
  log "Acquiring registration token..."
  if ! _acquire_reg_token; then
    RETRY_ATTEMPT=$(( RETRY_ATTEMPT + 1 ))
    # Exponential backoff with jitter, capped at 300s. WHY: multiple machines hitting the same
    # GitHub rate-limit must not retry in lockstep (thundering herd); jitter decorrelates them.
    # The exponent is capped to avoid integer overflow on a prolonged outage.
    exp=$(( RETRY_ATTEMPT - 1 )); (( exp > 6 )) && exp=6
    backoff=$(( REGISTRATION_RETRY_SECONDS * (2 ** exp) )); (( backoff > 300 )) && backoff=300
    backoff=$(( backoff + (RANDOM % 15) ))
    warn "Token acquisition failed (attempt ${RETRY_ATTEMPT}) — retrying in ${backoff}s."
    sleep "${backoff}"
    continue
  fi
  RETRY_ATTEMPT=0
  _CURRENT_REG_TOKEN="${REG_TOKEN}"

  # ------ Register (ephemeral) + run one job -----------------------------
  # Collision-safe suffix: $RANDOM is only 15-bit; uuidgen gives a process-unique name so two
  # concurrent machines don't accidentally deregister each other with --replace.
  RUNNER_NAME="$(hostname -s)-mobile-$(uuidgen | tr -d - | cut -c1-8)"
  log "Registering runner: ${RUNNER_NAME}"

  # WHY: --ephemeral tells the runner to deregister itself after completing exactly one job.
  # --replace removes any stale registration with the same name so re-runs don't collide.
  # config.sh exits 0 on success; if it fails we skip this cycle and retry.
  if ! nice -n "${NICE_PRIORITY}" "${RUNNER_DIR}/config.sh" \
    --unattended \
    --ephemeral \
    --replace \
    --url "https://github.com/${GH_ORG}" \
    --token "${REG_TOKEN}" \
    --labels "${RUNNER_LABELS}" \
    --name "${RUNNER_NAME}"; then
    warn "config.sh failed — will retry in ${REGISTRATION_RETRY_SECONDS}s."
    _CURRENT_REG_TOKEN=""
    sleep "${REGISTRATION_RETRY_SECONDS}"
    continue
  fi

  log "Runner registered as ${RUNNER_NAME}. Waiting for a job..."

  # WHY: run.sh blocks until exactly one job completes (because --ephemeral), then exits 0.
  # We run it with nice so CPU-intensive jobs don't peg the machine.
  # If run.sh exits non-zero (job failure or runner error) we log but still loop — the runner
  # picks up the next job rather than staying stuck.
  if ! nice -n "${NICE_PRIORITY}" "${RUNNER_DIR}/run.sh"; then
    warn "run.sh exited with a non-zero status — looping to re-register."
  else
    log "Job complete. Re-registering for next job."
  fi

  _CURRENT_REG_TOKEN=""
  # No sleep between cycles — re-register immediately to stay available.

done
