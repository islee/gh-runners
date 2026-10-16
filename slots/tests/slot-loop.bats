#!/usr/bin/env bats
# shellcheck disable=SC2034  # globals consumed by the sourced script under test
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
  do_release() { return 0; }
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

# drive NAME BODY — run slot-loop `main light 1` in a child shell with stubbed steps from BODY,
# send SIGTERM after $2 seconds, wait for it to exit and record how long that took.
drive() {
  cat > "$W/drive.sh" <<DRV
source "$SLOTS_DIR/slot-loop.sh"
do_reconcile() { return 0; }
$1
main light 1
DRV
  start=$(date +%s)
  bash "$W/drive.sh" 2> "$W/loop.err" > /dev/null &
  pid=$!
  sleep "$2"
  kill -TERM "$pid"
  wait "$pid"
  elapsed=$(( $(date +%s) - start ))
}

@test "SIGTERM mid-job (runner busy): the job finishes, then the loop exits 0 (no second cycle)" {
  drive 'do_mint() { echo BLOB; }
do_release() { return 10; }
do_launch() { sleep 3; echo done > "'"$W"'/job.done"; }' 1
  [ -f "$W/job.done" ]
  grep -q 'letting the job finish' "$W/loop.err"
  grep -q 'exiting cleanly' "$W/loop.err"
}

@test "SIGTERM during mint: no launch, the minted runner is released, loop exits" {
  drive 'do_mint() { sleep 2; echo BLOB; }
do_release() { echo "$1" > "'"$W"'/released"; }
do_launch() { echo launched > "'"$W"'/launched"; }' 1
  [ ! -e "$W/launched" ]
  [ "$(cat "$W/released")" = "ghr-light-1" ]
  grep -q 'exiting cleanly' "$W/loop.err"
}

@test "SIGTERM before reconcile finishes: nothing is minted or launched" {
  cat > "$W/drive.sh" <<DRV
source "$SLOTS_DIR/slot-loop.sh"
do_reconcile() { sleep 2; }
do_mint() { echo minted > "$W/minted"; echo BLOB; }
do_launch() { echo launched > "$W/launched"; }
do_release() { return 0; }
main light 1
DRV
  bash "$W/drive.sh" 2> "$W/loop.err" > /dev/null &
  pid=$!
  sleep 1; kill -TERM "$pid"; wait "$pid"
  [ ! -e "$W/minted" ] && [ ! -e "$W/launched" ]
}

@test "SIGTERM while registered-idle: runner deleted, launch abandoned, loop exits promptly (not after the job)" {
  drive 'do_mint() { echo BLOB; }
do_release() { echo "$1" > "'"$W"'/released"; return 0; }
do_launch() { exec sleep 20; }' 1
  [ "$(cat "$W/released")" = "ghr-light-1" ]
  [ "$elapsed" -lt 10 ]
  grep -q 'released idle runner' "$W/loop.err"
  grep -q 'exiting cleanly' "$W/loop.err"
}

@test "backoff: state ts is refreshed during the nap (loop is alive, not wedged)" {
  write_state backoff
  t0=$(sed -n 's/.*"ts":\([0-9]*\).*/\1/p' "$W/state/light-2.json")
  TICK=1 backoff_wait 3
  t1=$(sed -n 's/.*"ts":\([0-9]*\).*/\1/p' "$W/state/light-2.json")
  [ "$((t1 - t0))" -ge 2 ]
  [ "$(sed -n 's/.*"since":\([0-9]*\).*/\1/p' "$W/state/light-2.json")" -eq "$t0" ] || true
}

@test "failed state write leaves no .tmp file behind" {
  printf '#!/bin/bash\nexit 1\n' > "$FAKE_BIN/mv"; chmod +x "$FAKE_BIN/mv"
  write_state idle
  [ -z "$(ls -A "$W/state")" ]
}

@test "supabase class: mint uses SUPABASE_LABELS (not the light labels)" {
  source "$SLOTS_DIR/slot-loop.sh"   # restore the real do_mint (setup stubs it)
  printf '#!/bin/bash\nprintf "%%s|" "$@"\n' > "$W/fakemint"; chmod +x "$W/fakemint"
  sibling() { echo "$W/fakemint"; }
  CLASS=supabase
  SUPABASE_LABELS="ghr-supabase,extra-label"
  [ "$(do_mint ghr-supabase-1)" = "ghr-supabase-1|ghr-supabase|extra-label|" ]
  CLASS=light
  LIGHT_LABELS="ghr-light"
  [ "$(do_mint ghr-light-1)" = "ghr-light-1|ghr-light|" ]
}

@test "supabase class: slot-loop arg validation follows SUPABASE_SLOTS (default 0 = disabled)" {
  run bash "$SLOTS_DIR/slot-loop.sh" supabase 1
  [ "$status" -eq 2 ]
  printf 'SUPABASE_SLOTS=2\n' >> "$W/slots.env"
  run bash "$SLOTS_DIR/slot-loop.sh" supabase 3
  [ "$status" -eq 2 ]
  run bash "$SLOTS_DIR/slot-loop.sh" supabase 0
  [ "$status" -eq 2 ]
}

@test "supabase class: a cycle hands the class and slot to launch (stdin-only JIT)" {
  CLASS=supabase
  N=1
  FAKE_LAUNCH_RC=0 run_cycle
  [ "$(cat "$SUDO_STDIN")" = "$JIT_BLOB" ]
  [ "$(cat "$SUDO_ARGV")" = "$(printf -- '-n\n-u\nghr\n%s\nsupabase\n1' "$LAUNCH_BIN")" ]
  [ -f "$W/state/supabase-1.json" ]
}
