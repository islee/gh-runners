#!/usr/bin/env bats
# shellcheck disable=SC2034  # globals consumed by the sourced script under test
# Offline tests for images/build-ios.sh (ios golden build). `tart` is a shim (helpers.bash tart_setup);
# provision.sh itself runs inside a macOS guest and is covered by shellcheck only.

load helpers

BASE="ghcr.io/example/macos-xcode@sha256:$(printf 'b%.0s' $(seq 1 64))"
RSHA="$(printf 'c%.0s' $(seq 1 64))"
BUILD="$SLOTS_DIR/../images/build-ios.sh"

setup() {
  slots_setup
  tart_setup
  export RUNNER_VERSION=2.999.0 RUNNER_SHA256="$RSHA" IOS_BUILD_BOOT_POLL=1
}

line_of() { grep -n -F -e "$1" "$TART_LOG" | head -1 | cut -d: -f1; }

@test "refuses a base image without a digest, a malformed digest, and missing/invalid runner pins -- before any tart call" {
  for base in "ghcr.io/example/macos-xcode:latest" "ghcr.io/example/macos-xcode" "ghcr.io/example/macos-xcode@sha256:abc" "-evil@sha256:$(printf 'b%.0s' $(seq 1 64))"; do
    run bash "$BUILD" "$base"
    [ "$status" -eq 2 ]
  done
  RUNNER_VERSION="" run bash "$BUILD" "$BASE"
  [ "$status" -eq 2 ]
  RUNNER_VERSION="latest" run bash "$BUILD" "$BASE"
  [ "$status" -eq 2 ]
  RUNNER_SHA256="" run bash "$BUILD" "$BASE"
  [ "$status" -eq 2 ]
  RUNNER_SHA256="abc" run bash "$BUILD" "$BASE"
  [ "$status" -eq 2 ]
  run bash "$BUILD"
  [ "$status" -eq 2 ]
  [ ! -s "$TART_LOG" ]
}

@test "happy path: clone -> set -> run -> agent -> provision -> stop -> rename; stdout is exactly one GOLDEN-OK line" {
  FAKE_TART_GOLDEN_STATE=none tart_setup
  out=$(bash "$BUILD" "$BASE" 2> "$W/err")
  [ "$out" = "GOLDEN-OK 2.999.0 26.0" ]
  c=$(line_of "clone $BASE ghr-ios-build")
  s=$(line_of 'set ghr-ios-build --cpu 4 --memory 8192')
  r=$(line_of 'run ghr-ios-build --no-graphics --no-audio')
  a=$(line_of 'exec ghr-ios-build /usr/bin/true')
  p=$(line_of "exec ghr-ios-build /bin/bash -c set -o pipefail; /bin/bash /tmp/ghr-provision.sh \"\$1\" \"\$2\" 2>&1 | head -c \"\$3\" _ 2.999.0 $RSHA 20000000")
  x=$(line_of 'stop ghr-ios-build')
  m=$(line_of 'rename ghr-ios-build ghr-ios-golden')
  [ -n "$c" ] && [ -n "$s" ] && [ -n "$r" ] && [ -n "$a" ] && [ -n "$p" ] && [ -n "$x" ] && [ -n "$m" ]
  [ "$c" -lt "$s" ] && [ "$s" -lt "$r" ] && [ "$r" -lt "$a" ] && [ "$a" -lt "$p" ] && [ "$p" -lt "$x" ] && [ "$x" -lt "$m" ]
  [ "$(cat "$TARTSTATE/vms/ghr-ios-golden")" = stopped ]
  [ ! -e "$TARTSTATE/vms/ghr-ios-build" ]
  # the provision script travelled over the agent's stdin into a file, then ran with no stdin
  grep -q 'provision.sh <runner-version> <runner-sha256>' "$TART_OTHER_STDIN"
  grep -q '^TART_NO_AUTO_PRUNE=1$' "$TART_ENV"
  grep -q 'inputs: base=' "$W/err"
  grep -q 'golden disk: 50 GB' "$W/err"
}

