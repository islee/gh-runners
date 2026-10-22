#!/usr/bin/env bats
# shellcheck disable=SC2034  # globals consumed by the sourced script under test
# Tests for the `ios` class of slots/launch.sh: one throwaway Tart macOS VM per job, cloned from a
# STOPPED golden, JIT only on stdin, the in-guest LAN preflight, VM stopped + deleted on every exit
# path, golden untouched. `tart` is a shim (helpers.bash tart_setup); nothing touches a real VM.

load helpers

JIT_BLOB="IOSJITBLOB0123456789abcdef=="

setup() {
  slots_setup
  tart_setup
  printf 'IOS_SLOTS=1\nIOS_MEM_MB=8192\nIOS_CPUS=4\nIOS_LAN_PROBES="192.0.2.1:443 192.168.64.1:22"\n' >> "$W/slots.env"
  # keychain: `security` is a shim that records argv + stdin; the password file stands in for ~ghr/.ghr/keychain.pass
  SEC_LOG="$W/security.log"; SEC_STDIN="$W/security.stdin"; : > "$SEC_LOG"
  export SEC_LOG SEC_STDIN SECURITY="$FAKE_BIN/security" TEST_IOS_KEYCHAIN="$W/login.keychain-db" TEST_IOS_KEYCHAIN_PASS="$W/keychain.pass"
  printf 'KEYCHAIN-PW-0123456789\n' > "$W/keychain.pass"
  cat > "$FAKE_BIN/security" <<'SHIM'
#!/bin/bash
echo "$*" >> "$SEC_LOG"
cat > "$SEC_STDIN"
exit "${FAKE_SECURITY_RC:-0}"
SHIM
  chmod +x "$FAKE_BIN/security"
  # fast boot polling in tests
  export IOS_BOOT_POLL=1
}

launch() { printf '%s\n' "$JIT_BLOB" | bash "$SLOTS_DIR/launch.sh" "$@"; }

# line_of PATTERN — first line number in the tart log matching PATTERN (fixed string).
line_of() { grep -n -F -e "$1" "$TART_LOG" | head -1 | cut -d: -f1; }

@test "arg validation: ios only slot 1, only with IOS_SLOTS=1; no VM call on refusal" {
  for args in "ios 0" "ios 2" "ios -1" "ios 1;id" "ios" "ios 1 2"; do
    # shellcheck disable=SC2086
    run launch $args
    [ "$status" -eq 2 ]
  done
  sed -i.bak 's/^IOS_SLOTS=1$/IOS_SLOTS=0/' "$W/slots.env"
  run launch ios 1
  [ "$status" -eq 2 ]
  sed -i.bak 's/^IOS_SLOTS=0$/IOS_SLOTS=2/' "$W/slots.env"
  run launch ios 2             # hard max 1 regardless of config
  [ "$status" -eq 2 ]
  [ ! -s "$TART_LOG" ]
}

@test "VM sizing, golden and runner dir from config are validated (no argv/shell injection)" {
  for bad in "IOS_MEM_MB|8192;id" "IOS_MEM_MB|512" "IOS_MEM_MB|-8192" "IOS_MEM_MB|8GiB" "IOS_MEM_MB|1000000" \
    "IOS_CPUS|4;id" "IOS_CPUS|0" "IOS_CPUS|100" "IOS_GOLDEN|-evil" "IOS_GOLDEN|a b" "IOS_GOLDEN|ghr-ios-1" \
    "IOS_RUNNER_DIR|relative/dir" "IOS_RUNNER_DIR|/a;id" 'IOS_RUNNER_DIR|/a b'; do
    cp "$W/slots.env" "$W/slots2.env"
    printf "%s='%s'\n" "${bad%%|*}" "${bad#*|}" >> "$W/slots2.env"
    GHR_CONFIG="$W/slots2.env" run launch ios 1
    [ "$status" -eq 2 ]
  done
  [ ! -s "$TART_LOG" ]
}

