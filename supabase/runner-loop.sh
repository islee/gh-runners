#!/usr/bin/env bash
# runner-loop.sh — ephemeral relaunch loop for a vanilla actions/runner on Linux (supabase variant).
#
# Driven by runner-bootstrap.sh (ExecStart target for gh-runner-light@.service). Loops forever:
#   1. Acquire a fresh registration token each cycle (ephemeral runners expire it after one job).
#   2. Register (--ephemeral) and run exactly one job (run.sh exits after it).
#   3. After a completed job: clear crash counter, snapshot last_good/, check for fleet-code update.
#   4. Re-register clean. Repeat.
#
# Token priority (checked in order): RUNNER_TOKEN (static) → BROKER_URL (broker) → ACCESS_TOKEN (PAT).
# config.env (mode 600, written by install.sh) lives in this script's dir and supplies the values.
#
# Fleet self-update: the broker /token response may include a fleet_update object with
# {desired_ref, manifest_sha256, min_version}. After each completed job, self-update.sh is
# invoked with those values. If it applied an update (exit 77), this loop exits 0 so the
# supervisor relaunches runner-bootstrap.sh, which exec's the new runner-loop.sh.
#
# SELFTEST mode: SELFTEST=1 SELFTEST_CONFIG=/path/to/config.env bash runner-loop.sh
#   Sources config from SELFTEST_CONFIG, verifies required function definitions, exits 0.
#   Used by self-update.sh to validate a staged runner-loop.sh before committing.
#
# Graceful shutdown: SIGTERM (systemd stop) / SIGINT deregisters before exit.

set -euo pipefail

# ── SELFTEST early setup ────────────────────────────────────────────────────────
# Capture before config.env is sourced so config.env cannot override the SELFTEST flag.
_SELFTEST="${SELFTEST:-0}"

# ── Bootstrap — config.env sits next to this script (its instance runner dir) ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_ENV="${SCRIPT_DIR}/config.env"
if [[ "${_SELFTEST}" == "1" ]]; then
  # In SELFTEST mode source the production config (real env vars); fall back to /dev/null.
  # shellcheck source=/dev/null
  source "${SELFTEST_CONFIG:-/dev/null}" 2>/dev/null || true
else
  [[ -f "${CONFIG_ENV}" ]] || { echo "[ERROR] config.env not found at ${CONFIG_ENV}. Run install.sh first." >&2; exit 1; }
  # shellcheck source=/dev/null
  source "${CONFIG_ENV}"
fi

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

# Fleet self-update knobs (written by install.sh; self-update.sh reads them from config.env directly).
AUTO_UPDATE="${AUTO_UPDATE:-1}"
UPDATE_MIN_INTERVAL="${UPDATE_MIN_INTERVAL:-300}"

# Local fleet-code version (written by self-update.sh after each successful update; absent on
# fresh install until first update). Sent as X-Fleet-Version to the broker each cycle.
FLEET_VERSION="$(cat "${RUNNER_DIR}/.fleet-version" 2>/dev/null || echo "")"

# Fleet update fields populated by _acquire_reg_token from the broker /token response.
# Empty when the broker doesn't send fleet_update (dormant mode) or when using static/PAT cred.
FLEET_DESIRED_REF=""
FLEET_MANIFEST_SHA256=""
FLEET_MIN_VERSION=""

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

# Parse fleet_update fields from broker JSON on stdin; outputs three lines (empty if absent/null).
# WHY separate function: fleet_update is an optional nested object; _json_field only handles
# top-level strings and would raise KeyError on a missing fleet_update key.
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

