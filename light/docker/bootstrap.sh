#!/usr/bin/env bash
# bootstrap.sh — stable ENTRYPOINT trust root for the containerized "light" runner.
#
# Purpose: resolve a registration token (broker model captures the full /token JSON for the
# optional fleet_update payload), optionally self-update runner-payload.sh from a verified
# GitHub ref, then exec the payload. Each container restart is the update boundary — no atomic
# swap or rollback machinery is needed (unlike the systemd variant, which patches files in place).
#
# CRITICAL: this file is NOT listed in .fleet-manifest and must NEVER be self-updated. It is the
# stable trust root. Update it only via a full Docker image rebuild.
#
# Trust model (broker-anchored):
#   broker /token response  →  .fleet_update.manifest_sha256 (out-of-repo anchor)
#   fetch manifest from GitHub  →  compare sha256 to broker-supplied value
#   match proves manifest was not tampered after the broker snapshot
#   download each managed file, verify sha256 per manifest entry, then exec
#   Compromising the git ref alone cannot forge an update — the broker must also be compromised.
#
# Fail-safe: ANY failure in the update path (network, hash mismatch, bad manifest, disallowed
# path, missing tool) logs a warning and falls back to the baked-in runner-payload.sh.
# A job is never blocked by an update failure.
#
# Dependencies: curl, jq, bash 4+, sha256sum (all present in the base image + Dockerfile).

set -euo pipefail

# ── Config (from container environment; defaults below) ────────────────────────
RUNNER_HOME="${RUNNER_HOME:-/home/runner}"
GH_ORG="${GH_ORG:-your-org}"
RUNNER_NAME="${RUNNER_NAME:-gh-runner-light-${OWNER:-$(hostname -s)}-${RUNNER_NUMBER:-1}}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,x64,light}"
RUNNER_WORKDIR="${RUNNER_WORKDIR:-_work}"
AUTO_UPDATE="${AUTO_UPDATE:-1}"
UPDATE_REPO="${UPDATE_REPO:-islee/gh-runners}"

# NOTE: BOOTSTRAP_DIR is resolved at startup from the script's own path (typically /opt).
BOOTSTRAP_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BOOTSTRAP_DIR
readonly BAKED_PAYLOAD="${BOOTSTRAP_DIR}/runner-payload.sh"

