#!/usr/bin/env bats
# Offline tests for slots/install-pve.sh (dry-run plan, never touches the host), the systemd template
# and slots/slot-unit.sh.

load helpers

IPVE() { echo "$SLOTS_DIR/install-pve.sh"; }

setup() {
  slots_setup
  printf 'PVE_SLOTS="5, 6"\nORG=test-org\n' > "$W/pve.env"
  printf 'KEYMARKER-do-not-print\n' > "$W/runner.pem"
}

plan() { bash "$(IPVE)" --dry-run --config "$W/pve.env" "$@" 2>&1; }

@test "dry-run needs no root and prints a plan without touching the host" {
  run plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY: useradd --system --home-dir /var/lib/ghrctl --no-create-home --shell /usr/sbin/nologin ghrctl"* ]]
  [[ "$output" == *"[install-pve] done"* ]]
  [ ! -e /usr/local/libexec/ghr/launch-pve ] || skip "host already has an install"
}

@test "plan: scripts to libexec root 0755 with launch-pve marked GHR_INSTALLED=1; libs alongside; no macOS-only pieces" {
  run plan
  for s in slot-loop slot-unit mint-jit reconcile; do
    [[ "$output" == *"DRY: install -m 0755 -o root -g root $SLOTS_DIR/$s.sh /usr/local/libexec/ghr/$s"* ]]
  done
  [[ "$output" == *"/usr/local/libexec/ghr/launch-pve (with GHR_INSTALLED=1)"* ]]
  for l in gh-app pve-fw pve-guest; do
    [[ "$output" == *"DRY: install -m 0644 -o root -g root $SLOTS_DIR/lib/$l.sh /usr/local/libexec/ghr/lib/$l.sh"* ]]
  done
  refute grep -qiE 'heartbeat|launchctl|plist|dscl|sysadminctl' <<< "$output"
}

@test "plan: config only installed from --config, key 0400 owned by ghrctl, state dirs, home 0700" {
  run plan --runner-key "$W/runner.pem"
  [[ "$output" == *"DRY: install -m 0644 -o root -g root $W/pve.env /usr/local/etc/ghr/slots.env"* ]]
  [[ "$output" == *"DRY: install -m 0400 -o ghrctl -g ghrctl $W/runner.pem /var/lib/ghrctl/runner-app.pem"* ]]
  [[ "$output" == *"DRY: install -d -m 0700 -o ghrctl -g ghrctl /var/lib/ghrctl"* ]]
  [[ "$output" == *"DRY: install -d -m 0755 -o ghrctl -g ghrctl /var/lib/ghr/slots"* ]]
}

@test "the runner key's CONTENT is never printed (and without --runner-key a TODO is shown)" {
  run plan --runner-key "$W/runner.pem"
  refute grep -q 'KEYMARKER' <<< "$output"
  run plan
  [[ "$output" == *"TODO: place the runner App key at /var/lib/ghrctl/runner-app.pem"* ]]
}

@test "plan: sudoers lets ghrctl run exactly launch-pve as root, validated with visudo -cf, no setenv" {
  run plan
  [[ "$output" == *"DRY: write sudoers drop-in /etc/sudoers.d/ghr:"* ]]
  [[ "$output" == *"Defaults!/usr/local/libexec/ghr/launch-pve env_reset, !setenv, secure_path=\"/usr/sbin:/usr/bin:/sbin:/bin\""* ]]
  [[ "$output" == *"ghrctl ALL=(root) NOPASSWD: /usr/local/libexec/ghr/launch-pve"* ]]
  [[ "$output" == *"validated with visudo -cf"* ]]
}

@test "plan: the unit template is installed and one instance is enabled per PVE_SLOTS entry; others disabled without blocking" {
  run plan
  [[ "$output" == *"/etc/systemd/system/ghr-slot@.service"* ]]
  [[ "$output" == *"DRY: systemctl enable --now ghr-slot@supabase-5.service"* ]]
  [[ "$output" == *"DRY: systemctl enable --now ghr-slot@supabase-6.service"* ]]
  refute grep -q 'enable --now ghr-slot@supabase-1.service' <<< "$output"
  [[ "$output" == *"DRY: systemctl disable --now --no-block ghr-slot@supabase-1.service"* ]]
}

@test "PVE_SLOTS from the template is empty (nothing enabled); invalid entries are ignored with a note" {
  run bash "$(IPVE)" --dry-run
  refute grep -q 'enable --now' <<< "$output"
  printf 'PVE_SLOTS="5 x 0 10 5"\n' > "$W/pve.env"
  run plan
  [[ "$output" == *"ignoring invalid PVE_SLOTS entry: x"* ]]
  [ "$(grep -c 'enable --now ghr-slot@supabase-5.service' <<< "$output")" -eq 1 ]
}

