#!/bin/bash
# install.sh [--dry-run] [--uninstall [--purge]] [--runner-key F] [--state-key F] [--config F]
#
# Installs the slot controllers on the Mac mini host. Run as root (sudo). Idempotent: re-running
# converges; existing config and keys are never overwritten.
#
# What it does (in order):
#   1. role accounts _ghrctl (mints runners, runs slot loops) and _ghrstate (heartbeat only),
#      via sysadminctl -roleAccount (no login shell, no GUI, homes under /var/db)
#   2. directories: /var/db/ghr (_ghrstate), /var/db/ghr/slots (_ghrctl), /usr/local/libexec/ghr
#      and /usr/local/etc/ghr (root), /var/log/ghr
#   3. scripts -> /usr/local/libexec/ghr (root:wheel 0755; `.sh` stripped; lib/gh-app.sh alongside)
#   4. config -> /usr/local/etc/ghr/slots.env (root 0644, NO secrets; only created if absent)
#   5. optional App keys -> /var/db/_ghrctl/runner-app.pem, /var/db/_ghrstate/state-app.pem (0400)
#   6. sudoers drop-in letting _ghrctl run ONLY the launch script as `ghr` (validated by visudo -c)
#   7. render + bootstrap LaunchDaemons: dev.ghr.slot.light-1..N, dev.ghr.heartbeat, dev.ghr.pool
# --uninstall reverses 3,6,7 and the state dir; --purge additionally removes config, keys, logs
# and the role accounts (the `ghr` account and its Lima VMs are never touched).
# --dry-run prints every action instead of executing it (no root needed, writes nothing).
#
# Dependencies: macOS (sysadminctl, dscl, launchctl, plutil, visudo). Source-guarded so tests can
# call render_plist / main-less helpers without side effects.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBEXEC="${GHR_LIBEXEC:-/usr/local/libexec/ghr}"
ETC_DIR="${GHR_ETC:-/usr/local/etc/ghr}"
CONFIG_DEST="$ETC_DIR/slots.env"
STATE_ROOT="${GHR_STATE_ROOT:-/var/db/ghr}"
LOGDIR="${GHR_LOGDIR:-/var/log/ghr}"
DAEMON_DIR="${GHR_DAEMON_DIR:-/Library/LaunchDaemons}"
SUDOERS_FILE="${GHR_SUDOERS:-/etc/sudoers.d/ghr}"
CTL_USER=_ghrctl
STATE_USER=_ghrstate
# NOTE: spec says "UID 4xx"; sysadminctl's documented role-account range is narrower on some
# releases. Override with GHRCTL_UID / GHRSTATE_UID if the host rejects these.
CTL_UID="${GHRCTL_UID:-451}"
STATE_UID="${GHRSTATE_UID:-452}"
MAX_SLOTS=6

DRY=0
UNINSTALL=0
PURGE=0
RUNNER_KEY=""
STATE_KEY=""
CONFIG_SRC=""

say() { echo "[install] $*"; }

# run CMD... — execute, or print in --dry-run. Everything state-changing goes through here.
run() {
  if [ "$DRY" -eq 1 ]; then echo "DRY: $*"; else "$@"; fi
}

# render_plist TEMPLATE OUT KEY=VAL... — substitute @KEY@ placeholders. Values come from this
# script (paths, class, slot number), never from user input, so sed delimiters are safe.
render_plist() {
  local tpl=$1 out=$2 expr="" kv
  shift 2
  for kv in "$@"; do expr="$expr -e s|@${kv%%=*}@|${kv#*=}|g"; done
  # shellcheck disable=SC2086
  sed $expr "$tpl" > "$out"
}

# mkfile OWNER PATH — create an empty 0644 file (BSD install rejects /dev/null as a source).
mkfile() {
  run touch "$2"
  run chown "$1" "$2"
  run chmod 0644 "$2"
}

user_exists() { dscl . -read "/Users/$1" > /dev/null 2>&1; }

user_home() {
  if [ "$DRY" -eq 1 ] && ! user_exists "$1"; then echo "/Users/$1"; return; fi
  dscl . -read "/Users/$1" NFSHomeDirectory 2> /dev/null | awk '{print $2}'
}

