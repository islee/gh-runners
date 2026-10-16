#!/bin/bash
# pool.sh ensure|rebuild — manage the Lima pool VM (`ghr-pool`) that hosts the runner containers.
#
# Context: runs as the `ghr` user (owner of the Lima VMs). Called by launch.sh before every job
# (cheap no-op when the VM is running) and by the dev.ghr.pool boot LaunchDaemon.
#   ensure  : clone ghr-pool from ghr-pool-golden if missing, start it if stopped.
#   rebuild : stub (nightly golden rebuild is P1+); exits 64 so nothing mistakes it for success.
#
# Dependencies: limactl (LIMACTL, default /usr/local/bin/limactl).
# NOTE: `limactl start` leaves a long-lived host agent behind; the launchd job that ends up
# running this therefore sets AbandonProcessGroup, or launchd would kill the VM on exit.

# CRITICAL: launch.sh (the sudo boundary) runs this script; same hardening as launch.sh.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
GHR_INSTALLED=0   # install.sh rewrites to 1 in the root-owned copy; see launch.sh
if [ "$GHR_INSTALLED" = 1 ]; then
  unset LIMA_HOME BASH_ENV ENV CDPATH LIMACTL POOL_INSTANCE POOL_GOLDEN POOL_LOCK_WAIT GHR_POOL_LOCK TMPDIR
fi

set -euo pipefail

LIMACTL="${LIMACTL:-/usr/local/bin/limactl}"
POOL_INSTANCE="${POOL_INSTANCE:-ghr-pool}"
POOL_GOLDEN="${POOL_GOLDEN:-ghr-pool-golden}"
POOL_LOCK_WAIT="${POOL_LOCK_WAIT:-900}"

pool_log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] pool: $*" >&2; }

# Serialise concurrent ensure calls: six slot loops can all hit a stopped VM at once and a
# double `limactl clone/start` would fail or corrupt.
# WHY a symlink lock: `ln -s <pid> lock` creates the lock AND its owner record atomically, so a
# crash can never leave an empty/garbled pid file (the failure mode of mkdir+echo). A target that
# is not a live pid is stale and is taken over by rename (mv), which only one reaper can win.
# NOTE: the residual race (a reaper moving a lock someone else just re-created) is detected and
# undone below; at worst two ensure calls overlap and `limactl start` fails loudly and is retried
# by the next launch.
pool_lock_path() { echo "${GHR_POOL_LOCK:-${HOME:?HOME unset}/.ghr/pool.lock}"; }

pool_lock() {
  local lock waited=0 owner moved
  lock=$(pool_lock_path)
  mkdir -p "$(dirname "$lock")" && chmod 700 "$(dirname "$lock")" || return 1
  while ! ln -s "$$" "$lock" 2> /dev/null; do
    owner=$(readlink "$lock" 2> /dev/null || true)
    if ! [[ "$owner" =~ ^[0-9]+$ ]] || ! kill -0 "$owner" 2> /dev/null; then
      moved="$lock.reap.$$"
      if mv "$lock" "$moved" 2> /dev/null; then
        if [ "$(readlink "$moved" 2> /dev/null || true)" = "$owner" ]; then
          rm -f "$moved"
        else
          # We moved a lock that was re-created in the meantime: put it back.
          ln -s "$(readlink "$moved" 2> /dev/null || echo 0)" "$lock" 2> /dev/null || true
          rm -f "$moved"
        fi
      fi
      continue
    fi
    [ "$waited" -lt "$POOL_LOCK_WAIT" ] || { pool_log "ERROR lock wait exceeded"; return 1; }
    sleep 2
    waited=$((waited + 2))
  done
  POOL_LOCK_HELD="$lock"
}
pool_unlock() {
  [ -z "${POOL_LOCK_HELD:-}" ] && return 0
  # Only remove a lock that is still ours.
  [ "$(readlink "$POOL_LOCK_HELD" 2> /dev/null || true)" = "$$" ] && rm -f "$POOL_LOCK_HELD"
  return 0
}

pool_status() {
  "$LIMACTL" list "$POOL_INSTANCE" --format '{{.Status}}' < /dev/null 2> /dev/null || true
}

pool_ensure() {
  local status
  status=$(pool_status)
  [ "$status" = "Running" ] && return 0
  pool_lock || return 1
  trap pool_unlock EXIT
  # Re-check under the lock: another caller may have finished the start while we waited.
  status=$(pool_status)
  case "$status" in
    Running) return 0 ;;
    Stopped)
      pool_log "starting $POOL_INSTANCE"
      # < /dev/null: limactl would otherwise swallow our stdin.
      "$LIMACTL" start "$POOL_INSTANCE" --tty=false < /dev/null
      ;;
    "")
      pool_log "creating $POOL_INSTANCE from $POOL_GOLDEN"
      "$LIMACTL" clone "$POOL_GOLDEN" "$POOL_INSTANCE" --tty=false < /dev/null
      "$LIMACTL" start "$POOL_INSTANCE" --tty=false < /dev/null
      ;;
    *)
      pool_log "ERROR $POOL_INSTANCE in unexpected state: $status"
      return 1
      ;;
  esac
}

main() {
  case "${1:-}" in
    ensure) pool_ensure ;;
    rebuild) pool_log "rebuild is not implemented in P1"; exit 64 ;;
    *) echo "usage: pool.sh ensure|rebuild" >&2; exit 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
