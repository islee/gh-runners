#!/usr/bin/env bash
# runner-loop.sh — ephemeral re-registration loop for the iOS/Android-on-Mac self-hosted runner.
#
# Driven by runner-bootstrap.sh (ProgramArguments target for com.example.gh-runner.plist) and
# loops forever:
#   1. Battery guard — skips a cycle if on battery and ALLOW_BATTERY != 1.
#   2. Mint a fresh registration token each cycle (ephemeral runners expire the token after one job).
#   3. Register + run one job (--ephemeral -> run.sh exits after one job).
#   4. After a completed job: clear crash counter, snapshot last_good/, check for fleet-code update.
#   5. Re-register clean. Repeat.
#
# Token acquisition priority (checked in order):
#   RUNNER_TOKEN (static)  ->  BROKER_URL (token-broker)  ->  ACCESS_TOKEN (PAT, mints via REST)
#
# Fleet self-update: the broker /token response may include fleet_update {desired_ref,
# manifest_sha256, min_version}. After each completed job, self-update.sh is invoked. If it
# applied an update (exit 77), this loop exits 0 so launchd (KeepAlive=true) relaunches
# runner-bootstrap.sh, which exec's the new runner-loop.sh.
#
# SELFTEST mode: SELFTEST=1 SELFTEST_CONFIG=/path/to/config.env bash runner-loop.sh
#   Verifies required function definitions without registering or running jobs. Used by
#   self-update.sh to validate a staged runner-loop.sh before committing.
#
# Graceful shutdown: SIGTERM/SIGINT triggers deregistration before exit.

set -euo pipefail

# ---------------------------------------------------------------------------
# SELFTEST early setup
# ---------------------------------------------------------------------------

_SELFTEST="${SELFTEST:-0}"

# ---------------------------------------------------------------------------
# Bootstrap — locate config.env relative to this script's install dir
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_ENV="${SCRIPT_DIR}/config.env"

if [[ "${_SELFTEST}" == "1" ]]; then
  # In SELFTEST mode, source the production config provided by self-update.sh.
  # shellcheck source=/dev/null
  source "${SELFTEST_CONFIG:-/dev/null}" 2>/dev/null || true
else
  [[ -f "${CONFIG_ENV}" ]] || {
    echo "[ERROR] config.env not found at ${CONFIG_ENV}. Run install.sh first." >&2
    exit 1
  }
  # shellcheck source=/dev/null
  source "${CONFIG_ENV}"
fi

# ---------------------------------------------------------------------------
# Defaults and derived values
# ---------------------------------------------------------------------------

# WHY: these defaults are only reached if config.env is missing a field (e.g. manually edited).
# Normal installs always write all fields via install.sh.
GH_ORG="${GH_ORG:-your-org}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,mobile,ios,android}"
# Display name: install.sh writes the gh-runner-ios-<id>-<n> name into config.env. Fallback to a
# host+uuid name if unset. Fixed per machine — re-register each ephemeral cycle with --replace.
RUNNER_NAME="${RUNNER_NAME:-$(hostname -s)-mobile-$(uuidgen | tr -d - | cut -c1-8)}"
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

AUTO_UPDATE="${AUTO_UPDATE:-1}"
UPDATE_MIN_INTERVAL="${UPDATE_MIN_INTERVAL:-300}"

# Local fleet-code version — sent as X-Fleet-Version to the broker each cycle.
FLEET_VERSION="$(cat "${RUNNER_DIR}/.fleet-version" 2>/dev/null || echo "")"