slot_count() {
  local n=""
  if [ -r "$CONFIG_DEST" ]; then n=$(sed -n 's/^LIGHT_SLOTS=\([0-9]*\).*/\1/p' "$CONFIG_DEST" | head -1); fi
  if [ -z "$n" ]; then n=$(sed -n 's/^LIGHT_SLOTS=\([0-9]*\).*/\1/p' "${CONFIG_SRC:-$SRC/config.example.env}" | head -1); fi
  [[ "$n" =~ ^[0-9]+$ ]] || n=6
  [ "$n" -le "$MAX_SLOTS" ] || n=$MAX_SLOTS
  echo "$n"
}

# Source file -> installed name (".sh" stripped; launch.sh must become exactly `launch`).
SCRIPTS="slot-loop mint-jit reconcile launch heartbeat pool"

ensure_account() {
  local name=$1 uid=$2
  if user_exists "$name"; then say "account $name exists"; return; fi
  run sysadminctl -addUser "$name" -UID "$uid" -roleAccount -fullName "ghr $name" -home "/var/db/$name" -shell /usr/bin/false
  run install -d -m 0700 -o "$name" "/var/db/$name"
}

install_files() {
  local s
  run install -d -m 0755 -o root -g wheel "$LIBEXEC" "$LIBEXEC/lib" "$ETC_DIR"
  for s in $SCRIPTS; do
    run install -m 0755 -o root -g wheel "$SRC/$s.sh" "$LIBEXEC/$s"
  done
  run install -m 0644 -o root -g wheel "$SRC/lib/gh-app.sh" "$LIBEXEC/lib/gh-app.sh"
  if [ -e "$CONFIG_DEST" ]; then
    say "config exists, not overwriting: $CONFIG_DEST"
  else
    run install -m 0644 -o root -g wheel "${CONFIG_SRC:-$SRC/config.example.env}" "$CONFIG_DEST"
    say "EDIT $CONFIG_DEST (org, App ids, repos, image digest) before the daemons can work"
  fi
  run install -d -m 0755 -o "$STATE_USER" "$STATE_ROOT"
  run install -d -m 0755 -o "$CTL_USER" "$STATE_ROOT/slots"
  run install -d -m 0755 -o root -g wheel "$LOGDIR"
  # launchd opens StandardOutPath as the job's user only on some releases; pre-creating the files
  # with the right owner removes the question.
  local n
  for n in $(seq 1 "$(slot_count)"); do
    mkfile "$CTL_USER" "$LOGDIR/slot-light-$n.log"
  done
  mkfile "$STATE_USER" "$LOGDIR/heartbeat.log"
  mkfile ghr "$LOGDIR/pool.log"
}

install_keys() {
  if [ -n "$RUNNER_KEY" ]; then
    run install -m 0400 -o "$CTL_USER" "$RUNNER_KEY" "/var/db/$CTL_USER/runner-app.pem"
  elif [ ! -e "/var/db/$CTL_USER/runner-app.pem" ]; then
    say "TODO: place the runner App key at /var/db/$CTL_USER/runner-app.pem (0400, owner $CTL_USER)"
  fi
  if [ -n "$STATE_KEY" ]; then
    run install -m 0400 -o "$STATE_USER" "$STATE_KEY" "/var/db/$STATE_USER/state-app.pem"
  elif [ ! -e "/var/db/$STATE_USER/state-app.pem" ]; then
    say "TODO: place the state App key at /var/db/$STATE_USER/state-app.pem (0400, owner $STATE_USER)"
  fi
}

install_sudoers() {
  local rule="$CTL_USER ALL=(ghr) NOPASSWD: $LIBEXEC/launch"
  if [ "$DRY" -eq 1 ]; then
    echo "DRY: write sudoers drop-in $SUDOERS_FILE: $rule (validated with visudo -cf before install)"
    return
  fi
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/ghr-sudoers.XXXXXX")
  printf '%s\n' "$rule" > "$tmp"
  # CRITICAL: never install a sudoers file that fails validation -- it can lock out sudo entirely.
  visudo -cf "$tmp" > /dev/null || { rm -f "$tmp"; echo "sudoers validation failed" >&2; exit 1; }
  install -m 0440 -o root -g wheel "$tmp" "$SUDOERS_FILE"
  rm -f "$tmp"
}

bootstrap_daemon() {
  local label=$1 plist=$2
  # bootout first so a re-run picks up a changed plist (ignore "not loaded").
  run launchctl bootout "system/$label" 2> /dev/null || true
  run launchctl bootstrap system "$plist"
}

