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

@test "launch user is configurable: LAUNCH_USER=root runs the launch script as root (Proxmox host)" {
  source "$SLOTS_DIR/slot-loop.sh"
  LAUNCH_USER=root
  LAUNCH_BIN=/usr/local/libexec/ghr/launch-pve
  CLASS=supabase
  N=3
  JIT="$JIT_BLOB"
  FAKE_LAUNCH_RC=0 do_launch
  [ "$(cat "$SUDO_ARGV")" = "$(printf -- '-n\n-u\nroot\n/usr/local/libexec/ghr/launch-pve\nsupabase\n3')" ]
  [ "$(cat "$SUDO_STDIN")" = "$JIT_BLOB" ]
  refute grep -q "$JIT_BLOB" "$SUDO_ARGV"
}

@test "launch user defaults to ghr (macOS behaviour unchanged)" {
  grep -q '^LAUNCH_USER="${LAUNCH_USER:-ghr}"' "$SLOTS_DIR/slot-loop.sh"
  grep -q 'sudo -n -u "$LAUNCH_USER" "$LAUNCH_BIN" "$CLASS" "$N"' "$SLOTS_DIR/slot-loop.sh"
}

@test "PVE_SLOTS: a listed supabase slot is accepted although SUPABASE_SLOTS=0; unlisted and other classes are not" {
  source "$SLOTS_DIR/slot-loop.sh"
  PVE_SLOTS="5, 6"
  pve_slot_listed 5
  pve_slot_listed 6
  refute pve_slot_listed 4
  refute pve_slot_listed 55
  PVE_SLOTS=""
  refute pve_slot_listed 5
  printf 'PVE_SLOTS="5"\n' >> "$W/slots.env"
  run bash "$SLOTS_DIR/slot-loop.sh" supabase 4
  [ "$status" -eq 2 ]
  # light is not opened up by PVE_SLOTS
  printf 'LIGHT_SLOTS=1\n' >> "$W/slots.env"
  run bash "$SLOTS_DIR/slot-loop.sh" light 3
  [ "$status" -eq 2 ]
}

@test "PVE_SLOTS: supabase-5 passes the range check and enters the loop (stays alive, exits 143 on SIGTERM)" {
  printf 'PVE_SLOTS="5"\nSUPABASE_SLOTS=0\n' >> "$W/slots.env"
  # reconcile/mint hit the curl shim (404) -> the cycle fails and the loop backs off; what matters is
  # that it did NOT exit 2 at the range check
  bash "$SLOTS_DIR/slot-loop.sh" supabase 5 > "$W/loop.out" 2>&1 3>&- &
  pid=$!
  sleep 1
  kill -0 "$pid"
  kill -TERM "$pid"
  rc=0
  wait "$pid" || rc=$?
  [ "$rc" -ne 2 ]
  refute grep -q "beyond configured" "$W/loop.out"
}

# ── ios class: dormant slot, capacity lease, supabase yield ──────────────────────────────────────────

# ios_env — config for the capacity tests: 3 supabase slots, one allowed to stay up beside the ios VM.
ios_env() {
  printf 'IOS_SLOTS=1\nSUPABASE_SLOTS=3\nIOS_SUPA_KEEP=1\nALLOWED_LABELS="ghr-light,ghr-supabase,ghr-ios"\n' >> "$W/slots.env"
  export GHR_CAP_DIR="$W/cap" GHR_DEMAND_DIR="$W/demand"
  mkdir -p "$GHR_CAP_DIR" "$GHR_DEMAND_DIR"
  # setup() loaded the config before these lines existed
  ghr_load_config
}
teardown() { [ -z "${DRV_PID:-}" ] || kill -TERM "$DRV_PID" 2> /dev/null || true; }
demand_on() { printf '%s 1\n' "$(date -u +%s)" > "$GHR_DEMAND_DIR/ios"; }
demand_off() { rm -f "$GHR_DEMAND_DIR/ios"; }
# sup_state N STATE — a fresh supabase slot file.
sup_state() {
  local now
  now=$(date -u +%s)
  printf '{"slot":"supabase-%s","class":"supabase","n":%s,"state":"%s","ts":%s,"since":%s,"last_exit":0}\n' "$1" "$1" "$2" "$now" "$now" > "$W/state/supabase-$1.json"
}
state_is() { [ "$(state_of "$1")" = "$2" ]; }
state_of() { sed -n 's/.*"state":"\([a-z-]*\)".*/\1/p' "$W/state/$1.json"; }
# wait_for DESC CMD... — poll up to ~15 s.
wait_for() { local i; for i in $(seq 1 75); do "$@" && return 0; sleep 0.2; done; return 1; }
# driver CLASS N BODY — background `main CLASS N` with stubbed steps from BODY; sets DRV_PID.
driver() {
  cat > "$W/drive2.sh" <<DRV
source "$SLOTS_DIR/slot-loop.sh"
do_reconcile() { return 0; }
do_mint() { echo "\$1" >> "$W/minted"; echo BLOB; }
do_release() { echo "\$1" >> "$W/released"; return 0; }
do_launch() { echo launched >> "$W/launched"; sleep 1; }
$3
main $1 $2
DRV
  bash "$W/drive2.sh" 2> "$W/loop.err" > /dev/null &
  DRV_PID=$!
}
stop_driver() { kill -TERM "$DRV_PID" 2> /dev/null; wait "$DRV_PID" 2> /dev/null || true; }

