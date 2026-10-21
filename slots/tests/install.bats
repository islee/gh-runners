#!/usr/bin/env bats
# Tests for slots/install.sh (--dry-run / --uninstall planning, plist rendering) and repo hygiene
# of the slots/ tree. Never runs a real install: needs no root and touches nothing.

load helpers

setup() {
  slots_setup
  export GHR_ALLOW_NONROOT_OWNER=1 GHR_NEWSYSLOG="$W/newsyslog-ghr.conf"
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

@test "--dry-run: hardened sudoers (Defaults before the rule), root:wheel 0755 scripts, 0400 keys, 0640 logs" {
  run bash "$SLOTS_DIR/install.sh" --dry-run --runner-key /k/r.pem --state-key /k/s.pem
  [ "$status" -eq 0 ]
  d="Defaults!$W/libexec/launch env_reset, !setenv, always_set_home, secure_path=\"/usr/bin:/bin:/usr/sbin:/sbin\""
  r="_ghrctl ALL=(ghr) NOPASSWD: $W/libexec/launch"
  [[ "$output" == *"$d"* ]]
  # Defaults line precedes the NOPASSWD rule
  [ "$(grep -n -F -e "$d" <<< "$output" | head -1 | cut -d: -f1)" -lt "$(grep -n -F -e "$r" <<< "$output" | head -1 | cut -d: -f1)" ]
  for s in slot-loop mint-jit reconcile launch heartbeat pool; do
    [[ "$output" == *"install -m 0755 -o root -g wheel $SLOTS_DIR/$s.sh $W/libexec/$s"* ]]
  done
  [[ "$output" == *"install -m 0644 -o root -g wheel $SLOTS_DIR/lib/gh-app.sh $W/libexec/lib/gh-app.sh"* ]]
  [[ "$output" == *"install -m 0400 -o _ghrctl /k/r.pem /var/db/_ghrctl/runner-app.pem"* ]]
  [[ "$output" == *"install -m 0400 -o _ghrstate /k/s.pem /var/db/_ghrstate/state-app.pem"* ]]
  [[ "$output" == *"launch.sh $W/libexec/launch (with GHR_INSTALLED=1)"* ]]
  [[ "$output" == *"pool.sh $W/libexec/pool (with GHR_INSTALLED=1)"* ]]
  [[ "$output" == *"chmod 0640 $W/log/slot-light-1.log"* ]]
  [[ "$output" == *"write $W/newsyslog-ghr.conf"* ]]
  [[ "$output" == *"wait up to 30s until launchctl print system/dev.ghr.heartbeat fails"* ]]
  for p in slot hb pool; do [[ "$output" == *"plutil -lint"*"$p.plist"* ]]; done
}

@test "refuses to install into group/other-writable or non-root-owned directories" {
  mkdir -p "$W/libexec"; chmod 777 "$W/libexec"
  run bash "$SLOTS_DIR/install.sh" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"group/other-writable"* ]]
  chmod 775 "$W/libexec"
  run bash "$SLOTS_DIR/install.sh" --dry-run
  [ "$status" -eq 1 ]
  chmod 755 "$W/libexec"
  run bash "$SLOTS_DIR/install.sh" --dry-run
  [ "$status" -eq 0 ]
  # root-ownership is enforced unless the test-only escape hatch is set
  GHR_ALLOW_NONROOT_OWNER=0 run bash "$SLOTS_DIR/install.sh" --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"not owned by root"* ]]
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
  [[ "$output" == *"rm -f $W/sudoers-ghr $W/newsyslog-ghr.conf"* ]]
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
  # lib/pve-fw.sh legitimately names the private ranges it drops (checked separately in launch-pve.bats)
  refute grep -rniE --exclude=pve-fw.sh "$a|$b|$c|$d" "$SLOTS_DIR"
}