@test "uninstall plan removes units, sudoers, libexec and state but keeps config/key/account; --purge removes them" {
  run bash "$(IPVE)" --dry-run --uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY: rm -f /etc/systemd/system/ghr-slot@.service /etc/sudoers.d/ghr"* ]]
  [[ "$output" == *"DRY: rm -rf /usr/local/libexec/ghr"* ]]
  [[ "$output" == *"kept config"* ]]
  refute grep -q 'userdel' <<< "$output"
  run bash "$(IPVE)" --dry-run --uninstall --purge
  [[ "$output" == *"DRY: rm -rf /usr/local/etc/ghr /var/lib/ghr /var/lib/ghrctl"* ]]
  [[ "$output" == *"DRY: userdel ghrctl"* ]]
}

@test "bad arguments are rejected (2); a real run as non-root is refused (1)" {
  run bash "$(IPVE)" --nope
  [ "$status" -eq 2 ]
  [ "$(id -u)" -ne 0 ] || skip "root"
  run bash "$(IPVE)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must run as root"* ]]
}

@test "systemd template: unprivileged user, graceful stop, restart, slot-unit entry point" {
  f="$SLOTS_DIR/systemd/ghr-slot@.service"
  grep -q '^User=@CTL_USER@' "$f"
  grep -q '^Restart=always' "$f"
  grep -q '^KillMode=process' "$f"
  refute grep -qE '^KillMode=(mixed|control-group)' "$f"
  grep -q '^TimeoutStopSec=21700' "$f"
  grep -q '^ExecStart=@LIBEXEC@/slot-unit %i' "$f"
  grep -q '^Environment=LAUNCH_USER=root' "$f"
  grep -q '^Environment=LAUNCH_BIN=@LIBEXEC@/launch-pve' "$f"
  grep -q '^Environment=GHR_STATE_DIR=@STATE_ROOT@/slots' "$f"
  # sudo is setuid: NoNewPrivileges would break the launch hand-off
  refute grep -qE '^NoNewPrivileges=(yes|true)' "$f"
}

@test "rendered unit has no leftover placeholders" {
  # shellcheck source=slots/install-pve.sh
  source "$(IPVE)"
  render_unit "$SLOTS_DIR/systemd/ghr-slot@.service" "$W/unit" CTL_USER=ghrctl CTL_HOME=/var/lib/ghrctl STATE_ROOT=/var/lib/ghr LIBEXEC=/usr/local/libexec/ghr
  refute grep -q '@[A-Z_]*@' "$W/unit"
  grep -q '^ExecStart=/usr/local/libexec/ghr/slot-unit %i' "$W/unit"
}

# ── slot-unit.sh ──────────────────────────────────────────────────────────────

@test "slot-unit splits <class>-<n> and execs slot-loop with two arguments" {
  mkdir -p "$W/su"
  cp "$SLOTS_DIR/slot-unit.sh" "$W/su/slot-unit"
  printf '#!/bin/bash\nprintf "%%s|" "$@"\n' > "$W/su/slot-loop"
  chmod +x "$W/su/slot-unit" "$W/su/slot-loop"
  run "$W/su/slot-unit" supabase-5
  [ "$status" -eq 0 ]
  [ "$output" = "supabase|5|" ]
  run "$W/su/slot-unit" light-12
  [ "$output" = "light|12|" ]
}

@test "slot-unit rejects malformed instance names" {
  for bad in "" "supabase" "supabase-" "supabase-0" "supabase-5;id" "other-1" "supabase-5 4"; do
    run bash "$SLOTS_DIR/slot-unit.sh" "$bad"
    [ "$status" -eq 2 ]
  done
  run bash "$SLOTS_DIR/slot-unit.sh"
  [ "$status" -eq 2 ]
}

@test "config.example.env documents REMOTE_SLOTS and the commented Proxmox block with placeholders" {
  f="$SLOTS_DIR/config.example.env"
  grep -q '^REMOTE_SLOTS=$' "$f"
  for k in PVE_SLOTS PVE_VMID_BASE GOLDEN_VMID SUPA_MEM_MB PVE_IPCONFIG_5 PVE_NAMESERVER LAUNCH_USER LAUNCH_BIN; do
    grep -q "^#$k=" "$f"
  done
  # documentation addresses only
  refute grep -E '^[^#]*(10|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]+\.[0-9]+' "$f"
  # the template still loads as a config
  GHR_CONFIG="$f" bash -c 'source "$1"; ghr_load_config' _ "$SLOTS_DIR/lib/gh-app.sh"
}
