#!/bin/bash
# slot-loop.sh <class> <n> — the forever loop that keeps ONE runner slot (ghr-<class>-<n>) fed.
#
# Context: one LaunchDaemon per slot (dev.ghr.slot.<class>-<n>, user _ghrctl, KeepAlive). Per cycle:
#   state idle-prep -> reconcile (drop stale offline runner) -> mint JIT -> state registered ->
#   launch container (JIT on stdin through sudo -u ghr) -> state idle(+exit code) -> repeat.
# The slot's state file (/var/db/ghr/slots/<class>-<n>.json) is what heartbeat.sh reads to decide
# ok/saturated/down, so it is refreshed every TICK seconds even while a job runs.
#
# CRITICAL: the JIT config lives only in the shell variable JIT (never exported) and travels via
# a pipe (printf is a builtin, so no argv either). Do not add `set -x`, do not export it.
#
# Failure handling: any failed step counts as a failure; consecutive failures back off
# 30 -> 60 -> 120 -> 240 -> 300 s (capped), a clean cycle resets it.
# SIGTERM: TERMINATING is checked before reconcile, mint and launch. If the runner is minted but
# not busy (registered/idle), it is deleted via `reconcile.sh --release` and the launch is
# abandoned instead of waiting up to 6 h for a job; if it IS busy the current job finishes
# first. A SECOND signal kills the launch immediately.
#
# ios class (Tart macOS VM; IOS_SLOTS 0|1): DORMANT by default -- no runner registered, no VM. The
# heartbeat's demand probe writes $GHR_DEMAND_DIR/ios while a job labelled ghr-ios is queued. Then
# this loop (1) takes a capacity LEASE ($GHR_CAP_DIR/ios.lease, refreshed every TICK) and shows
# `waiting-capacity`, (2) waits until every supabase slot above IOS_SUPA_KEEP reports `yielded`
# (the 8 GiB macOS VM does not fit next to more supabase VMs), (3) mints a JIT runner and launches
# as usual. Supabase loops above IOS_SUPA_KEEP watch the lease: before minting they sit in
# `yielded`, and a runner that is registered but has no job yet is released and its launch (VM)
# abandoned. `yielded` is written only after that slot's launch has exited (VM destroyed).
# An idle ios runner is also released when the demand disappears, so a vanished job never pins the
# lease (and the supabase slots) for hours.
#
# Linux / Proxmox host: LAUNCH_USER=root and LAUNCH_BIN=/usr/local/libexec/ghr/launch-pve (set in the
# systemd unit by install-pve.sh); the slot range then comes from PVE_SLOTS instead of SUPABASE_SLOTS.
#
# Dependencies: lib/gh-app.sh, mint-jit.sh, reconcile.sh, /usr/local/libexec/ghr/launch via sudo.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=slots/lib/gh-app.sh
. "$HERE/lib/gh-app.sh"

GHR_STATE_DIR="${GHR_STATE_DIR:-/var/db/ghr/slots}"
LAUNCH_BIN="${LAUNCH_BIN:-/usr/local/libexec/ghr/launch}"
# macOS: the launch script runs as `ghr` (owner of the Lima VMs); Proxmox: as root (qm is root-only).
LAUNCH_USER="${LAUNCH_USER:-ghr}"
TICK="${TICK:-15}"
BACKOFF_MIN=30
BACKOFF_MAX=300
# ios capacity handshake (see header). Directories are created by install.sh; overridable for tests.
GHR_CAP_DIR="${GHR_CAP_DIR:-/var/db/ghr/capacity}"
GHR_DEMAND_DIR="${GHR_DEMAND_DIR:-/var/db/ghr/demand}"
# The demand file is rewritten every heartbeat (60 s): 150 s tolerates two missed beats.
DEMAND_FRESH_SECS="${DEMAND_FRESH_SECS:-150}"
# The lease and a `yielded` state file are rewritten every TICK (15 s).
LEASE_FRESH_SECS="${LEASE_FRESH_SECS:-60}"
IOS_YIELD_WAIT_SECS="${IOS_YIELD_WAIT_SECS:-3600}"
# Tolerated clock skew for the epochs read back from those files.
FUTURE_SECS="${FUTURE_SECS:-5}"
# After "busy" answers to a release attempt that is not a shutdown, wait this long before asking again.
BUSY_REPROBE_SECS="${BUSY_REPROBE_SECS:-120}"
# After a failed ios cycle the slot stays dormant (takes no lease) for IOS_COOLDOWN_BASE s, doubling per
# consecutive failure up to IOS_COOLDOWN_MAX. WHY: backoff_wait does not refresh the lease, so without
# this the supabase slots resume, the still-fresh demand makes ios retake the lease, and the pair thrash.
IOS_COOLDOWN_BASE="${IOS_COOLDOWN_BASE:-900}"
IOS_COOLDOWN_MAX="${IOS_COOLDOWN_MAX:-3600}"
IOS_COOLDOWN=0
IOS_COOLDOWN_UNTIL=0

