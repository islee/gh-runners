#!/bin/bash
# heartbeat.sh — publish the fleet's health as a repo variable and run the foreign-runner tripwire.
#
# Context: LaunchDaemon dev.ghr.heartbeat, user _ghrstate, every 60 s. Reads the slot state files
# written by slot-loop.sh (read-only), asks GitHub which runners exist, computes one of
#   down      anything else (missing/stale slot file, stuck slot, tripwire, no slots configured)
#   ok        every slot fresh and none stuck, and no class saturated
#   ok@<epoch>/sat=<c1>,<c2>
#             as ok, but the listed classes (ios|light|supabase, sorted) are SATURATED: every configured
#             slot of that class has been busy for >= SATURATED_SECS, so a job for it would queue.
#             Callers route jobs for a listed class to hosted runners and keep using other classes.
#   saturated every configured class saturated (kept plain for back-compat consumers)
# and writes the value to the repo variable SELF_HOSTED_STATE of each CONSUMER_REPOS repo (PATCH,
# then POST on 404): "<down|ok|saturated>@<epoch>" or "ok@<epoch>/sat=<classes>". pick-runner in
# the org's .github repo reads it and falls back to hosted runners when it is not a fresh `ok`
# (or when the requested label's class is listed in sat=).
# WHY per class: with both supabase slots busy and light slots idle, a fleet-wide "all busy" rule
# never fired and supabase jobs queued on the mini instead of spilling to hosted runners.
#
# WHY repo-level variables: org variables don't reach private repos on GitHub Free.
# WHY "stuck" uses GitHub runner status, not the job queue: the published state must not depend on
# the queue. A slot sitting in idle-prep/registered/backoff for > STUCK_SECS whose runner is not
# `online` on GitHub is wedged either way, and that is observable. (ios slots use IOS_STUCK_SECS (600):
# a macOS VM needs 1-2 min to boot before its runner is online, plus the 60 s heartbeat marks. The ios states dormant,
# waiting-capacity and yielded are healthy.)
# ios demand probe: the ONE place that reads the job queue. With IOS_DEMAND_REPOS set (and
# IOS_SLOTS=1) each run looks at the queued + in_progress runs of those repos for a queued job whose
# labels equal IOS_LABELS and writes `<epoch> <count>` to $GHR_DEMAND_DIR/ios (removed when none).
# The ios slot loop (slot-loop.sh) wakes on that file; it never feeds the published state. Needs the
# State App's repo permission "Actions: read". An API failure leaves the file untouched (it ages
# out after DEMAND_FRESH_SECS in the slot loop) and is only logged.
# Tripwire: any org runner with a foreign name, a slot number beyond the configured count, or
# labels differing from the class label is logged as TRIPWIRE and latched into
# $GHR_HB_ROOT/tripwire; while latched the published state is `down` (operator deletes the file).
# NOTE: `ok` does not look at the job queue (only the ios demand probe does); the org-side rescuer
# covers jobs stranded on a dead pool.
# Saturation inputs: a supabase slot in `yielded` (giving its memory to the ios VM) counts as busy,
# and so does an ios slot in `waiting-capacity`, so jobs spill to hosted runners meanwhile.
# Remote slots (REMOTE_SLOTS="supabase-5"): slots served by ANOTHER host (the optional Proxmox node,
# slots/launch-pve.sh) have no state file here. They are best-effort extra capacity: the tripwire
# accepts their runner names, saturation counts each as one more slot of its class (busy when its
# runner is busy OR absent/offline, since an unreachable slot gives no capacity), and they can
# NEVER make the state `down`.
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
GHR_DEMAND_DIR="${GHR_DEMAND_DIR:-/var/db/ghr/demand}"
# Grace for a slot above the configured count whose loop is still releasing its runner (see retiring).
RETIRE_SECS="${RETIRE_SECS:-180}"
STATE_VAR_NAME="${STATE_VAR_NAME:-SELF_HOSTED_STATE}"

