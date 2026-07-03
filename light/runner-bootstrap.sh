#!/usr/bin/env bash
# runner-bootstrap.sh — stable supervisor entrypoint for the "light" runner (NEVER self-updated).
#
# ExecStart target for gh-runner-light@.service. Maintains a crash counter and performs rollback
# if runner-loop.sh crashes repeatedly after a fleet-code swap, then exec's the payload.
#
# CRITICAL: this file is NOT in the self-update allowlist and must NEVER be updated automatically.
# It is the recovery mechanism — a bad update cannot brick its own rollback path if bootstrap
# is stable. Update runner-bootstrap.sh only via a full re-install (install.sh).
#
# Crash counter semantics:
#   starts           — count of bootstrap startups since the last completed job. Cleared by
#                      runner-loop.sh via _record_job_complete after a job completes.
#   has_pending_swap — 1 after a fleet-code swap is applied; 0 after first completed job post-swap.
#   If starts > ROLLBACK_THRESHOLD AND has_pending_swap=1: restore last_good/ over managed files.
#
# State persists in .fleet-state (key=value, no eval) so it survives supervisor restarts.

set -euo pipefail

# ── Bootstrap — config.env sits next to this script (its instance runner dir) ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_ENV="${SCRIPT_DIR}/config.env"
[[ -f "${CONFIG_ENV}" ]] || { echo "[ERROR] config.env not found at ${CONFIG_ENV}. Run install.sh first." >&2; exit 1; }
# shellcheck source=/dev/null
source "${CONFIG_ENV}"

RUNNER_DIR="${SCRIPT_DIR}"

# Keep globally-installed npm CLIs resolvable. The unit points npm at a per-instance prefix
# (npm_config_prefix) so co-hosted jobs don't race on `npm i -g` into the shared toolcache; its bin
# dir must be on PATH for the job to find the installed tool. Prepending here (vs hardcoding PATH in
# the unit) preserves whatever PATH systemd provides and is inherited by the exec'd runner + its jobs.
[[ -n "${npm_config_prefix:-}" ]] && export PATH="${npm_config_prefix}/bin:${PATH}"

readonly STATE_FILE="${RUNNER_DIR}/.fleet-state"
readonly LAST_GOOD_DIR="${RUNNER_DIR}/last_good"
# CRITICAL: this list must match self-update.sh UPDATE_ALLOWLIST exactly.
readonly MANAGED_FILES_CSV="runner-loop.sh self-update.sh"
ROLLBACK_THRESHOLD="${ROLLBACK_THRESHOLD:-3}"
readonly ROLLBACK_THRESHOLD

log()  { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [BOOTSTRAP] [INFO]  $*" >&2; }
warn() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [BOOTSTRAP] [WARN]  $*" >&2; }

# Read .fleet-state into starts/has_pending_swap (plain key=value parsing — no eval/source).
_read_state() {
  starts=0
  has_pending_swap=0
  if [[ -f "${STATE_FILE}" ]]; then
    local _key _val
    while IFS='=' read -r _key _val; do
      [[ -z "${_key}" || "${_key}" == \#* ]] && continue
      case "${_key}" in
        starts)           starts="${_val}" ;;
        has_pending_swap) has_pending_swap="${_val}" ;;
      esac
    done < "${STATE_FILE}"
  fi
  # Sanitise — must be integers in expected ranges.
  [[ "${starts}"           =~ ^[0-9]+$  ]] || starts=0
  [[ "${has_pending_swap}" =~ ^[01]$    ]] || has_pending_swap=0
}

_write_state() {
  printf 'starts=%s\nhas_pending_swap=%s\n' "${starts}" "${has_pending_swap}" > "${STATE_FILE}"
}

# Restore managed files from last_good/ and reset crash state.
_rollback() {
  warn "Crash threshold (${ROLLBACK_THRESHOLD}) exceeded with a pending fleet-code swap."
  warn "Restoring last_good/ payload and resetting crash counter."
  local _f
  for _f in ${MANAGED_FILES_CSV}; do
    if [[ -f "${LAST_GOOD_DIR}/${_f}" ]]; then
      cp "${LAST_GOOD_DIR}/${_f}" "${RUNNER_DIR}/${_f}"
      chmod 755 "${RUNNER_DIR}/${_f}"
      log "Restored ${_f} from last_good/."
    else
      warn "last_good/${_f} missing — cannot restore; proceeding with current file."
    fi
  done
  starts=0
  has_pending_swap=0
  _write_state
  warn "Rollback complete. Runner will start with last_good/ payload."
}

# ── Main ──────────────────────────────────────────────────────────────────────

_read_state
starts=$(( starts + 1 ))

if (( starts > ROLLBACK_THRESHOLD && has_pending_swap == 1 )); then
  _rollback
else
  _write_state
fi

log "Launching runner payload (startup #${starts} since last completed job)."

# WHY exec: replaces this process with the payload so the supervisor (systemd) tracks the
# runner-loop.sh PID directly. SIGTERM from systemd stop reaches runner-loop.sh cleanly.
exec /bin/bash "${RUNNER_DIR}/runner-loop.sh"
