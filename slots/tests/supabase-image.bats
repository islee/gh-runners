#!/usr/bin/env bats
# Static checks for images/supabase/{provision.sh,lima.yaml} and offline tests for
# images/build-supabase.sh. The golden itself is built on the host (needs Lima + network); here we
# pin the properties that make it trustworthy and make the job-time caches hit.

load helpers

IMG() { echo "$SLOTS_DIR/../images/supabase/$1"; }
BUILD() { echo "$SLOTS_DIR/../images/build-supabase.sh"; }

setup() { slots_setup; }

# ── provision.sh ──────────────────────────────────────────────────────────────

@test "provision: runner is the pinned linux-arm64 release, checksum-verified before extraction" {
  grep -Eq '^RUNNER_VERSION="\$\{RUNNER_VERSION:-2\.338\.0\}"' "$(IMG provision.sh)"
  grep -Eq '^RUNNER_SHA256="\$\{RUNNER_SHA256:-[0-9a-f]{64}\}"' "$(IMG provision.sh)"
  grep -q 'actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz' "$(IMG provision.sh)"
  grep -q 'fetch ".*${tarball}" "$TMP/$tarball" "$RUNNER_SHA256"' "$(IMG provision.sh)"
  # fetch() verifies with sha256sum -c and dies on mismatch
  grep -q 'sha256sum -c -' "$(IMG provision.sh)"
  grep -q 'checksum mismatch' "$(IMG provision.sh)"
  # the runner lives in /opt/actions-runner owned by runner
  grep -q 'RUNNER_HOME=/opt/actions-runner' "$(IMG provision.sh)"
  grep -q 'chown -R runner:runner "$RUNNER_HOME"' "$(IMG provision.sh)"
}

@test "provision: user runner uid 1001, docker group, validated passwordless sudo" {
  grep -q 'useradd -m -u 1001 -s /bin/bash runner' "$(IMG provision.sh)"
  grep -q 'usermod -aG docker runner' "$(IMG provision.sh)"
  grep -q "runner ALL=(ALL) NOPASSWD:ALL" "$(IMG provision.sh)"
  grep -q 'visudo -cf' "$(IMG provision.sh)"
}

@test "provision: supabase CLI pinned to 2.107.0 with a sha256, in the tool cache with a .complete marker" {
  grep -Eq '^CLI_VERSION="\$\{CLI_VERSION:-2\.107\.0\}"' "$(IMG provision.sh)"
  grep -Eq '^CLI_SHA256="\$\{CLI_SHA256:-[0-9a-f]{64}\}"' "$(IMG provision.sh)"
  grep -q 'supabase_${CLI_VERSION}_linux_arm64.tar.gz" "$TMP/supabase.tgz" "$CLI_SHA256"' "$(IMG provision.sh)"
  grep -q 'touch "$TC/supabase/$CLI_VERSION/$TC_ARCH.complete"' "$(IMG provision.sh)"
}

@test "provision: .complete markers for node, deno, python; node checked against SHASUMS, deno against .sha256sum" {
  grep -q 'touch "$TC/node/$v/$TC_ARCH.complete"' "$(IMG provision.sh)"
  grep -q 'touch "$TC/deno/$v/$TC_ARCH.complete"' "$(IMG provision.sh)"
  grep -q 'Python/$ver/$TC_ARCH.complete' "$(IMG provision.sh)"
  grep -q 'SHASUMS256' "$(IMG provision.sh)"
  grep -q '\.sha256sum' "$(IMG provision.sh)"
  grep -Eq '^DENO_VERSIONS="\$\{DENO_VERSIONS:-2\.6\.8 ' "$(IMG provision.sh)"
  grep -Eq '^NODE_VERSIONS="\$\{NODE_VERSIONS:-20\.20\.2 22\.23\.3 24\.22\.0\}"' "$(IMG provision.sh)"
  for py in 3.11 3.12 3.13; do grep -Eq "$py\.[0-9]+-[0-9]+\|[0-9a-f]{64}" "$(IMG provision.sh)"; done
  grep -q 'ln -sf "$TC/node/$NODE_DEFAULT/$TC_ARCH/bin/$b" "/usr/local/bin/$b"' "$(IMG provision.sh)"
}

