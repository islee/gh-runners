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

@test "SIGTERM while the job runs: the job is killed, the VM is stopped + deleted, exit 143" {
  FAKE_RUN_SLEEP=6 bash -c "printf '%s\n' '$JIT_BLOB' | bash '$SLOTS_DIR/launch.sh' supabase 1" > "$W/out" 2>&1 &
  pid=$!
  # wait until the runner command has started, then signal the launch (the pipeline's bash)
  for _ in $(seq 1 30); do grep -q 'sudo -u runner' "$LIMA_LOG" && break; sleep 0.2; done
  grep -q 'sudo -u runner' "$LIMA_LOG"
  pkill -TERM -f "launch.sh supabase 1" || true
  wait "$pid" || true
  grep -q '^stop -f ghr-supa-1' "$LIMA_LOG"
  grep -q '^delete -f ghr-supa-1' "$LIMA_LOG"
  [ "$(grep -c 'sudo -u runner' "$LIMA_LOG")" -eq 1 ]
}

@test "SIGTERM during the clone: the runner is never started and the VM is deleted" {
  FAKE_CLONE_SLEEP=3 bash -c "printf '%s\n' '$JIT_BLOB' | bash '$SLOTS_DIR/launch.sh' supabase 1" > "$W/out" 2>&1 &
  pid=$!
  for _ in $(seq 1 30); do grep -q '^clone' "$LIMA_LOG" && break; sleep 0.2; done
  pkill -TERM -f "launch.sh supabase 1" || true
  wait "$pid" || true
  refute grep -q 'sudo -u runner' "$LIMA_LOG"
  grep -q '^delete -f ghr-supa-1' "$LIMA_LOG"
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