install_daemons() {
  local n count plist tmp ctl_home state_home ghr_home
  count=$(slot_count)
  ctl_home=$(user_home "$CTL_USER")
  state_home=$(user_home "$STATE_USER")
  ghr_home=$(user_home ghr)
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/ghr-plists.XXXXXX")
  for n in $(seq 1 "$count"); do
    plist="$DAEMON_DIR/dev.ghr.slot.light-$n.plist"
    render_plist "$SRC/launchd/dev.ghr.slot.plist" "$tmp/slot.plist" CLASS=light N="$n" LIBEXEC="$LIBEXEC" CTL_HOME="$ctl_home" LOGDIR="$LOGDIR"
    run plutil -lint "$tmp/slot.plist"
    run install -m 0644 -o root -g wheel "$tmp/slot.plist" "$plist"
    bootstrap_daemon "dev.ghr.slot.light-$n" "$plist"
  done
  render_plist "$SRC/launchd/dev.ghr.heartbeat.plist" "$tmp/hb.plist" LIBEXEC="$LIBEXEC" STATE_HOME="$state_home" LOGDIR="$LOGDIR"
  run install -m 0644 -o root -g wheel "$tmp/hb.plist" "$DAEMON_DIR/dev.ghr.heartbeat.plist"
  bootstrap_daemon dev.ghr.heartbeat "$DAEMON_DIR/dev.ghr.heartbeat.plist"
  render_plist "$SRC/launchd/dev.ghr.pool.plist" "$tmp/pool.plist" LIBEXEC="$LIBEXEC" GHR_HOME="$ghr_home" LOGDIR="$LOGDIR"
  run install -m 0644 -o root -g wheel "$tmp/pool.plist" "$DAEMON_DIR/dev.ghr.pool.plist"
  bootstrap_daemon dev.ghr.pool "$DAEMON_DIR/dev.ghr.pool.plist"
  rm -rf "$tmp"
  # Slots beyond the configured count (LIGHT_SLOTS lowered) must not keep running.
  for n in $(seq "$((count + 1))" "$MAX_SLOTS"); do
    if [ -e "$DAEMON_DIR/dev.ghr.slot.light-$n.plist" ]; then
      run launchctl bootout "system/dev.ghr.slot.light-$n" 2> /dev/null || true
      run rm -f "$DAEMON_DIR/dev.ghr.slot.light-$n.plist"
    fi
  done
}

do_uninstall() {
  local n
  for n in $(seq 1 "$MAX_SLOTS"); do
    run launchctl bootout "system/dev.ghr.slot.light-$n" 2> /dev/null || true
    run rm -f "$DAEMON_DIR/dev.ghr.slot.light-$n.plist"
  done
  for n in heartbeat pool; do
    run launchctl bootout "system/dev.ghr.$n" 2> /dev/null || true
    run rm -f "$DAEMON_DIR/dev.ghr.$n.plist"
  done
  run rm -f "$SUDOERS_FILE"
  run rm -rf "$LIBEXEC"
  run rm -rf "$STATE_ROOT/slots"
  if [ "$PURGE" -eq 1 ]; then
    run rm -rf "$ETC_DIR" "$STATE_ROOT" "$LOGDIR"
    for n in "$CTL_USER" "$STATE_USER"; do
      if [ "$DRY" -eq 1 ] || user_exists "$n"; then
        run sysadminctl -deleteUser "$n"
        run rm -rf "/var/db/$n"
      fi
    done
  else
    say "kept config ($ETC_DIR), keys, logs and accounts; use --purge to remove them"
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) DRY=1 ;;
      --uninstall) UNINSTALL=1 ;;
      --purge) PURGE=1 ;;
      --runner-key) RUNNER_KEY=${2:?}; shift ;;
      --state-key) STATE_KEY=${2:?}; shift ;;
      --config) CONFIG_SRC=${2:?}; shift ;;
      -h | --help) sed -n '2,3p' "${BASH_SOURCE[0]}"; exit 0 ;;
      *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"
  if [ "$DRY" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then echo "must run as root (sudo)" >&2; exit 1; fi
  if [ "$UNINSTALL" -eq 1 ]; then do_uninstall; exit 0; fi
  if [ "$DRY" -eq 0 ]; then id ghr > /dev/null 2>&1 || { echo "account 'ghr' (Lima VM owner) must exist first" >&2; exit 1; }; fi
  ensure_account "$CTL_USER" "$CTL_UID"
  ensure_account "$STATE_USER" "$STATE_UID"
  install_files
  install_keys
  install_sudoers
  install_daemons
  say "done"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
