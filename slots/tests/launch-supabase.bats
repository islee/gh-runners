#!/usr/bin/env bats
# shellcheck disable=SC2034  # globals consumed by the sourced script under test
# Tests for the `supabase` class of slots/launch.sh: one throwaway VM per job, cloned from a
# STOPPED golden, JIT only on stdin, VM stopped + deleted on every exit path, golden untouched.
# limactl is a shim (helpers.bash lima_setup); nothing touches a real VM.

load helpers

JIT_BLOB="SUPAJITBLOB0123456789abcdef=="

setup() {
  slots_setup
  lima_setup
  printf 'SUPABASE_SLOTS=2\nSUPA_MEM=4GiB\nSUPA_CPUS=4\n' >> "$W/slots.env"
}

launch() { printf '%s\n' "$JIT_BLOB" | bash "$SLOTS_DIR/launch.sh" "$@"; }

# line_of PATTERN — first line number in the limactl log matching PATTERN (fixed string).
line_of() { grep -n -F -e "$1" "$LIMA_LOG" | head -1 | cut -d: -f1; }

@test "arg validation: n must be 1..min(3, SUPABASE_SLOTS); class disabled at 0; no VM call on refusal" {
  for args in "supabase 0" "supabase 3" "supabase 4" "supabase -1" "supabase 1;id" "supabase" "supabase 1 2"; do
    # shellcheck disable=SC2086
    run launch $args
    [ "$status" -eq 2 ]
  done
  sed -i.bak 's/^SUPABASE_SLOTS=2$/SUPABASE_SLOTS=0/' "$W/slots.env"
  run launch supabase 1
  [ "$status" -eq 2 ]
  sed -i.bak 's/^SUPABASE_SLOTS=0$/SUPABASE_SLOTS=9/' "$W/slots.env"
  run launch supabase 4          # hard max 3 regardless of config
  [ "$status" -eq 2 ]
  [ ! -s "$LIMA_LOG" ]
}

@test "VM sizing from config is validated (no yq/shell injection)" {
  for bad in "SUPA_MEM|4GiB;id" "SUPA_MEM|4" "SUPA_MEM|-4GiB" "SUPA_CPUS|4;id" "SUPA_CPUS|0" "SUPA_CPUS|100"; do
    printf 'SUPABASE_SLOTS=2\nSUPA_MEM=4GiB\nSUPA_CPUS=4\n' > "$W/extra.env"
    printf "%s='%s'\n" "${bad%%|*}" "${bad#*|}" >> "$W/extra.env"
    cat "$W/slots.env" "$W/extra.env" > "$W/slots2.env"
    GHR_CONFIG="$W/slots2.env" run launch supabase 1
    [ "$status" -eq 2 ]
  done
  [ ! -s "$LIMA_LOG" ]
}

@test "happy path: delete-if-present -> clone -> start -> preflight -> run -> stop -> delete, in that order" {
  run launch supabase 2
  [ "$status" -eq 0 ]
  c=$(line_of 'clone ghr-supa-golden ghr-supa-2 --tty=false --set .cpus = 4 | .memory = "4GiB"')
  s=$(line_of 'start ghr-supa-2 --tty=false')
  p=$(line_of 'dev/tcp/192.0.2.1/22')
  r=$(line_of 'shell ghr-supa-2 -- sudo -u runner -H env AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache RUNNER_TOOL_CACHE=/opt/hostedtoolcache bash -c')
  x=$(line_of 'stop -f ghr-supa-2')
  d=$(line_of 'delete -f ghr-supa-2')
  [ -n "$c" ] && [ -n "$s" ] && [ -n "$p" ] && [ -n "$r" ] && [ -n "$x" ] && [ -n "$d" ]
  [ "$c" -lt "$s" ] && [ "$s" -lt "$p" ] && [ "$p" -lt "$r" ] && [ "$r" -lt "$x" ] && [ "$x" -lt "$d" ]
  grep -q "cd /opt/actions-runner && read -r J && exec ./run.sh --jitconfig" "$LIMA_LOG"
}

@test "JIT travels ONLY on stdin into the VM, never in any argv" {
  run launch supabase 1
  [ "$status" -eq 0 ]
  [ "$(cat "$LIMA_STDIN")" = "$JIT_BLOB" ]
  refute grep -q "$JIT_BLOB" "$LIMA_LOG"
  refute grep -q "$JIT_BLOB" "$CURL_ARGV_LOG"
}

@test "the golden is never started, stopped, deleted or shelled into" {
  run launch supabase 1
  [ "$status" -eq 0 ]
  refute grep -E -e '^(start|stop|delete|shell|edit|protect|unprotect).*ghr-supa-golden' "$LIMA_LOG"
  FAKE_RUN_RC=3 run launch supabase 1
  refute grep -E -e '^(start|stop|delete|shell|edit).*ghr-supa-golden' "$LIMA_LOG"
}

@test "golden missing or still Running -> refuse (exit 1), nothing cloned, nothing stopped" {
  FAKE_GOLDEN_STATUS="" run launch supabase 1
  [ "$status" -eq 1 ]
  FAKE_GOLDEN_STATUS=Running run launch supabase 1
  [ "$status" -eq 1 ]
  refute grep -q -e '^clone' -e '^stop' -e '^delete' "$LIMA_LOG"
}

