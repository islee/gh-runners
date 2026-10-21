#!/usr/bin/env bats
# shellcheck disable=SC2034  # globals consumed by the sourced script under test
# Tests for slots/launch-pve.sh (Proxmox per-job VM): linked clone of a STOPPED-template golden, JIT
# only on stdin over the guest agent, egress firewall file before first boot, destroy on every exit
# path, golden untouched, sweep limited to name + VMID range. `qm` is a stateful shim
# (helpers.bash pve_setup); nothing touches a real hypervisor.

load helpers

JIT_BLOB="PVEJITBLOB0123456789abcdef=="

setup() {
  slots_setup
  pve_setup
  cat >> "$W/slots.env" <<CFG
PVE_SLOTS="5"
PVE_VMID_BASE=300
GOLDEN_VMID=300
SUPA_MEM_MB=4096
SUPA_CPUS=4
PVE_IPCONFIG_5="ip=192.0.2.50/24,gw=192.0.2.1"
CFG
  # fast polling for the tests; the installed copy ignores all of these
  export PVE_POLL_SECS=0.2 PVE_AGENT_WAIT_SECS=3 PVE_EXIT_POLL_EVERY=2
}

launch() { printf '%s\n' "$JIT_BLOB" | bash "$SLOTS_DIR/launch-pve.sh" "$@"; }

# line_of PATTERN — first line number in the qm log matching PATTERN (fixed string).
line_of() { grep -n -F -e "$1" "$QM_LOG" | head -1 | cut -d: -f1; }

@test "arg validation: only supabase, n in PVE_SLOTS (1..9); nothing is called on refusal" {
  for args in "light 5" "supabase 1" "supabase 3" "supabase 4" "supabase 0" "supabase 10" "supabase x" "supabase 5;id" "supabase" "supabase 5 4"; do
    # shellcheck disable=SC2086
    run launch $args
    [ "$status" -eq 2 ]
  done
  [ ! -s "$QM_LOG" ]
}

@test "config validation: VMIDs, sizing, nameserver and the slot's ipconfig are checked (no injection into qm)" {
  for bad in "GOLDEN_VMID|30" "GOLDEN_VMID|3x0" "PVE_VMID_BASE|99" "SUPA_MEM_MB|4096;id" "SUPA_MEM_MB|64" "SUPA_CPUS|0" \
    "PVE_NAMESERVER|1.1.1.1;id" "PVE_IPCONFIG_5|ip=192.0.2.50/24,gw=192.0.2.1,ip6=auto" "PVE_IPCONFIG_5|\$(id)" "PVE_IPCONFIG_5|" "PVE_SLOTS|5;id"; do
    cp "$W/slots.env" "$W/slots2.env"
    printf "%s='%s'\n" "${bad%%|*}" "${bad#*|}" >> "$W/slots2.env"
    GHR_CONFIG="$W/slots2.env" run launch supabase 5
    [ "$status" -eq 2 ]
  done
  [ ! -s "$QM_LOG" ]
}

@test "a slot whose VMID equals GOLDEN_VMID is refused outright" {
  printf 'PVE_VMID_BASE=295\n' >> "$W/slots.env"      # 295 + 5 = 300 = golden
  run launch supabase 5
  [ "$status" -eq 2 ]
  [ ! -s "$QM_LOG" ]
}

@test "stdin must be a JIT-shaped line" {
  run bash -c "printf 'not a jit; id\n' | bash '$SLOTS_DIR/launch-pve.sh' supabase 5"
  [ "$status" -eq 2 ]
  [ ! -s "$QM_LOG" ]
}