TERMINATING=0
LAUNCH_PID=""
STATE_NAME=""
STATE_SINCE=0
LAST_EXIT=0

sibling() { if [ -x "$HERE/$1" ]; then echo "$HERE/$1"; else echo "$HERE/$1.sh"; fi; }

# next_backoff CURRENT — 0 (no failures yet) -> 30, then doubling, capped at 300.
next_backoff() {
  local cur=$1
  if [ "$cur" -le 0 ]; then echo "$BACKOFF_MIN"; return; fi
  cur=$((cur * 2))
  [ "$cur" -gt "$BACKOFF_MAX" ] && cur=$BACKOFF_MAX
  echo "$cur"
}

# write_state STATE — atomically write the slot file. `since` only moves when the state NAME
# changes, so heartbeat can tell "just entered" from "stuck here for minutes" while `ts` keeps
# proving the loop is alive.
write_state() {
  local st=$1 now
  now=$(date -u +%s)
  if [ "$st" != "$STATE_NAME" ]; then STATE_NAME=$st; STATE_SINCE=$now; fi
  local f="$GHR_STATE_DIR/$CLASS-$N.json"
  # WHY tmp in the same dir: rename is atomic only within one filesystem.
  ( umask 022
    printf '{"slot":"%s-%s","class":"%s","n":%s,"state":"%s","ts":%s,"since":%s,"last_exit":%s}\n' \
      "$CLASS" "$N" "$CLASS" "$N" "$STATE_NAME" "$now" "$STATE_SINCE" "$LAST_EXIT" > "$f.tmp.$$" \
      && mv -f "$f.tmp.$$" "$f" ) 2> /dev/null \
    || { rm -f "$f.tmp.$$" 2> /dev/null; ghr_log "WARN cannot write state file $f"; }
}

on_signal() {
  if [ "$TERMINATING" -eq 1 ]; then
    ghr_log "second signal: killing launch and exiting"
    [ -n "$LAUNCH_PID" ] && kill -TERM "$LAUNCH_PID" 2> /dev/null
    exit 143
  fi
  TERMINATING=1
  ghr_log "signal received: exiting after the current job"
}

# Steps are separate functions so tests can replace them without network/sudo.
do_reconcile() { "$(sibling reconcile)" "$1"; }
# NOTE: labels word-split on purpose (config holds `a,b` or `a b`); mint-jit validates each.
do_mint() {
  local labels
  case "$CLASS" in light) labels=$LIGHT_LABELS ;; supabase) labels=$SUPABASE_LABELS ;; ios) labels=$IOS_LABELS ;; esac
  # shellcheck disable=SC2086
  "$(sibling mint-jit)" "$1" ${labels//,/ }
}
# do_release NAME — un-register this slot's own idle runner. 0 = deleted/absent, 10 = busy.
do_release() { "$(sibling reconcile)" --release "$1"; }
# do_launch — JIT on stdin, never argv/env. Reads the JIT from the global JIT.
do_launch() { printf '%s\n' "$JIT" | sudo -n -u "$LAUNCH_USER" "$LAUNCH_BIN" "$CLASS" "$N"; }

# ── ios capacity handshake ────────────────────────────────────────────────────

# nap — sleep one TICK; a trapped signal wakes it early.
nap() {
  sleep "$TICK" &
  wait $! 2> /dev/null
}

