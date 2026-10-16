#!/usr/bin/env bats
# Static checks for images/light/Dockerfile and offline tests for images/build-light.sh.
# The image itself is built on the host (needs Docker + network); here we pin the properties that
# make it safe and make setup-node/setup-deno cache hits, by inspecting the Dockerfile text.

load helpers

DOCKERFILE() { echo "$SLOTS_DIR/../images/light/Dockerfile"; }

setup() { slots_setup; }

@test "Dockerfile: base image is pinned by sha256 digest" {
  grep -Eq '^FROM ghcr\.io/actions/actions-runner@sha256:[0-9a-f]{64}$' "$(DOCKERFILE)"
}

@test "Dockerfile: AGENT_TOOLSDIRECTORY is /opt/hostedtoolcache and chowned to uid 1001" {
  grep -q '^ENV AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache' "$(DOCKERFILE)"
  grep -q 'chown -R 1001 "${tc}"' "$(DOCKERFILE)"
}

@test "Dockerfile: .complete markers are created for node and deno in the tool-cache layout" {
  grep -Fq 'touch "${tc}/node/${v}/${TC_ARCH}.complete"' "$(DOCKERFILE)"
  grep -Fq 'touch "${tc}/deno/${dv}/${TC_ARCH}.complete"' "$(DOCKERFILE)"
  grep -Fq 'dest="${tc}/node/${v}/${TC_ARCH}"' "$(DOCKERFILE)"
  grep -Fq 'deno_dest="${tc}/deno/${dv}/${TC_ARCH}"' "$(DOCKERFILE)"
}

@test "Dockerfile: every download is checksum-verified before extraction" {
  # node tarball and deno zip each go through sha256sum -c
  [ "$(grep -c 'sha256sum -c -' "$(DOCKERFILE)")" -ge 3 ]
  # CRITICAL: pinned values in the file; a checksum fetched from the artifact's own origin is not a pin
  refute grep -E 'SHASUMS256\.txt"|\.sha256sum"' "$(DOCKERFILE)"
  grep -Eq '^ARG NODE_SPECS="20\.20\.2\|[0-9a-f]{64} 22\.23\.3\|[0-9a-f]{64} 24\.22\.0\|[0-9a-f]{64}"' "$(DOCKERFILE)"
  grep -Eq '^ARG DENO_SPECS="2\.9\.7\|[0-9a-f]{64} 2\.6\.8\|09a0a800be639986515540ddae2f2752625ed412f63d36c7152c2a72ee78c2d7"' "$(DOCKERFILE)"
  # the verification of the node tarball precedes its extraction
  [ "$(grep -n 'sha256sum -c' "$(DOCKERFILE)" | head -1 | cut -d: -f1)" -lt "$(grep -n 'tar -xJf' "$(DOCKERFILE)" | head -1 | cut -d: -f1)" ]
}

@test "Dockerfile: final USER is numeric 1001; USER 0 only before it" {
  last=$(grep -E '^USER ' "$(DOCKERFILE)" | tail -1)
  [ "$last" = "USER 1001" ]
  refute grep -Eq '^USER [A-Za-z]' "$(DOCKERFILE)"
}

@test "Dockerfile: hosted-parity bits (node symlinks on PATH, gh from the signed apt repo, apt cleaned)" {
  for b in node npm npx corepack; do grep -q "$b" "$(DOCKERFILE)"; done
  grep -q '/usr/local/bin/' "$(DOCKERFILE)"
  grep -q 'signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg' "$(DOCKERFILE)"
  grep -q 'apt-get clean' "$(DOCKERFILE)"
  grep -q 'rm -rf /var/lib/apt/lists' "$(DOCKERFILE)"
  for pkg in git curl jq unzip zip xz-utils zstd python3 python3-venv python3-pip build-essential libatomic1 postgresql-client; do
    grep -qw -e "$pkg" "$(DOCKERFILE)"
  done
}

@test "Dockerfile: default node versions and arm64 arch are build ARGs" {
  grep -q '^ARG NODE_SPECS=' "$(DOCKERFILE)"
  grep -q '^ARG NODE_DEFAULT="22.23.3"' "$(DOCKERFILE)"
  grep -q '^ARG DENO_SPECS=' "$(DOCKERFILE)"
  grep -q '^ARG TC_ARCH="arm64"' "$(DOCKERFILE)"
}

# ── build-light.sh ────────────────────────────────────────────────────────────

