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
# Dependencies: lib/gh-app.sh, mint-jit.sh, reconcile.sh, /usr/local/libexec/ghr/launch via sudo.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=slots/lib/gh-app.sh
. "$HERE/lib/gh-app.sh"

GHR_STATE_DIR="${GHR_STATE_DIR:-/var/db/ghr/slots}"
LAUNCH_BIN="${LAUNCH_BIN:-/usr/local/libexec/ghr/launch}"
TICK="${TICK:-15}"
BACKOFF_MIN=30
BACKOFF_MAX=300

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
  # shellcheck disable=SC2086
  "$(sibling mint-jit)" "$1" ${LIGHT_LABELS//,/ }
}
# do_release NAME — un-register this slot's own idle runner. 0 = deleted/absent, 10 = busy.
do_release() { "$(sibling reconcile)" --release "$1"; }
# do_launch — JIT on stdin, never argv/env. Reads the JIT from the global JIT.
do_launch() { printf '%s\n' "$JIT" | sudo -n -u ghr "$LAUNCH_BIN" "$CLASS" "$N"; }

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
  local name="ghr-$CLASS-$N" rc aborted=0
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
  write_state registered
  # Background so we can keep the state file fresh for the whole job (up to 6 h).
  do_launch &
  LAUNCH_PID=$!
  JIT=""
  while kill -0 "$LAUNCH_PID" 2> /dev/null; do
    if [ "$TERMINATING" -eq 1 ] && [ "$aborted" -eq 0 ]; then
      rc=0
      do_release "$name" || rc=$?
      if [ "$rc" -eq 0 ]; then
        # NOTE: the sudo'd launch is root-owned and cannot be signalled from here; deleting the
        # runner makes the in-container listener exit, which ends docker run and launch.
        aborted=1
        ghr_log "released idle runner $name; abandoning launch"
        kill -TERM "$LAUNCH_PID" 2> /dev/null
        break
      fi
      ghr_log "runner $name busy (rc=$rc): letting the job finish"
    fi
    write_state "$STATE_NAME"
    sleep "$TICK" &
    wait $! 2> /dev/null
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
  return 0
}

main() {
  [ "$#" -eq 2 ] || { echo "usage: slot-loop.sh <class> <n>" >&2; exit 2; }
  CLASS=$1
  N=$2
  [ "$CLASS" = "light" ] || { echo "slot-loop: unsupported class: $CLASS" >&2; exit 2; }
  [[ "$N" =~ ^[1-9][0-9]*$ ]] || { echo "slot-loop: invalid slot number" >&2; exit 2; }
  ghr_load_config || exit 1
  [ "$N" -le "$LIGHT_SLOTS" ] || { echo "slot-loop: slot beyond LIGHT_SLOTS" >&2; exit 2; }
  ghr_valid_runner_name "ghr-$CLASS-$N" || exit 2
  trap on_signal TERM INT
  local backoff=0
  while [ "$TERMINATING" -eq 0 ]; do
    if run_cycle; then
      backoff=0
    else
      backoff=$(next_backoff "$backoff")
      write_state backoff
      ghr_log "backing off ${backoff}s"
      backoff_wait "$backoff"
    fi
  done
  ghr_log "exiting cleanly"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