@test "an existing golden is replaced only AFTER the new one is stopped; the old one is deleted at the end" {
  out=$(bash "$BUILD" "$BASE" 2> /dev/null)
  [ "$out" = "GOLDEN-OK 2.999.0 26.0" ]
  x=$(line_of 'stop ghr-ios-build')
  a=$(line_of 'rename ghr-ios-golden ghr-ios-golden-prev')
  b=$(line_of 'rename ghr-ios-build ghr-ios-golden')
  d=$(line_of 'delete ghr-ios-golden-prev')
  [ "$x" -lt "$a" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$d" ]
  [ -e "$TARTSTATE/vms/ghr-ios-golden" ] && [ ! -e "$TARTSTATE/vms/ghr-ios-golden-prev" ] && [ ! -e "$TARTSTATE/vms/ghr-ios-build" ]
}

@test "provisioning failure: the build VM is deleted, the OLD golden is never touched, exit non-zero, no GOLDEN-OK" {
  FAKE_PROVISION_RC=1 run bash "$BUILD" "$BASE"
  [ "$status" -ne 0 ]
  refute grep -q 'GOLDEN-OK' <<< "$output"
  [ ! -e "$TARTSTATE/vms/ghr-ios-build" ]
  [ "$(cat "$TARTSTATE/vms/ghr-ios-golden")" = stopped ]
  refute grep -q -e '^rename' -e '^delete ghr-ios-golden' -e '^stop ghr-ios-golden' "$TART_LOG"
}

@test "no PROVISION-OK line in the output is a failure" {
  FAKE_PROVISION_OUT="all done" run bash "$BUILD" "$BASE"
  [ "$status" -ne 0 ]
  [ ! -e "$TARTSTATE/vms/ghr-ios-build" ]
  refute grep -q '^rename' "$TART_LOG"
}

@test "a runner version other than the pinned one is a failure" {
  FAKE_PROVISION_OUT="PROVISION-OK 2.111.0 26.0" run bash "$BUILD" "$BASE"
  [ "$status" -ne 0 ]
  refute grep -q '^rename' "$TART_LOG"
}

@test "boot timeout: the build VM is deleted and the old golden survives" {
  FAKE_AGENT_NEVER=1 IOS_BUILD_BOOT_TIMEOUT=2 run bash "$BUILD" "$BASE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"guest agent not up after 2s"* ]]
  [ ! -e "$TARTSTATE/vms/ghr-ios-build" ]
  [ -e "$TARTSTATE/vms/ghr-ios-golden" ]
}

@test "a failure between the two renames restores the previous golden" {
  FAKE_RENAME_FAIL_TO=ghr-ios-golden run bash "$BUILD" "$BASE"
  [ "$status" -ne 0 ]
  grep -q '^rename ghr-ios-golden-prev ghr-ios-golden' "$TART_LOG"
  [ -e "$TARTSTATE/vms/ghr-ios-golden" ] && [ ! -e "$TARTSTATE/vms/ghr-ios-golden-prev" ] && [ ! -e "$TARTSTATE/vms/ghr-ios-build" ]
}

@test "a running golden, or a leftover -prev VM, is refused before anything is cloned" {
  echo running > "$TARTSTATE/vms/ghr-ios-golden"
  run bash "$BUILD" "$BASE"
  [ "$status" -ne 0 ]
  echo stopped > "$TARTSTATE/vms/ghr-ios-golden"
  echo stopped > "$TARTSTATE/vms/ghr-ios-golden-prev"
  run bash "$BUILD" "$BASE"
  [ "$status" -ne 0 ]
  refute grep -q '^clone' "$TART_LOG"
}

@test "a leftover build VM is removed first" {
  echo stopped > "$TARTSTATE/vms/ghr-ios-build"
  run bash "$BUILD" "$BASE"
  [ "$status" -eq 0 ]
  d=$(line_of 'delete ghr-ios-build')
  c=$(line_of "clone $BASE")
  [ "$d" -lt "$c" ]
}

@test "IOS_DISK_GB adds a disk resize; IOS_GOLDEN renames the target" {
  FAKE_TART_GOLDEN_STATE=none tart_setup
  IOS_DISK_GB=120 IOS_GOLDEN=ghr-ios-other run bash "$BUILD" "$BASE"
  [ "$status" -eq 0 ]
  grep -q '^set ghr-ios-build --disk-size 120' "$TART_LOG"
  [ -e "$TARTSTATE/vms/ghr-ios-other" ]
}

@test "provisioning output is capped inside the guest; a capped (SIGPIPE) run fails the build and keeps the old golden" {
  # 141 = the runaway writer killed by SIGPIPE once head -c stopped reading (pipefail surfaces it)
  IOS_PROVISION_OUT_MAX=4096 FAKE_PROVISION_RC=141 run bash "$BUILD" "$BASE"
  [ "$status" -ne 0 ]
  grep -q 'head -c "\$3" _ 2.999.0 [0-9a-f]* 4096$' "$TART_LOG"
  refute grep -q '^GOLDEN-OK' <<< "$output"
  IOS_PROVISION_OUT_MAX=12 run bash "$BUILD" "$BASE"
  [ "$status" -eq 2 ]
}