@test "happy path: golden check -> clone -> set -> run -> agent -> preflight -> runner -> stop -> delete, in order" {
  run launch ios 1
  [ "$status" -eq 0 ]
  c=$(line_of 'clone ghr-ios-golden ghr-ios-1')
  s=$(line_of 'set ghr-ios-1 --cpu 4 --memory 8192 --random-mac')
  r=$(line_of 'run ghr-ios-1 --no-graphics --no-audio')
  a=$(line_of 'exec ghr-ios-1 /usr/bin/true')
  p=$(line_of 'exec ghr-ios-1 /usr/bin/nc -z -G 5 192.0.2.1 443')
  p2=$(line_of 'exec ghr-ios-1 /usr/bin/nc -z -G 5 192.168.64.1 22')
  j=$(line_of 'exec -i ghr-ios-1 /bin/bash -c')
  x=$(line_of 'stop ghr-ios-1')
  d=$(line_of 'delete ghr-ios-1')
  [ -n "$c" ] && [ -n "$s" ] && [ -n "$r" ] && [ -n "$a" ] && [ -n "$p" ] && [ -n "$p2" ] && [ -n "$j" ] && [ -n "$x" ] && [ -n "$d" ]
  [ "$c" -lt "$s" ] && [ "$s" -lt "$r" ] && [ "$r" -lt "$a" ] && [ "$a" -lt "$p" ] && [ "$p" -lt "$p2" ] && [ "$p2" -lt "$j" ] && [ "$j" -lt "$x" ] && [ "$x" -lt "$d" ]
  grep -q 'run.sh --jitconfig' "$TART_LOG"
  refute grep -q ' -w ' "$TART_LOG"
  [ "$(cat "$SEC_LOG")" = "unlock-keychain $W/login.keychain-db" ]
  grep -q '_ /Users/admin/actions-runner' "$TART_LOG"
  [ -z "$(cat "$TARTSTATE/vms/ghr-ios-1" 2> /dev/null)" ]
}

@test "keychain: the password reaches 'security unlock-keychain' on STDIN only, before tart run; never in argv/env" {
  run launch ios 1
  [ "$status" -eq 0 ]
  [ "$(cat "$SEC_STDIN")" = "KEYCHAIN-PW-0123456789" ]
  refute grep -q 'KEYCHAIN-PW' "$SEC_LOG"
  refute grep -q 'KEYCHAIN-PW' "$TART_LOG"
  refute grep -q 'KEYCHAIN-PW' "$TART_ENV"
}

@test "keychain: an unlock failure refuses (exit 1), logs, never starts the VM, and still deletes the clone" {
  FAKE_SECURITY_RC=51 run launch ios 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot unlock the login keychain"* ]]
  refute grep -q -e '^run ' -e 'run.sh' "$TART_LOG"
  grep -q '^delete ghr-ios-1' "$TART_LOG"
  [ ! -e "$TARTSTATE/vms/ghr-ios-1" ]
}

@test "the clone never prunes the OCI cache: TART_NO_AUTO_PRUNE=1 reaches every tart call" {
  TART_NO_AUTO_PRUNE=0 run launch ios 1
  [ "$status" -eq 0 ]
  grep -q '^TART_NO_AUTO_PRUNE=1$' "$TART_ENV"
  refute grep -q '^TART_NO_AUTO_PRUNE=0$' "$TART_ENV"
}

@test "JIT travels ONLY on stdin into the VM, never in any argv or environment" {
  run launch ios 1
  [ "$status" -eq 0 ]
  [ "$(cat "$TART_STDIN")" = "$JIT_BLOB" ]
  refute grep -q "$JIT_BLOB" "$TART_LOG"
  refute grep -q "$JIT_BLOB" "$TART_ENV"
  refute grep -q "$JIT_BLOB" "$CURL_ARGV_LOG"
}

@test "no non-runner tart call inherits stdin: extra bytes behind the JIT are never swallowed" {
  run bash -c "printf '%s\nEXTRA-STDIN\n' '$JIT_BLOB' | bash '$SLOTS_DIR/launch.sh' ios 1"
  [ "$status" -eq 0 ]
  [ "$(cat "$TART_STDIN")" = "$JIT_BLOB" ]
  [ ! -s "$TART_OTHER_STDIN" ]
}