log()  { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [bootstrap] [INFO]  $*" >&2; }
warn() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [bootstrap] [WARN]  $*" >&2; }

# ── Read local fleet version from the baked-in manifest ────────────────────────
# Sent as X-Fleet-Version so the broker can emit appropriate fleet_update guidance.
_read_local_version() {
  local _mf="${BOOTSTRAP_DIR}/.fleet-manifest" _line
  if [[ ! -f "${_mf}" ]]; then
    echo "unknown"; return
  fi
  while IFS= read -r _line; do
    if [[ "${_line}" == version=* ]]; then
      echo "${_line#version=}"; return
    fi
  done < "${_mf}"
  echo "unknown"
}

_LOCAL_VERSION="$(_read_local_version)"
readonly _LOCAL_VERSION

# ── Credential resolution ──────────────────────────────────────────────────────
# Priority: RUNNER_TOKEN (A) → BROKER_URL+BROKER_SECRET (B) → ACCESS_TOKEN (PAT).
# Model B: capture the full /token JSON to extract the optional fleet_update payload alongside
# the token. Models A and C produce no fleet_update — the update check is skipped for them.

REG_TOKEN=""
_fleet_desired_ref=""
_fleet_manifest_sha256=""

resolve_credential() {
  if [[ -n "${RUNNER_TOKEN:-}" ]]; then
    log "Credential: RUNNER_TOKEN (model A — static registration token)"
    REG_TOKEN="${RUNNER_TOKEN}"
    return 0
  fi

  if [[ -n "${BROKER_URL:-}" ]]; then
    log "Credential: BROKER_URL (model B — fetching full /token JSON from broker)"
    local _resp
    _resp="$(curl --silent --fail --max-time 15 -X POST \
      -H "Authorization: Bearer ${BROKER_SECRET:-}" \
      -H "X-Runner-Name: ${RUNNER_NAME}" \
      -H "X-Fleet-Version: ${_LOCAL_VERSION}" \
      -H "X-Fleet-Variant: docker" \
      "${BROKER_URL%/}/token")" || {
      echo "[bootstrap] FATAL: broker token fetch failed (check BROKER_URL / BROKER_SECRET)." >&2
      exit 1
    }

    REG_TOKEN="$(jq -r '.token' <<< "${_resp}")"
    [[ -n "${REG_TOKEN}" && "${REG_TOKEN}" != "null" ]] || {
      echo "[bootstrap] FATAL: broker returned an empty token." >&2; exit 1
    }

    # Extract optional fleet_update fields; absent fields → empty strings → update skipped.
    _fleet_desired_ref="$(jq -r '.fleet_update.desired_ref // empty' <<< "${_resp}" 2>/dev/null)" \
      || _fleet_desired_ref=""
    _fleet_manifest_sha256="$(jq -r '.fleet_update.manifest_sha256 // empty' <<< "${_resp}" 2>/dev/null)" \
      || _fleet_manifest_sha256=""
    return 0
  fi

  if [[ -n "${ACCESS_TOKEN:-}" ]]; then
    log "Credential: ACCESS_TOKEN (PAT — minting registration token via GitHub REST)"
    local _tok
    _tok="$(curl --silent --fail --max-time 15 -X POST \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/orgs/${GH_ORG}/actions/runners/registration-token" \
      | jq -r '.token')" || {
      echo "[bootstrap] FATAL: GitHub REST token mint failed (check ACCESS_TOKEN scope and GH_ORG)." >&2
      exit 1
    }
    [[ -n "${_tok}" && "${_tok}" != "null" ]] || {
      echo "[bootstrap] FATAL: GitHub returned an empty token." >&2; exit 1
    }
    unset ACCESS_TOKEN  # drop the PAT from the environment once we have the token
    REG_TOKEN="${_tok}"
    return 0
  fi

  echo "[bootstrap] FATAL: no credential found. Set RUNNER_TOKEN, BROKER_URL(+BROKER_SECRET), or ACCESS_TOKEN." >&2
  echo "[bootstrap]        See env.example for each variable." >&2
  exit 1
}

