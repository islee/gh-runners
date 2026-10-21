#!/usr/bin/env bats
# shellcheck disable=SC2034  # globals consumed by the sourced script under test
# Offline tests for images/build-supabase-pve.sh (Proxmox golden build). `qm`, `pvesm` and `curl` are
# shims (helpers.bash pve_setup); the cloud image is a small fake file whose sha256 is injected through
# IMAGE_SHA256, so the pin comparison itself is exercised.

load helpers

BUILD() { echo "$SLOTS_DIR/../images/build-supabase-pve.sh"; }
IMG() { echo "$SLOTS_DIR/../images/supabase/$1"; }

setup() {
  slots_setup
  FAKE_GOLDEN_MISSING=1 pve_setup
  printf 'fake cloud image\n' > "$W/fake.img"
  if command -v sha256sum > /dev/null 2>&1; then SHA=$(sha256sum "$W/fake.img" | awk '{print $1}'); else SHA=$(shasum -a 256 "$W/fake.img" | awk '{print $1}'); fi
  cat > "$FAKE_BIN/pvesm" <<'SHIM'
#!/bin/bash
echo "pvesm $*" >> "$QM_LOG"
case "$1" in
  status) echo "Name Type Status Total Used Available %"; [ -n "${FAKE_NO_SNIPPETS:-}" ] || echo "local dir active 1 1 1 1%" ;;
  path) echo "$W_SNIPPETS/${2#*:snippets/}" ;;
esac
SHIM
  cat > "$FAKE_BIN/fakecurl" <<'SHIM'
#!/bin/bash
echo "curl $*" >> "$QM_LOG"
out=""; while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
cp "$FAKE_IMG" "$out"
SHIM
  chmod +x "$FAKE_BIN/pvesm" "$FAKE_BIN/fakecurl"
  export W_SNIPPETS="$W/snippets" FAKE_IMG="$W/fake.img" PVESM="$FAKE_BIN/pvesm" CURL="$FAKE_BIN/fakecurl"
  export BUILD_TMP="$W" GHR_BUILD_ALLOW_NONROOT=1 PVE_POLL_SECS=0.1 PVE_AGENT_WAIT_SECS=3 PROVISION_TIMEOUT_SECS=3
  export IMAGE_URL=http://example.invalid/noble.img IMAGE_SHA256="$SHA"
}

bb() { bash "$(BUILD)" "$@" 2> "$W/build.err"; }
line_of() { grep -n -F -e "$1" "$QM_LOG" | head -1 | cut -d: -f1; }

@test "happy path: stdout is exactly the GOLDEN-OK line; create -> import -> resize -> start -> agent -> provision -> shutdown -> template" {
  run bb
  [ "$status" -eq 0 ]
  [ "$output" = "GOLDEN-OK 2.338.0 2.107.0" ]
  c=$(line_of 'create 300 --name ghr-supa-golden')
  i=$(line_of 'set 300 --scsi0 local-lvm:0,import-from=')
  r=$(line_of 'resize 300 scsi0 40G')
  s=$(line_of 'start 300')
  a=$(line_of 'agent 300 ping')
  p=$(line_of 'systemd-run --unit ghr-provision')
  sh=$(line_of 'shutdown 300')
  t=$(line_of 'template 300')
  for v in "$c" "$i" "$r" "$s" "$a" "$p" "$sh" "$t"; do [ -n "$v" ]; done
  [ "$c" -lt "$i" ] && [ "$i" -lt "$r" ] && [ "$r" -lt "$s" ] && [ "$s" -lt "$a" ] && [ "$a" -lt "$p" ] && [ "$p" -lt "$sh" ] && [ "$sh" -lt "$t" ]
  [ -e "$QMSTATE/300/template" ]
}

@test "VM shape: q35, host CPU, agent enabled, virtio-scsi, NIC on the bridge with firewall=1, no balloon, cloud-init drive + ipconfig + nameserver + cicustom" {
  run bb
  [ "$status" -eq 0 ]
  grep -qF -e '--machine q35' "$QM_LOG"
  grep -qF -e '--cpu host' "$QM_LOG"
  grep -qF -e '--agent enabled=1' "$QM_LOG"
  grep -qF -e '--scsihw virtio-scsi-single' "$QM_LOG"
  grep -qF -e '--net0 virtio,bridge=vmbr0,firewall=1' "$QM_LOG"
  grep -qF -e '--balloon 0' "$QM_LOG"
  grep -qF -e '--ide2 local-lvm:cloudinit --ipconfig0 ip=dhcp --nameserver 1.1.1.1 8.8.8.8 --cicustom user=local:snippets/ghr-golden-user.yaml' "$QM_LOG"
}

