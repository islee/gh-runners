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

# CRITICAL (privilege boundary): pin PATH before anything else so no external is resolved from
# a caller-controlled directory (sudo's secure_path is the belt, this is the braces).
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
# WHY a literal marker instead of an env switch: install.sh rewrites this line to 1 in the
# root-owned installed copy. A caller cannot set a shell variable assigned inside the script, so
# only the repo/test copy (0) honours the override variables below.
GHR_INSTALLED=0
if [ "$GHR_INSTALLED" = 1 ]; then
  unset LIMA_HOME BASH_ENV ENV CDPATH GHR_CONFIG LIMACTL POOL_INSTANCE POOL_GOLDEN \
    JOB_TIMEOUT_SECS GHR_POOL_LOCK POOL_LOCK_WAIT TMPDIR GH_API_BASE
fi

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

# The image must be immutable: either repo@sha256:<digest> or a bare LOCAL image ID
# (sha256:<64 hex>, as printed by images/build-light.sh). A mutable tag would let an upstream push
# change the code that runs with the JIT credential.
launch_validate_image() {
  local img=${1:-}
  [[ "$img" =~ ^sha256:[0-9a-f]{64}$ ]] && return 0
  # WHY leading [a-z0-9]: a leading "-" would be parsed by docker run as an option (--privileged@...).
  [[ "$img" =~ ^[a-z0-9][a-z0-9./_-]*(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}$ ]]
}

# launch_preflight — exit 0 iff the pool guest CANNOT reach the LAN probe target.
# WHY from inside the guest: the pf rule blocks the VM's egress; checking from the host would
# prove nothing. Fails closed: an unset LAN_PROBE or an unusable guest shell is a refusal.
launch_preflight() {
  [[ "${LAN_PROBE:-}" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] || { ghr_log "preflight: LAN_PROBE unset/invalid, refusing"; return 3; }
  local host=${LAN_PROBE%:*} port=${LAN_PROBE##*:}
  "$LIMACTL" shell "$POOL_INSTANCE" -- true < /dev/null > /dev/null 2>&1 \
    || { ghr_log "preflight: guest shell unusable, refusing"; return 3; }
  # Only rc 1 (connect refused/unreachable) and 124 (timeout: packets dropped) mean "blocked".
  # 0 = reachable; anything else (2 syntax, 126/127 missing tool, 255 ssh failure) is a probe we
  # cannot interpret, and an uninterpretable probe must not pass. /usr/bin/timeout runs in the
  # Linux guest, not on the host.
  "$LIMACTL" shell "$POOL_INSTANCE" -- /usr/bin/timeout 5 bash -c "exec 3<>/dev/tcp/${host}/${port}" < /dev/null > /dev/null 2>&1
  case $? in
    1 | 124) return 0 ;;
    0) ghr_log "preflight: guest CAN reach $LAN_PROBE -- egress isolation broken, refusing"; return 3 ;;
    *) ghr_log "preflight: probe result uninterpretable, refusing"; return 3 ;;
  esac
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
  # place. Installed copy: take ghr's home from the account database (dscl), never from the
  # environment, and fail closed. Repo/test copy keeps the caller's HOME (no dscl on CI).
  if [ "$GHR_INSTALLED" = 1 ]; then
    local me home
    me=$(id -un) || exit 2
    home=$(dscl . -read "/Users/$me" NFSHomeDirectory 2> /dev/null | awk '{print $2}')
    [[ "$home" =~ ^/[A-Za-z0-9._/-]+$ ]] && [ -d "$home" ] || { echo "launch: cannot resolve home for $me" >&2; exit 2; }
    HOME=$home
    export HOME
  fi
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