@test "happy path: golden check -> clone -> set -> start -> agent -> preflight -> JIT -> unit -> stop -> destroy, in order" {
  run launch supabase 5
  [ "$status" -eq 0 ]
  g=$(line_of 'config 300')
  c=$(line_of 'clone 300 305 --name ghr-supa-5')
  s=$(line_of 'set 305 --memory 4096 --cores 4 --balloon 0 --ipconfig0 ip=192.0.2.50/24,gw=192.0.2.1 --nameserver 1.1.1.1 8.8.8.8')
  b=$(line_of 'start 305')
  a=$(line_of 'agent 305 ping')
  ci=$(line_of 'guest exec 305 --timeout 240 -- cloud-init status --wait')
  p=$(line_of 'dev/tcp/192.0.2.1/22')
  j=$(line_of '/run/ghr/jit')
  u=$(line_of 'systemctl start --no-block ghr-runner.service')
  x=$(line_of 'stop 305 --skiplock')
  d=$(line_of 'destroy 305 --purge --destroy-unreferenced-disks 1')
  for v in "$g" "$c" "$s" "$b" "$a" "$ci" "$p" "$j" "$u" "$x" "$d"; do [ -n "$v" ]; done
  [ "$g" -lt "$c" ] && [ "$c" -lt "$s" ] && [ "$s" -lt "$b" ] && [ "$b" -lt "$a" ] && [ "$a" -lt "$ci" ]
  [ "$ci" -lt "$p" ] && [ "$p" -lt "$j" ] && [ "$j" -lt "$u" ] && [ "$u" -lt "$x" ] && [ "$x" -lt "$d" ]
  # linked clone: never --full
  refute grep -q -e '--full' "$QM_LOG"
  [ ! -d "$QMSTATE/305" ]
  [ ! -e "$PVE_FW_DIR/305.fw" ]
}

@test "the egress firewall file exists BEFORE the first boot and holds the isolation rules" {
  run launch supabase 5
  [ "$status" -eq 0 ]
  # the shim copies the file at `qm start` time into the VM's state dir, which destroy removes: re-run
  # with the destroy kept to read it
  FAKE_DESTROY_PERSIST=1 run launch supabase 5
  fw="$QMSTATE/305/fw-at-start"
  [ -s "$fw" ]
  grep -qx 'enable: 1' "$fw"
  grep -qx 'policy_in: DROP' "$fw"
  # byte-for-byte the shared template (lib/pve-fw.sh), which drops every private/link-local/CGNAT range
  source "$SLOTS_DIR/lib/pve-fw.sh"
  [ "$(cat "$fw")" = "$(pve_fw_rules)" ]
  [ "$(grep -c '^OUT DROP -dest' "$fw")" -eq 7 ]
  # first rule accepts ipv6-icmp, drops come after it
  [ "$(grep -n 'OUT ACCEPT -p ipv6-icmp' "$fw" | cut -d: -f1)" -lt "$(grep -n 'OUT DROP' "$fw" | head -1 | cut -d: -f1)" ]
}

@test "the clone's NIC must carry firewall=1, else the VM is destroyed and never started" {
  FAKE_NO_FW=1 run launch supabase 5
  [ "$status" -eq 1 ]
  refute grep -q '^start 305' "$QM_LOG"
  grep -q '^destroy 305' "$QM_LOG"
}

@test "JIT travels ONLY on stdin into the guest file: in no qm argv and no qm environment" {
  run launch supabase 5
  [ "$status" -eq 0 ]
  [ "$(cat "$QM_STDIN")" = "$JIT_BLOB" ]
  refute grep -q "$JIT_BLOB" "$QM_LOG"
  refute grep -q "$JIT_BLOB" "$QM_ENV"
  refute grep -q "$JIT_BLOB" "$CURL_ARGV_LOG"
  # it is written to tmpfs by a guest-side cat, not passed as an argument
  grep -q "guest exec 305 --pass-stdin 1 --timeout 30 -- bash -c umask 077; mkdir -p /run/ghr && cat > /run/ghr/jit" "$QM_LOG"
}

@test "no qm call except the JIT delivery inherits stdin: bytes behind the JIT are never swallowed" {
  run bash -c "printf '%s\nEXTRA-STDIN\n' '$JIT_BLOB' | bash '$SLOTS_DIR/launch-pve.sh' supabase 5"
  [ "$status" -eq 0 ]
  [ "$(cat "$QM_STDIN")" = "$JIT_BLOB" ]
  [ ! -s "$QM_OTHER_STDIN" ]
}

@test "the golden is never started, stopped, destroyed, set or cloned INTO" {
  run launch supabase 5
  [ "$status" -eq 0 ]
  refute grep -E -e '^(start|stop|destroy|set|shutdown|template|resize) 300( |$)' "$QM_LOG"
  FAKE_JOB_RC=3 run launch supabase 5
  refute grep -E -e '^(start|stop|destroy|set|shutdown|template|resize) 300( |$)' "$QM_LOG"
}