@test "the golden is never started, stopped, deleted, renamed or exec'd into" {
  run launch ios 1
  [ "$status" -eq 0 ]
  refute grep -E -e '^(run|stop|delete|rename|exec|set).* ghr-ios-golden' "$TART_LOG"
  FAKE_RUN_RC=3 run launch ios 1
  FAKE_PROBE_RC=0 run launch ios 1
  FAKE_CLONE_RC=1 run launch ios 1
  refute grep -E -e '^(run|stop|delete|rename|exec|set).* ghr-ios-golden' "$TART_LOG"
  [ "$(cat "$TARTSTATE/vms/ghr-ios-golden")" = stopped ]
}

@test "golden missing, running or suspended -> refuse (exit 1), nothing cloned, nothing stopped" {
  for st in none running suspended; do
    rm -f "$TARTSTATE/vms/ghr-ios-golden"
    [ "$st" = none ] || echo "$st" > "$TARTSTATE/vms/ghr-ios-golden"
    run launch ios 1
    [ "$status" -eq 1 ]
  done
  refute grep -q -e '^clone' -e '^stop' -e '^delete' "$TART_LOG"
}

@test "an unreadable VM list is a refusal, not 'the golden is missing' guesswork" {
  FAKE_TART_LIST_RC=1 run launch ios 1
  [ "$status" -eq 1 ]
  refute grep -q -e '^clone' -e '^run' "$TART_LOG"
}

@test "runner failure: exit code propagated and the VM is still stopped + deleted" {
  FAKE_RUN_RC=7 run launch ios 1
  [ "$status" -eq 7 ]
  grep -q '^stop ghr-ios-1' "$TART_LOG"
  grep -q '^delete ghr-ios-1' "$TART_LOG"
  [ ! -e "$TARTSTATE/vms/ghr-ios-1" ]
}

@test "job timeout -> 124 and the VM is deleted" {
  FAKE_RUN_SLEEP=3 JOB_TIMEOUT_SECS=1 run launch ios 1
  [ "$status" -eq 124 ]
  grep -q '^delete ghr-ios-1' "$TART_LOG"
  [ ! -e "$TARTSTATE/vms/ghr-ios-1" ]
}

@test "preflight: LAN reachable from the guest -> exit 3, runner never started, VM deleted" {
  FAKE_PROBE_RC=0 run launch ios 1
  [ "$status" -eq 3 ]
  refute grep -q 'run.sh' "$TART_LOG"
  grep -q '^delete ghr-ios-1' "$TART_LOG"
  [ ! -e "$TARTSTATE/vms/ghr-ios-1" ]
}

@test "preflight fails closed on an uninterpretable probe (127, 255) and on a missing LAN_PROBE" {
  for rc in 127 255 2; do
    FAKE_PROBE_RC=$rc run launch ios 1
    [ "$status" -eq 3 ]
  done
  : > "$TART_LOG"
  sed -i.bak 's#^LAN_PROBE=.*#LAN_PROBE=#' "$W/slots.env"
  run launch ios 1                 # the host-LAN probe is irrelevant for ios
  [ "$status" -eq 0 ]
}

@test "preflight: EVERY IOS_LAN_PROBES target must be blocked (second one reachable -> refuse); a bad or empty list is refused; LAN_PROBE is not used" {
  cat > "$FAKE_BIN/tart-probe" <<'WRAP'
#!/bin/bash
case "$*" in *"nc -z -G 5 192.168.64.1 22"*) echo "$*" >> "$TART_LOG"; exit 0 ;; esac
exec "$REAL_TART" "$@"
WRAP
  chmod +x "$FAKE_BIN/tart-probe"
  REAL_TART="$FAKE_BIN/tart" TART="$FAKE_BIN/tart-probe" run launch ios 1
  [ "$status" -eq 3 ]
  [[ "$output" == *"guest CAN reach 192.168.64.1:22"* ]]
  refute grep -q 'run.sh' "$TART_LOG"
  grep -q '^delete ghr-ios-1' "$TART_LOG"
  : > "$TART_LOG"
  for bad in "" "nothost" "a:1;id"; do
    cp "$W/slots.env" "$W/slots2.env"
    printf "IOS_LAN_PROBES='%s'\n" "$bad" >> "$W/slots2.env"
    GHR_CONFIG="$W/slots2.env" run launch ios 1
    [ "$status" -eq 2 ]
  done
  [ ! -s "$TART_LOG" ]
}