# Fleet update fields — populated by _acquire_reg_token from the broker /token response.
FLEET_DESIRED_REF=""
FLEET_MANIFEST_SHA256=""
FLEET_MIN_VERSION=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# All logging goes to STDERR — load-bearing: keeps logs out of command-substitution captures
# so token values are never polluted by log lines. Do not introduce stdout logging.
log()   { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [INFO]  $*" >&2; }
warn()  { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [WARN]  $*" >&2; }
fatal() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [ERROR] $*" >&2; exit 1; }

# Mask credentials embedded in a URL authority (https://user:secret@host -> https://***@host).
_mask_url() { echo "$1" | sed -E 's#://[^@/]+@#://***@#'; }

# Extract a top-level string field from a JSON object on stdin.
_json_field() { python3 -c "import sys,json; print(json.load(sys.stdin)['$1'])"; }

# Parse fleet_update fields from broker JSON on stdin; outputs three lines (empty if absent/null).
_parse_fleet_update() {
  python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    fu = d.get('fleet_update') or {}
    print(fu.get('desired_ref') or '')
    print(fu.get('manifest_sha256') or '')
    v = fu.get('min_version')
    print(v if v else '')
except Exception:
    print(''); print(''); print('')
"
}

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
  FLEET_DESIRED_REF=""
  FLEET_MANIFEST_SHA256=""
  FLEET_MIN_VERSION=""

  # Priority 1: static RUNNER_TOKEN (Model A, manual one-off).
  # WARNING: a bare registration token expires ~1h after minting, so it survives only the FIRST
  # cycle of this re-registering loop. For an unattended runner use ACCESS_TOKEN or BROKER_URL.
  if [[ -n "${RUNNER_TOKEN}" ]]; then
    log "Using static RUNNER_TOKEN (one-off; expires ~1h — see README on sustainable credentials)."
    REG_TOKEN="${RUNNER_TOKEN}"
    return 0
  fi

  # Priority 2: token-broker (Model B — no GitHub credential on this machine).
  # Also the only path that receives fleet_update from the broker response.
  if [[ -n "${BROKER_URL}" ]]; then
    log "Fetching registration token from broker: $(_mask_url "${BROKER_URL}")"
    local _raw
    _raw="$(curl --silent --fail --max-time 15 -X POST \
      -H "Authorization: Bearer ${BROKER_SECRET}" \
      -H "X-Runner-Name: ${RUNNER_NAME}" \
      -H "X-Fleet-Version: ${FLEET_VERSION}" \
      "${BROKER_URL%/}/token")" || {
      warn "Broker request failed (check BROKER_URL / BROKER_SECRET in config.env)."
      return 1
    }
    REG_TOKEN="$(echo "${_raw}" | _json_field token)" || { warn "Broker returned unparseable JSON."; return 1; }
    [[ -n "${REG_TOKEN}" ]] || { warn "Broker returned an empty token."; return 1; }

    { read -r FLEET_DESIRED_REF
      read -r FLEET_MANIFEST_SHA256
      read -r FLEET_MIN_VERSION
    } < <(echo "${_raw}" | _parse_fleet_update 2>/dev/null) \
      || { FLEET_DESIRED_REF=""; FLEET_MANIFEST_SHA256=""; FLEET_MIN_VERSION=""; }

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
# Post-job bookkeeping — clear crash counter and snapshot last_good/
# ---------------------------------------------------------------------------

_record_job_complete() {
  printf 'starts=0\nhas_pending_swap=0\n' > "${RUNNER_DIR}/.fleet-state"
  mkdir -p "${RUNNER_DIR}/last_good"
  local _f
  for _f in runner-loop.sh self-update.sh; do
    [[ -f "${RUNNER_DIR}/${_f}" ]] && cp "${RUNNER_DIR}/${_f}" "${RUNNER_DIR}/last_good/${_f}"
  done
  log "Crash counter cleared and last_good/ snapshot updated post-job."
}

# ---------------------------------------------------------------------------
# SELFTEST exit point — after all function definitions, before main loop
# ---------------------------------------------------------------------------

if [[ "${_SELFTEST}" == "1" ]]; then
  type _acquire_reg_token    &>/dev/null || exit 1
  type _shutdown             &>/dev/null || exit 1
  type _record_job_complete  &>/dev/null || exit 1
  exit 0
fi

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
    exp=$(( RETRY_ATTEMPT - 1 )); (( exp > 6 )) && exp=6
    backoff=$(( REGISTRATION_RETRY_SECONDS * (2 ** exp) )); (( backoff > 300 )) && backoff=300
    backoff=$(( backoff + (RANDOM % 15) ))
    warn "Token acquisition failed (attempt ${RETRY_ATTEMPT}) — retrying in ${backoff}s."
    sleep "${backoff}"
    continue
  fi
  RETRY_ATTEMPT=0
  _CURRENT_REG_TOKEN="${REG_TOKEN}"

  # Advisory: log if fleet-code version is below the broker-specified minimum.
  if [[ -n "${FLEET_MIN_VERSION}" && -n "${FLEET_VERSION}" ]]; then
    if ! python3 -c "
import sys
try:
    a = [int(x) for x in '${FLEET_VERSION}'.strip().split('.') if x.isdigit()]
    b = [int(x) for x in '${FLEET_MIN_VERSION}'.strip().split('.') if x.isdigit()]
    sys.exit(0 if a >= b else 1)
except Exception:
    sys.exit(0)
" 2>/dev/null; then
      warn "Advisory: fleet-code version '${FLEET_VERSION}' is below minimum '${FLEET_MIN_VERSION}'. Update will apply after the next job if AUTO_UPDATE=1."
    fi
  fi

  # ------ Register (ephemeral) + run one job -----------------------------
  log "Registering runner: ${RUNNER_NAME}"

  # WHY: --ephemeral deregisters after exactly one job; --replace clears stale same-name entries.
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
    rm -f "${RUNNER_DIR}/.runner" "${RUNNER_DIR}/.credentials" "${RUNNER_DIR}/.credentials_rsaparams" || true
    sleep "${REGISTRATION_RETRY_SECONDS}"
    continue
  fi

  log "Runner registered as ${RUNNER_NAME}. Waiting for a job..."

  _run_exit=0
  nice -n "${NICE_PRIORITY}" "${RUNNER_DIR}/run.sh" || _run_exit=$?
  _CURRENT_REG_TOKEN=""

  if (( _run_exit != 0 )); then
    warn "run.sh exited with a non-zero status (${_run_exit}) — looping to re-register."
  else
    log "Job complete. Running post-job bookkeeping and update check."
    _record_job_complete

    # Invoke fleet-code updater at the ephemeral boundary (between jobs). Non-fatal.
    if [[ -n "${FLEET_DESIRED_REF}" && -n "${FLEET_MANIFEST_SHA256}" ]]; then
      _su_exit=0
      "${RUNNER_DIR}/self-update.sh" "${FLEET_DESIRED_REF}" "${FLEET_MANIFEST_SHA256}" || _su_exit=$?
      if (( _su_exit == 77 )); then
        # UPDATE_APPLIED: exit 0 so launchd (KeepAlive=true) relaunches runner-bootstrap.sh,
        # which exec's the newly-installed runner-loop.sh.
        log "Fleet-code update applied — exiting for launchd to relaunch new payload."
        exit 0
      elif (( _su_exit != 0 )); then
        warn "self-update.sh returned ${_su_exit} (non-fatal, continuing loop)."
      fi
    fi

    log "Re-registering for next job."
  fi

done
