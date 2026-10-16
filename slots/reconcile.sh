#!/bin/bash
# reconcile.sh <name> — delete a stale OFFLINE org runner that has exactly this name.
#
# Context: run by slot-loop.sh (as _ghrctl) before each mint. A crash between mint and use
# leaves a registered-but-offline JIT runner whose name would make the next mint fail with a
# 422 name conflict. Exact-name only: it never touches any other runner (the tripwire, not this
# script, deals with foreign names). An ONLINE runner of the same name is left alone and
# logged -- deleting it would kill a live job.
#
# Dependencies: lib/gh-app.sh.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=slots/lib/gh-app.sh
. "$HERE/lib/gh-app.sh"

# reconcile_pick NAME < tsv — print `id status` of the runner whose name equals NAME exactly.
# WHY awk string equality (not regex): ghr-light-1 must never match ghr-light-10.
reconcile_pick() {
  awk -F'\t' -v n="$1" '$2 == n { print $1 " " $3; exit }'
}

main() {
  [ "$#" -eq 1 ] || { echo "usage: reconcile.sh <name>" >&2; exit 2; }
  local name=$1
  ghr_valid_runner_name "$name" || { echo "invalid runner name" >&2; exit 2; }
  ghr_load_config || exit 1
  gh_app_init "${RUNNER_APP_ID:-}" "${RUNNER_INSTALLATION_ID:-}" "${RUNNER_APP_KEY:-/var/db/_ghrctl/runner-app.pem}" || exit 1
  local hit id status
  hit=$(gh_list_runners | reconcile_pick "$name") || { ghr_log "ERROR runner list failed"; exit 1; }
  [ -n "$hit" ] || exit 0
  id=${hit%% *}
  status=${hit#* }
  [[ "$id" =~ ^[0-9]+$ ]] || { ghr_log "ERROR unexpected runner id"; exit 1; }
  if [ "$status" = "offline" ]; then
    ghr_log "reconcile: deleting stale offline runner $name (id $id)"
    gh_api DELETE "/orgs/${ORG}/actions/runners/${id}" > /dev/null || { ghr_log "ERROR delete failed"; exit 1; }
  else
    ghr_log "reconcile: runner $name is $status, leaving it"
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
