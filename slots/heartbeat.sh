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
# Tripwire: any org runner with a foreign name, a slot number beyond the configured count, or
# labels differing from the class label is logged as TRIPWIRE and latched into
# $GHR_HB_ROOT/tripwire; while latched the published state is `down` (operator deletes the file).
# NOTE: `ok` cannot see the job queue (state App has no Actions:read); the org-side rescuer covers it.
#
# Dependencies: lib/gh-app.sh. Uses the STATE App (never the runner App).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=slots/lib/gh-app.sh
. "$HERE/lib/gh-app.sh"

GHR_STATE_DIR="${GHR_STATE_DIR:-/var/db/ghr/slots}"
GHR_HB_ROOT="${GHR_HB_ROOT:-/var/db/ghr}"
STALE_SECS="${STALE_SECS:-120}"
# Stuck = no online runner on two consecutive heartbeats (60 s apart, > 45 s): a wedged slot goes down
# about 2 min after GitHub marks it offline; a finishing job (runner gone for 2-5 s) is never seen twice.
STUCK_SECS="${STUCK_SECS:-45}"
# Tolerated clock skew between a slot file and this process.
FUTURE_SECS="${FUTURE_SECS:-5}"
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
  local class count n f ts since st name status busy total=0 busy_ct=0 first mark
  mkdir -p "$hb" 2> /dev/null
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
      # A timestamp from the future (clock jump, or a forged/garbled file) must not look fresh.
      [ "$((ts - now))" -le "$FUTURE_SECS" ] && [ "$((since - now))" -le "$FUTURE_SECS" ] || { echo down; return 0; }
      name="ghr-$class-$n"
      # NOTE: no awk `exit` (would SIGPIPE a producer under pipefail); first match wins via flag.
      status=$(awk -F'\t' -v nm="$name" '$2 == nm && !f { print $3; f = 1 }' "$runners")
      busy=$(awk -F'\t' -v nm="$name" '$2 == nm && !f { print $4; f = 1 }' "$runners")
      # Stuck = a slot that wants a runner (idle-prep/registered/backoff) whose runner is not online on
      # TWO consecutive heartbeats. Timed from the first heartbeat that OBSERVED it, kept in $hb.
      # WHY not from `since`: during a job the state stays `registered` with the mint time as `since`;
      # when the job ends GitHub deletes the single-use runner seconds before the loop writes its next
      # state, so `since`-based timing called a just-finished slot stuck (live false `down`, 2026-10-16).
      mark="$hb/notonline_$class-$n"
      case "$st" in
        idle-prep | registered | backoff)
          if [ "$status" = "online" ]; then
            rm -f "$mark"
          else
            first=$(cat "$mark" 2> /dev/null || true)
            if ! [[ "$first" =~ ^[0-9]+$ ]] || [ "$first" -gt "$now" ]; then first=$now; echo "$now" > "$mark"; fi
            if [ "$((now - first))" -gt "$STUCK_SECS" ]; then echo down; return 0; fi
          fi
          ;;
        *) rm -f "$mark" ;;
      esac
      [ "$busy" = "true" ] && busy_ct=$((busy_ct + 1))
      n=$((n + 1))
    done
  done
  [ "$total" -gt 0 ] || { echo down; return 0; }
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

# norm_labels STRING — comma/space separated labels -> lowercase, sorted, unique, comma-joined.
norm_labels() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr ', ' '\n\n' | grep -v '^$' | sort -u | paste -sd, -
}

# expected_labels CLASS — the label set a runner of CLASS must carry, normalised.
expected_labels() {
  case "$1" in
    light) norm_labels "${LIGHT_LABELS:-ghr-light}" ;;
    supabase) norm_labels "${SUPABASE_LABELS:-ghr-supabase}" ;;
  esac
}

# tripwire_names < tsv — print names of runners that do not belong to this fleet:
#   - name not matching ghr-(light|supabase)-<n>
#   - <n> outside 1..<configured slot count> for its class (LIGHT_SLOTS / SUPABASE_SLOTS)
#   - custom labels different from the configured label set for its class
# WHY: a foreign or copied runner in the org can steal jobs meant for the pool.
tripwire_names() {
  local id name status busy labels class num count want
  while IFS=$'\t' read -r id name status busy labels; do
    [ -n "$id$name" ] || continue
    ghr_valid_runner_name "$name" || { printf '%s\n' "$name"; continue; }
    class=${name#ghr-}; class=${class%%-*}
    num=${name##*-}
    case $class in light) count=${LIGHT_SLOTS:-0} ;; supabase) count=${SUPABASE_SLOTS:-0} ;; *) count=0 ;; esac
    # >6 digits cannot be a real slot number (and would overflow shell arithmetic)
    if [ "${#num}" -gt 6 ] || [ "$((10#$num))" -lt 1 ] || [ "$((10#$num))" -gt "$count" ]; then
      printf '%s\n' "$name"; continue
    fi
    want=$(expected_labels "$class")
    [ "$labels" = "$want" ] || printf '%s\n' "$name"
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
  # Latched: while the tripwire file exists the pool is not trusted, whatever the slots say.
  if [ -e "$GHR_HB_ROOT/tripwire" ]; then state=down; ghr_log "tripwire latched: publishing down"; fi
  for repo in ${CONSUMER_REPOS//,/ }; do
    [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { ghr_log "WARN skipping invalid repo: $repo"; rc=1; continue; }
    write_state_var "$repo" "${state}@${now}" || { ghr_log "ERROR variable write failed: $repo"; rc=1; }
  done
  exit "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
