#!/usr/bin/env bats
# shellcheck disable=SC2034  # globals consumed by the sourced script under test
# Re-running install.sh while slot daemons are mid-job (normal during upgrades): unchanged plist ->
# SIGTERM only; changed plist + idle -> bootout/bootstrap; changed plist + busy -> deferred to a
# one-shot helper (reload-slot.sh) that re-bootstraps once the old process is gone. launchctl is a
# stateful shim; nothing touches launchd.

load helpers

LABEL=dev.ghr.slot.supabase-2

setup() {
  slots_setup
  LCTL_LOG="$W/launchctl.log"; LOADED="$W/loaded"; BUSY="$W/busy"
  mkdir -p "$LOADED" "$BUSY" "$W/daemons" "$W/etc" "$W/libexec"
  : > "$LCTL_LOG"
  export LCTL_LOG LOADED BUSY
  # launchctl: print succeeds while a loaded-marker exists. bootout removes it unless the label is
  # BUSY (job still running: stays loaded, as launchd does). bootstrap loads. kill is logged.
  cat > "$FAKE_BIN/launchctl" <<'SHIM'
#!/bin/bash
echo "$*" >> "$LCTL_LOG"
case "$1" in
  print) [ -f "$LOADED/${2#system/}" ]; exit $? ;;
  bootout) l=${2#system/}; [ -f "$BUSY/$l" ] || rm -f "$LOADED/$l"; exit 0 ;;
  bootstrap) l=$(basename "$3" .plist); : > "$LOADED/$l"; exit 0 ;;
  kill) exit 0 ;;
esac
exit 0
SHIM
  # install: copy src -> dst ignoring owner/mode flags (we are not root); -d makes directories
  cat > "$FAKE_BIN/install" <<'SHIM'
#!/bin/bash
args=(); while [ $# -gt 0 ]; do case "$1" in -m|-o|-g) shift 2 ;; -d) d=1; shift ;; *) args+=("$1"); shift ;; esac; done
if [ -n "${d:-}" ]; then mkdir -p "${args[@]}"; else cp "${args[0]}" "${args[1]}"; fi
SHIM
  printf '#!/bin/bash\nexit 0\n' > "$FAKE_BIN/plutil"
  printf '#!/bin/bash\nexit 0\n' > "$FAKE_BIN/sleep"
  chmod +x "$FAKE_BIN/launchctl" "$FAKE_BIN/install" "$FAKE_BIN/plutil" "$FAKE_BIN/sleep"
  source "$SLOTS_DIR/install.sh"
  DRY=0
  DAEMON_DIR="$W/daemons"; ETC_DIR="$W/etc"; LIBEXEC="$W/libexec"; LOGDIR="$W/log"
  UNLOAD_WAIT_SECS=2
  render_plist "$SLOTS_DIR/launchd/dev.ghr.slot.plist" "$W/rendered.plist" CLASS=supabase N=2 LIBEXEC="$LIBEXEC" CTL_HOME=/var/db/_ghrctl LOGDIR="$LOGDIR"
  PLIST="$DAEMON_DIR/$LABEL.plist"
}

loaded() { : > "$LOADED/$1"; }

@test "unchanged plist + loaded: only 'launchctl kill SIGTERM'; no bootout, no bootstrap, plist not rewritten" {
  cp "$W/rendered.plist" "$PLIST"; loaded "$LABEL"
  touch -t 202001010000 "$PLIST"
  deploy_slot "$LABEL" "$W/rendered.plist" "$PLIST"
  grep -q "^kill SIGTERM system/$LABEL" "$LCTL_LOG"
  refute grep -q -e '^bootout' -e '^bootstrap' "$LCTL_LOG"
  [ -z "$DEFERRED" ]
  [ "$(date -r "$PLIST" +%Y)" = "2020" ]
}

@test "changed plist + idle slot: installed, bootout, bounded wait, bootstrap (as before); nothing deferred" {
  echo "<!-- old -->" > "$PLIST"; loaded "$LABEL"
  deploy_slot "$LABEL" "$W/rendered.plist" "$PLIST"
  cmp "$W/rendered.plist" "$PLIST"
  b=$(grep -n "^bootout system/$LABEL" "$LCTL_LOG" | head -1 | cut -d: -f1)
  s=$(grep -n "^bootstrap system $PLIST" "$LCTL_LOG" | head -1 | cut -d: -f1)
  [ -n "$b" ] && [ -n "$s" ] && [ "$b" -lt "$s" ]
  refute grep -q '^kill' "$LCTL_LOG"
  [ -z "$DEFERRED" ]
  [ ! -d "$ETC_DIR/reload" ]
}

