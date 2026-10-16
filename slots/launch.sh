#!/bin/bash
# launch.sh <class> <n> — run ONE ephemeral runner container for slot <class>-<n>.
#
# Context: installed root-owned as /usr/local/libexec/ghr/launch and invoked by slot-loop.sh via
#   printf %s "$JIT" | sudo -n -u ghr /usr/local/libexec/ghr/launch light 3
# so it runs as `ghr`, the owner of the Lima VMs (the pf egress rule matches that user). The
# sudoers rule lets _ghrctl run exactly this one path, which makes THIS SCRIPT the privilege
# boundary: everything it receives (args, stdin) is treated as hostile and validated.
#
# CRITICAL: the JIT config arrives on STDIN only. It is never placed in argv or the environment
# on the host (visible to every local user via ps). It is forwarded the same way into the
# container, whose entrypoint does `read -r J; exec ./run.sh --jitconfig "$J"`.
#
# Exit codes: 0/N = runner's own exit code, 2 = bad args/stdin/config, 3 = preflight refused
# (guest can reach the LAN), 124 = job timeout hit.
#
# Dependencies: lib/gh-app.sh (config), pool.sh (ensure), limactl.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=slots/lib/gh-app.sh
. "$HERE/lib/gh-app.sh"

LIMACTL="${LIMACTL:-/usr/local/bin/limactl}"
POOL_INSTANCE="${POOL_INSTANCE:-ghr-pool}"
LIGHT_MAX=6
# 6 h = GitHub's maximum job time; anything longer is a wedge.
JOB_TIMEOUT_SECS="${JOB_TIMEOUT_SECS:-21600}"

# Resolve a sibling script whether run from the repo (foo.sh) or installed (foo).
sibling() { if [ -x "$HERE/$1" ]; then echo "$HERE/$1"; else echo "$HERE/$1.sh"; fi; }

launch_validate_args() {
  local class=$1 n=$2
  [ "$class" = "light" ] || { echo "launch: unsupported class: $class" >&2; return 1; }
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "launch: invalid slot number" >&2; return 1; }
  [ "$n" -le "$LIGHT_MAX" ] || { echo "launch: slot out of range 1..$LIGHT_MAX" >&2; return 1; }
  [ "$n" -le "${LIGHT_SLOTS:-$LIGHT_MAX}" ] || { echo "launch: slot beyond configured LIGHT_SLOTS" >&2; return 1; }
}

# The image must be pinned by digest: a mutable tag would let a registry change swap the code
# that runs with the JIT credential.
launch_validate_image() {
  [[ "${1:-}" =~ ^[a-z0-9./_-]+(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}$ ]]
}

# launch_preflight — exit 0 iff the pool guest CANNOT reach the LAN probe target.
# WHY from inside the guest: the pf rule blocks the VM's egress; checking from the host would
# prove nothing. Fails closed: an unset LAN_PROBE or an unusable guest shell is a refusal.
launch_preflight() {
  [[ "${LAN_PROBE:-}" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] || { ghr_log "preflight: LAN_PROBE unset/invalid, refusing"; return 3; }
  local host=${LAN_PROBE%:*} port=${LAN_PROBE##*:}
  "$LIMACTL" shell "$POOL_INSTANCE" -- true < /dev/null > /dev/null 2>&1 \
    || { ghr_log "preflight: guest shell unusable, refusing"; return 3; }
  if "$LIMACTL" shell "$POOL_INSTANCE" -- timeout 5 bash -c "exec 3<>/dev/tcp/${host}/${port}" < /dev/null > /dev/null 2>&1; then
    ghr_log "preflight: guest CAN reach $LAN_PROBE -- egress isolation broken, refusing"
    return 3
  fi
  return 0
}

launch_cleanup() {
  "$LIMACTL" shell "$POOL_INSTANCE" -- sudo docker rm -f "$1" < /dev/null > /dev/null 2>&1 || true
}

# launch_run NAME JIT — run the container with JIT on stdin, enforcing the job timeout.
launch_run() {
  local cname=$1 jit=$2 child watcher rc
  launch_cleanup "$cname"
  # Subshell + builtin printf: the JIT travels only through the pipe.
  ( printf '%s\n' "$jit" | "$LIMACTL" shell "$POOL_INSTANCE" -- sudo docker run --rm -i \
      --name "$cname" --memory 2g --cpus 2 "$LIGHT_IMAGE" \
      bash -c 'read -r J; exec ./run.sh --jitconfig "$J"' ) &
  child=$!
  # WHY sleep+wait+trap: killing a plain `sleep 21600` subshell would orphan the sleep for hours.
  ( sleep "$JOB_TIMEOUT_SECS" & sp=$!
    trap 'kill "$sp" 2> /dev/null; exit 0' TERM
    wait "$sp"
    echo timeout > "$TIMEOUT_FLAG"
    kill -TERM "$child" 2> /dev/null ) &
  watcher=$!
  wait "$child"
  rc=$?
  kill "$watcher" 2> /dev/null
  wait "$watcher" 2> /dev/null
  launch_cleanup "$cname"
  if [ -s "$TIMEOUT_FLAG" ]; then ghr_log "launch: job timeout after ${JOB_TIMEOUT_SECS}s"; return 124; fi
  return "$rc"
}

main() {
  # cwd must be readable by `ghr`: sudo keeps the caller's cwd (_ghrctl's 0700 home).
  cd / || exit 2
  # WHY: limactl locates its instances via $HOME; sudo may leave the caller's (_ghrctl) HOME in
  # place. ~user expands from the account database, not the environment.
  HOME=$(eval echo "~$(id -un)")
  export HOME
  [ "$#" -eq 2 ] || { echo "usage: launch <class> <n>   (JIT config on stdin)" >&2; exit 2; }
  ghr_load_config || exit 2
  launch_validate_args "$1" "$2" || exit 2
  local cname="ghr-$1-$2" jit=""
  IFS= read -r jit || true
  [[ "$jit" =~ ^[A-Za-z0-9+/=_-]+$ ]] || { echo "launch: stdin is not a JIT config" >&2; exit 2; }
  launch_validate_image "${LIGHT_IMAGE:-}" || { echo "launch: LIGHT_IMAGE must be pinned by @sha256 digest" >&2; exit 2; }
  "$(sibling pool)" ensure || exit 1
  launch_preflight || exit 3
  TIMEOUT_FLAG=$(mktemp "${TMPDIR:-/tmp}/ghr-launch.XXXXXX") || exit 1
  trap 'rm -f "$TIMEOUT_FLAG"' EXIT
  launch_run "$cname" "$jit"
  exit $?
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