# ── sha256 helper ──────────────────────────────────────────────────────────────
# Linux container: sha256sum is always present; shasum fallback for local macOS testing.
_sha256_file() {
  if command -v sha256sum &>/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# ── Self-update ────────────────────────────────────────────────────────────────
# CRITICAL: only basenames in this list may be downloaded and staged.
# Must never include bootstrap.sh (the stable trust root) or any path containing / or ..
readonly _MANAGED_BASENAMES=("runner-payload.sh")

_in_allowlist() {
  local _f="$1" _b
  for _b in "${_MANAGED_BASENAMES[@]}"; do
    [[ "${_f}" == "${_b}" ]] && return 0
  done
  return 1
}

# Fetch, verify, and stage an updated runner-payload.sh, then exec it.
# On success: execs the staged payload — this process is replaced; the function never returns.
# On any failure: returns 1 so the caller falls back to the baked-in payload.
_try_update() {
  local _desired_ref="$1" _manifest_sha256="$2"
  local _manifest_url="https://raw.githubusercontent.com/${UPDATE_REPO}/${_desired_ref}/light/docker/.fleet-manifest"
  local _staging _manifest_tmp _fetched_hash _manifest_version _abort
  local _line _hash _fname _actual_hash _staged _base_url _i
  local -a _entry_hashes=() _entry_names=()

  _staging="$(mktemp -d)"
  _manifest_tmp="${_staging}/.fleet-manifest"
  _manifest_version=""
  _abort=0

  log "Fetching manifest from ${_manifest_url}"
  # --max-filesize bounds a repo-compromise DoS: the managed files are tiny, so cap at 1 MiB. A bigger
  # body is rejected before any hash work (the broker-anchored check would reject it anyway).
  if ! curl --silent --fail --max-time 15 --max-filesize 1048576 --output "${_manifest_tmp}" "${_manifest_url}"; then
    warn "Manifest fetch failed — falling back to baked-in payload."
    rm -rf "${_staging}"; return 1
  fi

  # IMPORTANT: verify the broker-anchored sha256 BEFORE trusting any manifest content.
  # The broker (not the repo) supplies the expected hash — the out-of-repo trust anchor.
  _fetched_hash="$(_sha256_file "${_manifest_tmp}")"
  if [[ "${_fetched_hash}" != "${_manifest_sha256}" ]]; then
    warn "SECURITY: manifest sha256 mismatch (got ${_fetched_hash}, expected ${_manifest_sha256}) — falling back."
    rm -rf "${_staging}"; return 1
  fi

  # Parse manifest: collect (hash, basename) pairs. One bad entry aborts the whole update.
  while IFS= read -r _line; do
    [[ -z "${_line}" || "${_line}" == \#* ]] && continue
    if [[ "${_line}" == version=* ]]; then
      _manifest_version="${_line#version=}"; continue
    fi
    read -r _hash _fname <<< "${_line}"

    # CRITICAL: path traversal guard — reject any / or .. in a basename immediately.
    # Abort the ENTIRE update (not just the offending entry) to prevent partial poisoning.
    if [[ "${_fname}" == *"/"* || "${_fname}" == *".."* ]]; then
      warn "SECURITY: manifest entry '${_fname}' contains path traversal — aborting update."
      _abort=1; break
    fi
    if ! _in_allowlist "${_fname}"; then
      warn "SECURITY: manifest entry '${_fname}' not in allowlist — aborting update."
      _abort=1; break
    fi
    _entry_hashes+=("${_hash}")
    _entry_names+=("${_fname}")
  done < "${_manifest_tmp}"

  if (( _abort )) || [[ -z "${_manifest_version}" ]] || (( ${#_entry_names[@]} == 0 )); then
    warn "Manifest invalid or no valid entries — falling back to baked-in payload."
    rm -rf "${_staging}"; return 1
  fi

  _base_url="https://raw.githubusercontent.com/${UPDATE_REPO}/${_desired_ref}/light/docker"

  # Download and verify each file; a single failure aborts and falls back.
  for _i in "${!_entry_names[@]}"; do
    _fname="${_entry_names[${_i}]}"
    _hash="${_entry_hashes[${_i}]}"
    _staged="${_staging}/${_fname}"

    log "Downloading ${_fname} (ref=${_desired_ref}) ..."
    if ! curl --silent --fail --max-time 30 --max-filesize 1048576 --output "${_staged}" "${_base_url}/${_fname}"; then
      warn "Download failed for ${_fname} — falling back to baked-in payload."
      rm -rf "${_staging}"; return 1
    fi

    _actual_hash="$(_sha256_file "${_staged}")"
    if [[ "${_actual_hash}" != "${_hash}" ]]; then
      warn "sha256 mismatch for ${_fname} (got ${_actual_hash}, expected ${_hash}) — falling back."
      rm -rf "${_staging}"; return 1
    fi

    if ! bash -n "${_staged}" 2>/dev/null; then
      warn "bash -n syntax check failed for staged ${_fname} — falling back."
      rm -rf "${_staging}"; return 1
    fi

    chmod 755 "${_staged}"
  done

  log "All files verified (manifest version ${_manifest_version}) — execing staged runner-payload.sh."
  # NOTE: _staging dir is not cleaned before exec. In an ephemeral container this is acceptable:
  # the container is torn down after the job regardless of temp files.
  exec "${_staging}/runner-payload.sh" || {
    warn "exec of staged runner-payload.sh failed — falling back to baked-in payload."
    rm -rf "${_staging}"; return 1
  }
}

# ── Main ──────────────────────────────────────────────────────────────────────

resolve_credential

# Export REG_TOKEN so the exec'd payload inherits it without a second broker call.
export REG_TOKEN

if [[ "${AUTO_UPDATE}" == "1" && -n "${_fleet_desired_ref}" && -n "${_fleet_manifest_sha256}" ]]; then
  log "fleet_update present (ref=${_fleet_desired_ref}) — attempting update ..."
  # _try_update execs on success (replaces this process) or returns 1 on any failure.
  _try_update "${_fleet_desired_ref}" "${_fleet_manifest_sha256}" \
    || warn "Update path failed (fail-safe) — running baked-in payload."
elif [[ "${AUTO_UPDATE}" != "1" ]]; then
  log "AUTO_UPDATE=0 — skipping update check, running baked-in payload."
else
  log "No fleet_update in broker response — running baked-in payload."
fi

exec "${BAKED_PAYLOAD}"
