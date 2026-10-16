#!/usr/bin/env bats
# Tests for slots/launch.sh (the sudo privilege boundary) and slots/pool.sh.
# limactl is a shim; nothing touches a real VM.

load helpers

JIT_BLOB="SECRETJITBLOB0123456789abcdef=="

setup() {
  slots_setup
  lima_setup
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

@test "the JIT is in no limactl call's environment (light path)" {
  run launch light 1
  [ "$status" -eq 0 ]
  [ -s "$LIMA_ENV" ]
  refute grep -q "$JIT_BLOB" "$LIMA_ENV"
}

@test "the runner's exit code is propagated" {
  FAKE_RUN_RC=7 run launch light 1
  [ "$status" -eq 7 ]
}

@test "image: an option-looking reference (leading '-') is rejected" {
  sed -i.bak "s#^LIGHT_IMAGE=.*#LIGHT_IMAGE=--privileged@sha256:$(printf 'a%.0s' $(seq 1 64))#" "$W/slots.env"
  run launch light 1
  [ "$status" -eq 2 ]
  [ ! -s "$LIMA_LOG" ]
}

@test "image: accepted forms are repo@sha256:<digest> and a bare local image ID sha256:<64hex>" {
  source "$SLOTS_DIR/launch.sh"
  h=$(printf 'b%.0s' $(seq 1 64))
  launch_validate_image "ghcr.io/actions/actions-runner@sha256:$h"
  launch_validate_image "ghr/light@sha256:$h"
  launch_validate_image "sha256:$h"
  for bad in "" "sha256:abc" "sha256:${h}0" "SHA256:$h" "-sha256:$h" "--privileged@sha256:$h" \
      "ghr/light:latest" "ghr/light:2026-10-16" "ghr/light" "ghr/light@sha256:abc" \
      "sha256:$h extra" "x@sha256:$h;id" "-x@sha256:$h" " sha256:$h"; do
    refute launch_validate_image "$bad"
  done
}

@test "a local image ID is passed to docker run unchanged" {
  h=$(printf 'c%.0s' $(seq 1 64))
  sed -i.bak "s#^LIGHT_IMAGE=.*#LIGHT_IMAGE=sha256:$h#" "$W/slots.env"
  run launch light 1
  [ "$status" -eq 0 ]
  grep -q -e "--cpus 2 sha256:$h bash -c" "$LIMA_LOG"
}

@test "no non-piping limactl call inherits stdin: extra bytes behind the JIT are never swallowed" {
  FAKE_POOL_STATUS=Stopped run bash -c "printf '%s\nEXTRA-STDIN\n' '$JIT_BLOB' | bash '$SLOTS_DIR/launch.sh' light 1"
  [ "$status" -eq 0 ]
  [ "$(cat "$LIMA_STDIN")" = "$JIT_BLOB" ]
  [ ! -s "$LIMA_OTHER_STDIN" ]
  grep -q 'start ghr-pool' "$LIMA_LOG"
}

@test "preflight: refuses (exit 3) when the guest can reach the LAN probe; no container started" {
  FAKE_PROBE_RC=0 run launch light 1
  [ "$status" -eq 3 ]
  refute grep -q 'docker run' "$LIMA_LOG"
}

@test "preflight: blocked = rc 1 (refused) or 124 (dropped, timed out)" {
  for rc in 1 124; do
    FAKE_PROBE_RC=$rc run launch light 1
    [ "$status" -eq 0 ]
  done
  grep -q 'dev/tcp/192.0.2.1/22' "$LIMA_LOG"
  grep -q '/usr/bin/timeout 5' "$LIMA_LOG"
}

@test "preflight fails closed on an erroring/garbled probe (127 missing tool, 2 syntax, 126, 255 ssh)" {
  for rc in 2 126 127 255; do
    : > "$LIMA_LOG"
    FAKE_PROBE_RC=$rc run launch light 1
    [ "$status" -eq 3 ]
    refute grep -q 'docker run' "$LIMA_LOG"
  done
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

# ── installed-copy hardening (privilege boundary) ───────────────────────────────

# installed_copy — what install.sh produces: GHR_INSTALLED flipped to 1, lib alongside.
installed_copy() {
  mkdir -p "$W/inst/lib"
  sed 's/^GHR_INSTALLED=0/GHR_INSTALLED=1/' "$SLOTS_DIR/launch.sh" > "$W/inst/launch"
  sed 's/^GHR_INSTALLED=0/GHR_INSTALLED=1/' "$SLOTS_DIR/pool.sh" > "$W/inst/pool"
  cp "$SLOTS_DIR/lib/gh-app.sh" "$W/inst/lib/"
  chmod +x "$W/inst/launch" "$W/inst/pool"
}

@test "repo copy pins PATH first and carries the install marker; installer-only difference is that marker" {
  grep -q '^GHR_INSTALLED=0' "$SLOTS_DIR/launch.sh"
  grep -q '^GHR_INSTALLED=0' "$SLOTS_DIR/pool.sh"
  first=$(grep -n '^PATH=/usr/bin:/bin:/usr/sbin:/sbin$' "$SLOTS_DIR/launch.sh" | head -1 | cut -d: -f1)
  # no executable statement (other than comments/blank) precedes the PATH pin
  [ -z "$(head -n $((first - 1)) "$SLOTS_DIR/launch.sh" | grep -vE '^\s*(#|$)')" ]
}

@test "installed copy ignores caller overrides (LIMACTL, GHR_CONFIG, PATH shims, TMPDIR) and runs nothing from them" {
  installed_copy
  printf '#!/bin/bash\ntouch "%s/RAN-marker-limactl"\n' "$W" > "$W/evil-limactl"
  printf '#!/bin/bash\ntouch "%s/RAN-marker-id"\necho root\n' "$W" > "$FAKE_BIN/id"
  printf '#!/bin/bash\ntouch "%s/RAN-marker-dscl"\n' "$W" > "$FAKE_BIN/dscl"
  chmod +x "$W/evil-limactl" "$FAKE_BIN/id" "$FAKE_BIN/dscl"
  LIMACTL="$W/evil-limactl" POOL_INSTANCE=evil GHR_CONFIG="$W/nonexistent.env" BASH_ENV="$W/evil-env" \
    run bash -c "printf '%s\n' '$JIT_BLOB' | '$W/inst/launch' light 1"
  [ "$status" -ne 0 ]
  [ ! -e "$W/RAN-marker-limactl" ] && [ ! -e "$W/RAN-marker-id" ] && [ ! -e "$W/RAN-marker-dscl" ]
}

@test "installed copy reads config only from the fixed root-owned path (GHR_CONFIG override is dropped)" {
  installed_copy
  run bash -c "printf '%s\n' '$JIT_BLOB' | GHR_CONFIG='$W/nonexistent.env' '$W/inst/launch' light 1 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"/usr/local/etc/ghr/slots.env"* ]]
  [[ "$output" != *"nonexistent.env"* ]]
}

# ── pool.sh lock ──────────────────────────────────────────────────────────────

@test "pool lock: a lock whose owner pid is dead is taken over" {
  ln -s 999999 "$W/pool.lock"
  FAKE_POOL_STATUS=Stopped run bash "$SLOTS_DIR/pool.sh" ensure
  [ "$status" -eq 0 ]
  grep -q 'start ghr-pool' "$LIMA_LOG"
  [ ! -e "$W/pool.lock" ] && [ ! -L "$W/pool.lock" ]
}

@test "pool lock: a garbled owner record is reaped immediately" {
  ln -s "not-a-pid" "$W/pool.lock"
  FAKE_POOL_STATUS=Stopped run bash "$SLOTS_DIR/pool.sh" ensure
  [ "$status" -eq 0 ]
  [ ! -L "$W/pool.lock" ]
}

@test "pool lock: a live owner is respected (wait budget exhausted -> error, nothing started)" {
  ln -s "$$" "$W/pool.lock"
  FAKE_POOL_STATUS=Stopped POOL_LOCK_WAIT=2 run bash "$SLOTS_DIR/pool.sh" ensure
  [ "$status" -eq 1 ]
  refute grep -q 'start ghr-pool' "$LIMA_LOG"
  [ -L "$W/pool.lock" ]
}

@test "pool lock default lives under HOME/.ghr, not /tmp" {
  unset GHR_POOL_LOCK
  FAKE_POOL_STATUS=Stopped run bash "$SLOTS_DIR/pool.sh" ensure
  [ "$status" -eq 0 ]
  [ -d "$HOME/.ghr" ]
}