# Slot files are our own fixed-format single-line JSON, so sed is enough (no python per slot).
state_field_num() { sed -n "s/.*\"$2\":\([0-9][0-9]*\).*/\1/p" "$1" | head -1; }
state_field_str() { sed -n "s/.*\"$2\":\"\([a-z-]*\)\".*/\1/p" "$1" | head -1; }

# inc VAR — bump a counter variable by name (bash 3.2: no namerefs).
inc() { printf -v "$1" '%s' "$(( ${!1:-0} + 1 ))"; }

# remote_nums CLASS LOCAL_COUNT [quiet] — print the valid remote slot numbers of CLASS, one per
# line. REMOTE_SLOTS entries must look like <light|supabase>-<n>; invalid ones and ones colliding
# with a local slot (n <= LOCAL_COUNT, which has a state file and stuck detection) are ignored and
# logged (unless quiet, so the tripwire pass does not log everything twice).
remote_nums() {
  local class=$1 local_count=$2 quiet=${3:-} rs=${REMOTE_SLOTS:-} ent n seen=" "
  for ent in ${rs//,/ }; do
    if ! [[ "$ent" =~ ^(light|supabase)-[1-9][0-9]{0,5}$ ]]; then
      [ -n "$quiet" ] || ghr_log "WARN REMOTE_SLOTS: ignoring invalid entry '$ent'"
      continue
    fi
    [ "${ent%-*}" = "$class" ] || continue
    n=${ent##*-}
    if [ "$n" -le "$local_count" ]; then
      [ -n "$quiet" ] || ghr_log "WARN REMOTE_SLOTS: $ent collides with a local slot, ignoring"
      continue
    fi
    # a repeated entry must not count twice
    case "$seen" in *" $n "*) continue ;; esac
    seen="$seen$n "
    printf '%s\n' "$n"
  done
}

# compute_state STATE_DIR NOW RUNNERS_TSV HB_DIR — print the state WITHOUT the timestamp:
#   down | ok | ok/sat=<classes> | saturated
# Slot counts come from LIGHT_SLOTS / SUPABASE_SLOTS / IOS_SLOTS (0|1). HB_DIR keeps all_busy_since_<class> between
# runs so "busy for >= 60 s" survives the 60 s process lifetime; the file is removed as soon as any
# slot of that class is not busy.
compute_state() {
  local dir=$1 now=$2 runners=$3 hb=$4
  local class count n f ts since st name status busy total=0 first mark stuck_secs
  local busy_ios=0 total_ios=0 busy_light=0 total_light=0 busy_supabase=0 total_supabase=0
  mkdir -p "$hb" 2> /dev/null
  for class in light supabase ios; do
    case $class in
      light) count=${LIGHT_SLOTS:-0} ;;
      supabase) count=${SUPABASE_SLOTS:-0} ;;
      ios) count=${IOS_SLOTS:-0}; [ "$count" -le 1 ] || count=1 ;;
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
      stuck_secs=$STUCK_SECS
      [ "$class" != ios ] || stuck_secs=${IOS_STUCK_SECS:-600}
      # `releasing` = the runner was deleted and the slot waits for its launch (and VM) to exit, which
      # can take a boot time; only a launch stuck for IOS_STUCK_SECS is a wedge.
      [ "$st" != releasing ] || stuck_secs=${IOS_STUCK_SECS:-600}
      case "$st" in
        idle-prep | registered | backoff | releasing)
          if [ "$status" = "online" ]; then
            rm -f "$mark"
          else
            first=$(cat "$mark" 2> /dev/null || true)
            if ! [[ "$first" =~ ^[0-9]+$ ]] || [ "$first" -gt "$now" ]; then first=$now; echo "$now" > "$mark"; fi
            if [ "$((now - first))" -gt "$stuck_secs" ]; then echo down; return 0; fi
          fi
          ;;
        *) rm -f "$mark" ;;
      esac
      # A slot that has handed its capacity to (or is waiting for) the ios VM serves nobody for now:
      # busy for saturation, whatever its runner says.
      case "$class:$st" in supabase:yielded | supabase:releasing | ios:waiting-capacity | ios:releasing) busy=true ;; esac
      inc "total_$class"
      [ "$busy" != "true" ] || inc "busy_$class"
      n=$((n + 1))
    done
  done
  [ "$total" -gt 0 ] || { echo down; return 0; }
  # Remote slots (see header): extra capacity only, never `down`. Idle = online and not busy;
  # absent/offline counts as busy so an unreachable remote host cannot hold back spilling.
  local rn rstatus rbusy
  for class in light supabase; do
    case $class in light) count=${LIGHT_SLOTS:-0} ;; supabase) count=${SUPABASE_SLOTS:-0} ;; esac
    for rn in $(remote_nums "$class" "$count"); do
      rstatus=$(awk -F'\t' -v nm="ghr-$class-$rn" '$2 == nm && !f { print $3; f = 1 }' "$runners")
      rbusy=$(awk -F'\t' -v nm="ghr-$class-$rn" '$2 == nm && !f { print $4; f = 1 }' "$runners")
      inc "total_$class"
      if [ "$rstatus" != online ] || [ "$rbusy" = "true" ]; then inc "busy_$class"; fi
    done
  done
  # Per-class saturation: every configured slot of the class busy, continuously, for >= SATURATED_SECS.
  # NOTE: class order is alphabetical on purpose -- it is the order of the published sat= list.
  local sat="" configured=0 nsat=0 tc bc
  for class in ios light supabase; do
    case $class in
      ios) tc=$total_ios; bc=$busy_ios ;;
      light) tc=$total_light; bc=$busy_light ;;
      supabase) tc=$total_supabase; bc=$busy_supabase ;;
    esac
    [ "$tc" -gt 0 ] || continue
    configured=$((configured + 1))
    mark="$hb/all_busy_since_$class"
    if [ "$bc" -eq "$tc" ]; then
      first=$(cat "$mark" 2> /dev/null || true)
      if ! [[ "$first" =~ ^[0-9]+$ ]] || [ "$first" -gt "$now" ]; then first=$now; echo "$now" > "$mark"; fi
      if [ "$((now - first))" -ge "$SATURATED_SECS" ]; then sat="${sat:+$sat,}$class"; nsat=$((nsat + 1)); fi
    else
      rm -f "$mark"
    fi
  done
  if [ "$nsat" -eq 0 ]; then echo ok
  elif [ "$nsat" -eq "$configured" ]; then echo saturated
  else echo "ok/sat=$sat"
  fi
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
    ios) norm_labels "${IOS_LABELS:-ghr-ios}" ;;
  esac
}