@test "golden missing, not a template, or wrongly named -> exit 1, nothing cloned, nothing destroyed" {
  FAKE_GOLDEN_MISSING=1 pve_setup
  run launch supabase 5
  [ "$status" -eq 1 ]
  refute grep -q -e '^clone' -e '^destroy' -e '^stop' "$QM_LOG"
  FAKE_GOLDEN_MISSING="" FAKE_GOLDEN_NOT_TEMPLATE=1 pve_setup
  run launch supabase 5
  [ "$status" -eq 1 ]
  refute grep -q -e '^clone' -e '^destroy' -e '^stop' "$QM_LOG"
  FAKE_GOLDEN_NOT_TEMPLATE="" FAKE_GOLDEN_NAME=something-else pve_setup
  run launch supabase 5
  [ "$status" -eq 1 ]
  refute grep -q -e '^clone' -e '^destroy' -e '^stop' "$QM_LOG"
}

@test "runner exit code reported by the guest is propagated; the VM is still destroyed" {
  FAKE_JOB_RC=7 FAKE_RUN_SLEEP=5 run launch supabase 5
  [ "$status" -eq 7 ]
  grep -q '^destroy 305' "$QM_LOG"
  [ ! -d "$QMSTATE/305" ]
}

@test "a VM that powers off by itself without a reported code is exit 0" {
  run launch supabase 5
  [ "$status" -eq 0 ]
}

@test "job timeout -> 124 and the VM is destroyed" {
  FAKE_RUN_SLEEP=30 JOB_TIMEOUT_SECS=1 run launch supabase 5
  [ "$status" -eq 124 ]
  grep -q '^stop 305 --skiplock' "$QM_LOG"
  grep -q '^destroy 305' "$QM_LOG"
  [ ! -d "$QMSTATE/305" ]
}

@test "preflight: LAN reachable from the VM -> exit 3, JIT never delivered, VM destroyed" {
  FAKE_PROBE_RC=0 run launch supabase 5
  [ "$status" -eq 3 ]
  refute grep -q '/run/ghr/jit' "$QM_LOG"
  refute grep -q 'ghr-runner.service' "$QM_LOG"
  grep -q '^destroy 305' "$QM_LOG"
  [ ! -s "$QM_STDIN" ]
}

@test "preflight probe: timeout (124) and refused (1) pass; anything else, and a not-ready guest, refuse (3)" {
  FAKE_PROBE_RC=124 run launch supabase 5
  [ "$status" -eq 0 ]
  for rc in 2 126 127 255; do
    FAKE_PROBE_RC=$rc run launch supabase 5
    [ "$status" -eq 3 ]
  done
  FAKE_CI_RC=1 run launch supabase 5
  [ "$status" -eq 3 ]
  # cloud-init "done with recoverable errors" (2) is acceptable
  FAKE_CI_RC=2 run launch supabase 5
  [ "$status" -eq 0 ]
}

@test "preflight fails closed on a missing LAN_PROBE and runs INSIDE the per-job VM (guest exec, not the host)" {
  sed -i.bak 's#^LAN_PROBE=.*#LAN_PROBE=#' "$W/slots.env"
  run launch supabase 5
  [ "$status" -eq 3 ]
  grep -q '^destroy 305' "$QM_LOG"
  sed -i.bak 's#^LAN_PROBE=.*#LAN_PROBE=192.0.2.1:22#' "$W/slots.env"
  run launch supabase 5
  [ "$status" -eq 0 ]
  grep -q 'guest exec 305 --timeout 30 -- /usr/bin/timeout 5 bash -c exec 3<>/dev/tcp/192.0.2.1/22' "$QM_LOG"
}

@test "an agent that never answers -> the VM is destroyed and the launch fails (1)" {
  FAKE_AGENT_RC=1 run launch supabase 5
  [ "$status" -eq 1 ]
  grep -q '^destroy 305' "$QM_LOG"
  refute grep -q 'guest exec' "$QM_LOG"
}

@test "clone, set, start and JIT-delivery failures: VM destroyed, exit 1, the runner unit never started" {
  for k in FAKE_CLONE_RC FAKE_SET_RC FAKE_START_RC FAKE_DELIVER_RC; do
    : > "$QM_LOG"
    env "$k=1" bash -c "printf '%s\n' '$JIT_BLOB' | bash '$SLOTS_DIR/launch-pve.sh' supabase 5" > /dev/null 2>&1 && return 1
    grep -q '^destroy 305' "$QM_LOG"
    refute grep -q 'ghr-runner.service' "$QM_LOG"
    [ ! -d "$QMSTATE/305" ]
  done
}

