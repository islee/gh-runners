#!/usr/bin/env bats
# Tests for slots/install.sh (--dry-run / --uninstall planning, plist rendering) and repo hygiene
# of the slots/ tree. Never runs a real install: needs no root and touches nothing.

load helpers

setup() {
  slots_setup
  export GHR_LIBEXEC="$W/libexec" GHR_ETC="$W/etc" GHR_STATE_ROOT="$W/varghr" GHR_LOGDIR="$W/log" \
    GHR_DAEMON_DIR="$W/daemons" GHR_SUDOERS="$W/sudoers-ghr"
}

@test "non-dry-run without root is refused" {
  [ "$(id -u)" -ne 0 ] || skip "running as root"
  run bash "$SLOTS_DIR/install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must run as root"* ]]
}

@test "--dry-run prints the full plan, exits 0 and writes nothing" {
  run bash "$SLOTS_DIR/install.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY: sysadminctl -addUser _ghrctl"* ]]
  [[ "$output" == *"DRY: sysadminctl -addUser _ghrstate"* ]]
  [[ "$output" == *"_ghrctl ALL=(ghr) NOPASSWD: $W/libexec/launch"* ]]
  [[ "$output" == *"visudo -cf"* ]]
  [[ "$output" == *"launchctl bootstrap system $W/daemons/dev.ghr.slot.light-6.plist"* ]]
  [[ "$output" == *"launchctl bootstrap system $W/daemons/dev.ghr.heartbeat.plist"* ]]
  [[ "$output" == *"launchctl bootstrap system $W/daemons/dev.ghr.pool.plist"* ]]
  [[ "$output" == *"install -m 0755 -o root -g wheel $SLOTS_DIR/launch.sh $W/libexec/launch"* ]]
  # nothing under the target roots, no sudoers file
  [ ! -e "$W/libexec" ] && [ ! -e "$W/etc" ] && [ ! -e "$W/daemons" ] && [ ! -e "$W/sudoers-ghr" ] && [ ! -e "$W/varghr" ]
}

@test "--dry-run honours LIGHT_SLOTS from --config (and caps at 6)" {
  printf 'LIGHT_SLOTS=2\n' > "$W/cfg.env"
  run bash "$SLOTS_DIR/install.sh" --dry-run --config "$W/cfg.env"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dev.ghr.slot.light-2.plist"* ]]
  refute grep -q 'light-3' <<< "$output"
  printf 'LIGHT_SLOTS=40\n' > "$W/cfg.env"
  run bash "$SLOTS_DIR/install.sh" --dry-run --config "$W/cfg.env"
  [[ "$output" == *"dev.ghr.slot.light-6.plist"* ]]
  refute grep -q 'light-7' <<< "$output"
}

@test "--dry-run --uninstall reverses daemons/sudoers/libexec; --purge adds accounts" {
  run bash "$SLOTS_DIR/install.sh" --dry-run --uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"launchctl bootout system/dev.ghr.heartbeat"* ]]
  [[ "$output" == *"rm -f $W/sudoers-ghr"* ]]
  [[ "$output" == *"rm -rf $W/libexec"* ]]
  refute grep -q 'deleteUser' <<< "$output"
  run bash "$SLOTS_DIR/install.sh" --dry-run --uninstall --purge
  [[ "$output" == *"sysadminctl -deleteUser _ghrctl"* ]]
}

@test "unknown flags are rejected" {
  run bash "$SLOTS_DIR/install.sh" --frobnicate
  [ "$status" -eq 2 ]
}

@test "plist templates render to valid plists with the intended launchd keys" {
  source "$SLOTS_DIR/install.sh"
  render_plist "$SLOTS_DIR/launchd/dev.ghr.slot.plist" "$W/slot.plist" CLASS=light N=4 LIBEXEC=/x/libexec CTL_HOME=/var/db/_ghrctl LOGDIR=/x/log
  render_plist "$SLOTS_DIR/launchd/dev.ghr.heartbeat.plist" "$W/hb.plist" LIBEXEC=/x/libexec STATE_HOME=/var/db/_ghrstate LOGDIR=/x/log
  render_plist "$SLOTS_DIR/launchd/dev.ghr.pool.plist" "$W/pool.plist" LIBEXEC=/x/libexec GHR_HOME=/Users/ghr LOGDIR=/x/log
  refute grep -q '@[A-Z_]*@' "$W/slot.plist" "$W/hb.plist" "$W/pool.plist"
  python3 - "$W" <<'PY'
import plistlib, sys
w = sys.argv[1]
slot = plistlib.load(open(w + "/slot.plist", "rb"))
assert slot["Label"] == "dev.ghr.slot.light-4"
assert slot["UserName"] == "_ghrctl"
assert slot["ProgramArguments"] == ["/x/libexec/slot-loop", "light", "4"]
assert slot["KeepAlive"] is True and slot["ThrottleInterval"] == 30
assert slot["AbandonProcessGroup"] is True
hb = plistlib.load(open(w + "/hb.plist", "rb"))
assert hb["Label"] == "dev.ghr.heartbeat" and hb["UserName"] == "_ghrstate" and hb["StartInterval"] == 60
pool = plistlib.load(open(w + "/pool.plist", "rb"))
assert pool["UserName"] == "ghr" and pool["RunAtLoad"] is True and pool["AbandonProcessGroup"] is True
assert pool["ProgramArguments"] == ["/x/libexec/pool", "ensure"]
PY
}

@test "public-repo hygiene: no org names, IPs or key material in slots/" {
  # patterns assembled from pieces so this file does not match itself
  a="lin""ple"; b="gyeol""hada"; c="BEGIN [A-Z ]*PRIV""ATE KEY"; d="192\.168\."
  refute grep -rniE "$a|$b|$c|$d" "$SLOTS_DIR"
}

@test "every script has a header and none enables xtrace (would leak the JIT config)" {
  for f in "$SLOTS_DIR"/*.sh "$SLOTS_DIR"/lib/*.sh; do
    sed -n 2p "$f" | grep -q '^# '
    refute grep -nE '^\s*set -[a-z]*x|set -o xtrace|bash -x' "$f"
  done
}