# retiring CLASS N NOW — 0 when slot CLASS-N above the configured count is still draining: its own
# slot loop wrote a fresh, non-future state file within RETIRE_SECS.
# WHY: lowering LIGHT_SLOTS/SUPABASE_SLOTS takes effect at the next heartbeat, but a removed slot's
# loop needs up to one tick to release its idle runner (or a whole job to finish a busy one). Without
# this the heartbeat latched its own just-removed runners as foreign (ghr-light-5/6, 2026-10-21).
# NOTE: the state dir is written only by the controller account, so a runner registered from outside
# the mini cannot claim a slot this way; once the loop stops writing, the grace runs out.
retiring() {
  local f="$GHR_STATE_DIR/$1-$2.json" ts
  [ -r "$f" ] || return 1
  ts=$(state_field_num "$f" ts)
  [ -n "$ts" ] && [ "$(($3 - ts))" -le "$RETIRE_SECS" ] && [ "$((ts - $3))" -le "$FUTURE_SECS" ]
}

# tripwire_names [NOW] < tsv — print names of runners that do not belong to this fleet:
#   - name not matching ghr-(light|supabase|ios)-<n>
#   - <n> outside 1..<configured slot count> for its class (LIGHT_SLOTS / SUPABASE_SLOTS /
#     IOS_SLOTS, ios capped at 1), unless
#     the runner is listed in REMOTE_SLOTS (a slot served by another host) or the slot is retiring
#     (see retiring)
#   - custom labels different from the configured label set for its class
# WHY: a foreign or copied runner in the org can steal jobs meant for the pool.
tripwire_names() {
  local now=${1:-$(date -u +%s)} id name status busy labels class num count want
  while IFS=$'\t' read -r id name status busy labels; do
    [ -n "$id$name" ] || continue
    ghr_valid_runner_name "$name" || { printf '%s\n' "$name"; continue; }
    class=${name#ghr-}; class=${class%%-*}
    num=${name##*-}
    case $class in
      light) count=${LIGHT_SLOTS:-0} ;;
      supabase) count=${SUPABASE_SLOTS:-0} ;;
      ios) count=${IOS_SLOTS:-0}; [ "$count" -le 1 ] || count=1 ;;
      *) count=0 ;;
    esac
    # >6 digits cannot be a real slot number (and would overflow shell arithmetic)
    if [ "${#num}" -gt 6 ] || [ "$((10#$num))" -lt 1 ]; then
      printf '%s\n' "$name"; continue
    fi
    want=$(expected_labels "$class")
    [ "$labels" = "$want" ] || { printf '%s\n' "$name"; continue; }
    if [ "$((10#$num))" -gt "$count" ]; then
      # beyond the local count: accepted only as a listed REMOTE_SLOTS entry (another host's slot)
      # or as one of this host's own slots still retiring after a scale-down
      case " $(remote_nums "$class" "$count" quiet | tr '\n' ' ')" in
        *" $((10#$num)) "*) continue ;;
      esac
      retiring "$class" "$((10#$num))" "$now" || printf '%s\n' "$name"
    fi
  done
}

