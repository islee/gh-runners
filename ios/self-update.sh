#!/usr/bin/env bash
# self-update.sh — fleet-code updater for the iOS/Android-on-Mac runner, invoked between jobs.
#
# Called by runner-loop.sh after a job completes:
#   ./self-update.sh <desired_ref> <manifest_sha256>
# Both values come from the broker /token response (fleet_update object). If either is empty,
# the feature is dormant and this script returns 0 immediately.
#
# Exit codes:
#   0  — no update applied (dormant, already current, or fail-safe abort)
#   77 — update committed; caller (runner-loop.sh) should exit 0 so launchd relaunches
#        runner-bootstrap.sh (via KeepAlive=true), which exec's the new runner-loop.sh.
#
# Security model (same as light/supabase variants):
#   - manifest_sha256 is the out-of-repo trust anchor from the broker, NOT from the repo.
#   - Path allowlist: only hardcoded basenames are updatable; / or .. in any entry aborts all.
#   - Stage-all-then-commit: all files verified before any file is moved into place.
#   - Atomic commit: snapshot → last_good/, mv staged files, write version stamp LAST.
#   - Fail-safe: ANY unexpected error returns 0. Current code is always preserved.
#
# CRITICAL: runner-bootstrap.sh is NOT in the allowlist and must NEVER be added.

set -euo pipefail

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_ENV="${SCRIPT_DIR}/config.env"
[[ -f "${CONFIG_ENV}" ]] || { echo "[ERROR] config.env not found at ${CONFIG_ENV}." >&2; exit 1; }
# shellcheck source=/dev/null
source "${CONFIG_ENV}"

RUNNER_DIR="${SCRIPT_DIR}"
readonly RUNNER_TYPE="ios"

# ---------------------------------------------------------------------------
# Config knobs (from config.env; defaults below)
# ---------------------------------------------------------------------------

AUTO_UPDATE="${AUTO_UPDATE:-1}"
UPDATE_REPO="${UPDATE_REPO:-islee/gh-runners}"
UPDATE_MIN_INTERVAL="${UPDATE_MIN_INTERVAL:-300}"
ENABLE_SELFTEST="${ENABLE_SELFTEST:-1}"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------

readonly DESIRED_REF="${1:-}"
readonly MANIFEST_SHA256="${2:-}"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# CRITICAL: only files in this list may be updated. Must match runner-bootstrap.sh MANAGED_FILES_CSV.
readonly UPDATE_ALLOWLIST_CSV="runner-loop.sh self-update.sh"
readonly UPDATE_APPLIED=77
readonly TS_FILE="${RUNNER_DIR}/.fleet-update-ts"
readonly STAGING_DIR="${RUNNER_DIR}/.fleet-staging"
readonly LAST_GOOD_DIR="${RUNNER_DIR}/last_good"
readonly STATE_FILE="${RUNNER_DIR}/.fleet-state"
readonly LOCAL_MANIFEST="${RUNNER_DIR}/.fleet-manifest"
readonly VERSION_FILE="${RUNNER_DIR}/.fleet-version"

