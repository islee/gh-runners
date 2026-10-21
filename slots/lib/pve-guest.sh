#!/bin/bash
# shellcheck disable=SC2034  # GE_OUT is read by the sourcing scripts
# pve-guest.sh — run commands inside a Proxmox VM through the qemu guest agent, with bounds.
#
# Context: sourced (never executed) by slots/launch-pve.sh and images/build-supabase-pve.sh, which
# both drive VMs exclusively over `qm guest exec` (no ssh, no keys, no inbound network).
# Expects the caller to define: QM (path to qm) and WORK (a private scratch directory).
#
# Dependencies: qm, python3 (stdlib; JSON parsing of the agent reply), bash 4+.

# run_bounded SECS CMD... — run CMD, kill it if it outlives SECS. Returns CMD's status, or 143/137
# when the bound fired. (Not coreutils `timeout`: the repo test suite also runs on macOS.)
# NOTE: a backgrounded job gets stdin from /dev/null, so callers that need stdin pipe it inside CMD.
run_bounded() {
  local secs=$1 pid wd rc=0
  shift
  "$@" &
  pid=$!
  ( sleep "$secs" & sp=$!
    trap 'kill "$sp" 2> /dev/null; exit 0' TERM
    wait "$sp"
    kill -TERM "$pid" 2> /dev/null
    sleep 1
    kill -KILL "$pid" 2> /dev/null ) &
  wd=$!
  # A trapped signal interrupts `wait` while the child still runs; the child must be really finished (or
  # killed by the bound above) before we report on it, or a half-done `qm clone` would look like a failure.
  while :; do
    rc=0
    wait "$pid" || rc=$?
    kill -0 "$pid" 2> /dev/null || break
  done
  kill "$wd" 2> /dev/null
  wait "$wd" 2> /dev/null || true
  return "$rc"
}

# GE_STDIN: data forwarded on the guest command's stdin (empty = none). A shell variable, never
# exported, so it is not in any process environment; the JIT config travels this way.
GE_STDIN=""
GE_OUT=""

ge_qm() {
  if [ -n "$GE_STDIN" ]; then
    # Builtin printf into a pipe: the data never reaches an argv. --pass-stdin reads until EOF.
    printf '%s\n' "$GE_STDIN" | "$QM" guest exec "$1" --pass-stdin 1 "${@:2}"
  else
    "$QM" guest exec "$@" < /dev/null
  fi
}

# guest_exec VMID TIMEOUT CMD... — run CMD inside the guest through the agent.
# Returns the guest command's exit code and sets GE_OUT to its stdout; 125 when qm itself failed,
# timed out, or its reply cannot be parsed (never mistaken for a guest exit code).
# NOTE: `qm guest exec` is synchronous with its own --timeout (default 30 s); when it expires the
# guest process keeps running but qm reports failure. Every long step is therefore given a larger
# TIMEOUT or started detached (systemd-run / systemctl start --no-block).
guest_exec() {
  local vmid=$1 t=$2 tmp parsed rc=0
  shift 2
  GE_OUT=""
  tmp=$(mktemp "$WORK/ge.XXXXXX") || return 125
  run_bounded "$((t + 15))" ge_qm "$vmid" --timeout "$t" -- "$@" > "$tmp" 2> /dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then rm -f "$tmp"; return 125; fi
  # reply: {"exitcode":N,"exited":1,"out-data":"..."}; a signalled process has no exitcode.
  parsed=$(python3 -I -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print(int(d["exitcode"]))
    sys.stdout.write(d.get("out-data", ""))
except Exception:
    sys.exit(1)
' < "$tmp") || { rm -f "$tmp"; return 125; }
  rm -f "$tmp"
  if [[ "$parsed" == *$'\n'* ]]; then GE_OUT=${parsed#*$'\n'}; fi
  return "${parsed%%$'\n'*}"
}