# ── ios demand probe ──────────────────────────────────────────────────────────

# run_ids_from_json — workflow-runs list JSON on stdin -> one run id per line.
run_ids_from_json() {
  python3 -I -c '
import sys, json
for r in json.load(sys.stdin).get("workflow_runs", []):
    i = r.get("id")
    if isinstance(i, int):
        print(i)
'
}

# jobs_queued_count WANT — run-jobs JSON on stdin -> number of jobs with status "queued" whose label
# set contains every WANT label (comma list, as norm_labels prints) and nothing outside WANT plus
# `self-hosted`. WHY: `runs-on: [self-hosted, ghr-ios]` is the usual spelling and must wake the slot,
# but a job asking for some OTHER label as well could not run on a runner that only carries ours.
jobs_queued_count() {
  python3 -I -c '
import sys, json
want = set(x for x in sys.argv[1].split(",") if x)
n = 0
for j in json.load(sys.stdin).get("jobs", []):
    if j.get("status") != "queued":
        continue
    labels = {str(l).lower() for l in j.get("labels", []) if l}
    if want <= labels <= want | {"self-hosted"}:
        n += 1
print(n)
' "$1"
}

# probe_time_left — 0 while the probe's overall deadline ($PROBE_DEADLINE, epoch) has not passed.
probe_time_left() { [ "$(date -u +%s)" -lt "${PROBE_DEADLINE:-0}" ]; }

# ios_repo_demand REPO WANT — print the number of queued ios jobs in REPO. Returns 1 on any API or
# parse failure (the caller then leaves the demand file alone).
# NOTE: a run whose earlier jobs are running is `in_progress` while its ios job is still `queued`,
# so both run statuses are scanned; the jobs list is the per-run truth.
ios_repo_demand() {
  local repo=$1 want=$2 st page id ids="" total=0 jobs c
  # NOTE: event=workflow_dispatch -- ios workflows are dispatch-only (config.example.env), which keeps
  # the run lists short; a push/PR-triggered ios job would never wake the slot.
  for st in queued in_progress; do
    probe_time_left || return 1
    page=$(gh_api GET "/repos/${repo}/actions/runs?status=${st}&event=workflow_dispatch&per_page=20") || return 1
    ids="$ids $(printf '%s' "$page" | run_ids_from_json)" || return 1
  done
  # a run can move between the two listings; count it once
  for id in $(printf '%s\n' $ids | sort -u); do
    probe_time_left || return 1
    jobs=$(gh_api GET "/repos/${repo}/actions/runs/${id}/jobs?filter=latest&per_page=100") || return 1
    c=$(printf '%s' "$jobs" | jobs_queued_count "$want") || return 1
    total=$((total + c))
  done
  echo "$total"
}