@test "every script has a header and none enables xtrace (would leak the JIT config)" {
  for f in "$SLOTS_DIR"/*.sh "$SLOTS_DIR"/lib/*.sh; do
    sed -n 2p "$f" | grep -q '^# '
    refute grep -nE '^\s*set -[a-z]*x|set -o xtrace|bash -x' "$f"
  done
}

@test "BSD seq (counts down when first > last) must not remove the top slot at LIGHT_SLOTS=MAX" {
  # Regression (2026-10-16, real mini): `seq 7 6` on macOS yields "7 6", so the "remove slots beyond
  # the configured count" loop deleted light-6 right after installing it. GNU seq hid it in CI.
  mkdir -p "$W/bin" "$W/daemons"
  cat > "$W/bin/seq" <<'SH'
#!/bin/bash
# BSD-style seq: counts down when FIRST > LAST
a=$1; b=$2
if [ "$a" -le "$b" ]; then i=$a; while [ "$i" -le "$b" ]; do echo "$i"; i=$((i + 1)); done
else i=$a; while [ "$i" -ge "$b" ]; do echo "$i"; i=$((i - 1)); done; fi
SH
  chmod +x "$W/bin/seq"
  touch "$W/daemons/dev.ghr.slot.light-6.plist"
  PATH="$W/bin:$PATH" run bash "$SLOTS_DIR/install.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"launchctl bootstrap system $W/daemons/dev.ghr.slot.light-6.plist"* ]]
  refute grep -q -F "rm -f $W/daemons/dev.ghr.slot.light-6.plist" <<< "$output"
}

@test "supabase plists/logs are rendered ONLY when SUPABASE_SLOTS > 0 (default config: none)" {
  run bash "$SLOTS_DIR/install.sh" --dry-run
  [ "$status" -eq 0 ]
  refute grep -q 'dev.ghr.slot.supabase' <<< "$output"
  refute grep -q 'slot-supabase' <<< "$output"
  printf 'SUPABASE_SLOTS=2\n' > "$W/cfg.env"
  run bash "$SLOTS_DIR/install.sh" --dry-run --config "$W/cfg.env"
  [ "$status" -eq 0 ]
  [[ "$output" == *"launchctl bootstrap system $W/daemons/dev.ghr.slot.supabase-1.plist"* ]]
  [[ "$output" == *"launchctl bootstrap system $W/daemons/dev.ghr.slot.supabase-2.plist"* ]]
  refute grep -q 'supabase-3' <<< "$output"
  [[ "$output" == *"chmod 0640 $W/log/slot-supabase-1.log"* ]]
}

@test "supabase slots are capped at 3 and a shrunk/disabled class has its stale plists removed" {
  printf 'SUPABASE_SLOTS=9\n' > "$W/cfg.env"
  run bash "$SLOTS_DIR/install.sh" --dry-run --config "$W/cfg.env"
  [[ "$output" == *"dev.ghr.slot.supabase-3.plist"* ]]
  refute grep -q 'supabase-4' <<< "$output"
  # class disabled but a plist from an earlier install exists -> bootout + rm (count 0 must not make BSD seq count down)
  mkdir -p "$W/daemons"; : > "$W/daemons/dev.ghr.slot.supabase-2.plist"
  printf 'SUPABASE_SLOTS=0\n' > "$W/cfg.env"
  run bash "$SLOTS_DIR/install.sh" --dry-run --config "$W/cfg.env"
  [ "$status" -eq 0 ]
  [[ "$output" == *"launchctl bootout system/dev.ghr.slot.supabase-2"* ]]
  [[ "$output" == *"rm -f $W/daemons/dev.ghr.slot.supabase-2.plist"* ]]
  refute grep -q 'bootstrap system .*supabase' <<< "$output"
}

@test "uninstall covers the supabase slot daemons" {
  run bash "$SLOTS_DIR/install.sh" --dry-run --uninstall
  for n in 1 2 3; do [[ "$output" == *"launchctl bootout system/dev.ghr.slot.supabase-$n"* ]]; done
}

@test "supabase plist renders with the class and slot in label, args and log path" {
  source "$SLOTS_DIR/install.sh"
  render_plist "$SLOTS_DIR/launchd/dev.ghr.slot.plist" "$W/s.plist" CLASS=supabase N=2 LIBEXEC=/x/libexec CTL_HOME=/var/db/_ghrctl LOGDIR=/x/log
  python3 - "$W/s.plist" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
assert p["Label"] == "dev.ghr.slot.supabase-2"
assert p["ProgramArguments"] == ["/x/libexec/slot-loop", "supabase", "2"]
assert p["StandardOutPath"] == "/x/log/slot-supabase-2.log"
assert p["UserName"] == "_ghrctl" and p["AbandonProcessGroup"] is True
PY
}
