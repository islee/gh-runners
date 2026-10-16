#!/bin/bash
# heartbeat.sh — publish the fleet's health as a repo variable and run the foreign-runner tripwire.
#
# Context: LaunchDaemon dev.ghr.heartbeat, user _ghrstate, every 60 s. Reads the slot state files
# written by slot-loop.sh (read-only), asks GitHub which runners exist, computes one of
#   ok        every slot fresh and none stuck
#   saturated every slot busy for >= SATURATED_SECS (jobs would queue; callers may prefer hosted)
#   down      anything else (missing/stale slot file, stuck slot, no slots configured)
# and writes "<state>@<epoch>" to the repo variable SELF_HOSTED_STATE of each CONSUMER_REPOS repo
# (PATCH, then POST on 404). pick-runner in the org's .github repo reads it and falls back to
# hosted runners when it is not a fresh `ok`.
#
# WHY repo-level variables: org variables don't reach private repos on GitHub Free.
# WHY "stuck" uses GitHub runner status, not the job queue: the state App has no Actions:read, so
# queued jobs are invisible. A slot sitting in idle-prep/registered/backoff for > STUCK_SECS
# whose runner is not `online` on GitHub is wedged either way, and that is observable.
# Tripwire: any org runner whose name is not ghr-(light|supabase)-<n> is logged as TRIPWIRE and
# latched into $GHR_HB_ROOT/tripwire (operator clears it by deleting the file).
#
# Dependencies: lib/gh-app.sh. Uses the STATE App (never the runner App).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=slots/lib/gh-app.sh
. "$HERE/lib/gh-app.sh"

GHR_STATE_DIR="${GHR_STATE_DIR:-/var/db/ghr/slots}"
GHR_HB_ROOT="${GHR_HB_ROOT:-/var/db/ghr}"
STALE_SECS="${STALE_SECS:-120}"
STUCK_SECS="${STUCK_SECS:-180}"
SATURATED_SECS="${SATURATED_SECS:-60}"
STATE_VAR_NAME="${STATE_VAR_NAME:-SELF_HOSTED_STATE}"

# Slot files are our own fixed-format single-line JSON, so sed is enough (no python per slot).
state_field_num() { sed -n "s/.*\"$2\":\([0-9][0-9]*\).*/\1/p" "$1" | head -1; }
state_field_str() { sed -n "s/.*\"$2\":\"\([a-z-]*\)\".*/\1/p" "$1" | head -1; }

# compute_state STATE_DIR NOW RUNNERS_TSV HB_DIR — print ok|saturated|down.
# Slot counts come from LIGHT_SLOTS / SUPABASE_SLOTS. HB_DIR keeps all_busy_since between runs so
# "busy for > 60 s" survives the 60 s process lifetime.
compute_state() {
  local dir=$1 now=$2 runners=$3 hb=$4
  local class count n f ts since st name status busy total=0 busy_ct=0 age
  for class in light supabase; do
    case $class in
      light) count=${LIGHT_SLOTS:-0} ;;
      supabase) count=${SUPABASE_SLOTS:-0} ;;
    esac
    n=1
    while [ "$n" -le "$count" ]; do
      total=$((total + 1))
      f="$dir/$class-$n.json"
      [ -r "$f" ] || { echo down; return 0; }
      ts=$(state_field_num "$f" ts)
      since=$(state_field_num "$f" since)
      st=$(state_field_str "$f" state)
      [ -n "$ts" ] && [ -n "$since" ] && [ -n "$st" ] || { echo down; return 0; }
      [ "$((now - ts))" -le "$STALE_SECS" ] || { echo down; return 0; }
      name="ghr-$class-$n"
      status=$(awk -F'\t' -v nm="$name" '$2 == nm { print $3; exit }' "$runners")
      busy=$(awk -F'\t' -v nm="$name" '$2 == nm { print $4; exit }' "$runners")
      case "$st" in
        idle-prep | registered | backoff)
          age=$((now - since))
          if [ "$age" -gt "$STUCK_SECS" ] && [ "$status" != "online" ]; then echo down; return 0; fi
          ;;
      esac
      [ "$busy" = "true" ] && busy_ct=$((busy_ct + 1))
      n=$((n + 1))
    done
  done
  [ "$total" -gt 0 ] || { echo down; return 0; }
  mkdir -p "$hb" 2> /dev/null
  if [ "$busy_ct" -eq "$total" ]; then
    local first
    first=$(cat "$hb/all_busy_since" 2> /dev/null || true)
    if ! [[ "$first" =~ ^[0-9]+$ ]]; then first=$now; echo "$now" > "$hb/all_busy_since"; fi
    if [ "$((now - first))" -ge "$SATURATED_SECS" ]; then echo saturated; return 0; fi
  else
    rm -f "$hb/all_busy_since"
  fi
  echo ok
}

# tripwire_names < tsv — print names of runners NOT matching the fleet naming convention.
tripwire_names() {
  local id name rest
  while IFS=$'\t' read -r id name rest; do
    [ -n "$id$name" ] || continue
    ghr_valid_runner_name "$name" || printf '%s\n' "$name"
  done
}

# write_state_var REPO VALUE — PATCH the repo variable, create it on 404.
write_state_var() {
  local repo=$1 value=$2 rc body
  body=$(printf '{"name":"%s","value":"%s"}' "$STATE_VAR_NAME" "$value")
  rc=0
  gh_api PATCH "/repos/${repo}/actions/variables/${STATE_VAR_NAME}" "$body" > /dev/null || rc=$?
  if [ "$rc" -eq 4 ]; then
    rc=0
    gh_api POST "/repos/${repo}/actions/variables" "$body" > /dev/null || rc=$?
  fi
  return "$rc"
}

main() {
  ghr_load_config || exit 1
  gh_app_init "${STATE_APP_ID:-}" "${STATE_INSTALLATION_ID:-}" "${STATE_APP_KEY:-/var/db/_ghrstate/state-app.pem}" || exit 1
  local tmp now state rc=0 repo bad
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/ghr-hb.XXXXXX") || exit 1
  trap 'rm -f "$tmp"' EXIT
  gh_list_runners > "$tmp" || { ghr_log "ERROR cannot list runners; not publishing"; exit 1; }
  now=$(date -u +%s)
  state=$(compute_state "$GHR_STATE_DIR" "$now" "$tmp" "$GHR_HB_ROOT/hb")
  ghr_log "state=$state"
  bad=$(tripwire_names < "$tmp")
  if [ -n "$bad" ]; then
    ghr_log "TRIPWIRE foreign runner(s) in org: $(printf '%s' "$bad" | tr '\n' ' ' | head -c 300)"
    { date -u +%Y-%m-%dT%H:%M:%SZ; printf '%s\n' "$bad"; } > "$GHR_HB_ROOT/tripwire" 2> /dev/null \
      || ghr_log "WARN cannot write tripwire file"
  fi
  for repo in ${CONSUMER_REPOS//,/ }; do
    [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { ghr_log "WARN skipping invalid repo: $repo"; rc=1; continue; }
    write_state_var "$repo" "${state}@${now}" || { ghr_log "ERROR variable write failed: $repo"; rc=1; }
  done
  exit "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
