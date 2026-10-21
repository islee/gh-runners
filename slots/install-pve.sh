#!/bin/bash
# install-pve.sh [--dry-run] [--uninstall [--purge]] [--runner-key F] [--config F]
#
# Installs the supabase-class slot loops on a Proxmox VE host (Debian, systemd). Run as root.
# Idempotent: re-running converges; existing config and keys are never overwritten. The Mac installer
# (install.sh) is unrelated and untouched; this host runs NO heartbeat (the Mac publishes the state,
# see REMOTE_SLOTS in config.example.env).
#
# What it does (in order):
#   1. system account `ghrctl` (no login shell, home /var/lib/ghrctl 0700) -- mints runners and runs
#      the slot loops, nothing else
#   2. directories: /usr/local/libexec/ghr + /usr/local/etc/ghr (root), /var/lib/ghr/slots (ghrctl)
#   3. scripts -> /usr/local/libexec/ghr (root 0755; `.sh` stripped; lib/*.sh alongside); launch-pve
#      gets its GHR_INSTALLED marker rewritten to 1 so the root-owned copy ignores caller overrides
#   4. config -> /usr/local/etc/ghr/slots.env (root 0644, NO secrets; only created if absent)
#   5. optional runner App key (--runner-key) -> /var/lib/ghrctl/runner-app.pem (0400, ghrctl); the key
#      is copied by `install` and never printed
#   6. sudoers drop-in letting ghrctl run ONLY launch-pve as root (validated by visudo -cf)
#   7. systemd template ghr-slot@.service, enabled for ghr-slot@supabase-<n> for every n in PVE_SLOTS
# --uninstall reverses 3, 6, 7 and the state dir; --purge additionally removes config, key, home and
# the account. VMs and the golden template are never touched. --dry-run prints every action instead of
# executing it (no root needed, writes nothing).
#
# Dependencies: Linux with systemd, useradd/userdel, visudo, sudo, qm. Source-guarded so tests can call
# the helpers without side effects.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBEXEC="${GHR_LIBEXEC:-/usr/local/libexec/ghr}"
ETC_DIR="${GHR_ETC:-/usr/local/etc/ghr}"
CONFIG_DEST="$ETC_DIR/slots.env"
STATE_ROOT="${GHR_STATE_ROOT:-/var/lib/ghr}"
CTL_HOME="${GHR_CTL_HOME:-/var/lib/ghrctl}"
UNIT_DIR="${GHR_UNIT_DIR:-/etc/systemd/system}"
SUDOERS_FILE="${GHR_SUDOERS:-/etc/sudoers.d/ghr}"
CTL_USER=ghrctl
PVE_MAX=9

DRY=0
UNINSTALL=0
PURGE=0
RUNNER_KEY=""
CONFIG_SRC=""

say() { echo "[install-pve] $*"; }

# run CMD... — execute, or print in --dry-run. Everything state-changing goes through here.
run() {
  if [ "$DRY" -eq 1 ]; then echo "DRY: $*"; else "$@"; fi
}

# render_unit TEMPLATE OUT KEY=VAL... — substitute @KEY@ placeholders (values come from this script,
# never from user input, so sed delimiters are safe).
render_unit() {
  local tpl=$1 out=$2 expr="" kv
  shift 2
  for kv in "$@"; do expr="$expr -e s|@${kv%%=*}@|${kv#*=}|g"; done
  # shellcheck disable=SC2086
  sed $expr "$tpl" > "$out"
}

user_exists() { id -u "$1" > /dev/null 2>&1; }

# config_value KEY — raw value of KEY from the installed config, else the template; quotes stripped.
config_value() {
  local v="" f
  for f in "$CONFIG_DEST" "${CONFIG_SRC:-$SRC/config.example.env}"; do
    [ -r "$f" ] || continue
    v=$(sed -n "s/^$1=//p" "$f" | head -1 | tr -d "\"'")
    [ -z "$v" ] || break
  done
  printf '%s' "$v"
}

# pve_slots — the validated slot numbers of PVE_SLOTS, one per line, uniq, 1..PVE_MAX.
pve_slots() {
  local s seen=" " v
  v=$(config_value PVE_SLOTS)
  for s in ${v//,/ }; do
    [[ "$s" =~ ^[1-9]$ ]] || { echo "ignoring invalid PVE_SLOTS entry: $s" >&2; continue; }
    case "$seen" in *" $s "*) continue ;; esac
    seen="$seen$s "
    printf '%s\n' "$s"
  done
}

