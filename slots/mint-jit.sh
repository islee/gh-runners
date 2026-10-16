#!/bin/bash
# mint-jit.sh <name> <label...> — mint a single-use GitHub org JIT runner config.
#
# Context: run by slot-loop.sh as _ghrctl with the runner App (org self-hosted-runners write).
# This is the label/name policy gate: it is the only place a runner identity is created, so
# every rule that keeps the fleet from stealing hosted-runner work lives here.
# Prints ONLY `encoded_jit_config` on stdout (the caller captures it into a shell variable and
# pipes it onward on stdin; it must never reach argv or the environment).
#
# Refuses (exit 2, nothing sent to GitHub):
#   - names not matching ^ghr-(light|supabase)-[0-9]+$ (anchored, no trailing newline)
#   - hosted-runner labels (ubuntu-*, macos-*, windows-*) -- CRITICAL: a runner carrying one of
#     these would silently absorb jobs meant for GitHub-hosted runners
#   - `self-hosted` as the only label
#   - any label not in ALLOWED_LABELS; an EMPTY ALLOWED_LABELS refuses everything (fail closed;
#     the broker treats empty as "disabled", but this controller has no reason to run open)
#
# Dependencies: lib/gh-app.sh, curl, openssl, python3.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=slots/lib/gh-app.sh
. "$HERE/lib/gh-app.sh"

# jit_label_ok LABEL — policy for a single label; prints the reason on failure.
jit_label_ok() {
  local lbl lower allowed found=0
  lbl=$1
  # WHY charset: labels are interpolated into hand-built JSON; the whitelist makes escaping moot.
  [[ "$lbl" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "invalid label characters: $lbl"; return 1; }
  lower=$(printf '%s' "$lbl" | tr '[:upper:]' '[:lower:]')
  # Hosted check runs BEFORE the allowlist so an operator typo in ALLOWED_LABELS can't open it.
  case "$lower" in
    ubuntu|ubuntu-*|macos|macos-*|windows|windows-*) echo "hosted-runner label refused: $lbl"; return 1 ;;
  esac
  [ -n "${ALLOWED_LABELS:-}" ] || { echo "ALLOWED_LABELS is empty (fail closed)"; return 1; }
  # Tolerate commas and spaces as separators (mirrors the broker's strip behaviour).
  for allowed in $(printf '%s' "$ALLOWED_LABELS" | tr ',' ' ' | tr '[:upper:]' '[:lower:]'); do
    [ "$allowed" = "$lower" ] && found=1
  done
  [ "$found" -eq 1 ] || { echo "label not allowed: $lbl"; return 1; }
  return 0
}

# jit_validate NAME LABEL... — whole-request validation; exit 0 iff mintable.
jit_validate() {
  local name=$1 lbl reason non_selfhosted=0
  shift
  ghr_valid_runner_name "$name" || { echo "invalid runner name" >&2; return 1; }
  [ "$#" -ge 1 ] || { echo "at least one label required" >&2; return 1; }
  for lbl in "$@"; do
    reason=$(jit_label_ok "$lbl") || { echo "$reason" >&2; return 1; }
    [ "$(printf '%s' "$lbl" | tr '[:upper:]' '[:lower:]')" = "self-hosted" ] || non_selfhosted=1
  done
  [ "$non_selfhosted" -eq 1 ] || { echo "self-hosted alone is refused" >&2; return 1; }
  return 0
}

# jit_body NAME GROUP LABEL... — request JSON. Inputs are pre-validated to a JSON-safe charset.
jit_body() {
  local name=$1 group=$2 lbl list=""
  shift 2
  for lbl in "$@"; do list="${list:+$list,}\"$lbl\""; done
  printf '{"name":"%s","runner_group_id":%s,"labels":[%s],"work_folder":"_work"}' "$name" "$group" "$list"
}

main() {
  [ "$#" -ge 2 ] || { echo "usage: mint-jit.sh <name> <label...>" >&2; exit 2; }
  ghr_load_config || exit 1
  local name=$1
  shift
  jit_validate "$name" "$@" || exit 2
  gh_app_init "${RUNNER_APP_ID:-}" "${RUNNER_INSTALLATION_ID:-}" "${RUNNER_APP_KEY:-/var/db/_ghrctl/runner-app.pem}" || exit 1
  local resp jit
  resp=$(gh_api POST "/orgs/${ORG}/actions/runners/generate-jitconfig" "$(jit_body "$name" "$RUNNER_GROUP_ID" "$@")") \
    || { ghr_log "ERROR generate-jitconfig failed for $name"; exit 1; }
  jit=$(printf '%s' "$resp" | gh_json_get encoded_jit_config) || { ghr_log "ERROR no encoded_jit_config"; exit 1; }
  [[ "$jit" =~ ^[A-Za-z0-9+/=_-]+$ ]] || { ghr_log "ERROR unexpected jit config shape"; exit 1; }
  printf '%s\n' "$jit"
}

# Sourced by tests (functions only); executed by slot-loop.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