@test "runner failure: exit code propagated and the VM is still stopped + deleted" {
  FAKE_RUN_RC=7 run launch supabase 1
  [ "$status" -eq 7 ]
  grep -q '^stop -f ghr-supa-1' "$LIMA_LOG"
  grep -q '^delete -f ghr-supa-1' "$LIMA_LOG"
}

@test "job timeout -> 124 and the VM is deleted" {
  FAKE_RUN_SLEEP=3 JOB_TIMEOUT_SECS=1 run launch supabase 1
  [ "$status" -eq 124 ]
  grep -q '^delete -f ghr-supa-1' "$LIMA_LOG"
}

@test "preflight: LAN reachable from the VM -> exit 3, runner never started, VM deleted" {
  FAKE_PROBE_RC=0 run launch supabase 1
  [ "$status" -eq 3 ]
  refute grep -q 'sudo -u runner' "$LIMA_LOG"
  grep -q '^delete -f ghr-supa-1' "$LIMA_LOG"
}

@test "preflight fails closed on an uninterpretable probe (127) and on a missing LAN_PROBE" {
  FAKE_PROBE_RC=127 run launch supabase 1
  [ "$status" -eq 3 ]
  : > "$LIMA_LOG"
  sed -i.bak 's#^LAN_PROBE=.*#LAN_PROBE=#' "$W/slots.env"
  run launch supabase 1
  [ "$status" -eq 3 ]
  refute grep -q 'sudo -u runner' "$LIMA_LOG"
  grep -q '^delete -f ghr-supa-1' "$LIMA_LOG"
}

@test "preflight probe targets the per-job VM, not the light pool VM" {
  FAKE_PROBE_RC=1 run launch supabase 1
  grep -q 'shell ghr-supa-1 -- /usr/bin/timeout 5' "$LIMA_LOG"
  refute grep -q 'shell ghr-pool' "$LIMA_LOG"
}

@test "clone failure and start failure: VM (possibly half-made) is deleted, exit 1, no runner" {
  FAKE_CLONE_RC=1 run launch supabase 1
  [ "$status" -eq 1 ]
  grep -q '^delete -f ghr-supa-1' "$LIMA_LOG"
  : > "$LIMA_LOG"
  FAKE_START_RC=1 run launch supabase 1
  [ "$status" -eq 1 ]
  grep -q '^delete -f ghr-supa-1' "$LIMA_LOG"
  refute grep -q 'sudo -u runner' "$LIMA_LOG"
}

@test "a leftover VM of the same slot is deleted BEFORE the clone" {
  FAKE_VM_STATUS=Running run launch supabase 1
  [ "$status" -eq 0 ]
  d=$(line_of 'delete -f ghr-supa-1')
  c=$(line_of 'clone ghr-supa-golden')
  [ "$d" -lt "$c" ]
}

@test "SIGTERM while the job runs: the job is killed, the VM is stopped + deleted, launch exits 143" {
  printf '%s\n' "$JIT_BLOB" > "$W/jit.in"
  FAKE_RUN_SLEEP=6 bash "$SLOTS_DIR/launch.sh" supabase 1 < "$W/jit.in" > "$W/out" 2>&1 &
  pid=$!
  for _ in $(seq 1 30); do grep -q 'sudo -u runner' "$LIMA_LOG" && break; sleep 0.2; done
  grep -q 'sudo -u runner' "$LIMA_LOG"
  kill -TERM "$pid"
  rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 143 ]
  grep -q '^stop -f ghr-supa-1' "$LIMA_LOG"
  grep -q '^delete -f ghr-supa-1' "$LIMA_LOG"
  [ "$(grep -c 'sudo -u runner' "$LIMA_LOG")" -eq 1 ]
}

@test "SIGTERM during the clone: the runner is never started, the VM is deleted, launch exits 143" {
  printf '%s\n' "$JIT_BLOB" > "$W/jit.in"
  FAKE_CLONE_SLEEP=3 bash "$SLOTS_DIR/launch.sh" supabase 1 < "$W/jit.in" > "$W/out" 2>&1 &
  pid=$!
  for _ in $(seq 1 30); do grep -q '^clone' "$LIMA_LOG" && break; sleep 0.2; done
  kill -TERM "$pid"
  rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 143 ]
  refute grep -q 'sudo -u runner' "$LIMA_LOG"
  grep -q '^delete -f ghr-supa-1' "$LIMA_LOG"
}

@test "JIT is in no limactl call's ENVIRONMENT either (argv covered above)" {
  run launch supabase 1
  [ "$status" -eq 0 ]
  [ -s "$LIMA_ENV" ]
  refute grep -q "$JIT_BLOB" "$LIMA_ENV"
}

@test "cleanup: a failing 'stop -f' is logged loudly, the delete still happens, the job's exit code survives" {
  FAKE_STOP_RC=1 FAKE_RUN_RC=4 run launch supabase 1
  [ "$status" -eq 4 ]
  [[ "$output" == *"WARN limactl stop -f ghr-supa-1 failed"* ]]
  grep -q '^delete -f ghr-supa-1' "$LIMA_LOG"
}