@test "boot timeout: the guest agent never answers -> exit 1, runner never started, VM deleted" {
  start=$(date +%s)
  FAKE_AGENT_NEVER=1 IOS_BOOT_TIMEOUT=2 run launch ios 1
  elapsed=$(( $(date +%s) - start ))
  [ "$status" -eq 1 ]
  [[ "$output" == *"guest agent not up after 2s"* ]]
  [ "$elapsed" -lt 20 ]
  refute grep -q 'run.sh' "$TART_LOG"
  grep -q '^stop ghr-ios-1' "$TART_LOG"
  grep -q '^delete ghr-ios-1' "$TART_LOG"
  [ ! -e "$TARTSTATE/vms/ghr-ios-1" ]
}

@test "the agent coming up late (after retries) still reaches the job" {
  FAKE_AGENT_FAILS=2 run launch ios 1
  [ "$status" -eq 0 ]
  [ "$(grep -c 'exec ghr-ios-1 /usr/bin/true' "$TART_LOG")" -ge 3 ]
  [ "$(cat "$TART_STDIN")" = "$JIT_BLOB" ]
}

@test "a tart run that dies at boot is detected early and the VM is deleted" {
  FAKE_RUN_DIES=1 IOS_BOOT_TIMEOUT=60 run launch ios 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"tart run exited before the guest agent answered"* ]]
  grep -q '^delete ghr-ios-1' "$TART_LOG"
  [ ! -e "$TARTSTATE/vms/ghr-ios-1" ]
}

@test "clone failure and set failure: VM (possibly half-made) is deleted, exit 1, never booted" {
  FAKE_CLONE_RC=1 run launch ios 1
  [ "$status" -eq 1 ]
  grep -q '^delete ghr-ios-1' "$TART_LOG"
  : > "$TART_LOG"
  FAKE_SET_RC=1 run launch ios 1
  [ "$status" -eq 1 ]
  grep -q '^delete ghr-ios-1' "$TART_LOG"
  refute grep -q '^run ' "$TART_LOG"
}

@test "a leftover VM of the same slot is deleted BEFORE the clone" {
  echo stopped > "$TARTSTATE/vms/ghr-ios-1"
  run launch ios 1
  [ "$status" -eq 0 ]
  d=$(line_of 'delete ghr-ios-1')
  c=$(line_of 'clone ghr-ios-golden')
  [ "$d" -lt "$c" ]
}

@test "SIGTERM while the job runs: the job is killed, the VM is stopped + deleted, launch exits 143" {
  printf '%s\n' "$JIT_BLOB" > "$W/jit.in"
  FAKE_RUN_SLEEP=6 bash "$SLOTS_DIR/launch.sh" ios 1 < "$W/jit.in" > "$W/out" 2>&1 &
  pid=$!
  for _ in $(seq 1 50); do grep -q 'run.sh' "$TART_LOG" && break; sleep 0.2; done
  grep -q 'run.sh' "$TART_LOG"
  kill -TERM "$pid"
  rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 143 ]
  grep -q '^stop ghr-ios-1' "$TART_LOG"
  grep -q '^delete ghr-ios-1' "$TART_LOG"
  [ ! -e "$TARTSTATE/vms/ghr-ios-1" ]
  [ "$(grep -c 'run.sh' "$TART_LOG")" -eq 1 ]
}

