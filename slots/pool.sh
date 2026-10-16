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

set -euo pipefail

LIMACTL="${LIMACTL:-/usr/local/bin/limactl}"
POOL_INSTANCE="${POOL_INSTANCE:-ghr-pool}"
POOL_GOLDEN="${POOL_GOLDEN:-ghr-pool-golden}"
POOL_LOCK_WAIT="${POOL_LOCK_WAIT:-900}"

pool_log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] pool: $*" >&2; }

# NOTE: lock under /tmp, not $HOME: only `ghr` ever runs this, and a sudo-inherited HOME may not be writable.
# Serialise concurrent ensure calls: six slot loops can all hit a stopped VM at once and a
# double `limactl clone/start` would fail or corrupt. mkdir is the portable atomic lock.
pool_lock() {
  local lock="${GHR_POOL_LOCK:-/tmp/ghr-pool.lock}" waited=0 owner
  while ! mkdir "$lock" 2> /dev/null; do
    owner=$(cat "$lock/pid" 2> /dev/null || true)
    # Reap a lock whose owner died (crash/kill) so the pool can't wedge forever.
    if [ -n "$owner" ] && ! kill -0 "$owner" 2> /dev/null; then
      rm -rf "$lock"
      continue
    fi
    [ "$waited" -lt "$POOL_LOCK_WAIT" ] || { pool_log "ERROR lock wait exceeded"; return 1; }
    sleep 2
    waited=$((waited + 2))
  done
  echo "$$" > "$lock/pid"
  POOL_LOCK_HELD="$lock"
}
pool_unlock() { [ -z "${POOL_LOCK_HELD:-}" ] || rm -rf "$POOL_LOCK_HELD"; }

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