@test "cleanup: a VM that survives stop+delete is a LEAK error and fails the launch even if the job passed" {
  FAKE_DELETE_PERSIST=1 run launch supabase 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR LEAK: VM ghr-supa-1 still present"* ]]
  # retried once
  [ "$(grep -c '^delete -f ghr-supa-1' "$LIMA_LOG")" -ge 2 ]
}

@test "cleanup: a failing delete is logged and verified against 'limactl list'" {
  FAKE_DELETE_RC=1 run launch supabase 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"WARN limactl delete -f ghr-supa-1 failed"* ]]
  [[ "$output" == *"ERROR LEAK"* ]]
}

@test "cleanup: a hung 'limactl stop' is bounded by SUPA_DESTROY_TIMEOUT" {
  start=$(date +%s)
  FAKE_STOP_SLEEP=8 SUPA_DESTROY_TIMEOUT=1 run launch supabase 1
  elapsed=$(( $(date +%s) - start ))
  [ "$status" -eq 0 ]
  [[ "$output" == *"failed or timed out"* ]]
  [ "$elapsed" -lt 8 ]
  grep -q '^delete -f ghr-supa-1' "$LIMA_LOG"
}

@test "sweep: stray ghr-supa-* VMs are deleted; configured slots, the golden and other VMs never are" {
  FAKE_ALL_VMS=$'ghr-supa-golden\nghr-supa-1\nghr-supa-2\nghr-supa-3\nghr-supa-old\nghr-pool\nsomething-else' run launch supabase 1
  [ "$status" -eq 0 ]
  grep -q '^delete -f ghr-supa-3' "$LIMA_LOG"
  grep -q '^delete -f ghr-supa-old' "$LIMA_LOG"
  refute grep -q '^delete -f ghr-supa-2' "$LIMA_LOG"
  refute grep -q '^\(stop\|delete\) .*ghr-supa-golden' "$LIMA_LOG"
  refute grep -q '^\(stop\|delete\) .*\(ghr-pool\|something-else\)' "$LIMA_LOG"
}

@test "supa_destroy refuses the golden outright" {
  source "$SLOTS_DIR/launch.sh"
  : > "$LIMA_LOG"
  run supa_destroy ghr-supa-golden
  [ "$status" -eq 1 ]
  [ ! -s "$LIMA_LOG" ]
}

# installed form (what install.sh produces): config-owned settings in the caller's environment
# must be dropped, not trusted.
@test "installed copy ignores SUPABASE_SLOTS/SUPABASE_LABELS/SUPA_MEM/SUPA_CPUS (and friends) from the environment" {
  sed 's/^GHR_INSTALLED=0/GHR_INSTALLED=1/' "$SLOTS_DIR/launch.sh" > "$W/installed-launch"
  # everything up to (not including) `set -uo pipefail` is the hardening preamble
  sed -n '1,/^set -uo pipefail/p' "$W/installed-launch" | sed '$d' > "$W/preamble.sh"
  echo 'echo "[${SUPABASE_SLOTS-unset}][${SUPABASE_LABELS-unset}][${SUPA_MEM-unset}][${SUPA_CPUS-unset}][${LAN_PROBE-unset}][${LIGHT_IMAGE-unset}][${SUPA_DESTROY_TIMEOUT-unset}]"' >> "$W/preamble.sh"
  vars="SUPABASE_SLOTS=3 SUPABASE_LABELS=evil SUPA_MEM=64GiB SUPA_CPUS=99 LAN_PROBE=127.0.0.1:1 LIGHT_IMAGE=evil SUPA_DESTROY_TIMEOUT=9999"
  # shellcheck disable=SC2086
  run env $vars bash "$W/preamble.sh"
  [ "$output" = "[unset][unset][unset][unset][unset][unset][unset]" ]
  # control: the repo form keeps them (this is exactly the override surface being removed)
  sed -n '1,/^set -uo pipefail/p' "$SLOTS_DIR/launch.sh" | sed '$d' > "$W/preamble0.sh"
  echo 'echo "[${SUPABASE_SLOTS-unset}][${SUPA_MEM-unset}]"' >> "$W/preamble0.sh"
  run env $vars bash "$W/preamble0.sh"
  [ "$output" = "[3][64GiB]" ]
}

@test "no non-piping limactl call inherits stdin: extra bytes behind the JIT are never swallowed" {
  run bash -c "printf '%s\nEXTRA-STDIN\n' '$JIT_BLOB' | bash '$SLOTS_DIR/launch.sh' supabase 1"
  [ "$status" -eq 0 ]
  [ "$(cat "$LIMA_STDIN")" = "$JIT_BLOB" ]
  [ ! -s "$LIMA_OTHER_STDIN" ]
}

@test "installed copy also ignores a caller-supplied SUPA_GOLDEN" {
  grep -E '^\s+JOB_TIMEOUT_SECS SUPA_GOLDEN' "$SLOTS_DIR/launch.sh"
}