@test "slot not loaded (fresh or crashed): installed and bootstrapped" {
  deploy_slot "$LABEL" "$W/rendered.plist" "$PLIST"
  grep -q "^bootstrap system $PLIST" "$LCTL_LOG"
  [ -z "$DEFERRED" ]
}

@test "changed plist + busy slot: install does NOT fail, the label is DEFERRED and a helper job is scheduled" {
  echo "<!-- old -->" > "$PLIST"; loaded "$LABEL"; : > "$BUSY/$LABEL"
  rc=0; output=$(deploy_slot "$LABEL" "$W/rendered.plist" "$PLIST" 2>&1) || rc=$?
  [ "$rc" -eq 0 ]
  [[ "$output" == *"$LABEL is busy"* ]]
  deploy_slot_again() { DEFERRED=""; echo "<!-- old -->" > "$PLIST"; deploy_slot "$LABEL" "$W/rendered.plist" "$PLIST"; }
  : > "$LCTL_LOG"; rm -rf "$ETC_DIR/reload"; rm -f "$LOADED"/dev.ghr.reload.*
  deploy_slot_again > /dev/null
  [ "$DEFERRED" = "$LABEL" ]
  cmp "$W/rendered.plist" "$PLIST"                     # the NEW plist is already on disk
  hp="$ETC_DIR/reload/dev.ghr.reload.supabase-2.plist"
  [ -f "$hp" ]
  grep -q "^bootstrap system $hp" "$LCTL_LOG"
  python3 - "$hp" "$PLIST" "$LIBEXEC" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
assert p["Label"] == "dev.ghr.reload.supabase-2"
assert p["ProgramArguments"] == [sys.argv[3] + "/reload-slot", "dev.ghr.slot.supabase-2", sys.argv[2]]
assert p["RunAtLoad"] is True and "KeepAlive" not in p
PY
  # the slot daemon itself was NOT bootstrapped over the still-running job
  refute grep -q "^bootstrap system $PLIST" "$LCTL_LOG"
  report_deferred_out=$(report_deferred)
  [ "$report_deferred_out" = "[install] deferred: $LABEL (busy; will reload when their jobs finish)" ]
}

@test "a pending helper is not scheduled twice" {
  echo "<!-- old -->" > "$PLIST"; loaded "$LABEL"; : > "$BUSY/$LABEL"; loaded dev.ghr.reload.supabase-2
  deploy_slot "$LABEL" "$W/rendered.plist" "$PLIST" > /dev/null
  refute grep -q '^bootstrap system .*reload' "$LCTL_LOG"
}

@test "deferred slot is re-bootstrapped once the old process is gone (helper run end to end)" {
  echo "<!-- old -->" > "$PLIST"; loaded "$LABEL"; : > "$BUSY/$LABEL"
  deploy_slot "$LABEL" "$W/rendered.plist" "$PLIST" > /dev/null
  hp="$ETC_DIR/reload/dev.ghr.reload.supabase-2.plist"
  [ -f "$hp" ]
  : > "$LCTL_LOG"
  # the job ends: the old loop exits and launchd drops the label
  rm -f "$LOADED/$LABEL" "$BUSY/$LABEL"
  LAUNCHCTL="$FAKE_BIN/launchctl" GHR_DAEMON_DIR="$DAEMON_DIR" RELOAD_HELPER_PLIST="$hp" bash "$SLOTS_DIR/reload-slot.sh" "$LABEL" "$PLIST" 2> /dev/null
  [ "$(grep -c "^bootstrap system $PLIST" "$LCTL_LOG")" -eq 1 ]
  grep -q '^bootout system/dev.ghr.reload.supabase-2' "$LCTL_LOG"
  [ ! -f "$hp" ]
}

@test "reload-slot waits while the label is still loaded, then bootstraps exactly once" {
  cp "$W/rendered.plist" "$PLIST"
  # print succeeds three times, then the label is gone
  cat > "$FAKE_BIN/launchctl" <<'SHIM'
#!/bin/bash
echo "$*" >> "$LCTL_LOG"
if [ "$1" = print ]; then
  n=$(cat "$LOADED/count" 2>/dev/null || echo 0); echo $((n + 1)) > "$LOADED/count"
  [ "$n" -lt 3 ]; exit $?
fi
exit 0
SHIM
  LAUNCHCTL="$FAKE_BIN/launchctl" RELOAD_POLL=1 GHR_DAEMON_DIR="$DAEMON_DIR" bash "$SLOTS_DIR/reload-slot.sh" "$LABEL" "$PLIST" 2> /dev/null
  [ "$(grep -c '^print' "$LCTL_LOG")" -eq 4 ]
  [ "$(grep -c "^bootstrap system $PLIST" "$LCTL_LOG")" -eq 1 ]
}

