#!/bin/bash
# reload-slot.sh <label> <plist> — bootstrap a slot daemon once its old incarnation has exited.
#
# Context: scheduled by install.sh (as the one-shot LaunchDaemon dev.ghr.reload.<slot>) when a
# re-install changed a slot's plist while that slot was running a job. `"$LAUNCHCTL" bootout` returns
# immediately but the job (up to 6 h) keeps running and the label stays loaded, so install.sh's
# bounded wait expires. Instead of failing the install (and leaving the slot gone once the old loop
# exits), the install hands over to this script: wait for the label to disappear, then bootstrap
# the already-installed new plist, then remove the helper's own plist and unload it.
#
# WHY a launchd job and not a background shell: macOS `nohup` fails without a controlling
# terminal, and a child of the install shell dies with its session. A LaunchDaemon outlives
# install.sh by construction. Its plist lives under $ETC_DIR/reload (root-owned, NOT in
# /Library/LaunchDaemons), so a reboot does not re-run a stale helper: at boot launchd loads the
# new slot plist itself.
#
# Bounds: RELOAD_MAX_WAIT seconds (default 25200 = 7 h, longer than the 6 h job maximum),
# polling every RELOAD_POLL seconds. Validates its arguments: it runs as root.
# Dependencies: launchctl (LAUNCHCTL, default /bin/launchctl).

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
# Same convention as launch.sh: install.sh flips this to 1 in the root-owned copy, which then
# ignores every override variable (this script runs as root).
GHR_INSTALLED=0
if [ "$GHR_INSTALLED" = 1 ]; then
  unset LAUNCHCTL RELOAD_MAX_WAIT RELOAD_POLL GHR_DAEMON_DIR RELOAD_HELPER_PLIST BASH_ENV ENV CDPATH
fi

set -uo pipefail

LAUNCHCTL="${LAUNCHCTL:-/bin/launchctl}"
RELOAD_MAX_WAIT="${RELOAD_MAX_WAIT:-25200}"
RELOAD_POLL="${RELOAD_POLL:-5}"
DAEMON_DIR="${GHR_DAEMON_DIR:-/Library/LaunchDaemons}"

log() { echo "[reload-slot] $*" >&2; }

main() {
  [ "$#" -eq 2 ] || { echo "usage: reload-slot.sh <label> <plist>" >&2; exit 2; }
  local label=$1 plist=$2 waited=0 helper_label helper_plist
  [[ "$label" =~ ^dev\.ghr\.slot\.(light|supabase|ios)-[1-9]$ ]] || { echo "invalid label" >&2; exit 2; }
  [ "$plist" = "$DAEMON_DIR/$label.plist" ] || { echo "plist must be $DAEMON_DIR/$label.plist" >&2; exit 2; }
  [ -f "$plist" ] || { echo "no such plist: $plist" >&2; exit 2; }
  helper_label="dev.ghr.reload.${label#dev.ghr.slot.}"

  while "$LAUNCHCTL" print "system/$label" > /dev/null 2>&1; do
    if [ "$waited" -ge "$RELOAD_MAX_WAIT" ]; then
      log "ERROR $label still loaded after ${RELOAD_MAX_WAIT}s; giving up (run install.sh again)"
      exit 1
    fi
    sleep "$RELOAD_POLL"
    waited=$((waited + RELOAD_POLL))
  done
  log "$label has exited; bootstrapping the new plist"
  if ! "$LAUNCHCTL" bootstrap system "$plist"; then
    sleep "$RELOAD_POLL"
    "$LAUNCHCTL" bootstrap system "$plist" || { log "ERROR bootstrap of $label failed"; exit 1; }
  fi
  # Self-cleanup: the helper plist is only a handover record.
  helper_plist="${RELOAD_HELPER_PLIST:-}"
  [ -z "$helper_plist" ] || rm -f "$helper_plist"
  "$LAUNCHCTL" bootout "system/$helper_label" 2> /dev/null || true
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