log()  { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [UPDATER] [INFO]  $*" >&2; }
warn() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [UPDATER] [WARN]  $*" >&2; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Compute sha256 of a file. shasum is always available on macOS; sha256sum is the Linux fallback.
_sha256_file() {
  if command -v shasum &>/dev/null; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

_in_allowlist() {
  local _f="$1" _af
  for _af in ${UPDATE_ALLOWLIST_CSV}; do
    [[ "${_f}" == "${_af}" ]] && return 0
  done
  return 1
}

_set_pending_swap() {
  local _starts=0 _k _v
  if [[ -f "${STATE_FILE}" ]]; then
    while IFS='=' read -r _k _v; do
      [[ "${_k}" == "starts" ]] && _starts="${_v}"
    done < "${STATE_FILE}"
  fi
  [[ "${_starts}" =~ ^[0-9]+$ ]] || _starts=0
  printf 'starts=%s\nhas_pending_swap=1\n' "${_starts}" > "${STATE_FILE}"
}

_get_file_mode() {
  python3 -c "
import os, stat as _st
try:
    s = os.stat('$1')
    print(oct(_st.S_IMODE(s.st_mode))[2:])
except Exception:
    print('755')
" 2>/dev/null || echo "755"
}

# ---------------------------------------------------------------------------
# Main update logic
# ---------------------------------------------------------------------------

_do_update() {

  # -- 1. Gate ---------------------------------------------------------------
  if [[ "${AUTO_UPDATE}" != "1" ]]; then
    log "AUTO_UPDATE=0 — skipping update check."; return 0
  fi
  if [[ -z "${DESIRED_REF}" || -z "${MANIFEST_SHA256}" ]]; then
    log "fleet_update absent from broker response — updater dormant, skipping."; return 0
  fi
  local _now _last _elapsed
  _now="$(date +%s)"
  _last="$(cat "${TS_FILE}" 2>/dev/null || echo 0)"
  [[ "${_last}" =~ ^[0-9]+$ ]] || _last=0
  _elapsed=$(( _now - _last ))
  if (( _elapsed < UPDATE_MIN_INTERVAL )); then
    log "Last check ${_elapsed}s ago (min interval ${UPDATE_MIN_INTERVAL}s) — skipping."; return 0
  fi
  printf '%s\n' "${_now}" > "${TS_FILE}"

  # -- 2. Fetch manifest -----------------------------------------------------
  local _manifest_url
  _manifest_url="https://raw.githubusercontent.com/${UPDATE_REPO}/${DESIRED_REF}/${RUNNER_TYPE}/.fleet-manifest"
  local _manifest_tmp
  _manifest_tmp="$(mktemp "${RUNNER_DIR}/.fleet-manifest-fetch-XXXXXX")"

  log "Fetching manifest: ${_manifest_url}"
  if ! curl --silent --fail --max-time 15 --output "${_manifest_tmp}" "${_manifest_url}"; then
    warn "Manifest fetch failed — fail-safe: no update applied."
    rm -f "${_manifest_tmp}"; return 0
  fi

  # -- 3. Verify broker-anchored hash ----------------------------------------
  local _fetched_hash
  _fetched_hash="$(_sha256_file "${_manifest_tmp}")"
  if [[ "${_fetched_hash}" != "${MANIFEST_SHA256}" ]]; then
    warn "SECURITY: manifest sha256 mismatch (got ${_fetched_hash}, expected ${MANIFEST_SHA256}). Fail-safe."
    rm -f "${_manifest_tmp}"; return 0
  fi

  # -- 4. Already current? ---------------------------------------------------
  if [[ -f "${LOCAL_MANIFEST}" ]]; then
    local _local_hash
    _local_hash="$(_sha256_file "${LOCAL_MANIFEST}")"
    if [[ "${_local_hash}" == "${_fetched_hash}" ]]; then
      log "Manifest unchanged (content-hash match) — already at current fleet-code version."
      rm -f "${_manifest_tmp}"; return 0
    fi
  fi

  # -- 5. Parse and validate manifest ----------------------------------------
  local _manifest_version="" _abort=0 _line _hash _fname
  local -a _entry_hashes=() _entry_names=()

  while IFS= read -r _line; do
    [[ -z "${_line}" || "${_line}" == \#* ]] && continue
    if [[ "${_line}" == version=* ]]; then
      _manifest_version="${_line#version=}"; continue
    fi
    read -r _hash _fname <<< "${_line}"

    # CRITICAL: reject traversal characters or off-allowlist entries; abort the whole update.
    if [[ "${_fname}" == *"/"* || "${_fname}" == *".."* ]]; then
      warn "SECURITY: manifest entry '${_fname}' contains path traversal. Aborting update."
      _abort=1; break
    fi
    if ! _in_allowlist "${_fname}"; then
      warn "SECURITY: manifest entry '${_fname}' not in update allowlist. Aborting update."
      _abort=1; break
    fi
    _entry_hashes+=("${_hash}")
    _entry_names+=("${_fname}")
  done < "${_manifest_tmp}"

  if (( _abort )); then
    rm -f "${_manifest_tmp}"; return 0
  fi
  if [[ -z "${_manifest_version}" ]]; then
    warn "Manifest missing version= line — fail-safe."; rm -f "${_manifest_tmp}"; return 0
  fi
  if (( ${#_entry_names[@]} == 0 )); then
    warn "Manifest has no file entries — fail-safe."; rm -f "${_manifest_tmp}"; return 0
  fi

  # -- 6. Download and verify each listed file --------------------------------
  rm -rf "${STAGING_DIR}"
  mkdir -p "${STAGING_DIR}"
  local _base_url="https://raw.githubusercontent.com/${UPDATE_REPO}/${DESIRED_REF}/${RUNNER_TYPE}"
  local _i

  for _i in "${!_entry_names[@]}"; do
    _fname="${_entry_names[${_i}]}"
    _hash="${_entry_hashes[${_i}]}"
    local _staged="${STAGING_DIR}/${_fname}"

    log "Downloading ${_fname} ..."
    if ! curl --silent --fail --max-time 30 --output "${_staged}" "${_base_url}/${_fname}"; then
      warn "Download failed for ${_fname} — fail-safe: no update applied."
      rm -rf "${STAGING_DIR}"; rm -f "${_manifest_tmp}"; return 0
    fi

    local _actual_hash
    _actual_hash="$(_sha256_file "${_staged}")"
    if [[ "${_actual_hash}" != "${_hash}" ]]; then
      warn "sha256 mismatch for ${_fname} (got ${_actual_hash}, expected ${_hash}) — fail-safe."
      rm -rf "${STAGING_DIR}"; rm -f "${_manifest_tmp}"; return 0
    fi
  done

  # -- 7. Syntax-check and SELFTEST each staged script -----------------------
  for _i in "${!_entry_names[@]}"; do
    _fname="${_entry_names[${_i}]}"
    local _staged="${STAGING_DIR}/${_fname}"

    if ! bash -n "${_staged}" 2>/dev/null; then
      warn "bash -n syntax check failed for staged ${_fname} — fail-safe: no update applied."
      rm -rf "${STAGING_DIR}"; rm -f "${_manifest_tmp}"; return 0
    fi

    if [[ "${_fname}" == "runner-loop.sh" && "${ENABLE_SELFTEST}" == "1" ]]; then
      if ! SELFTEST=1 SELFTEST_CONFIG="${RUNNER_DIR}/config.env" bash "${_staged}" 2>/dev/null; then
        warn "SELFTEST failed for staged runner-loop.sh — fail-safe: no update applied."
        rm -rf "${STAGING_DIR}"; rm -f "${_manifest_tmp}"; return 0
      fi
      log "SELFTEST passed for staged runner-loop.sh."
    fi
  done

  # -- 8. Atomic commit ------------------------------------------------------
  mkdir -p "${LAST_GOOD_DIR}"
  local _af
  for _af in ${UPDATE_ALLOWLIST_CSV}; do
    [[ -f "${RUNNER_DIR}/${_af}" ]] && cp "${RUNNER_DIR}/${_af}" "${LAST_GOOD_DIR}/${_af}"
  done

  _set_pending_swap

  for _i in "${!_entry_names[@]}"; do
    _fname="${_entry_names[${_i}]}"
    local _staged="${STAGING_DIR}/${_fname}"
    local _target="${RUNNER_DIR}/${_fname}"
    local _mode="755"
    [[ -f "${_target}" ]] && _mode="$(_get_file_mode "${_target}")"
    chmod "${_mode}" "${_staged}"
    mv "${_staged}" "${_target}"
  done

  for _af in ${UPDATE_ALLOWLIST_CSV}; do
    local _in_manifest=0
    for _fn in "${_entry_names[@]}"; do
      [[ "${_fn}" == "${_af}" ]] && { _in_manifest=1; break; }
    done
    if (( ! _in_manifest )) && [[ -f "${RUNNER_DIR}/${_af}" ]]; then
      log "Removing ${_af} (no longer in manifest)."
      rm -f "${RUNNER_DIR}/${_af}"
    fi
  done

  cp "${_manifest_tmp}" "${LOCAL_MANIFEST}"
  rm -f "${_manifest_tmp}"
  rm -rf "${STAGING_DIR}"

  # Write version stamp LAST — the commit point.
  printf '%s\n' "${_manifest_version}" > "${VERSION_FILE}"

  log "Fleet-code updated to version ${_manifest_version} (ref ${DESIRED_REF})."
  return "${UPDATE_APPLIED}"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

_update_exit=0
_do_update || _update_exit=$?
exit "${_update_exit}"