# bb — run build-light.sh with stderr dropped so $output is its stdout contract only.
bb() { bash "$SLOTS_DIR/../images/build-light.sh" "$@" 2> /dev/null; }

BUILD_ID="sha256:$(printf 'd%.0s' $(seq 1 64))"

build_shim() {
  LIMA_LOG="$W/lima.log"; LIMA_SEEN="$W/stdin.seen"; : > "$LIMA_LOG"; : > "$LIMA_SEEN"; export LIMA_LOG LIMA_SEEN BUILD_ID
  cat > "$FAKE_BIN/limactl" <<'SHIM'
#!/bin/bash
echo "$*" >> "$LIMA_LOG"
# record anything this call could read from stdin (1 s cap so a bug fails the test, not hangs it)
IFS= read -r -t 1 seen && echo "$seen" >> "$LIMA_SEEN"
case "$*" in
  "list "*) printf '%s' "${FAKE_STATUS-Running}" ;;
  *"docker build"*) echo "build chatter on stdout"; exit "${FAKE_BUILD_RC:-0}" ;;
  *"image inspect"*) echo "${FAKE_ID-$BUILD_ID}" ;;
esac
exit 0
SHIM
  chmod +x "$FAKE_BIN/limactl"
  export LIMACTL="$FAKE_BIN/limactl"
}

@test "build-light: prints exactly one IMAGE_ID line on stdout, tags by UTC date, leaves a running VM running" {
  build_shim
  run bb
  [ "$status" -eq 0 ]
  [ "$output" = "IMAGE_ID=$BUILD_ID" ]
  grep -q "docker build -t ghr/light:$(date -u +%Y%m%d)" "$LIMA_LOG"
  grep -q 'copy -r .*/images/light ghr-pool-golden:' "$LIMA_LOG"
  refute grep -q -e ' stop ' -e '^stop' "$LIMA_LOG"
}

@test "build-light: a stopped instance is started and stopped again" {
  build_shim
  FAKE_STATUS=Stopped run bb myvm
  [ "$status" -eq 0 ]
  grep -q '^start myvm' "$LIMA_LOG"
  grep -q '^stop myvm' "$LIMA_LOG"
}

@test "build-light: build failure -> non-zero, no IMAGE_ID, stopped VM still restored" {
  build_shim
  FAKE_STATUS=Stopped FAKE_BUILD_RC=1 run bb
  [ "$status" -ne 0 ]
  [[ "$output" != *IMAGE_ID* ]]
  grep -q '^stop ghr-pool-golden' "$LIMA_LOG"
}

@test "build-light: a garbled image id or unknown instance fails" {
  build_shim
  FAKE_ID="not-an-id" run bb
  [ "$status" -ne 0 ]
  FAKE_STATUS="" run bb
  [ "$status" -ne 0 ]
  run bash "$SLOTS_DIR/../images/build-light.sh" 'bad name;x'
  [ "$status" -ne 0 ]
}

@test "build-light: no limactl call inherits the caller's stdin" {
  build_shim
  # A writer offers one line on our stdin. A limactl call lacking </dev/null would read it.
  mkfifo "$W/fifo"
  { echo SHOULD-NOT-BE-READ; sleep 3; } > "$W/fifo" 3>&- &
  writer=$!
  run bash -c "bash '$SLOTS_DIR/../images/build-light.sh' < '$W/fifo' 2>/dev/null"
  kill "$writer" 2> /dev/null || true
  [ "$status" -eq 0 ]
  [ ! -s "$W/stdin.seen" ]
}

@test "light Dockerfile: bc, deno 2.6.8 and python 3.11/3.12/3.13 (checksum-pinned, setup.sh layout)" {
  grep -qw 'bc' "$(DOCKERFILE)"
  grep -q '2\.6\.8' "$(DOCKERFILE)"
  for py in 3.11 3.12 3.13; do grep -q "$py\.[0-9]*-[0-9]*|[0-9a-f]\{64\}" "$(DOCKERFILE)"; done
  # each python tarball is verified before extraction, then installed by the release's setup.sh
  grep -q 'echo "${pysha}  ${tmp}/py-${pyver}.tgz" | sha256sum -c -' "$(DOCKERFILE)"
  grep -q 'env -C "${tmp}/py-${pyver}" bash ./setup.sh' "$(DOCKERFILE)"
  grep -q 'Python/${pyver}/${TC_ARCH}.complete' "$(DOCKERFILE)"
}
