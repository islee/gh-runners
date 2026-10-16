#!/usr/bin/env bats
# Tests for slots/slot-loop.sh: backoff curve, state file, JIT hand-off (stdin only), failure
# handling and SIGTERM semantics. sudo is a shim; reconcile/mint are replaced by stubs.

load helpers

JIT_BLOB="LOOPJITBLOB0123456789abcdef=="

setup() {
  slots_setup
  export GHR_STATE_DIR="$W/state" TICK=1
  SUDO_ARGV="$W/sudo.argv"; SUDO_ENV="$W/sudo.env"; SUDO_STDIN="$W/sudo.stdin"
  export SUDO_ARGV SUDO_ENV SUDO_STDIN
  cat > "$FAKE_BIN/sudo" <<'SHIM'
#!/bin/bash
printf '%s\n' "$@" > "$SUDO_ARGV"
env > "$SUDO_ENV"
cat > "$SUDO_STDIN"
exit "${FAKE_LAUNCH_RC:-0}"
SHIM
  chmod +x "$FAKE_BIN/sudo"
  source "$SLOTS_DIR/slot-loop.sh"
  ghr_load_config
  CLASS=light
  N=2
  do_reconcile() { return 0; }
  do_mint() { echo "$JIT_BLOB"; }
}

state_file() { cat "$W/state/light-2.json"; }

@test "backoff: 30 -> 60 -> 120 -> 240 -> 300 (capped)" {
  b=0; seq=""
  for _ in 1 2 3 4 5 6; do b=$(next_backoff "$b"); seq="$seq $b"; done
  [ "$seq" = " 30 60 120 240 300 300" ]
}

@test "state file: single-line JSON with slot, state, ts, since, last_exit" {
  write_state idle-prep
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["slot"]=="light-2" and d["state"]=="idle-prep" and d["n"]==2 and d["class"]=="light"; assert all(isinstance(d[k],int) for k in ("ts","since","last_exit"))' "$W/state/light-2.json"
  [ "$(state_file | wc -l | tr -d ' ')" -eq 1 ]
}

@test "state file: 'since' holds while the state name is unchanged, resets on change" {
  write_state registered
  s1=$(sed -n 's/.*"since":\([0-9]*\).*/\1/p' "$W/state/light-2.json")
  STATE_SINCE=$((s1 - 500))   # pretend it has been registered for a while
  write_state registered
  [ "$(sed -n 's/.*"since":\([0-9]*\).*/\1/p' "$W/state/light-2.json")" -eq $((s1 - 500)) ]
  write_state idle
  [ "$(sed -n 's/.*"since":\([0-9]*\).*/\1/p' "$W/state/light-2.json")" -ge "$s1" ]
}

@test "cycle: JIT reaches launch ONLY on stdin; not in sudo argv or env" {
  FAKE_LAUNCH_RC=0 run_cycle
  [ "$(cat "$SUDO_STDIN")" = "$JIT_BLOB" ]
  refute grep -q "$JIT_BLOB" "$SUDO_ARGV"
  refute grep -q "$JIT_BLOB" "$SUDO_ENV"
  [ "$(cat "$SUDO_ARGV")" = "$(printf -- '-n\n-u\nghr\n%s\nlight\n2' "$LAUNCH_BIN")" ]
  [[ "$(state_file)" == *'"state":"idle"'* ]]
}

@test "cycle: launch failure is recorded (last_exit) and reported as a failed cycle" {
  FAKE_LAUNCH_RC=3 run run_cycle
  [ "$status" -eq 1 ]
  FAKE_LAUNCH_RC=3 run_cycle || true
  [[ "$(state_file)" == *'"last_exit":3'* ]]
}

@test "cycle: reconcile failure and mint failure never launch" {
  do_reconcile() { return 1; }
  run run_cycle
  [ "$status" -eq 1 ]
  [ ! -e "$SUDO_STDIN" ]
  do_reconcile() { return 0; }
  do_mint() { return 1; }
  run run_cycle
  [ "$status" -eq 1 ]
  [ ! -e "$SUDO_STDIN" ]
}

@test "arg validation" {
  run bash "$SLOTS_DIR/slot-loop.sh" light
  [ "$status" -eq 2 ]
  run bash "$SLOTS_DIR/slot-loop.sh" android 1
  [ "$status" -eq 2 ]
  run bash "$SLOTS_DIR/slot-loop.sh" light 0
  [ "$status" -eq 2 ]
  run bash "$SLOTS_DIR/slot-loop.sh" light 9
  [ "$status" -eq 2 ]
  run bash "$SLOTS_DIR/slot-loop.sh" light '1;id'
  [ "$status" -eq 2 ]
}

@test "SIGTERM mid-job: the job finishes, then the loop exits 0 (no second cycle)" {
  cat > "$W/drive.sh" <<DRV
source "$SLOTS_DIR/slot-loop.sh"
do_reconcile() { return 0; }
do_mint() { echo BLOB; }
do_launch() { sleep 2; echo done > "$W/job.done"; }
main light 1
DRV
  bash "$W/drive.sh" 2> "$W/loop.err" &
  pid=$!
  sleep 1
  kill -TERM "$pid"
  wait "$pid"
  [ -f "$W/job.done" ]
  grep -q 'exiting cleanly' "$W/loop.err"
}