@test "configuration comes from the environment: VMID, storage, bridge, disk size, ipconfig" {
  GOLDEN_VMID=350 STORAGE=tank BRIDGE=vmbr9 DISK_SIZE=60G IPCONFIG="ip=192.0.2.9/24,gw=192.0.2.1" run bb
  [ "$status" -eq 0 ]
  grep -qF 'create 350 --name ghr-supa-golden' "$QM_LOG"
  grep -qF 'tank:0,import-from=' "$QM_LOG"
  grep -qF 'resize 350 scsi0 60G' "$QM_LOG"
  grep -qF 'bridge=vmbr9,firewall=1' "$QM_LOG"
  grep -qF 'ipconfig0 ip=192.0.2.9/24,gw=192.0.2.1' "$QM_LOG"
  [ -e "$QMSTATE/350/template" ]
}

@test "the image is verified against the pin BEFORE anything is created" {
  IMAGE_SHA256=$(printf 'f%.0s' $(seq 1 64)) run bb
  [ "$status" -ne 0 ]
  [[ "$output" != *GOLDEN-OK* ]]
  grep -q 'checksum does not match the pin' "$W/build.err"
  refute grep -q '^create' "$QM_LOG"
}

@test "the pinned default is the noble amd64 release image checksum from the dated release directory" {
  grep -Eq '^IMAGE_URL="\$\{IMAGE_URL:-https://cloud-images\.ubuntu\.com/releases/24\.04/release-[0-9]{8}/ubuntu-24\.04-server-cloudimg-amd64\.img\}"' "$(BUILD)"
  grep -Eq '^IMAGE_SHA256="\$\{IMAGE_SHA256:-[0-9a-f]{64}\}"' "$(BUILD)"
}

@test "egress firewall file exists before the first boot and is removed again at the end" {
  run bb
  [ "$status" -eq 0 ]
  grep -qx 'policy_in: DROP' "$QMSTATE/300/fw-at-start"
  grep -qF 'OUT DROP -dest 10.0.0.0/8' "$QMSTATE/300/fw-at-start"
  [ ! -e "$PVE_FW_DIR/300.fw" ]
}

@test "provision.sh and the guest runner unit are copied into the guest intact, provisioning runs DETACHED and is polled" {
  run bb
  [ "$status" -eq 0 ]
  cmp "$QMSTATE/.pushed/ghr-provision.sh" "$(IMG provision.sh)" || [ "$(cat "$QMSTATE/.pushed/ghr-provision.sh")" = "$(cat "$(IMG provision.sh)")" ]
  [ "$(cat "$QMSTATE/.pushed/ghr-runner-run")" = "$(cat "$(IMG ghr-runner-run)")" ]
  [ "$(cat "$QMSTATE/.pushed/ghr-runner.service")" = "$(cat "$(IMG ghr-runner.service)")" ]
  grep -q 'systemd-run --unit ghr-provision bash -c bash /root/ghr-provision.sh > /var/log/ghr-provision.log' "$QM_LOG"
  grep -q 'cat /var/lib/ghr-provision.rc' "$QM_LOG"
  # the long step is never a synchronous guest exec of provision.sh itself
  refute grep -E 'guest exec 300 .*-- bash /root/ghr-provision.sh' "$QM_LOG"
}

@test "clones get a clean machine-id: cloud-init clean --machine-id runs before the shutdown; clones switch to the no-op user-data" {
  run bb
  [ "$status" -eq 0 ]
  c=$(line_of 'cloud-init clean --logs --machine-id')
  s=$(line_of 'shutdown 300')
  u=$(line_of 'set 300 --cicustom user=local:snippets/ghr-clone-user.yaml')
  t=$(line_of 'template 300')
  [ "$c" -lt "$s" ] && [ "$s" -lt "$u" ] && [ "$u" -lt "$t" ]
  grep -q 'qemu-guest-agent' "$W/snippets/ghr-golden-user.yaml"
  refute grep -q 'qemu-guest-agent\|package' "$W/snippets/ghr-clone-user.yaml"
}