# epoch_fresh FILE MAX_AGE — 0 iff FILE's first field is an epoch no older than MAX_AGE s and not
# more than FUTURE_SECS in the future. WHY the epoch inside and not the mtime: the writer controls
# it, and a clock jump or a stale copy must not look fresh.
epoch_fresh() {
  local ts="" now
  read -r ts _ < "$1" 2> /dev/null || true
  [[ "$ts" =~ ^[0-9]+$ ]] || return 1
  now=$(date -u +%s)
  [ "$((now - ts))" -le "$2" ] && [ "$((ts - now))" -le "$FUTURE_SECS" ]
}

# demand_fresh — 0 iff the heartbeat saw an ios-labelled job queued recently (`<epoch> <count>`).
demand_fresh() {
  local ts="" cnt=""
  epoch_fresh "$GHR_DEMAND_DIR/ios" "$DEMAND_FRESH_SECS" || return 1
  read -r ts cnt < "$GHR_DEMAND_DIR/ios" 2> /dev/null || true
  [[ "$cnt" =~ ^[0-9]+$ ]] && [ "$cnt" -gt 0 ]
}

lease_write() {
  local f="$GHR_CAP_DIR/ios.lease"
  ( umask 077
    mkdir -p "$GHR_CAP_DIR" && date -u +%s > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f" ) 2> /dev/null \
    || { rm -f "$f.tmp.$$" 2> /dev/null; ghr_log "WARN cannot write lease $f"; }
}
lease_remove() { rm -f "$GHR_CAP_DIR/ios.lease" 2> /dev/null; }
lease_fresh() { epoch_fresh "$GHR_CAP_DIR/ios.lease" "$LEASE_FRESH_SECS"; }

# supa_must_yield — 0 iff this is a supabase slot above IOS_SUPA_KEEP and a fresh ios lease exists.
# The iOS class being disabled (IOS_SLOTS=0, e.g. on the Proxmox host) switches the whole thing off.
supa_must_yield() {
  [ "$CLASS" = supabase ] && [ "${IOS_SLOTS:-0}" -ge 1 ] && [ "$N" -gt "${IOS_SUPA_KEEP:-1}" ] && lease_fresh
}

# supa_all_yielded — 0 iff every local supabase slot above IOS_SUPA_KEEP shows a fresh `yielded`
# state file (a slot that is not configured does not exist, so it counts as yielded).
supa_all_yielded() {
  local n f ts st now
  now=$(date -u +%s)
  n=$(( ${IOS_SUPA_KEEP:-1} + 1 ))
  while [ "$n" -le "${SUPABASE_SLOTS:-0}" ]; do
    f="$GHR_STATE_DIR/supabase-$n.json"
    [ -r "$f" ] || return 1
    ts=$(sed -n 's/.*"ts":\([0-9][0-9]*\).*/\1/p' "$f" | head -1)
    st=$(sed -n 's/.*"state":"\([a-z-]*\)".*/\1/p' "$f" | head -1)
    [ "$st" = yielded ] && [[ "$ts" =~ ^[0-9]+$ ]] || return 1
    [ "$((now - ts))" -le "$LEASE_FRESH_SECS" ] && [ "$((ts - now))" -le "$FUTURE_SECS" ] || return 1
    n=$((n + 1))
  done
  return 0
}

# cycle_gate — runs at the top of every cycle, before reconcile/mint. Returns 0 = proceed to mint,
# 1 = nothing to do this cycle (clean), 2 = failed (back off). Light slots always proceed.
cycle_gate() {
  case "$CLASS" in
    ios) ios_gate ;;
    supabase) supa_gate ;;
    *) return 0 ;;
  esac
}

# supa_gate — sit in `yielded` (no mint, no VM) for as long as the ios lease is fresh.
supa_gate() {
  supa_must_yield || return 0
  ghr_log "yielding to the ios slot"
  while [ "$TERMINATING" -eq 0 ] && supa_must_yield; do
    write_state yielded
    nap
  done
  [ "$TERMINATING" -eq 0 ] || return 1
  ghr_log "ios lease gone: resuming"
  return 0
}

