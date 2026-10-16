#!/bin/bash
# launch.sh <class> <n> — run ONE ephemeral runner for slot <class>-<n> (light: container in the
# shared pool VM; supabase: a throwaway per-job VM).
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
# supabase class: a fresh Lima VM `ghr-supa-<n>` is cloned from the STOPPED golden for every job,
# the runner runs natively inside it (own Docker daemon and loopback, which `supabase start` needs)
# and the VM is stopped + deleted on EVERY exit path (success, failure, preflight refusal, timeout,
# signal). The golden is never started, stopped, or modified here.
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
    JOB_TIMEOUT_SECS SUPA_GOLDEN GHR_POOL_LOCK POOL_LOCK_WAIT TMPDIR GH_API_BASE
fi

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=slots/lib/gh-app.sh
. "$HERE/lib/gh-app.sh"

LIMACTL="${LIMACTL:-/usr/local/bin/limactl}"
POOL_INSTANCE="${POOL_INSTANCE:-ghr-pool}"
LIGHT_MAX=6
SUPA_MAX=3
SUPA_GOLDEN="${SUPA_GOLDEN:-ghr-supa-golden}"
# 6 h = GitHub's maximum job time; anything longer is a wedge.
JOB_TIMEOUT_SECS="${JOB_TIMEOUT_SECS:-21600}"

# Resolve a sibling script whether run from the repo (foo.sh) or installed (foo).
sibling() { if [ -x "$HERE/$1" ]; then echo "$HERE/$1"; else echo "$HERE/$1.sh"; fi; }

launch_validate_args() {
  local class=$1 n=$2 max cfg
  case "$class" in
    light) max=$LIGHT_MAX; cfg=${LIGHT_SLOTS:-$LIGHT_MAX} ;;
    supabase) max=$SUPA_MAX; cfg=${SUPABASE_SLOTS:-0} ;;
    *) echo "launch: unsupported class: $class" >&2; return 1 ;;
  esac
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "launch: invalid slot number" >&2; return 1; }
  [ "$n" -le "$max" ] || { echo "launch: slot out of range 1..$max" >&2; return 1; }
  [ "$n" -le "$cfg" ] || { echo "launch: slot beyond configured ${class} slots ($cfg)" >&2; return 1; }
}

# launch_validate_supa — VM sizing comes from root-owned config but is still validated: it ends up
# in a yq expression handed to limactl.
launch_validate_supa() {
  [[ "${SUPA_MEM:-}" =~ ^[1-9][0-9]*GiB$ ]] || { echo "launch: SUPA_MEM must look like 4GiB" >&2; return 1; }
  [[ "${SUPA_CPUS:-}" =~ ^[1-9][0-9]?$ ]] || { echo "launch: SUPA_CPUS must be 1..99" >&2; return 1; }
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

# launch_preflight [INSTANCE] — exit 0 iff the guest (default: the pool VM) CANNOT reach the LAN
# probe target.
# WHY from inside the guest: the pf rule blocks the VM's egress; checking from the host would
# prove nothing. Fails closed: an unset LAN_PROBE or an unusable guest shell is a refusal.
launch_preflight() {
  [[ "${LAN_PROBE:-}" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] || { ghr_log "preflight: LAN_PROBE unset/invalid, refusing"; return 3; }
  local host=${LAN_PROBE%:*} port=${LAN_PROBE##*:} inst=${1:-$POOL_INSTANCE}
  "$LIMACTL" shell "$inst" -- true < /dev/null > /dev/null 2>&1 \
    || { ghr_log "preflight: guest shell unusable, refusing"; return 3; }
  # Only rc 1 (connect refused/unreachable) and 124 (timeout: packets dropped) mean "blocked".
  # 0 = reachable; anything else (2 syntax, 126/127 missing tool, 255 ssh failure) is a probe we
  # cannot interpret, and an uninterpretable probe must not pass. /usr/bin/timeout runs in the
  # Linux guest, not on the host.
  "$LIMACTL" shell "$inst" -- /usr/bin/timeout 5 bash -c "exec 3<>/dev/tcp/${host}/${port}" < /dev/null > /dev/null 2>&1
  case $? in
    1 | 124) return 0 ;;
    0) ghr_log "preflight: guest CAN reach $LAN_PROBE -- egress isolation broken, refusing"; return 3 ;;
    *) ghr_log "preflight: probe result uninterpretable, refusing"; return 3 ;;
  esac
}