@test "SIGTERM during boot (agent not up yet): the runner is never started, the VM is deleted, exit 143" {
  printf '%s\n' "$JIT_BLOB" > "$W/jit.in"
  FAKE_AGENT_NEVER=1 IOS_BOOT_TIMEOUT=60 bash "$SLOTS_DIR/launch.sh" ios 1 < "$W/jit.in" > "$W/out" 2>&1 &
  pid=$!
  for _ in $(seq 1 50); do grep -q 'exec ghr-ios-1 /usr/bin/true' "$TART_LOG" && break; sleep 0.2; done
  kill -TERM "$pid"
  rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 143 ]
  refute grep -q 'run.sh' "$TART_LOG"
  grep -q '^delete ghr-ios-1' "$TART_LOG"
  [ ! -e "$TARTSTATE/vms/ghr-ios-1" ]
}

@test "SIGTERM during the clone: nothing is booted, the VM is deleted" {
  printf '%s\n' "$JIT_BLOB" > "$W/jit.in"
  FAKE_CLONE_SLEEP=3 bash "$SLOTS_DIR/launch.sh" ios 1 < "$W/jit.in" > "$W/out" 2>&1 &
  pid=$!
  for _ in $(seq 1 30); do grep -q '^clone' "$TART_LOG" && break; sleep 0.2; done
  kill -TERM "$pid"
  rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 143 ]
  refute grep -q 'run.sh' "$TART_LOG"
  [ ! -e "$TARTSTATE/vms/ghr-ios-1" ]
}

@test "cleanup: a failing 'tart stop' is logged loudly, the stuck 'tart run' is reaped, the delete still happens, the job's exit code survives" {
  FAKE_STOP_RC=1 FAKE_RUN_RC=4 run launch ios 1
  [ "$status" -eq 4 ]
  [[ "$output" == *"WARN tart stop ghr-ios-1 failed"* ]]
  grep -q '^delete ghr-ios-1' "$TART_LOG"
  [ ! -e "$TARTSTATE/vms/ghr-ios-1" ]
}

@test "cleanup: a VM that survives stop+delete is a LEAK error and fails the launch even if the job passed" {
  FAKE_DELETE_PERSIST=1 run launch ios 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR LEAK: VM ghr-ios-1 still present"* ]]
  [ "$(grep -c '^delete ghr-ios-1' "$TART_LOG")" -ge 2 ]
}

@test "cleanup: a failing delete is logged and verified against 'tart list'" {
  FAKE_DELETE_RC=1 run launch ios 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"WARN tart delete ghr-ios-1 failed"* ]]
  [[ "$output" == *"ERROR LEAK"* ]]
}

@test "cleanup: an unreadable VM list after delete is not 'gone' -> LEAK (could not look)" {
  # let the golden check pass, then break the list for the destroy verification only
  cat > "$FAKE_BIN/tart-wrap" <<'WRAP'
#!/bin/bash
if [ "$1" = list ] && [ -f "$TARTSTATE/.break-list" ]; then exit 1; fi
exec "$REAL_TART" "$@"
WRAP
  chmod +x "$FAKE_BIN/tart-wrap"
  REAL_TART="$FAKE_BIN/tart" TART="$FAKE_BIN/tart-wrap" FAKE_RUN_SLEEP=1 bash -c '
    printf "%s\n" "$0" | bash "$1/launch.sh" ios 1 > "$2/out" 2>&1 &
    pid=$!
    for _ in $(seq 1 50); do grep -q run.sh "$TART_LOG" && break; sleep 0.2; done
    touch "$TARTSTATE/.break-list"
    wait $pid; echo $? > "$2/rc"' "$JIT_BLOB" "$SLOTS_DIR" "$W"
  [ "$(cat "$W/rc")" -eq 1 ]
  grep -q 'ERROR LEAK' "$W/out"
}