# secure_dir PATH — refuse to install into a directory another user could swap files in.
secure_dir() {
  local d=$1 line perms
  [ -e "$d" ] || return 0
  line=$(ls -ldn "$d")
  perms=${line%% *}
  case "${perms:5:1}${perms:8:1}" in
    *w*) echo "refusing to install: $d is group/other-writable ($perms)" >&2; return 1 ;;
  esac
}

check_install_dirs() {
  local d
  for d in /usr/local "$(dirname "$LIBEXEC")" "$LIBEXEC" "$LIBEXEC/lib" "$(dirname "$ETC_DIR")" "$ETC_DIR"; do
    secure_dir "$d" || return 1
  done
}

# preflight_checks — tools and host settings the slots depend on. Warnings only: a dry run on another
# machine must still print the plan.
preflight_checks() {
  local c fw
  for c in curl openssl python3 sudo visudo systemctl useradd qm; do
    command -v "$c" > /dev/null 2>&1 || say "WARN missing command: $c"
  done
  fw=/etc/pve/firewall/cluster.fw
  if [ -r "$fw" ]; then
    grep -Eq '^enable:[[:space:]]*1' "$fw" \
      || say "WARN the datacenter firewall is not enabled ($fw): per-VM egress rules are NOT applied until it is (launch-pve's preflight will refuse every job)"
  else
    say "NOTE cannot read $fw; make sure the datacenter firewall is enabled, or launch-pve's preflight refuses every job"
  fi
}

ensure_account() {
  if user_exists "$CTL_USER"; then say "account $CTL_USER exists"; return; fi
  run useradd --system --home-dir "$CTL_HOME" --no-create-home --shell /usr/sbin/nologin "$CTL_USER"
}

# install_script NAME — install slots/NAME.sh as LIBEXEC/NAME. launch-pve gets its GHR_INSTALLED
# marker flipped to 1 (see launch-pve.sh): the root-owned copy then ignores every override variable.
install_script() {
  local s=$1 tmp
  case "$s" in
    launch-pve)
      if [ "$DRY" -eq 1 ]; then
        echo "DRY: install -m 0755 -o root -g root $SRC/$s.sh $LIBEXEC/$s (with GHR_INSTALLED=1)"
        return
      fi
      tmp=$(mktemp "${TMPDIR:-/tmp}/ghr-script.XXXXXX")
      sed 's/^GHR_INSTALLED=0/GHR_INSTALLED=1/' "$SRC/$s.sh" > "$tmp"
      grep -q '^GHR_INSTALLED=1' "$tmp" || { rm -f "$tmp"; echo "failed to mark $s as installed" >&2; exit 1; }
      install -m 0755 -o root -g root "$tmp" "$LIBEXEC/$s"
      rm -f "$tmp"
      ;;
    *) run install -m 0755 -o root -g root "$SRC/$s.sh" "$LIBEXEC/$s" ;;
  esac
}

# Source file -> installed name (".sh" stripped). No heartbeat, pool or launch (macOS-only) here.
SCRIPTS="slot-loop slot-unit mint-jit reconcile launch-pve"
LIBS="gh-app pve-fw pve-guest"

install_files() {
  local s
  run install -d -m 0755 -o root -g root "$LIBEXEC" "$LIBEXEC/lib" "$ETC_DIR"
  for s in $SCRIPTS; do install_script "$s"; done
  for s in $LIBS; do run install -m 0644 -o root -g root "$SRC/lib/$s.sh" "$LIBEXEC/lib/$s.sh"; done
  if [ -e "$CONFIG_DEST" ]; then
    say "config exists, not overwriting: $CONFIG_DEST"
  else
    run install -m 0644 -o root -g root "${CONFIG_SRC:-$SRC/config.example.env}" "$CONFIG_DEST"
    say "EDIT $CONFIG_DEST (org, App ids, PVE_SLOTS, PVE_IPCONFIG_<n>, LAN_PROBE) before the slots can work"
  fi
  run install -d -m 0700 -o "$CTL_USER" -g "$CTL_USER" "$CTL_HOME"
  run install -d -m 0755 -o root -g root "$STATE_ROOT"
  run install -d -m 0755 -o "$CTL_USER" -g "$CTL_USER" "$STATE_ROOT/slots"
}

install_keys() {
  if [ -n "$RUNNER_KEY" ]; then
    run install -m 0400 -o "$CTL_USER" -g "$CTL_USER" "$RUNNER_KEY" "$CTL_HOME/runner-app.pem"
  elif [ ! -e "$CTL_HOME/runner-app.pem" ]; then
    say "TODO: place the runner App key at $CTL_HOME/runner-app.pem (0400, owner $CTL_USER) and point RUNNER_APP_KEY at it"
  fi
}