# ios_gate — dormant until demand, then take the lease and wait for the supabase slots to yield.
ios_gate() {
  local t0
  while [ "$TERMINATING" -eq 0 ] && { ! demand_fresh || [ "$(date -u +%s)" -lt "$IOS_COOLDOWN_UNTIL" ]; }; do
    lease_remove
    write_state dormant
    nap
  done
  [ "$TERMINATING" -eq 0 ] || return 1
  t0=$(date -u +%s)
  ghr_log "ios demand: taking the capacity lease"
  while [ "$TERMINATING" -eq 0 ]; do
    lease_write
    supa_all_yielded && return 0
    if ! demand_fresh; then
      ghr_log "ios demand gone while waiting for capacity"
      lease_remove
      return 1
    fi
    if [ "$(( $(date -u +%s) - t0 ))" -gt "$IOS_YIELD_WAIT_SECS" ]; then
      # Drop the lease so the supabase slots resume; the failed cycle backs off before retrying.
      ghr_log "ERROR supabase slots did not yield within ${IOS_YIELD_WAIT_SECS}s"
      lease_remove
      return 2
    fi
    write_state waiting-capacity
    nap
  done
  return 1
}

# ios_failed — a failed ios cycle: drop the lease NOW (supabase resumes) and go dormant for a
# doubling cooldown even if the demand stays fresh.
ios_failed() {
  if [ "$IOS_COOLDOWN" -le 0 ]; then IOS_COOLDOWN=$IOS_COOLDOWN_BASE; else IOS_COOLDOWN=$((IOS_COOLDOWN * 2)); fi
  [ "$IOS_COOLDOWN" -le "$IOS_COOLDOWN_MAX" ] || IOS_COOLDOWN=$IOS_COOLDOWN_MAX
  IOS_COOLDOWN_UNTIL=$(( $(date -u +%s) + IOS_COOLDOWN ))
  lease_remove
  ghr_log "ios cycle failed: dormant for ${IOS_COOLDOWN}s"
}

# abort_reason — print why the minted-but-possibly-idle runner should be released now ("" = no
# reason). Shutdown, an ios lease taking this supabase slot's memory, or an ios runner whose demand
# vanished (job cancelled or taken elsewhere).
abort_reason() {
  if [ "$TERMINATING" -eq 1 ]; then echo "shutting down"; return; fi
  case "$CLASS" in
    supabase) ! supa_must_yield || echo "ios lease" ;;
    ios) demand_fresh || echo "no ios demand" ;;
  esac
}

# backoff_wait SECONDS — nap in <= TICK chunks, refreshing the state file each chunk so the
# heartbeat does not mistake a backing-off (but alive) loop for a wedged one. Wakes early on a
# trapped signal.
backoff_wait() {
  local remaining=$1 chunk
  while [ "$remaining" -gt 0 ] && [ "$TERMINATING" -eq 0 ]; do
    chunk=$TICK
    [ "$remaining" -lt "$chunk" ] && chunk=$remaining
    sleep "$chunk" &
    wait $! 2> /dev/null
    remaining=$((remaining - chunk))
    write_state backoff
  done
}