@test "cleanup: a hung 'tart stop' is bounded by IOS_STOP_TIMEOUT" {
  start=$(date +%s)
  FAKE_STOP_SLEEP=8 IOS_STOP_TIMEOUT=1 run launch ios 1
  elapsed=$(( $(date +%s) - start ))
  [ "$status" -eq 0 ]
  [[ "$output" == *"failed or timed out"* ]]
  [ "$elapsed" -lt 8 ]
  grep -q '^delete ghr-ios-1' "$TART_LOG"
  [ ! -e "$TARTSTATE/vms/ghr-ios-1" ]
}

@test "sweep: orphan ghr-ios-<n> VMs are deleted; the configured slot, the golden, the build VM and others never are" {
  FAKE_ALL_VMS=$'ghr-ios-2 stopped\nghr-ios-07 stopped\nghr-ios-build stopped\nsomething-else stopped' tart_setup
  run launch ios 1
  [ "$status" -eq 0 ]
  grep -q '^delete ghr-ios-2' "$TART_LOG"
  grep -q '^delete ghr-ios-07' "$TART_LOG"
  refute grep -q -e '^\(stop\|delete\) ghr-ios-golden' -e '^\(stop\|delete\) ghr-ios-build' -e '^\(stop\|delete\) something-else' "$TART_LOG"
  [ "$(cat "$TARTSTATE/vms/ghr-ios-build")" = stopped ]
  [ "$(cat "$TARTSTATE/vms/something-else")" = stopped ]
}

@test "ios_destroy refuses the golden outright" {
  source "$SLOTS_DIR/launch.sh"
  : > "$TART_LOG"
  run ios_destroy ghr-ios-golden
  [ "$status" -eq 1 ]
  [ ! -s "$TART_LOG" ]
}

@test "tart_vm_states: OCI cache entries are skipped; an unparseable list is an error" {
  source "$SLOTS_DIR/launch.sh"
  run tart_vm_states
  [ "$status" -eq 0 ]
  refute grep -q 'ghcr.io' <<< "$output"
  [ "$output" = "$(printf 'ghr-ios-golden\tstopped')" ]
  FAKE_TART_LIST_JSON='not json' run tart_vm_states
  [ "$status" -eq 1 ]
  FAKE_TART_LIST_JSON='[

]' run tart_vm_states
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  FAKE_TART_LIST_JSON='[{"Name":"x","Running":true}]' run tart_vm_states
  [ "$output" = "$(printf 'x\trunning')" ]
}

@test "installed copy ignores IOS_*/TART* settings from the environment" {
  sed 's/^GHR_INSTALLED=0/GHR_INSTALLED=1/' "$SLOTS_DIR/launch.sh" > "$W/installed-launch"
  sed -n '1,/^set -uo pipefail/p' "$W/installed-launch" | sed '$d' > "$W/preamble.sh"
  echo 'echo "[${TART-unset}][${TART_HOME-unset}][${IOS_SLOTS-unset}][${IOS_GOLDEN-unset}][${IOS_MEM_MB-unset}][${IOS_CPUS-unset}][${IOS_RUNNER_DIR-unset}][${IOS_BOOT_TIMEOUT-unset}][${IOS_STOP_TIMEOUT-unset}][${IOS_LABELS-unset}][${IOS_LAN_PROBES-unset}][${IOS_KEYCHAIN-unset}][${IOS_KEYCHAIN_PASS-unset}][${SECURITY-unset}]"' >> "$W/preamble.sh"
  vars="TART=/tmp/evil TART_HOME=/tmp/x IOS_SLOTS=1 IOS_GOLDEN=evil IOS_MEM_MB=99999 IOS_CPUS=99 IOS_RUNNER_DIR=/tmp IOS_BOOT_TIMEOUT=1 IOS_STOP_TIMEOUT=1 IOS_LABELS=evil IOS_LAN_PROBES=x:1 IOS_KEYCHAIN=/tmp/k IOS_KEYCHAIN_PASS=/tmp/p SECURITY=/tmp/s"
  # shellcheck disable=SC2086
  run env $vars bash "$W/preamble.sh"
  [ "$output" = "[unset][unset][unset][unset][unset][unset][unset][unset][unset][unset][unset][unset][unset][unset]" ]
}