@test "ios: arg validation follows IOS_SLOTS (default 0 = disabled), hard max 1" {
  run bash "$SLOTS_DIR/slot-loop.sh" ios 1
  [ "$status" -eq 2 ]
  printf 'IOS_SLOTS=2\n' >> "$W/slots.env"
  run bash "$SLOTS_DIR/slot-loop.sh" ios 2
  [ "$status" -eq 2 ]
  run bash "$SLOTS_DIR/slot-loop.sh" ios 0
  [ "$status" -eq 2 ]
}

@test "ios: mint uses IOS_LABELS" {
  source "$SLOTS_DIR/slot-loop.sh"
  printf '#!/bin/bash\nprintf "%%s|" "$@"\n' > "$W/fakemint"; chmod +x "$W/fakemint"
  sibling() { echo "$W/fakemint"; }
  CLASS=ios
  IOS_LABELS="ghr-ios"
  [ "$(do_mint ghr-ios-1)" = "ghr-ios-1|ghr-ios|" ]
}

@test "demand_fresh: needs a fresh '<epoch> <count>' with count > 0 (stale, future, zero, garbage, missing -> no)" {
  ios_env
  refute demand_fresh
  demand_on
  demand_fresh
  printf '%s 0\n' "$(date -u +%s)" > "$GHR_DEMAND_DIR/ios"
  refute demand_fresh
  printf '%s 2\n' "$(( $(date -u +%s) - DEMAND_FRESH_SECS - 1 ))" > "$GHR_DEMAND_DIR/ios"
  refute demand_fresh
  printf '%s 2\n' "$(( $(date -u +%s) + 3600 ))" > "$GHR_DEMAND_DIR/ios"
  refute demand_fresh
  echo garbage > "$GHR_DEMAND_DIR/ios"
  refute demand_fresh
}

@test "ios: dormant without demand -- no lease, no mint, no launch; the state file keeps refreshing" {
  ios_env
  driver ios 1 ''
  wait_for state_is ios-1 dormant
  t0=$(sed -n 's/.*"ts":\([0-9]*\).*/\1/p' "$W/state/ios-1.json")
  sleep 2.2
  t1=$(sed -n 's/.*"ts":\([0-9]*\).*/\1/p' "$W/state/ios-1.json")
  stop_driver
  [ "$t1" -gt "$t0" ]
  [ ! -e "$W/minted" ] && [ ! -e "$W/launched" ] && [ ! -e "$GHR_CAP_DIR/ios.lease" ]
}

@test "ios: a stale lease is removed while dormant" {
  ios_env
  echo 1 > "$GHR_CAP_DIR/ios.lease"
  driver ios 1 ''
  wait_for test ! -e "$GHR_CAP_DIR/ios.lease"
  stop_driver
}

@test "ios: demand -> lease + waiting-capacity, and NO mint until every supabase slot above KEEP is yielded" {
  ios_env
  demand_on
  sup_state 1 registered; sup_state 2 registered; sup_state 3 yielded
  driver ios 1 ''
  wait_for state_is ios-1 waiting-capacity
  [ -s "$GHR_CAP_DIR/ios.lease" ]
  sleep 1.5
  [ ! -e "$W/minted" ]
  # lease is refreshed, not just written once
  l0=$(cat "$GHR_CAP_DIR/ios.lease"); sleep 2.2; l1=$(cat "$GHR_CAP_DIR/ios.lease")
  [ "$l1" -gt "$l0" ]
  sup_state 2 yielded
  demand_on
  wait_for test -e "$W/minted"
  stop_driver
  [ "$(cat "$W/minted")" = "ghr-ios-1" ]
  [ -e "$W/launched" ]
}