@test "provisioning failure: non-zero, no GOLDEN-OK, the partial golden is destroyed" {
  FAKE_PROVISION_RC=1 run bb
  [ "$status" -ne 0 ]
  [[ "$output" != *GOLDEN-OK* ]]
  [ ! -d "$QMSTATE/300" ]
  [ ! -e "$PVE_FW_DIR/300.fw" ]
  grep -q '^destroy 300' "$QM_LOG"
}

@test "a missing or garbled PROVISION-OK line fails the build and removes the golden" {
  FAKE_PROVISION_OUT="all done" run bb
  [ "$status" -ne 0 ]
  [ ! -d "$QMSTATE/300" ]
  FAKE_PROVISION_OUT="PROVISION-OK 1.0;rm 2.0" run bb
  [ "$status" -ne 0 ]
  [ ! -d "$QMSTATE/300" ]
}

@test "provisioning that never finishes is bounded by PROVISION_TIMEOUT_SECS and cleaned up" {
  FAKE_PROVISION_RC=none PROVISION_TIMEOUT_SECS=1 run bb
  [ "$status" -ne 0 ]
  [ ! -d "$QMSTATE/300" ]
}

@test "an agent that never answers fails the build and removes the golden" {
  FAKE_AGENT_RC=1 PVE_AGENT_WAIT_SECS=1 run bb
  [ "$status" -ne 0 ]
  [ ! -d "$QMSTATE/300" ]
}

@test "an existing golden is refused without --rebuild (and left alone); --rebuild destroys it first" {
  FAKE_GOLDEN_MISSING="" pve_setup
  run bb
  [ "$status" -ne 0 ]
  refute grep -q -e '^create' -e '^destroy' -e '^stop' "$QM_LOG"
  [ -e "$QMSTATE/300/template" ]
  run bb --rebuild
  [ "$status" -eq 0 ]
  d=$(line_of 'destroy 300')
  c=$(line_of 'create 300')
  [ "$d" -lt "$c" ]
}

@test "a VMID that belongs to some other VM is never destroyed, not even with --rebuild" {
  mkdir -p "$QMSTATE/300"; printf 'important-db' > "$QMSTATE/300/name"; echo running > "$QMSTATE/300/status"
  run bb --rebuild
  [ "$status" -ne 0 ]
  refute grep -q -e '^destroy' -e '^stop' -e '^create' "$QM_LOG"
  [ -d "$QMSTATE/300" ]
}

@test "a failure BEFORE the VM exists (bad storage content type) destroys nothing" {
  FAKE_NO_SNIPPETS=1 run bb
  [ "$status" -ne 0 ]
  grep -q "no 'snippets' content type" "$W/build.err"
  refute grep -q -e '^create' -e '^destroy' "$QM_LOG"
}

@test "bad flags and malformed settings are rejected before any qm call" {
  run bash "$(BUILD)" --nope
  [ "$status" -eq 2 ]
  for bad in "DISK_SIZE=40" "GOLDEN_VMID=30" "IPCONFIG=ip=1.2.3.4;id" "PVE_NAMESERVER=1.1.1.1;id" "STORAGE=a;b" "BRIDGE=vmbr0 x"; do
    env "$bad" bash "$(BUILD)" > /dev/null 2>&1 && return 1
  done
  [ ! -s "$QM_LOG" ]
}

@test "no qm call inherits stdin: bytes on the caller's stdin are never swallowed" {
  run bash -c "printf 'SHOULD-NOT-BE-READ\n' | bash '$(BUILD)' 2>/dev/null"
  [ "$status" -eq 0 ]
  [ ! -s "$QM_OTHER_STDIN" ]
  refute grep -q 'SHOULD-NOT-BE-READ' "$QM_STDIN"
}

@test "refuses to run as non-root unless the test bypass is set" {
  [ "$(id -u)" -ne 0 ] || skip "root"
  GHR_BUILD_ALLOW_NONROOT="" run bash "$(BUILD)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must run as root"* ]]
}
