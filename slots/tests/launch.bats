#!/usr/bin/env bats
# Tests for slots/launch.sh (the sudo privilege boundary) and slots/pool.sh.
# limactl is a shim; nothing touches a real VM.

load helpers

JIT_BLOB="SECRETJITBLOB0123456789abcdef=="

setup() {
  slots_setup
  LIMA_LOG="$W/lima.log"
  LIMA_STDIN="$W/lima.stdin"
  : > "$LIMA_LOG"
  export LIMA_LOG LIMA_STDIN GHR_POOL_LOCK="$W/pool.lock"
  cat > "$FAKE_BIN/limactl" <<'SHIM'
#!/bin/bash
echo "$*" >> "$LIMA_LOG"
case "$*" in
  "list "*) printf '%s' "${FAKE_POOL_STATUS-Running}" ;;
  *dev/tcp*) exit "${FAKE_PROBE_RC:-1}" ;;
  *"docker run"*) cat > "$LIMA_STDIN"; sleep "${FAKE_RUN_SLEEP:-0}"; exit "${FAKE_RUN_RC:-0}" ;;
  *) exit 0 ;;
esac
SHIM
  chmod +x "$FAKE_BIN/limactl"
  export LIMACTL="$FAKE_BIN/limactl"
}

launch() { printf '%s\n' "$JIT_BLOB" | bash "$SLOTS_DIR/launch.sh" "$@"; }

@test "arg validation: bad class / slot numbers / argc are refused before any VM call" {
  for args in "android 1" "light 0" "light 7" "light 4" "light -1" "light 1;id" "light 01x" "light" "light 1 2" ""; do
    # shellcheck disable=SC2086
    run launch $args
    [ "$status" -eq 2 ]
  done
  [ ! -s "$LIMA_LOG" ]
}

@test "stdin must look like a JIT config" {
  run bash -c "printf '' | bash '$SLOTS_DIR/launch.sh' light 1"
  [ "$status" -eq 2 ]
  run bash -c "printf 'not a jit; rm -rf /\n' | bash '$SLOTS_DIR/launch.sh' light 1"
  [ "$status" -eq 2 ]
  [ ! -s "$LIMA_LOG" ]
}

@test "image must be pinned by sha256 digest" {
  sed -i.bak 's#^LIGHT_IMAGE=.*#LIGHT_IMAGE=ghcr.io/actions/actions-runner:latest#' "$W/slots.env"
  run launch light 1
  [ "$status" -eq 2 ]
  [ ! -s "$LIMA_LOG" ]
}

@test "happy path: JIT goes to the container on stdin and NEVER into any argv" {
  run launch light 2
  [ "$status" -eq 0 ]
  [ "$(cat "$LIMA_STDIN")" = "$JIT_BLOB" ]
  refute grep -q "$JIT_BLOB" "$LIMA_LOG"
  refute grep -q "$JIT_BLOB" "$CURL_ARGV_LOG"
  grep -q 'docker run --rm -i --name ghr-light-2 --memory 2g --cpus 2 ghcr.io/actions/actions-runner@sha256:' "$LIMA_LOG"
  grep -q 'read -r J; exec ./run.sh --jitconfig "\$J"' "$LIMA_LOG"
}

@test "the runner's exit code is propagated" {
  FAKE_RUN_RC=7 run launch light 1
  [ "$status" -eq 7 ]
}

@test "preflight: refuses (exit 3) when the guest can reach the LAN probe; no container started" {
  FAKE_PROBE_RC=0 run launch light 1
  [ "$status" -eq 3 ]
  refute grep -q 'docker run' "$LIMA_LOG"
}

@test "preflight: passes when the LAN probe is blocked" {
  FAKE_PROBE_RC=1 run launch light 1
  [ "$status" -eq 0 ]
  grep -q 'dev/tcp/192.0.2.1/22' "$LIMA_LOG"
}

@test "preflight fails closed when LAN_PROBE is unset or malformed" {
  sed -i.bak 's#^LAN_PROBE=.*#LAN_PROBE=#' "$W/slots.env"
  run launch light 1
  [ "$status" -eq 3 ]
  sed -i.bak 's#^LAN_PROBE=.*#LAN_PROBE=1.2.3.4;reboot:22#' "$W/slots.env"
  run launch light 1
  [ "$status" -eq 3 ]
  refute grep -q 'docker run' "$LIMA_LOG"
}

@test "job timeout -> exit 124 and the container is force-removed" {
  FAKE_RUN_SLEEP=3 JOB_TIMEOUT_SECS=1 run launch light 1
  [ "$status" -eq 124 ]
  grep -q 'docker rm -f ghr-light-1' "$LIMA_LOG"
}

# ── pool.sh ───────────────────────────────────────────────────────────────────

@test "pool ensure: Running is a no-op" {
  FAKE_POOL_STATUS=Running run bash "$SLOTS_DIR/pool.sh" ensure
  [ "$status" -eq 0 ]
  refute grep -q -e 'start' -e 'clone' "$LIMA_LOG"
}

@test "pool ensure: Stopped -> start" {
  FAKE_POOL_STATUS=Stopped run bash "$SLOTS_DIR/pool.sh" ensure
  [ "$status" -eq 0 ]
  grep -q 'start ghr-pool --tty=false' "$LIMA_LOG"
  refute grep -q 'clone' "$LIMA_LOG"
}

@test "pool ensure: missing -> clone from golden then start" {
  FAKE_POOL_STATUS="" run bash "$SLOTS_DIR/pool.sh" ensure
  [ "$status" -eq 0 ]
  grep -q 'clone ghr-pool-golden ghr-pool --tty=false' "$LIMA_LOG"
  grep -q 'start ghr-pool --tty=false' "$LIMA_LOG"
}

@test "pool ensure: unexpected state is an error; rebuild is a stub (64); usage error (2)" {
  FAKE_POOL_STATUS=Broken run bash "$SLOTS_DIR/pool.sh" ensure
  [ "$status" -eq 1 ]
  run bash "$SLOTS_DIR/pool.sh" rebuild
  [ "$status" -eq 64 ]
  run bash "$SLOTS_DIR/pool.sh" nonsense
  [ "$status" -eq 2 ]
}