# ── Graceful shutdown — deregister before exit ─────────────────────────────────
_CURRENT_REG_TOKEN=""
_shutdown() {
  log "Caught signal — deregistering runner and exiting."
  # Best-effort: a removal needs a remove-token. Reuse the broker/PAT to mint one when possible;
  # fall back to the current registration token. Never fail the trap (token may be expired already).
  local _rm=""
  if [[ -n "${BROKER_URL}" ]]; then
    _rm="$(curl --silent --fail --max-time 10 -X POST \
      -H "Authorization: Bearer ${BROKER_SECRET}" -H "X-Runner-Name: ${RUNNER_NAME}" \
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
  FLEET_DESIRED_REF=""
  FLEET_MANIFEST_SHA256=""
  FLEET_MIN_VERSION=""

  # Priority 1: static RUNNER_TOKEN (model A). WARNING: a bare registration token expires ~1h after
  # minting, so it survives only the FIRST cycle of this re-registering loop. Unattended → use B/PAT.
  if [[ -n "${RUNNER_TOKEN}" ]]; then
    log "Using static RUNNER_TOKEN (one-off; expires ~1h — see README on sustainable creds)."
    REG_TOKEN="${RUNNER_TOKEN}"; return 0
  fi

  # Priority 2: token-broker (model B). No GitHub credential lives on this host.
  # Also the only path that receives fleet_update from the broker response.
  if [[ -n "${BROKER_URL}" ]]; then
    log "Fetching registration token from broker: $(_mask_url "${BROKER_URL}")"
    local _raw
    _raw="$(curl --silent --fail --max-time 15 -X POST \
      -H "Authorization: Bearer ${BROKER_SECRET}" \
      -H "X-Runner-Name: ${RUNNER_NAME}" \
      -H "X-Fleet-Version: ${FLEET_VERSION}" \
      "${BROKER_URL%/}/token")" || { warn "Broker request failed (BROKER_URL/BROKER_SECRET?)."; return 1; }

    REG_TOKEN="$(echo "${_raw}" | _json_field token)" || { warn "Broker returned unparseable JSON."; return 1; }
    [[ -n "${REG_TOKEN}" ]] || { warn "Broker returned an empty token."; return 1; }

    # Parse optional fleet_update (absent when feature is dormant — no error if missing).
    { read -r FLEET_DESIRED_REF
      read -r FLEET_MANIFEST_SHA256
      read -r FLEET_MIN_VERSION
    } < <(echo "${_raw}" | _parse_fleet_update 2>/dev/null) \
      || { FLEET_DESIRED_REF=""; FLEET_MANIFEST_SHA256=""; FLEET_MIN_VERSION=""; }

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

# ── Post-job bookkeeping — clear crash counter and snapshot last_good/ ─────────
# Called after run.sh exits 0 (a job completed successfully). Records a verified-good state so
# runner-bootstrap.sh can roll back to it if a subsequent fleet-code update causes crash-loops.
_record_job_complete() {
  printf 'starts=0\nhas_pending_swap=0\n' > "${RUNNER_DIR}/.fleet-state"
  mkdir -p "${RUNNER_DIR}/last_good"
  local _f
  for _f in runner-loop.sh self-update.sh; do
    [[ -f "${RUNNER_DIR}/${_f}" ]] && cp "${RUNNER_DIR}/${_f}" "${RUNNER_DIR}/last_good/${_f}"
  done
  log "Crash counter cleared and last_good/ snapshot updated post-job."
}

# ── Post-job disk reclaim — keep the shared Docker host from filling between jobs ──────────────
# WHY: instances co-located on one host (e.g. CT 102: light×4 + supabase + the android container)
# share /var/lib/docker. Jobs that build images or run `supabase start` leave dangling images and
# build cache that, left unchecked, fill the rootfs until the next emulator boot can't create its
# 7 GB userdata partition. Pruning after every job keeps it bounded with no manual intervention.
# CRITICAL: concurrency-safe by construction — a sibling instance may have a job IN FLIGHT, so we
# touch ONLY objects that are reclaimable by definition: stopped containers (a running job's are
# not stopped), dangling images (untagged + unreferenced — never a tagged image a job pulled), and
# build cache idle past the cutoff (active builds keep theirs fresh). Deliberately NO `-a` (would
# delete tagged images siblings rely on) and NO volume prune (a concurrent stack's data volume
# could be destroyed). No-op where Docker is absent/unreachable.
_prune_docker() {
  [[ "${PRUNE_DOCKER_AFTER_JOB:-1}" == "1" ]] || return 0
  command -v docker &>/dev/null || return 0
  docker info &>/dev/null || return 0   # CLI present but daemon unreachable / no perms → skip quietly
  docker container prune -f &>/dev/null || true
  docker image prune -f     &>/dev/null || true
  docker builder prune -f --filter "until=${PRUNE_BUILDER_UNTIL:-48h}" &>/dev/null || true
  log "Post-job Docker prune: stopped containers + dangling images + build cache older than ${PRUNE_BUILDER_UNTIL:-48h}."
}

# ── SELFTEST exit point — after all function definitions, before main loop ─────
if [[ "${_SELFTEST}" == "1" ]]; then
  type _acquire_reg_token &>/dev/null || exit 1
  type _shutdown         &>/dev/null || exit 1
  type _record_job_complete &>/dev/null || exit 1
  type _prune_docker &>/dev/null || exit 1
  exit 0
fi

# ── Main loop ──────────────────────────────────────────────────────────────────
cd "${RUNNER_DIR}"
log "gh-runner (supabase) loop starting. Org=${GH_ORG}, Labels=${RUNNER_LABELS}"

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

  # Advisory: log if fleet-code version is below the broker-specified minimum. This never forces
  # an update and never overrides AUTO_UPDATE=0 — it is informational only.
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
  _run_exit=0
  nice -n "${NICE_PRIORITY}" "${RUNNER_DIR}/run.sh" || _run_exit=$?
  _CURRENT_REG_TOKEN=""

  # Reclaim disk regardless of job outcome (a failed job can still leave dangling layers/cache).
  _prune_docker

  if (( _run_exit != 0 )); then
    warn "run.sh exited non-zero (${_run_exit}) — looping to re-register."
  else
    log "Job complete. Running post-job bookkeeping and update check."
    _record_job_complete

    # Invoke fleet-code updater between jobs (ephemeral boundary). Non-fatal: any failure from
    # self-update.sh leaves current code in place and the loop continues normally.
    if [[ -n "${FLEET_DESIRED_REF}" && -n "${FLEET_MANIFEST_SHA256}" ]]; then
      _su_exit=0
      "${RUNNER_DIR}/self-update.sh" "${FLEET_DESIRED_REF}" "${FLEET_MANIFEST_SHA256}" || _su_exit=$?
      if (( _su_exit == 77 )); then
        # UPDATE_APPLIED: exit 0 so the supervisor (systemd Restart=always) relaunches
        # runner-bootstrap.sh, which exec's the newly-installed runner-loop.sh.
        log "Fleet-code update applied — exiting for supervisor to relaunch new payload."
        exit 0
      elif (( _su_exit != 0 )); then
        warn "self-update.sh returned ${_su_exit} (non-fatal, continuing loop)."
      fi
    fi

    log "Re-registering for next job."
  fi
done