# probe_ios_demand NOW — publish or clear $GHR_DEMAND_DIR/ios (see header). Never fatal.
probe_ios_demand() {
  local now=$1 repo want total=0 failed=0 c f="$GHR_DEMAND_DIR/ios"
  [ -n "${IOS_DEMAND_REPOS:-}" ] && [ "${IOS_SLOTS:-0}" -ge 1 ] || return 0
  if ! [ -d "$GHR_DEMAND_DIR" ] || ! [ -w "$GHR_DEMAND_DIR" ]; then
    ghr_log "ERROR ios demand dir $GHR_DEMAND_DIR is missing or not writable: the ios slot will never wake"
    return 0
  fi
  # Overall budget: the probe runs after the state is published and must not stretch a heartbeat run.
  PROBE_DEADLINE=$(( $(date -u +%s) + ${PROBE_BUDGET_SECS:-20} ))
  # NOTE: read by _gh_request (lib/gh-app.sh) in its subshell: per-call curl cap for the probe.
  # shellcheck disable=SC2034
  local GH_MAX_TIME=10
  want=$(norm_labels "${IOS_LABELS:-ghr-ios}")
  for repo in ${IOS_DEMAND_REPOS//,/ }; do
    [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { ghr_log "WARN skipping invalid IOS_DEMAND_REPOS entry: $repo"; continue; }
    if c=$(ios_repo_demand "$repo" "$want"); then
      total=$((total + c))
    else
      failed=1
      ghr_log "WARN ios demand probe failed for $repo"
    fi
  done
  if [ "$total" -gt 0 ]; then
    # Positive evidence is written even if another repo failed. Atomic: the slot loop reads it any time.
    ( umask 022
      printf '%s %s\n' "$now" "$total" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f" ) 2> /dev/null \
      || { rm -f "$f.tmp.$$" 2> /dev/null; ghr_log "WARN cannot write $f"; }
  elif [ "$failed" -eq 0 ]; then
    rm -f "$f" 2> /dev/null
  fi
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
  gh_list_runners > "$tmp" || { ghr_log "ERROR cannot list runners; not publishing"; probe_ios_demand "$(date -u +%s)"; exit 1; }
  now=$(date -u +%s)
  state=$(compute_state "$GHR_STATE_DIR" "$now" "$tmp" "$GHR_HB_ROOT/hb")
  ghr_log "state=$state"
  bad=$(tripwire_names "$now" < "$tmp")
  if [ -n "$bad" ]; then
    ghr_log "TRIPWIRE foreign runner(s) in org: $(printf '%s' "$bad" | tr '\n' ' ' | head -c 300)"
    { date -u +%Y-%m-%dT%H:%M:%SZ; printf '%s\n' "$bad"; } > "$GHR_HB_ROOT/tripwire" 2> /dev/null \
      || ghr_log "WARN cannot write tripwire file"
  fi
  # Latched: while the tripwire file exists the pool is not trusted, whatever the slots say.
  if [ -e "$GHR_HB_ROOT/tripwire" ]; then state=down; ghr_log "tripwire latched: publishing down"; fi
  for repo in ${CONSUMER_REPOS//,/ }; do
    [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { ghr_log "WARN skipping invalid repo: $repo"; rc=1; continue; }
    write_state_var "$repo" "${state%%/*}@${now}${state#"${state%%/*}"}" || { ghr_log "ERROR variable write failed: $repo"; rc=1; }
  done
  # AFTER the publish loop and time-boxed: the probe never delays or blocks the published state.
  probe_ios_demand "$(date -u +%s)"
  exit "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