# run_cycle — one full slot cycle. Returns 0 on a clean (or shutdown) cycle, 1 on a failed step.
run_cycle() {
  local name="ghr-$CLASS-$N" rc aborted=0 gate=0 reason next_probe=0
  [ "$TERMINATING" -eq 0 ] || return 0
  # IMPORTANT: the gate comes first -- an ios lease must stop a supabase slot BEFORE it mints, and
  # the ios slot stays dormant (no runner, no VM) until there is demand.
  cycle_gate || gate=$?
  [ "$gate" -eq 0 ] || { [ "$gate" -eq 1 ] && return 0; return 1; }
  [ "$TERMINATING" -eq 0 ] || return 0
  write_state idle-prep
  do_reconcile "$name" || { ghr_log "reconcile failed for $name"; return 1; }
  [ "$TERMINATING" -eq 0 ] || return 0
  JIT=$(do_mint "$name") || { JIT=""; ghr_log "mint failed for $name"; return 1; }
  [ -n "$JIT" ] || { ghr_log "mint returned nothing for $name"; return 1; }
  if [ "$TERMINATING" -eq 1 ]; then
    # Signalled while minting: the runner exists on GitHub but nothing will ever use it.
    JIT=""
    do_release "$name" || ghr_log "WARN could not release $name"
    return 0
  fi
  [ "$CLASS" != ios ] || lease_write
  write_state registered
  # Background so we can keep the state file fresh for the whole job (up to 6 h).
  do_launch &
  LAUNCH_PID=$!
  JIT=""
  while kill -0 "$LAUNCH_PID" 2> /dev/null; do
    [ "$CLASS" != ios ] || lease_write
    reason=""
    if [ "$aborted" -eq 0 ] && [ "$(date -u +%s)" -ge "$next_probe" ]; then reason=$(abort_reason); fi
    if [ -n "$reason" ]; then
      rc=0
      do_release "$name" || rc=$?
      if [ "$rc" -eq 0 ]; then
        aborted=1
        ghr_log "released idle runner $name ($reason); abandoning launch"
        if [ "$TERMINATING" -eq 1 ]; then
          # Shutdown: leave now (the sudo'd launch finishes on its own once the runner is gone).
          kill -TERM "$LAUNCH_PID" 2> /dev/null
          break
        fi
        # CRITICAL: for lease/demand reasons do NOT kill and do NOT leave. LAUNCH_PID is only the
        # `do_launch &` subshell; the `printf | sudo launch` pipeline behind it survives a kill and
        # still owns the VM. Deleting the runner makes launch fail and destroy its VM; we keep
        # looping (and, for ios, keep refreshing the lease) until it has really exited, so neither
        # `yielded` nor a freed lease can be published while that VM is alive.
        write_state releasing
      fi
      ghr_log "runner $name busy (rc=$rc): letting the job finish"
      # A shutdown re-asks every tick (as before); other reasons back off so a long job does not
      # cost an API listing per tick.
      if [ "$TERMINATING" -eq 1 ]; then next_probe=0; else next_probe=$(( $(date -u +%s) + BUSY_REPROBE_SECS )); fi
    fi
    write_state "$STATE_NAME"
    nap
  done
  if [ "$aborted" -eq 1 ]; then
    wait "$LAUNCH_PID" 2> /dev/null
    LAUNCH_PID=""
    write_state idle
    return 0
  fi
  rc=0
  wait "$LAUNCH_PID" || rc=$?
  LAUNCH_PID=""
  LAST_EXIT=$rc
  write_state idle
  [ "$rc" -eq 0 ] || { ghr_log "launch exited $rc"; return 1; }
  IOS_COOLDOWN=0
  return 0
}

# pve_slot_listed N — true iff N is in PVE_SLOTS (space/comma separated list of slot numbers).
pve_slot_listed() {
  local s rs=${PVE_SLOTS:-}
  for s in ${rs//,/ }; do [ "$s" = "$1" ] && return 0; done
  return 1
}

main() {
  [ "$#" -eq 2 ] || { echo "usage: slot-loop.sh <class> <n>" >&2; exit 2; }
  CLASS=$1
  N=$2
  case "$CLASS" in light | supabase | ios) ;; *) echo "slot-loop: unsupported class: $CLASS" >&2; exit 2 ;; esac
  [[ "$N" =~ ^[1-9][0-9]*$ ]] || { echo "slot-loop: invalid slot number" >&2; exit 2; }
  ghr_load_config || exit 1
  local max
  case "$CLASS" in
    light) max=$LIGHT_SLOTS ;;
    supabase) max=$SUPABASE_SLOTS ;;
    # hard max 1: the macOS licence allows 2 VMs per host, we spend memory on one
    ios) max=$IOS_SLOTS; [ "$max" -le 1 ] || max=1 ;;
  esac
  # NOTE: on the Proxmox host SUPABASE_SLOTS is 0 and the supabase slots are PVE_SLOTS (a list).
  if ! [ "$N" -le "$max" ] && ! { [ "$CLASS" = supabase ] && pve_slot_listed "$N"; }; then
    echo "slot-loop: slot beyond configured ${CLASS} slots" >&2
    exit 2
  fi
  ghr_valid_runner_name "ghr-$CLASS-$N" || exit 2
  trap on_signal TERM INT
  # The lease must never outlive this loop: stale or not, a held lease starves the supabase slots.
  [ "$CLASS" != ios ] || trap lease_remove EXIT
  local backoff=0
  while [ "$TERMINATING" -eq 0 ]; do
    if run_cycle; then
      backoff=0
    else
      backoff=$(next_backoff "$backoff")
      [ "$CLASS" != ios ] || ios_failed
      write_state backoff
      ghr_log "backing off ${backoff}s"
      backoff_wait "$backoff"
    fi
  done
  ghr_log "exiting cleanly"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