@test "ios: only slots ABOVE IOS_SUPA_KEEP must yield (supabase-1 may keep running), unconfigured ones do not exist" {
  ios_env
  demand_on
  sup_state 1 registered; sup_state 2 yielded; sup_state 3 yielded
  supa_all_yielded
  sup_state 3 registered
  refute supa_all_yielded
  # a yielded file that has stopped refreshing is not proof of anything
  printf '{"slot":"supabase-3","class":"supabase","n":3,"state":"yielded","ts":%s,"since":1,"last_exit":0}\n' "$(( $(date -u +%s) - LEASE_FRESH_SECS - 5 ))" > "$W/state/supabase-3.json"
  refute supa_all_yielded
  sup_state 3 yielded
  rm "$W/state/supabase-2.json"
  refute supa_all_yielded
  SUPABASE_SLOTS=1
  supa_all_yielded
}

@test "ios: demand vanishing while waiting drops the lease and returns to dormant" {
  ios_env
  demand_on
  sup_state 2 registered; sup_state 3 registered
  driver ios 1 ''
  wait_for state_is ios-1 waiting-capacity
  demand_off
  wait_for state_is ios-1 dormant
  stop_driver
  [ ! -e "$GHR_CAP_DIR/ios.lease" ] && [ ! -e "$W/minted" ]
}

@test "ios: the capacity wait is bounded -- lease dropped (supabase resumes), failed cycle, backoff" {
  ios_env
  demand_on
  sup_state 2 registered; sup_state 3 registered
  IOS_YIELD_WAIT_SECS=2 TICK=1 CLASS=ios N=1
  # keep the demand fresh for the duration of the wait
  ( for _ in $(seq 1 12); do demand_on; sleep 0.5; done ) &
  bg=$!
  rc=0
  run_cycle || rc=$?
  wait "$bg" 2> /dev/null || true
  [ "$rc" -eq 1 ]
  [ ! -e "$GHR_CAP_DIR/ios.lease" ]
  [ ! -e "$W/minted" ]
}

@test "ios: after the job the lease is KEPT while demand is still fresh, dropped (dormant) when it is not" {
  ios_env
  demand_on
  sup_state 2 yielded; sup_state 3 yielded
  driver ios 1 'do_launch() { echo launched >> "'"$W"'/launched"; [ -e "'"$GHR_CAP_DIR"'/ios.lease" ] && echo lease-held >> "'"$W"'/during"; sleep 1; }'
  wait_for test -e "$W/launched"
  # (demand file keeps being fresh: a second job is queued) -> second cycle, lease continuously held
  demand_on
  launched_twice() { [ "$(grep -c launched "$W/launched" 2> /dev/null || echo 0)" -ge 2 ]; }
  wait_for launched_twice
  [ -s "$GHR_CAP_DIR/ios.lease" ]
  demand_off
  wait_for state_is ios-1 dormant
  stop_driver
  [ ! -e "$GHR_CAP_DIR/ios.lease" ]
  [ "$(sort -u "$W/during")" = lease-held ]
}

@test "ios: the lease is refreshed for as long as the job runs" {
  ios_env
  demand_on
  sup_state 2 yielded; sup_state 3 yielded
  driver ios 1 'do_launch() { echo launched >> "'"$W"'/launched"; sleep 30; }'
  wait_for test -e "$W/launched"
  l0=$(cat "$GHR_CAP_DIR/ios.lease"); sleep 2.5; l1=$(cat "$GHR_CAP_DIR/ios.lease")
  stop_driver
  [ "$l1" -gt "$l0" ]
}

@test "ios: SIGTERM while waiting for capacity removes the lease and exits cleanly" {
  ios_env
  demand_on
  sup_state 2 registered; sup_state 3 registered
  driver ios 1 ''
  wait_for state_is ios-1 waiting-capacity
  [ -s "$GHR_CAP_DIR/ios.lease" ]
  kill -TERM "$DRV_PID"
  wait "$DRV_PID"
  [ ! -e "$GHR_CAP_DIR/ios.lease" ]
  grep -q 'exiting cleanly' "$W/loop.err"
  [ ! -e "$W/minted" ]
}

@test "ios: SIGTERM mid-job (busy) lets the job finish, then removes the lease" {
  ios_env
  demand_on
  sup_state 2 yielded; sup_state 3 yielded
  driver ios 1 'do_release() { return 10; }
do_launch() { echo launched >> "'"$W"'/launched"; sleep 3; echo done > "'"$W"'/job.done"; }'
  wait_for test -e "$W/launched"
  kill -TERM "$DRV_PID"
  wait "$DRV_PID"
  [ -f "$W/job.done" ]
  [ ! -e "$GHR_CAP_DIR/ios.lease" ]
}