@test "cleanup: a VM that survives stop+destroy is a LEAK error and fails the launch even if the job passed" {
  FAKE_DESTROY_PERSIST=1 run launch supabase 5
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR LEAK: VM 305 still present"* ]]
  [ "$(grep -c '^destroy 305' "$QM_LOG")" -ge 2 ]
}

@test "cleanup: a failing destroy / stop is logged loudly and verified against 'qm status'" {
  FAKE_DESTROY_RC=1 run launch supabase 5
  [ "$status" -eq 1 ]
  [[ "$output" == *"WARN qm destroy 305 failed"* ]]
  [[ "$output" == *"ERROR LEAK"* ]]
  FAKE_STOP_RC=1 FAKE_JOB_RC=4 FAKE_RUN_SLEEP=5 run launch supabase 5
  [ "$status" -eq 4 ]
  [[ "$output" == *"WARN qm stop 305 failed"* ]]
}

@test "cleanup: a hung 'qm stop' is bounded by SUPA_DESTROY_TIMEOUT" {
  start=$(date +%s)
  FAKE_STOP_SLEEP=8 SUPA_DESTROY_TIMEOUT=1 run launch supabase 5
  elapsed=$(( $(date +%s) - start ))
  [ "$status" -eq 0 ]
  [[ "$output" == *"failed or timed out"* ]]
  [ "$elapsed" -lt 8 ]
  grep -q '^destroy 305' "$QM_LOG"
}

@test "sweep: only ghr-supa-<k> VMs inside the VMID range with k outside PVE_SLOTS are destroyed" {
  # 301/302/303 qualify; 304 is named for the configured slot 5; 399 and 310 are out of range; 306 is
  # not ours by name; the golden (300) and its name never match
  FAKE_EXTRA_VMS=$'301 ghr-supa-1\n302 ghr-supa-2\n303 ghr-supa-3\n304 ghr-supa-5\n306 webserver\n310 ghr-supa-4\n399 ghr-supa-7\n250 ghr-supa-6\n307 ghr-supa-golden' \
    run launch supabase 5
  [ "$status" -eq 0 ]
  for v in 301 302 303; do grep -q "^destroy $v " "$QM_LOG"; done
  for v in 304 306 310 399 250 307 300; do refute grep -q -e "^destroy $v " -e "^stop $v " "$QM_LOG"; done
}

@test "an unrelated VM sitting on this slot's VMID is never destroyed: refuse (1)" {
  mkdir -p "$QMSTATE/305"; printf 'important-db' > "$QMSTATE/305/name"; echo running > "$QMSTATE/305/status"
  run launch supabase 5
  [ "$status" -eq 1 ]
  [[ "$output" == *"taken by 'important-db'"* ]]
  refute grep -q -e '^destroy 305' -e '^stop 305' -e '^clone' "$QM_LOG"
  [ -d "$QMSTATE/305" ]
}

@test "a leftover ghr-supa-5 on the slot's VMID is destroyed BEFORE the clone" {
  mkdir -p "$QMSTATE/305"; printf 'ghr-supa-5' > "$QMSTATE/305/name"; echo running > "$QMSTATE/305/status"
  run launch supabase 5
  [ "$status" -eq 0 ]
  d=$(line_of 'destroy 305')
  c=$(line_of 'clone 300 305')
  [ -n "$d" ] && [ -n "$c" ] && [ "$d" -lt "$c" ]
}

@test "pve_destroy refuses the golden and any VMID outside the slot range" {
  source "$SLOTS_DIR/launch-pve.sh"
  ghr_load_config
  PVE_VMID_BASE=300 GOLDEN_VMID=300 WORK="$W"
  : > "$QM_LOG"
  for v in 300 250 310 399 abc; do
    run pve_destroy "$v"
    [ "$status" -eq 1 ]
  done
  [ ! -s "$QM_LOG" ]
}

@test "SIGTERM during the job: the VM is stopped + destroyed and launch exits 143" {
  printf '%s\n' "$JIT_BLOB" > "$W/jit.in"
  FAKE_RUN_SLEEP=30 bash "$SLOTS_DIR/launch-pve.sh" supabase 5 < "$W/jit.in" > "$W/out" 2>&1 &
  pid=$!
  for _ in $(seq 1 50); do grep -q 'ghr-runner.service' "$QM_LOG" && break; sleep 0.2; done
  kill -TERM "$pid"
  rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 143 ]
  grep -q '^stop 305' "$QM_LOG"
  grep -q '^destroy 305' "$QM_LOG"
  [ ! -d "$QMSTATE/305" ]
}