@test "provision: FULL stack pre-pull (init + untrimmed start + stop --no-backup) under the registry setup-cli selects" {
  f="$(IMG provision.sh)"
  grep -q '"$cli" init' "$f"
  grep -q '"$cli" start' "$f"
  grep -q '"$cli" stop --no-backup' "$f"
  # untrimmed: no -x exclusions anywhere on the start line
  refute grep -E '"\$cli" start.*( -x |--exclude)' "$f"
  grep -q 'SUPABASE_INTERNAL_IMAGE_REGISTRY' "$f"
  grep -Eq '^PREPULL_REGISTRIES="\$\{PREPULL_REGISTRIES:-ghcr\.io\}"' "$f"
  # the images must be verifiable afterwards
  grep -q 'docker image ls' "$f"
  grep -q 'supabase/postgres' "$f"
  grep -q 'supabase/studio' "$f"
  # and the pre-pull must happen before the final cleanup
  [ "$(grep -n '^prepull$' "$f" | cut -d: -f1)" -lt "$(grep -n '^cleanup$' "$f" | cut -d: -f1)" ]
}

@test "provision: docker apt key fingerprint pinned; apt auto-upgrades off; apt cleaned at the end" {
  f="$(IMG provision.sh)"
  grep -Eq '^DOCKER_KEY_FPR="\$\{DOCKER_KEY_FPR:-[0-9A-F]{40}\}"' "$f"
  grep -q 'does not match the pin' "$f"
  grep -q 'unattended-upgrades' "$f"
  grep -q 'apt-get clean' "$f"
  grep -q 'rm -rf /var/lib/apt/lists' "$f"
  for pkg in git curl jq unzip zip xz-utils zstd bc python3 python3-venv python3-pip build-essential libatomic1 postgresql-client docker-ce; do
    grep -qw -e "$pkg" "$f"
  done
}

@test "provision: nothing is piped from the network into a shell" {
  refute grep -E 'curl[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh' "$(IMG provision.sh)"
  # ends with the machine-readable line build-supabase.sh parses
  tail -1 "$(IMG provision.sh)" | grep -q 'echo "PROVISION-OK $RUNNER_VERSION $CLI_VERSION"'
}

# ── lima.yaml ─────────────────────────────────────────────────────────────────

@test "lima.yaml: vz, aarch64 Ubuntu 24.04, 4 CPU / 4GiB / 40GiB, NO mounts, every guest port ignored" {
  f="$(IMG lima.yaml)"
  grep -q '^vmType: "vz"' "$f"
  grep -q '^arch: "aarch64"' "$f"
  grep -q '^cpus: 4' "$f"
  grep -q '^memory: "4GiB"' "$f"
  grep -q '^disk: "40GiB"' "$f"
  grep -q 'releases/24.04/.*arm64' "$f"
  grep -q '^mounts: \[\]' "$f"
  python3 - "$f" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
# both tcp (default) and udp rules ignore the full range
blocks = re.findall(r"- guestPortRange: \[1, 65535\]\n(?:    proto: udp\n)?    ignore: true", t)
assert len(blocks) == 2, blocks
PY
}

@test "images/ hygiene: no org names, LAN addresses or key material" {
  a="lin""ple"; b="gyeol""hada"; c="BEGIN [A-Z ]*PRIV""ATE KEY"; d="192\.168\."
  refute grep -rniE "$a|$b|$c|$d" "$SLOTS_DIR/../images"
}

# ── build-supabase.sh ─────────────────────────────────────────────────────────

# Stateful limactl shim: tracks the golden's status in a file so create/start/stop/delete behave.
build_shim() {
  LIMA_LOG="$W/lima.log"; STATE="$W/golden.state"; PROV_IN="$W/provision.stdin"; LIMA_SEEN="$W/stdin.seen"
  : > "$LIMA_LOG"; : > "$LIMA_SEEN"
  export LIMA_LOG STATE PROV_IN LIMA_SEEN
  cat > "$FAKE_BIN/limactl" <<'SHIM'
#!/bin/bash
echo "$*" >> "$LIMA_LOG"
case "$*" in
  "shell "*) cat > "$PROV_IN" ;;
  *) IFS= read -r -t 1 seen && echo "$seen" >> "$LIMA_SEEN" ;;
