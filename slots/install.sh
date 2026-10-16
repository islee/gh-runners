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
NEWSYSLOG_FILE="${GHR_NEWSYSLOG:-/etc/newsyslog.d/ghr.conf}"
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

# mkfile OWNER PATH — create an empty 0640 file (BSD install rejects /dev/null as a source).
# WHY 0640: logs can contain runner names and API error snippets; owner + root group only.
mkfile() {
  run touch "$2"
  run chown "$1" "$2"
  run chmod 0640 "$2"
}

# secure_dir PATH [any-owner] — refuse to install into a directory another user could swap
# files in: it must not be group/other-writable and (unless any-owner) must be owned by root.
# Missing directories are fine (we create them). ALLOW_NONROOT_OWNER=1 is for tests only.
secure_dir() {
  local d=$1 anyowner=${2:-0} line perms uid
  [ -e "$d" ] || return 0
  line=$(ls -ldn "$d")
  perms=${line%% *}
  uid=$(echo "$line" | awk '{print $3}')
  case "${perms:5:1}${perms:8:1}" in
    *w*) echo "refusing to install: $d is group/other-writable ($perms)" >&2; return 1 ;;
  esac
  if [ "$anyowner" != 1 ] && [ "${GHR_ALLOW_NONROOT_OWNER:-0}" != 1 ] && [ "$uid" != 0 ]; then
    echo "refusing to install: $d is not owned by root (uid $uid)" >&2
    return 1
  fi
}

check_install_dirs() {
  local d
  for d in /usr/local "$(dirname "$LIBEXEC")" "$LIBEXEC" "$LIBEXEC/lib" "$(dirname "$ETC_DIR")" "$ETC_DIR"; do
    secure_dir "$d" || return 1
  done
  # role homes hold the keys: owned by the role account, but never writable by others
  for d in "/var/db/$CTL_USER" "/var/db/$STATE_USER"; do secure_dir "$d" 1 || return 1; done
}

# install_script NAME — install slots/NAME.sh as LIBEXEC/NAME. launch and pool get their
# GHR_INSTALLED marker flipped to 1 (see launch.sh): the root-owned copies then ignore every
# caller-controlled override variable.
install_script() {
  local s=$1 tmp
  case "$s" in
    launch | pool)
      if [ "$DRY" -eq 1 ]; then
        echo "DRY: install -m 0755 -o root -g wheel $SRC/$s.sh $LIBEXEC/$s (with GHR_INSTALLED=1)"
        return
      fi
      tmp=$(mktemp "${TMPDIR:-/tmp}/ghr-script.XXXXXX")
      sed 's/^GHR_INSTALLED=0/GHR_INSTALLED=1/' "$SRC/$s.sh" > "$tmp"
      grep -q '^GHR_INSTALLED=1' "$tmp" || { rm -f "$tmp"; echo "failed to mark $s as installed" >&2; exit 1; }
      install -m 0755 -o root -g wheel "$tmp" "$LIBEXEC/$s"
      rm -f "$tmp"
      ;;
    *) run install -m 0755 -o root -g wheel "$SRC/$s.sh" "$LIBEXEC/$s" ;;
  esac
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
  for s in $SCRIPTS; do install_script "$s"; done
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
  install_newsyslog
}

# install_newsyslog — size-based rotation. NOTE: launchd keeps StandardOutPath open, so a rotated
# file keeps receiving writes until the daemon restarts; the N flag stops newsyslog signalling.
install_newsyslog() {
  local tmp n
  if [ "$DRY" -eq 1 ]; then
    echo "DRY: write $NEWSYSLOG_FILE (rotate $LOGDIR/*.log at 5 MB, keep 5, mode 640)"
    return
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/ghr-newsyslog.XXXXXX")
  {
    echo "# logfilename [owner:group] mode count size(KB) when flags"
    for n in $(seq 1 "$(slot_count)"); do echo "$LOGDIR/slot-light-$n.log $CTL_USER:wheel 640 5 5120 * JN"; done
    echo "$LOGDIR/heartbeat.log $STATE_USER:wheel 640 5 5120 * JN"
    echo "$LOGDIR/pool.log ghr:wheel 640 5 5120 * JN"
  } > "$tmp"
  install -d -m 0755 -o root -g wheel "$(dirname "$NEWSYSLOG_FILE")"
  install -m 0644 -o root -g wheel "$tmp" "$NEWSYSLOG_FILE"
  rm -f "$tmp"
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
  local defaults="Defaults!$LIBEXEC/launch env_reset, !setenv, always_set_home, secure_path=\"/usr/bin:/bin:/usr/sbin:/sbin\""
  local rule="$CTL_USER ALL=(ghr) NOPASSWD: $LIBEXEC/launch"
  if [ "$DRY" -eq 1 ]; then
    echo "DRY: write sudoers drop-in $SUDOERS_FILE:"
    echo "DRY:   $defaults"
    echo "DRY:   $rule"
    echo "DRY: (validated with visudo -cf before install)"
    return
  fi
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/ghr-sudoers.XXXXXX")
  # WHY the Defaults line: the caller must not be able to inject environment (!setenv), and the
  # launch script must see a fixed PATH and ghr's HOME.
  printf '%s\n%s\n' "$defaults" "$rule" > "$tmp"
  # CRITICAL: never install a sudoers file that fails validation -- it can lock out sudo entirely.
  visudo -cf "$tmp" > /dev/null || { rm -f "$tmp"; echo "sudoers validation failed" >&2; exit 1; }
  install -m 0440 -o root -g wheel "$tmp" "$SUDOERS_FILE"
  rm -f "$tmp"
}

# wait_unloaded LABEL — bootout is asynchronous; bootstrapping before the old job is gone fails
# with an I/O error. Bounded wait (30 s).
wait_unloaded() {
  local label=$1 i=0
  if [ "$DRY" -eq 1 ]; then echo "DRY: wait up to 30s until launchctl print system/$label fails"; return; fi
  while launchctl print "system/$label" > /dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -le 30 ] || { echo "timeout waiting for $label to unload" >&2; return 1; }
    sleep 1
  done
}

bootstrap_daemon() {
  local label=$1 plist=$2
  # bootout first so a re-run picks up a changed plist (ignore "not loaded").
  run launchctl bootout "system/$label" 2> /dev/null || true
  wait_unloaded "$label"
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
  run plutil -lint "$tmp/hb.plist"
  run install -m 0644 -o root -g wheel "$tmp/hb.plist" "$DAEMON_DIR/dev.ghr.heartbeat.plist"
  bootstrap_daemon dev.ghr.heartbeat "$DAEMON_DIR/dev.ghr.heartbeat.plist"
  render_plist "$SRC/launchd/dev.ghr.pool.plist" "$tmp/pool.plist" LIBEXEC="$LIBEXEC" GHR_HOME="$ghr_home" LOGDIR="$LOGDIR"
  run plutil -lint "$tmp/pool.plist"
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
  run rm -f "$SUDOERS_FILE" "$NEWSYSLOG_FILE"
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
  check_install_dirs || exit 1
  ensure_account "$CTL_USER" "$CTL_UID"
  ensure_account "$STATE_USER" "$STATE_UID"
  install_files
  install_keys
  install_sudoers
  install_daemons
  say "done"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