launch_cleanup() {
  "$LIMACTL" shell "$POOL_INSTANCE" -- sudo docker rm -f "$1" < /dev/null > /dev/null 2>&1 || true
}

# run_watched JIT CMD... — run CMD with the JIT on its stdin under the job-timeout watchdog.
# Returns CMD's exit code, 124 on timeout, 143 if we were signalled.
run_watched() {
  local jit=$1 child watcher rc
  shift
  # Subshell + builtin printf: the JIT travels only through the pipe.
  ( printf '%s\n' "$jit" | "$@" ) &
  child=$!
  LAUNCH_CHILD=$child
  # WHY sleep+wait+trap: killing a plain `sleep 21600` subshell would orphan the sleep for hours.
  ( sleep "$JOB_TIMEOUT_SECS" & sp=$!
    trap 'kill "$sp" 2> /dev/null; exit 0' TERM
    wait "$sp"
    echo timeout > "$TIMEOUT_FLAG"
    kill -TERM "$child" 2> /dev/null ) &
  watcher=$!
  rc=0
  wait "$child" || rc=$?
  # A trapped signal interrupts `wait`; make sure the child is really gone before cleanup.
  if kill -0 "$child" 2> /dev/null; then kill -TERM "$child" 2> /dev/null; wait "$child" 2> /dev/null || true; fi
  kill "$watcher" 2> /dev/null
  wait "$watcher" 2> /dev/null
  if [ -s "$TIMEOUT_FLAG" ]; then ghr_log "launch: job timeout after ${JOB_TIMEOUT_SECS}s"; return 124; fi
  [ "$SIGNALLED" -eq 0 ] || return 143
  return "$rc"
}

# launch_run NAME JIT — light: container in the shared pool VM.
launch_run() {
  local cname=$1 jit=$2 rc
  launch_cleanup "$cname"
  rc=0
  run_watched "$jit" "$LIMACTL" shell "$POOL_INSTANCE" -- sudo docker run --rm -i \
    --name "$cname" --memory 2g --cpus 2 "$LIGHT_IMAGE" \
    bash -c 'read -r J; exec ./run.sh --jitconfig "$J"' || rc=$?
  launch_cleanup "$cname"
  return "$rc"
}

# ── supabase class: one throwaway VM per job ──────────────────────────────────

# supa_destroy VM — stop + delete, tolerating "already gone". Never touches the golden: callers
# only ever pass the per-slot name, and supa_run refuses anything else.
supa_destroy() {
  "$LIMACTL" stop -f "$1" < /dev/null > /dev/null 2>&1 || true
  "$LIMACTL" delete -f "$1" < /dev/null > /dev/null 2>&1 || true
}