esac
case "$*" in
  "list "*) [ -f "$STATE" ] && printf '%s' "$(cat "$STATE")"; exit 0 ;;
  "create "*) echo Stopped > "$STATE" ;;
  "start "*) echo Running > "$STATE" ;;
  "stop "*) [ -n "${FAKE_STOP_STICKY:-}" ] || echo Stopped > "$STATE" ;;
  "delete "*) rm -f "$STATE" ;;
  "shell "*) printf '%s\n' "${FAKE_PROVISION_OUT-PROVISION-OK 2.338.0 2.107.0}"; exit "${FAKE_PROVISION_RC:-0}" ;;
esac
exit 0
SHIM
  chmod +x "$FAKE_BIN/limactl"
  export LIMACTL="$FAKE_BIN/limactl"
}

bb() { bash "$(BUILD)" "$@" 2> /dev/null; }

@test "build-supabase: create -> start -> provision (script on stdin) -> stop; stdout is exactly the GOLDEN-OK line" {
  build_shim
  run bb
  [ "$status" -eq 0 ]
  [ "$output" = "GOLDEN-OK 2.338.0 2.107.0" ]
  c=$(grep -n '^create --name ghr-supa-golden' "$LIMA_LOG" | head -1 | cut -d: -f1)
  s=$(grep -n '^start ghr-supa-golden' "$LIMA_LOG" | head -1 | cut -d: -f1)
  p=$(grep -n '^shell ghr-supa-golden -- sudo bash -s' "$LIMA_LOG" | head -1 | cut -d: -f1)
  x=$(grep -n '^stop ghr-supa-golden' "$LIMA_LOG" | tail -1 | cut -d: -f1)
  [ "$c" -lt "$s" ] && [ "$s" -lt "$p" ] && [ "$p" -lt "$x" ]
  grep -q 'images/supabase/lima.yaml' "$LIMA_LOG"
  cmp "$PROV_IN" "$(IMG provision.sh)"
  [ "$(cat "$STATE")" = "Stopped" ]
}

@test "build-supabase: an existing golden is refused without --rebuild; --rebuild deletes it first" {
  build_shim
  echo Stopped > "$STATE"
  run bb
  [ "$status" -ne 0 ]
  refute grep -q '^create' "$LIMA_LOG"
  run bb --rebuild
  [ "$status" -eq 0 ]
  d=$(grep -n '^delete -f ghr-supa-golden' "$LIMA_LOG" | head -1 | cut -d: -f1)
  c=$(grep -n '^create ' "$LIMA_LOG" | head -1 | cut -d: -f1)
  [ "$d" -lt "$c" ]
}

@test "build-supabase: provisioning failure -> non-zero, no GOLDEN-OK, the partial golden is deleted" {
  build_shim
  FAKE_PROVISION_RC=1 run bb
  [ "$status" -ne 0 ]
  [[ "$output" != *GOLDEN-OK* ]]
  [ ! -e "$STATE" ]
}

@test "build-supabase: missing/garbled PROVISION-OK or a golden that is not Stopped afterwards fails and is removed" {
  build_shim
  FAKE_PROVISION_OUT="all done" run bb
  [ "$status" -ne 0 ]
  [ ! -e "$STATE" ]
  FAKE_PROVISION_OUT="PROVISION-OK 1.0;rm 2.0" run bb
  [ "$status" -ne 0 ]
  FAKE_STOP_STICKY=1 run bb
  [ "$status" -ne 0 ]
  [[ "$output" != *GOLDEN-OK* ]]
}

@test "build-supabase: bad flags rejected; no limactl call except the provision pipe inherits stdin" {
  build_shim
  run bash "$(BUILD)" --nope
  [ "$status" -eq 2 ]
  mkfifo "$W/fifo"
  { echo SHOULD-NOT-BE-READ; sleep 3; } > "$W/fifo" 3>&- &
  writer=$!
  run bash -c "bash '$(BUILD)' < '$W/fifo' 2>/dev/null"
  kill "$writer" 2> /dev/null || true
  [ "$status" -eq 0 ]
  [ ! -s "$LIMA_SEEN" ]
}