@test "SIGTERM during the clone: no JIT is ever delivered, the VM is destroyed, launch exits 143" {
  printf '%s\n' "$JIT_BLOB" > "$W/jit.in"
  FAKE_CLONE_SLEEP=3 bash "$SLOTS_DIR/launch-pve.sh" supabase 5 < "$W/jit.in" > "$W/out" 2>&1 &
  pid=$!
  for _ in $(seq 1 30); do grep -q '^clone' "$QM_LOG" && break; sleep 0.2; done
  kill -TERM "$pid"
  rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 143 ]
  refute grep -q '/run/ghr/jit' "$QM_LOG"
  grep -q '^destroy 305' "$QM_LOG"
}

# installed form (what install-pve.sh produces): config-owned settings and test overrides in the
# caller's environment must be dropped, not trusted.
@test "installed copy ignores QM, PVE_FW_DIR, timeouts, VMIDs, slots and ipconfigs from the environment" {
  sed 's/^GHR_INSTALLED=0/GHR_INSTALLED=1/' "$SLOTS_DIR/launch-pve.sh" > "$W/installed-launch"
  sed -n '1,/^set -uo pipefail/p' "$W/installed-launch" | sed '$d' > "$W/preamble.sh"
  echo 'echo "[${QM-unset}][${PVE_FW_DIR-unset}][${PVE_SLOTS-unset}][${GOLDEN_VMID-unset}][${PVE_VMID_BASE-unset}][${PVE_IPCONFIG_5-unset}][${LAN_PROBE-unset}][${SUPA_MEM_MB-unset}][${JOB_TIMEOUT_SECS-unset}][${SUPA_DESTROY_TIMEOUT-unset}][${PVE_POLL_SECS-unset}]"' >> "$W/preamble.sh"
  vars="QM=/tmp/evil PVE_FW_DIR=/tmp/fw PVE_SLOTS=1 GOLDEN_VMID=101 PVE_VMID_BASE=100 PVE_IPCONFIG_5=ip=dhcp LAN_PROBE=127.0.0.1:1 SUPA_MEM_MB=999999 JOB_TIMEOUT_SECS=1 SUPA_DESTROY_TIMEOUT=1 PVE_POLL_SECS=0"
  # shellcheck disable=SC2086
  run env $vars bash "$W/preamble.sh"
  [ "$output" = "[unset][unset][unset][unset][unset][unset][unset][unset][unset][unset][unset]" ]
  # control: the repo form keeps them
  sed -n '1,/^set -uo pipefail/p' "$SLOTS_DIR/launch-pve.sh" | sed '$d' > "$W/preamble0.sh"
  echo 'echo "[${QM-unset}][${PVE_SLOTS-unset}]"' >> "$W/preamble0.sh"
  # shellcheck disable=SC2086
  run env $vars bash "$W/preamble0.sh"
  [ "$output" = "[/tmp/evil][1]" ]
}

@test "launch-pve is bash-5 only but must not hardcode org names, LAN addresses or key material" {
  a="lin""ple"; b="gyeol""hada"; c="BEGIN [A-Z ]*PRIV""ATE KEY"; d="192\.168\.[0-9]"; m="min""d2"
  refute grep -niE "$a|$b|$c|$m" "$SLOTS_DIR/launch-pve.sh" "$SLOTS_DIR/install-pve.sh" "$SLOTS_DIR/slot-unit.sh" "$SLOTS_DIR"/lib/pve-*.sh "$SLOTS_DIR"/systemd/* "$SLOTS_DIR/../images/build-supabase-pve.sh" "$SLOTS_DIR"/../images/supabase/*
  # the firewall template legitimately names the private ranges; nothing else may carry a LAN address
  refute grep -nE "$d" "$SLOTS_DIR/launch-pve.sh" "$SLOTS_DIR/install-pve.sh" "$SLOTS_DIR/slot-unit.sh" "$SLOTS_DIR"/systemd/* "$SLOTS_DIR/../images/build-supabase-pve.sh" "$SLOTS_DIR"/../images/supabase/*
}