# supa_run N JIT — clone the golden, boot, preflight, run the runner natively, always delete.
supa_run() {
  local n=$1 jit=$2 vm="ghr-supa-$1" rc=0 status
  [ "$vm" != "$SUPA_GOLDEN" ] || return 2
  # The golden must exist and be STOPPED (APFS CoW clone needs a quiescent source); we do not
  # "fix" it by stopping or starting it -- that is the build script's job.
  status=$("$LIMACTL" list "$SUPA_GOLDEN" --format '{{.Status}}' < /dev/null 2> /dev/null || true)
  [ "$status" = "Stopped" ] || { ghr_log "supabase: golden $SUPA_GOLDEN is '${status:-missing}', need Stopped"; return 1; }
  # Leftover from a crashed run (same slot, same name) must go before we clone over it.
  status=$("$LIMACTL" list "$vm" --format '{{.Status}}' < /dev/null 2> /dev/null || true)
  [ -z "$status" ] || { ghr_log "supabase: removing leftover $vm ($status)"; supa_destroy "$vm"; }
  # From here on the VM must not outlive this call, whatever happens.
  SUPA_VM=$vm
  "$LIMACTL" clone "$SUPA_GOLDEN" "$vm" --tty=false --set ".cpus = ${SUPA_CPUS} | .memory = \"${SUPA_MEM}\"" < /dev/null > /dev/null \
    || { ghr_log "supabase: clone failed"; supa_destroy "$vm"; return 1; }
  "$LIMACTL" start "$vm" --tty=false < /dev/null > /dev/null \
    || { ghr_log "supabase: start failed"; supa_destroy "$vm"; return 1; }
  # A signal that arrived during the (slow) clone/start must not be followed by a job.
  [ "$SIGNALLED" -eq 0 ] || { supa_destroy "$vm"; return 143; }
  launch_preflight "$vm" || { rc=$?; supa_destroy "$vm"; return "$rc"; }
  [ "$SIGNALLED" -eq 0 ] || { supa_destroy "$vm"; return 143; }
  # The runner runs natively as `runner` (uid 1001); read -r pulls the JIT from stdin inside the
  # guest, same convention as the container path.
  run_watched "$jit" "$LIMACTL" shell "$vm" -- sudo -u runner -H env \
    AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache RUNNER_TOOL_CACHE=/opt/hostedtoolcache \
    bash -c 'cd /opt/actions-runner && read -r J && exec ./run.sh --jitconfig "$J"' || rc=$?
  supa_destroy "$vm"
  SUPA_VM=""
  return "$rc"
}

main() {
  # cwd must be readable by `ghr`: sudo keeps the caller's cwd (_ghrctl's 0700 home).
  cd / || exit 2
  [ "$#" -eq 2 ] || { echo "usage: launch <class> <n>   (JIT config on stdin)" >&2; exit 2; }
  # IMPORTANT: config before HOME. The root-owned config path is fixed in the installed copy, so
  # validating it first needs nothing from the account database; it also keeps the error order the
  # same on Linux CI, which has no dscl.
  ghr_load_config || exit 2
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
  launch_validate_args "$1" "$2" || exit 2
  local class=$1 n=$2 cname="ghr-$1-$2" jit=""
  IFS= read -r jit || true
  [[ "$jit" =~ ^[A-Za-z0-9+/=_-]+$ ]] || { echo "launch: stdin is not a JIT config" >&2; exit 2; }
  if [ "$class" = "light" ]; then
    launch_validate_image "${LIGHT_IMAGE:-}" || { echo "launch: LIGHT_IMAGE must be pinned by @sha256 digest or be a local sha256: image ID" >&2; exit 2; }
  else
    launch_validate_supa || exit 2
  fi
  TIMEOUT_FLAG=$(mktemp "${TMPDIR:-/tmp}/ghr-launch.XXXXXX") || exit 1
  SIGNALLED=0
  SUPA_VM=""
  # CRITICAL: a signal must still reach the cleanup below; the trap only records it and kills the
  # job, the straight-line code after run_watched() then deletes the VM. The EXIT trap is the
  # backstop for any path that bails out earlier.
  trap 'SIGNALLED=1; [ -z "${LAUNCH_CHILD:-}" ] || kill -TERM "$LAUNCH_CHILD" 2> /dev/null' TERM INT HUP
  trap '[ -z "${SUPA_VM:-}" ] || supa_destroy "$SUPA_VM"; rm -f "$TIMEOUT_FLAG"' EXIT
  if [ "$class" = "supabase" ]; then
    supa_run "$n" "$jit"
    exit $?
  fi
  "$(sibling pool)" ensure || exit 1
  launch_preflight || exit 3
  launch_run "$cname" "$jit"
  exit $?
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