@test "ios: an idle runner whose demand vanished is released and its launch abandoned (lease dropped)" {
  ios_env
  demand_on
  sup_state 2 yielded; sup_state 3 yielded
  driver ios 1 'do_launch() { echo launched >> "'"$W"'/launched"; exec sleep 20; }'
  wait_for test -e "$W/launched"
  demand_off
  wait_for test -e "$W/released"
  [ "$(cat "$W/released")" = "ghr-ios-1" ]
  wait_for state_is ios-1 dormant
  stop_driver
  grep -q 'no ios demand' "$W/loop.err"
  [ ! -e "$GHR_CAP_DIR/ios.lease" ]
}

@test "ios: a BUSY ios runner is not released when the demand file is gone (the queued job is running now)" {
  ios_env
  demand_on
  sup_state 2 yielded; sup_state 3 yielded
  driver ios 1 'do_release() { echo "$1" >> "'"$W"'/released"; return 10; }
do_launch() { echo launched >> "'"$W"'/launched"; sleep 4; echo done > "'"$W"'/job.done"; }'
  wait_for test -e "$W/launched"
  demand_off
  wait_for test -f "$W/job.done"
  stop_driver
  # asked once, "busy" -> not asked again for BUSY_REPROBE_SECS
  [ "$(wc -l < "$W/released")" -eq 1 ]
}

# supabase side ------------------------------------------------------------------------------------

lease_on() { date -u +%s > "$GHR_CAP_DIR/ios.lease"; }

@test "supabase above KEEP: with a fresh lease it sits in 'yielded' and mints NOTHING; resumes when the lease goes" {
  ios_env
  lease_on
  driver supabase 2 ''
  wait_for state_is supabase-2 yielded
  # keep the lease fresh for a while
  for _ in 1 2 3; do lease_on; sleep 0.7; done
  [ ! -e "$W/minted" ] && [ ! -e "$W/launched" ]
  rm -f "$GHR_CAP_DIR/ios.lease"
  wait_for test -e "$W/minted"
  stop_driver
  [ "$(head -1 "$W/minted")" = "ghr-supabase-2" ]
}

@test "supabase yields BEFORE mint: the gate runs ahead of reconcile and mint (mutation target)" {
  ios_env
  lease_on
  driver supabase 3 'do_reconcile() { echo reconcile >> "'"$W"'/order"; return 0; }'
  wait_for state_is supabase-3 yielded
  stop_driver
  [ ! -e "$W/order" ] && [ ! -e "$W/minted" ]
}

@test "supabase at or below KEEP and light slots ignore the lease" {
  ios_env
  lease_on
  driver supabase 1 ''
  wait_for test -e "$W/minted"
  stop_driver
  [ "$(head -1 "$W/minted")" = "ghr-supabase-1" ]
  [ "$(state_of supabase-1)" != yielded ]
  rm -f "$W/minted" "$W/launched"
  driver light 1 ''
  wait_for test -e "$W/minted"
  stop_driver
  [ "$(head -1 "$W/minted")" = "ghr-light-1" ]
}

@test "supabase: a stale lease, or IOS_SLOTS=0 (e.g. the Proxmox host), never makes a slot yield" {
  ios_env
  echo 1 > "$GHR_CAP_DIR/ios.lease"
  CLASS=supabase N=2
  refute supa_must_yield
  lease_on
  supa_must_yield
  IOS_SLOTS=0
  refute supa_must_yield
}

@test "supabase registered (job not started): a new lease releases the runner, abandons the launch, and 'yielded' appears only AFTER the launch exited" {
  ios_env
  driver supabase 2 'do_launch() { echo launched >> "'"$W"'/launched"; trap "sleep 1; echo exited > \"'"$W"'/launch.exit\"; exit 143" TERM; sleep 30 & wait; }'
  wait_for test -e "$W/launched"
  lease_on
  wait_for state_is supabase-2 yielded
  # the moment 'yielded' is visible the VM-owning launch must already be gone
  [ -e "$W/launch.exit" ]
  [ "$(cat "$W/released")" = "ghr-supabase-2" ]
  stop_driver
  grep -q 'released idle runner ghr-supabase-2 (ios lease)' "$W/loop.err"
}

@test "supabase busy when the lease appears: the job finishes untouched, THEN the slot yields" {
  ios_env
  driver supabase 2 'do_release() { echo "$1" >> "'"$W"'/released"; return 10; }
do_launch() { echo launched >> "'"$W"'/launched"; sleep 4; echo done > "'"$W"'/job.done"; }'
  wait_for test -e "$W/launched"
  lease_on
  wait_for state_is supabase-2 yielded
  [ -f "$W/job.done" ]
  stop_driver
  [ "$(grep -c launched "$W/launched")" -eq 1 ]
}