@test "reload-slot gives up after RELOAD_MAX_WAIT (label never leaves) without bootstrapping" {
  cp "$W/rendered.plist" "$PLIST"; loaded "$LABEL"
  rc=0; LAUNCHCTL="$FAKE_BIN/launchctl" GHR_DAEMON_DIR="$DAEMON_DIR" RELOAD_MAX_WAIT=3 RELOAD_POLL=1 bash "$SLOTS_DIR/reload-slot.sh" "$LABEL" "$PLIST" 2> /dev/null || rc=$?
  [ "$rc" -eq 1 ]
  refute grep -q '^bootstrap' "$LCTL_LOG"
}

@test "reload-slot validates its arguments (runs as root)" {
  cp "$W/rendered.plist" "$PLIST"
  for args in "dev.ghr.slot.light-9x $PLIST" "$LABEL /etc/passwd" "$LABEL" "dev.ghr.slot.android-1 $PLIST"; do
    rc=0
    # shellcheck disable=SC2086
    LAUNCHCTL="$FAKE_BIN/launchctl" GHR_DAEMON_DIR="$DAEMON_DIR" bash "$SLOTS_DIR/reload-slot.sh" $args 2> /dev/null || rc=$?
    [ "$rc" -eq 2 ]
  done
  [ ! -s "$LCTL_LOG" ]
}

@test "slot plist template: KeepAlive on and ThrottleInterval short enough for a prompt relaunch" {
  python3 - "$SLOTS_DIR/launchd/dev.ghr.slot.plist" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
assert p["KeepAlive"] is True
assert p["ThrottleInterval"] <= 30
PY
}

@test "install dry-run lists reload-slot among the installed scripts" {
  output=$(GHR_ALLOW_NONROOT_OWNER=1 bash "$SLOTS_DIR/install.sh" --dry-run)
  [[ "$output" == *"reload-slot.sh"*"/reload-slot"* ]]
}

@test "installed reload-slot copy (GHR_INSTALLED=1) drops LAUNCHCTL/GHR_DAEMON_DIR/RELOAD_* overrides" {
  grep -q '^GHR_INSTALLED=0' "$SLOTS_DIR/reload-slot.sh"
  sed 's/^GHR_INSTALLED=0/GHR_INSTALLED=1/' "$SLOTS_DIR/reload-slot.sh" > "$W/installed-reload"
  sed -n '1,/^set -uo pipefail/p' "$W/installed-reload" | sed '$d' > "$W/pre.sh"
  echo 'echo "[${LAUNCHCTL-unset}][${GHR_DAEMON_DIR-unset}][${RELOAD_MAX_WAIT-unset}][${RELOAD_POLL-unset}]"' >> "$W/pre.sh"
  out=$(LAUNCHCTL=/tmp/evil GHR_DAEMON_DIR=/tmp RELOAD_MAX_WAIT=1 RELOAD_POLL=0 bash "$W/pre.sh")
  [ "$out" = "[unset][unset][unset][unset]" ]
}

@test "install.sh installs reload-slot with the installed marker" {
  grep -q 'launch | pool | reload-slot)' "$SLOTS_DIR/install.sh"
}

@test "reload-slot accepts the ios slot label (and still bootstraps once the old loop is gone)" {
  render_plist "$SLOTS_DIR/launchd/dev.ghr.slot.plist" "$W/ios.plist" CLASS=ios N=1 LIBEXEC="$LIBEXEC" CTL_HOME=/var/db/_ghrctl LOGDIR="$LOGDIR"
  cp "$W/ios.plist" "$DAEMON_DIR/dev.ghr.slot.ios-1.plist"
  rc=0; LAUNCHCTL="$FAKE_BIN/launchctl" GHR_DAEMON_DIR="$DAEMON_DIR" RELOAD_MAX_WAIT=3 RELOAD_POLL=1 bash "$SLOTS_DIR/reload-slot.sh" dev.ghr.slot.ios-1 "$DAEMON_DIR/dev.ghr.slot.ios-1.plist" 2> /dev/null || rc=$?
  [ "$rc" -eq 0 ]
  grep -q '^bootstrap system .*dev.ghr.slot.ios-1.plist' "$LCTL_LOG"
}