install_sudoers() {
  local defaults="Defaults!$LIBEXEC/launch-pve env_reset, !setenv, secure_path=\"/usr/sbin:/usr/bin:/sbin:/bin\""
  local rule="$CTL_USER ALL=(root) NOPASSWD: $LIBEXEC/launch-pve"
  if [ "$DRY" -eq 1 ]; then
    echo "DRY: write sudoers drop-in $SUDOERS_FILE:"
    echo "DRY:   $defaults"
    echo "DRY:   $rule"
    echo "DRY: (validated with visudo -cf before install)"
    return
  fi
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/ghr-sudoers.XXXXXX")
  # WHY the Defaults line: the caller must not inject environment (!setenv) and launch-pve must see a
  # fixed PATH.
  printf '%s\n%s\n' "$defaults" "$rule" > "$tmp"
  # CRITICAL: never install a sudoers file that fails validation -- it can lock out sudo entirely.
  visudo -cf "$tmp" > /dev/null || { rm -f "$tmp"; echo "sudoers validation failed" >&2; exit 1; }
  install -m 0440 -o root -g root "$tmp" "$SUDOERS_FILE"
  rm -f "$tmp"
}

# install_units — render the template unit, then enable one instance per PVE_SLOTS entry. A running
# instance is NOT restarted (that would block until its job ends): it gets SIGTERM, finishes its job,
# exits, and Restart=always brings it back with the new scripts. Instances of slots that left
# PVE_SLOTS are disabled with --no-block for the same reason.
install_units() {
  local tmp n active wanted
  wanted=$(pve_slots)
  tmp=$(mktemp "${TMPDIR:-/tmp}/ghr-unit.XXXXXX")
  render_unit "$SRC/systemd/ghr-slot@.service" "$tmp" CTL_USER="$CTL_USER" CTL_HOME="$CTL_HOME" STATE_ROOT="$STATE_ROOT" LIBEXEC="$LIBEXEC"
  run install -m 0644 -o root -g root "$tmp" "$UNIT_DIR/ghr-slot@.service"
  rm -f "$tmp"
  run systemctl daemon-reload
  for n in $(seq 1 "$PVE_MAX"); do
    if grep -qx "$n" <<< "$wanted"; then
      active=0
      if [ "$DRY" -eq 0 ] && systemctl is-active --quiet "ghr-slot@supabase-$n.service"; then active=1; fi
      if [ "$active" -eq 1 ]; then
        say "ghr-slot@supabase-$n: running, SIGTERM so it reloads the new scripts after its current job"
        run systemctl kill --kill-whom=main --signal=SIGTERM "ghr-slot@supabase-$n.service"
      else
        run systemctl enable --now "ghr-slot@supabase-$n.service"
      fi
    elif [ "$DRY" -eq 1 ] || systemctl is-enabled --quiet "ghr-slot@supabase-$n.service" 2> /dev/null; then
      run systemctl disable --now --no-block "ghr-slot@supabase-$n.service"
    fi
  done
}

do_uninstall() {
  local n
  for n in $(seq 1 "$PVE_MAX"); do
    run systemctl disable --now --no-block "ghr-slot@supabase-$n.service" 2> /dev/null || true
  done
  run rm -f "$UNIT_DIR/ghr-slot@.service" "$SUDOERS_FILE"
  run systemctl daemon-reload
  run rm -rf "$LIBEXEC"
  run rm -rf "$STATE_ROOT/slots"
  if [ "$PURGE" -eq 1 ]; then
    run rm -rf "$ETC_DIR" "$STATE_ROOT" "$CTL_HOME"
    if [ "$DRY" -eq 1 ] || user_exists "$CTL_USER"; then run userdel "$CTL_USER"; fi
  else
    say "kept config ($ETC_DIR), key ($CTL_HOME) and account; use --purge to remove them"
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) DRY=1 ;;
      --uninstall) UNINSTALL=1 ;;
      --purge) PURGE=1 ;;
      --runner-key) RUNNER_KEY=${2:?}; shift ;;
      --config) CONFIG_SRC=${2:?}; shift ;;
      -h | --help) sed -n '2,3p' "${BASH_SOURCE[0]}"; exit 0 ;;
      *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"
  if [ "$DRY" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then echo "must run as root" >&2; exit 1; fi
  if [ "$UNINSTALL" -eq 1 ]; then do_uninstall; exit 0; fi
  check_install_dirs || exit 1
  preflight_checks
  ensure_account
  install_files
  install_keys
  install_sudoers
  install_units
  say "done"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
