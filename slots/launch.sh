#!/bin/bash
# launch.sh <class> <n> — run ONE ephemeral runner for slot <class>-<n> (light: container in the
# shared pool VM; supabase: a throwaway per-job Lima VM; ios: a throwaway per-job Tart macOS VM).
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
# ios class: same shape with Tart instead of Lima. `ghr-ios-1` is cloned from the STOPPED golden
# (IOS_GOLDEN), booted headless by a background `tart run` (it blocks for the VM's lifetime), the
# guest agent is awaited, the LAN preflight runs INSIDE the guest (`tart exec ... nc`), then the
# runner starts through `tart exec -i` with the JIT on stdin. The VM is stopped + deleted on every
# exit path. Tart's NAT traffic is forwarded by the kernel and is NOT covered by the `user ghr` pf
# rules, so the in-guest preflight is the enforcement check (images/ios/README.md has the anchor).
#
# Exit codes: 0/N = runner's own exit code, 2 = bad args/stdin/config, 3 = preflight refused
# (guest can reach the LAN), 124 = job timeout hit.
#
# Dependencies: lib/gh-app.sh (config), pool.sh (ensure), limactl (light, supabase), tart (ios).

# CRITICAL (privilege boundary): pin PATH before anything else so no external is resolved from
# a caller-controlled directory (sudo's secure_path is the belt, this is the braces).
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
# WHY a literal marker instead of an env switch: install.sh rewrites this line to 1 in the
# root-owned installed copy. A caller cannot set a shell variable assigned inside the script, so
# only the repo/test copy (0) honours the override variables below.
GHR_INSTALLED=0
if [ "$GHR_INSTALLED" = 1 ]; then
  # Caller overrides AND config-owned settings: the root-owned config file is the only source.
  unset LIMA_HOME BASH_ENV ENV CDPATH GHR_CONFIG LIMACTL POOL_INSTANCE POOL_GOLDEN \
    JOB_TIMEOUT_SECS SUPA_GOLDEN SUPA_DESTROY_TIMEOUT GHR_POOL_LOCK POOL_LOCK_WAIT TMPDIR GH_API_BASE \
    ORG RUNNER_GROUP_ID LIGHT_SLOTS LIGHT_LABELS LIGHT_IMAGE ALLOWED_LABELS LAN_PROBE \
    SUPABASE_SLOTS SUPABASE_LABELS SUPA_MEM SUPA_CPUS \
    TART TART_HOME TART_NO_AUTO_PRUNE IOS_SLOTS IOS_LABELS IOS_MEM_MB IOS_CPUS IOS_GOLDEN IOS_RUNNER_DIR \
    IOS_BOOT_TIMEOUT IOS_BOOT_POLL IOS_STOP_TIMEOUT IOS_LAN_PROBES IOS_KEYCHAIN IOS_KEYCHAIN_PASS SECURITY
fi

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=slots/lib/gh-app.sh
. "$HERE/lib/gh-app.sh"

LIMACTL="${LIMACTL:-/usr/local/bin/limactl}"
POOL_INSTANCE="${POOL_INSTANCE:-ghr-pool}"
LIGHT_MAX=6
SUPA_MAX=3
# macOS licensing allows 2 VMs per host; we use 1 (memory). Config may lower it, never raise it.
IOS_MAX=1
TART="${TART:-/usr/local/bin/tart}"
# Absolute: PATH is pinned, and this binary handles the keychain password.
SECURITY="${SECURITY:-/usr/bin/security}"
IOS_GOLDEN="${IOS_GOLDEN:-ghr-ios-golden}"
IOS_MEM_MB="${IOS_MEM_MB:-8192}"
IOS_CPUS="${IOS_CPUS:-4}"
IOS_RUNNER_DIR="${IOS_RUNNER_DIR:-/Users/admin/actions-runner}"
# macOS boot to a reachable guest agent is ~1-2 min; poll every IOS_BOOT_POLL s up to IOS_BOOT_TIMEOUT s.
IOS_BOOT_TIMEOUT="${IOS_BOOT_TIMEOUT:-300}"
IOS_BOOT_POLL="${IOS_BOOT_POLL:-5}"
# `tart stop` is bounded separately from delete: a wedged guest must not hold the slot for minutes.
IOS_STOP_TIMEOUT="${IOS_STOP_TIMEOUT:-30}"
SUPA_GOLDEN="${SUPA_GOLDEN:-ghr-supa-golden}"
# Upper bound for each stop/delete/list of a per-job VM; a hung limactl must not hang the slot.
SUPA_DESTROY_TIMEOUT="${SUPA_DESTROY_TIMEOUT:-120}"
# 6 h = GitHub's maximum job time; anything longer is a wedge.
JOB_TIMEOUT_SECS="${JOB_TIMEOUT_SECS:-21600}"

# Resolve a sibling script whether run from the repo (foo.sh) or installed (foo).
sibling() { if [ -x "$HERE/$1" ]; then echo "$HERE/$1"; else echo "$HERE/$1.sh"; fi; }

launch_validate_args() {
  local class=$1 n=$2 max cfg
  case "$class" in
    light) max=$LIGHT_MAX; cfg=${LIGHT_SLOTS:-$LIGHT_MAX} ;;
    supabase) max=$SUPA_MAX; cfg=${SUPABASE_SLOTS:-0} ;;
    ios) max=$IOS_MAX; cfg=${IOS_SLOTS:-0} ;;
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

# launch_validate_ios — VM sizing, golden and runner dir come from root-owned config but are still
# validated: they end up in tart argv and in a guest `cd`.
launch_validate_ios() {
  [[ "${IOS_MEM_MB:-}" =~ ^[1-9][0-9]{3,5}$ ]] || { echo "launch: IOS_MEM_MB must be MiB, e.g. 8192" >&2; return 1; }
  [[ "${IOS_CPUS:-}" =~ ^[1-9][0-9]?$ ]] || { echo "launch: IOS_CPUS must be 1..99" >&2; return 1; }
  # WHY leading alnum: a leading "-" would be parsed by tart as an option.
  [[ "${IOS_GOLDEN:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "launch: IOS_GOLDEN invalid" >&2; return 1; }
  # The golden must never collide with the per-slot names the destroy path is allowed to delete.
  ! [[ "$IOS_GOLDEN" =~ ^ghr-ios-[0-9]+$ ]] || { echo "launch: IOS_GOLDEN collides with a slot VM name" >&2; return 1; }
  [[ "${IOS_RUNNER_DIR:-}" =~ ^/[A-Za-z0-9._/-]+$ ]] || { echo "launch: IOS_RUNNER_DIR invalid" >&2; return 1; }
  ghr_valid_probe_list "${IOS_LAN_PROBES:-}" || { echo "launch: IOS_LAN_PROBES must be a non-empty host:port list" >&2; return 1; }
  [[ "${IOS_KEYCHAIN:-}" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "${IOS_KEYCHAIN_PASS:-}" =~ ^/[A-Za-z0-9._/-]+$ ]] \
    || { echo "launch: IOS_KEYCHAIN/IOS_KEYCHAIN_PASS invalid" >&2; return 1; }
  [[ "${IOS_BOOT_TIMEOUT:-}" =~ ^[1-9][0-9]{0,4}$ ]] && [[ "${IOS_BOOT_POLL:-}" =~ ^[1-9][0-9]?$ ]] \
    && [[ "${IOS_STOP_TIMEOUT:-}" =~ ^[1-9][0-9]{0,3}$ ]] || { echo "launch: IOS_BOOT_TIMEOUT/IOS_BOOT_POLL/IOS_STOP_TIMEOUT invalid" >&2; return 1; }
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

# ── egress preflight: one verdict, one probe per transport ──────────────────────
# preflight_probe_<transport> INSTANCE HOST PORT — run the connect probe INSIDE the guest and print
# nothing; return 0 = the guest CAN reach the target, 1 = it cannot (blocked), 2 = the probe result
# is uninterpretable. The shared verdict in launch_preflight is the only place that decides.

preflight_ready_lima() { "$LIMACTL" shell "$1" -- true < /dev/null > /dev/null 2>&1; }
preflight_probe_lima() {
  # Only rc 1 (connect refused/unreachable) and 124 (timeout: packets dropped) mean "blocked".
  # 0 = reachable; anything else (2 syntax, 126/127 missing tool, 255 ssh failure) is a probe we
  # cannot interpret, and an uninterpretable probe must not pass. /usr/bin/timeout runs in the
  # Linux guest, not on the host.
  "$LIMACTL" shell "$1" -- /usr/bin/timeout 5 bash -c "exec 3<>/dev/tcp/${2}/${3}" < /dev/null > /dev/null 2>&1
  case $? in 0) return 0 ;; 1 | 124) return 1 ;; *) return 2 ;; esac
}

preflight_ready_tart() { run_bounded 20 "$TART" exec "$1" /usr/bin/true < /dev/null > /dev/null 2>&1; }
preflight_probe_tart() {
  # macOS guest: /usr/bin/nc -z -G <connect timeout> (no -w: it misreports on this guest). nc exits 1
  # on refusal, unreachable and timeout alike (= blocked); 0 = connected. 127/126 (no nc), a `tart exec` transport error and signals
  # are uninterpretable. The agent was proven reachable by preflight_ready_tart right before.
  # CRITICAL: the nc exit code is echoed INSIDE the guest and read from stdout. An exit 1 of `tart exec`
  # itself (agent or transport error) would otherwise be indistinguishable from nc's "blocked".
  local out
  out=$(run_bounded 30 "$TART" exec "$1" /bin/sh -c '/usr/bin/nc -z -G 5 "$1" "$2" > /dev/null 2>&1; echo GHR_NC_RC=$?' _ "$2" "$3" < /dev/null 2> /dev/null) || return 2
  case "$out" in GHR_NC_RC=0) return 0 ;; GHR_NC_RC=1) return 1 ;; *) return 2 ;; esac
}

# ghr_valid_probe_list LIST — non-empty, space/comma separated host:port entries.
ghr_valid_probe_list() {
  local p n=0
  for p in ${1//,/ }; do
    [[ "$p" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*:[0-9]+$ ]] || return 1
    n=$((n + 1))
  done
  [ "$n" -gt 0 ]
}

# launch_preflight [INSTANCE [TRANSPORT]] — exit 0 iff the guest (default: the pool VM, transport
# lima) CANNOT reach ANY probe target. Targets: LAN_PROBE (lima) / every entry of IOS_LAN_PROBES (tart).
# WHY a separate ios list: LAN_PROBE is the HOST's own LAN address, which a Tart NAT guest cannot reach
# even with no filtering at all, so it would prove nothing there. Pick targets that ARE reachable when
# unfiltered (a LAN device, the vmnet gateway's sshd).
# WHY from inside the guest: the pf rule blocks the VM's egress; checking from the host would
# prove nothing. Fails closed: no/invalid targets or an unusable guest shell is a refusal.
launch_preflight() {
  local inst=${1:-$POOL_INSTANCE} tr=${2:-lima} targets probe rc
  case $tr in tart) targets=${IOS_LAN_PROBES:-} ;; *) targets=${LAN_PROBE:-} ;; esac
  ghr_valid_probe_list "$targets" || { ghr_log "preflight: probe target(s) unset/invalid, refusing"; return 3; }
  "preflight_ready_$tr" "$inst" || { ghr_log "preflight: guest shell unusable, refusing"; return 3; }
  for probe in ${targets//,/ }; do
    rc=0
    "preflight_probe_$tr" "$inst" "${probe%:*}" "${probe##*:}" || rc=$?
    case $rc in
      1) ;;
      0) ghr_log "preflight: guest CAN reach $probe -- egress isolation broken, refusing"; return 3 ;;
      *) ghr_log "preflight: probe result uninterpretable, refusing"; return 3 ;;
    esac
  done
  return 0
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

# run_bounded SECS CMD... — run CMD, kill it if it outlives SECS (no host `timeout` on macOS).
# Returns CMD's status, or 143/137 when the bound fired.
run_bounded() {
  local secs=$1 pid wd rc=0
  shift
  "$@" &
  pid=$!
  ( sleep "$secs" & sp=$!
    trap 'kill "$sp" 2> /dev/null; exit 0' TERM
    wait "$sp"
    kill -TERM "$pid" 2> /dev/null
    sleep 1
    kill -KILL "$pid" 2> /dev/null ) &
  wd=$!
  wait "$pid" || rc=$?
  kill "$wd" 2> /dev/null
  wait "$wd" 2> /dev/null || true
  return "$rc"
}

# supa_destroy VM — stop + delete (bounded), then VERIFY the VM is gone via `limactl list`.
# Returns 1 and logs a loud LEAK error if it is not. Never touches the golden: callers only ever
# pass per-slot names, and the golden name is refused here too.
supa_destroy() {
  local vm=$1 attempt status=""
  [ "$vm" != "$SUPA_GOLDEN" ] || { ghr_log "ERROR refusing to destroy the golden"; return 1; }
  for attempt in 1 2; do
    run_bounded "$SUPA_DESTROY_TIMEOUT" "$LIMACTL" stop -f "$vm" < /dev/null > /dev/null 2>&1 \
      || ghr_log "WARN limactl stop -f $vm failed or timed out (attempt $attempt)"
    run_bounded "$SUPA_DESTROY_TIMEOUT" "$LIMACTL" delete -f "$vm" < /dev/null > /dev/null 2>&1 \
      || ghr_log "WARN limactl delete -f $vm failed or timed out (attempt $attempt)"
    status=$("$LIMACTL" list "$vm" --format '{{.Status}}' < /dev/null 2> /dev/null || true)
    [ -z "$status" ] && return 0
  done
  ghr_log "ERROR LEAK: VM $vm still present ($status) after cleanup"
  return 1
}

# supa_sweep — delete ghr-supa-* VMs that do not correspond to a configured slot (crashed runs,
# a lowered SUPABASE_SLOTS, hand-made strays). Configured slots may be mid-job on another slot loop,
# so they are never touched; the golden never is either.
supa_sweep() {
  local names name n keep
  names=$(run_bounded "$SUPA_DESTROY_TIMEOUT" "$LIMACTL" list --format '{{.Name}}' < /dev/null 2> /dev/null || true)
  for name in $names; do
    case "$name" in ghr-supa-*) ;; *) continue ;; esac
    [ "$name" != "$SUPA_GOLDEN" ] || continue
    keep=0
    if [[ "$name" =~ ^ghr-supa-([1-9][0-9]*)$ ]]; then
      n=${BASH_REMATCH[1]}
      [ "$n" -le "${SUPABASE_SLOTS:-0}" ] && [ "$n" -le "$SUPA_MAX" ] && keep=1
    fi
    [ "$keep" -eq 1 ] || { ghr_log "supabase: sweeping orphan VM $name"; supa_destroy "$name" || true; }
  done
}

# supa_run N JIT — clone the golden, boot, preflight, run the runner natively, always delete.
supa_run() {
  local n=$1 jit=$2 vm="ghr-supa-$1" rc=0 status
  [ "$vm" != "$SUPA_GOLDEN" ] || return 2
  # The golden must exist and be STOPPED (APFS CoW clone needs a quiescent source); we do not
  # "fix" it by stopping or starting it -- that is the build script's job.
  status=$("$LIMACTL" list "$SUPA_GOLDEN" --format '{{.Status}}' < /dev/null 2> /dev/null || true)
  [ "$status" = "Stopped" ] || { ghr_log "supabase: golden $SUPA_GOLDEN is '${status:-missing}', need Stopped"; return 1; }
  supa_sweep
  # Leftover from a crashed run (same slot, same name) must go before we clone over it.
  status=$("$LIMACTL" list "$vm" --format '{{.Status}}' < /dev/null 2> /dev/null || true)
  if [ -n "$status" ]; then
    ghr_log "supabase: removing leftover $vm ($status)"
    supa_destroy "$vm" || return 1
  fi
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
  # A leaked VM is a failure even when the job passed: surface it so the slot backs off and the
  # next job's sweep retries.
  if supa_destroy "$vm"; then SUPA_VM=""; elif [ "$rc" -eq 0 ]; then rc=1; fi
  return "$rc"
}

# ── ios class: one throwaway Tart macOS VM per job ────────────────────────────

# tart_vm_states — print `name<TAB>state` for every LOCAL Tart VM (state: stopped|running|suspended).
# Return 1 when `tart list` fails or its output is not parseable, so callers can tell "the VM is
# gone" from "I could not look".
# NOTE: this is the ONLY place that knows the `tart list --format json` shape: a JSON array of
# objects with "Name", "State" (older builds only a "Running" bool) and "Source" (local|OCI). OCI
# cache entries are skipped. UNVERIFIED against a populated list on a real host -- correct HERE
# if the live shape differs.
tart_vm_states() {
  local out
  out=$(run_bounded "$SUPA_DESTROY_TIMEOUT" "$TART" list --format json < /dev/null 2> /dev/null) || return 1
  printf '%s' "$out" | python3 -I -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(d, list):
    sys.exit(1)
for v in d:
    if not isinstance(v, dict) or str(v.get("Source", "local")).lower() == "oci":
        continue
    name = str(v.get("Name", ""))
    st = str(v.get("State") or ("running" if v.get("Running") else "stopped")).lower()
    if name and "\t" not in name and "\n" not in name:
        print("%s\t%s" % (name, st))
'
}

# tart_state VM — print the VM's state ("" = no such local VM). Returns 1 if the list is unavailable.
tart_state() {
  local lines
  lines=$(tart_vm_states) || return 1
  printf '%s\n' "$lines" | awk -F'\t' -v nm="$1" '$1 == nm && !f { print $2; f = 1 }'
}

# ios_reap_run — make sure the background `tart run` is gone (it exits by itself once the VM stops).
ios_reap_run() {
  [ -n "${IOS_RUN_PID:-}" ] || return 0
  for _ in 1 2 3; do kill -0 "$IOS_RUN_PID" 2> /dev/null || break; sleep 1; done
  if kill -0 "$IOS_RUN_PID" 2> /dev/null; then
    kill -TERM "$IOS_RUN_PID" 2> /dev/null
    sleep 1
    kill -KILL "$IOS_RUN_PID" 2> /dev/null
  fi
  wait "$IOS_RUN_PID" 2> /dev/null || true
  IOS_RUN_PID=""
}

# ios_destroy VM — bounded `tart stop`, reap the background `tart run`, bounded `tart delete`, then
# VERIFY the VM is gone via `tart list`. Returns 1 and logs a loud LEAK error if it is not (also
# when the list itself is unavailable: "could not look" is not "gone"). Same contract as
# supa_destroy; the golden name is refused outright.
ios_destroy() {
  local vm=$1 attempt st
  [ "$vm" != "$IOS_GOLDEN" ] || { ghr_log "ERROR refusing to destroy the golden"; return 1; }
  for attempt in 1 2; do
    run_bounded "$IOS_STOP_TIMEOUT" "$TART" stop "$vm" < /dev/null > /dev/null 2>&1 \
      || ghr_log "WARN tart stop $vm failed or timed out (attempt $attempt)"
    ios_reap_run
    run_bounded "$SUPA_DESTROY_TIMEOUT" "$TART" delete "$vm" < /dev/null > /dev/null 2>&1 \
      || ghr_log "WARN tart delete $vm failed or timed out (attempt $attempt)"
    if st=$(tart_state "$vm") && [ -z "$st" ]; then return 0; fi
  done
  ghr_log "ERROR LEAK: VM $vm still present or unverifiable after cleanup"
  return 1
}

# ios_sweep — delete ghr-ios-<n> VMs that do not correspond to a configured slot (crashed runs, a
# lowered IOS_SLOTS). Only canonical per-slot names are candidates: the golden (ghr-ios-golden) and
# the build VM (ghr-ios-build, images/build-ios.sh runs as this same account) never match.
ios_sweep() {
  local lines name n keep
  lines=$(tart_vm_states) || { ghr_log "ios: cannot list VMs, skipping sweep"; return 0; }
  for name in $(printf '%s\n' "$lines" | cut -f1); do
    [[ "$name" =~ ^ghr-ios-[0-9]+$ ]] || continue
    keep=0
    if [[ "$name" =~ ^ghr-ios-([1-9][0-9]*)$ ]]; then
      n=${BASH_REMATCH[1]}
      [ "$n" -le "${IOS_SLOTS:-0}" ] && [ "$n" -le "$IOS_MAX" ] && keep=1
    fi
    [ "$keep" -eq 1 ] || { ghr_log "ios: sweeping orphan VM $name"; ios_destroy "$name" || true; }
  done
}

# ios_wait_agent — poll the guest agent (`tart exec VM /usr/bin/true`) until it answers. Fails early
# when the background `tart run` died, on a signal, or after IOS_BOOT_TIMEOUT seconds.
ios_wait_agent() {
  local vm=$1 t0 now
  t0=$(date -u +%s)
  while :; do
    [ "$SIGNALLED" -eq 0 ] || return 143
    kill -0 "$IOS_RUN_PID" 2> /dev/null || { ghr_log "ios: tart run exited before the guest agent answered"; return 1; }
    run_bounded 20 "$TART" exec "$vm" /usr/bin/true < /dev/null > /dev/null 2>&1 && return 0
    now=$(date -u +%s)
    [ "$((now - t0))" -lt "$IOS_BOOT_TIMEOUT" ] || { ghr_log "ios: guest agent not up after ${IOS_BOOT_TIMEOUT}s"; return 1; }
    sleep "$IOS_BOOT_POLL"
  done
}

# ios_fail VM — destroy on an early-exit path and forget the VM only if it is verifiably gone (the EXIT
# trap keeps the backstop when it is not).
ios_fail() { if ios_destroy "$1"; then IOS_VM=""; fi; }

# ios_check_keychain_pass — the keychain password file must be a regular file (not a link) owned by the
# running user with mode 0400 or 0600; anything looser means someone else could have read or planted it.
ios_check_keychain_pass() {
  local f=$IOS_KEYCHAIN_PASS mode owner
  if [ -f "$f" ] && ! [ -L "$f" ]; then
    # GNU stat first: BSD stat rejects -c, while GNU stat -f means "filesystem" and would not fail.
    { read -r mode owner < <(stat -c '%a %u' "$f" 2> /dev/null || stat -f '%Lp %u' "$f" 2> /dev/null); } || true
    if { [ "$mode" = 400 ] || [ "$mode" = 600 ]; } && [ "$owner" = "$(id -u)" ]; then return 0; fi
  fi
  ghr_log "ios: keychain password file $f must be a regular file owned by $(id -un) with mode 0400/0600, refusing"
  return 1
}

# ios_run N JIT — clone the golden, boot headless, wait for the agent, preflight, run the runner
# through the agent, always delete.
ios_run() {
  local n=$1 jit=$2 vm="ghr-ios-$1" rc=0 st
  [ "$vm" != "$IOS_GOLDEN" ] || return 2
  # Same rule as the supabase golden: it must exist and be STOPPED; fixing it is the build script's job.
  st=$(tart_state "$IOS_GOLDEN") || { ghr_log "ios: cannot read the VM list"; return 1; }
  [ "$st" = "stopped" ] || { ghr_log "ios: golden $IOS_GOLDEN is '${st:-missing}', need stopped"; return 1; }
  ios_sweep
  st=$(tart_state "$vm") || { ghr_log "ios: cannot read the VM list"; return 1; }
  if [ -n "$st" ]; then
    ghr_log "ios: removing leftover $vm ($st)"
    ios_destroy "$vm" || return 1
  fi
  ios_check_keychain_pass || return 1
  # From here on the VM must not outlive this call, whatever happens.
  IOS_VM=$vm
  "$TART" clone "$IOS_GOLDEN" "$vm" < /dev/null > /dev/null \
    || { ghr_log "ios: clone failed"; ios_fail "$vm"; return 1; }
  "$TART" set "$vm" --cpu "$IOS_CPUS" --memory "$IOS_MEM_MB" --random-mac < /dev/null > /dev/null \
    || { ghr_log "ios: set failed"; ios_fail "$vm"; return 1; }
  # CRITICAL: a macOS guest cannot start (VZErrorDomain -9 "Failed to get current host key") unless the
  # VM owner's login keychain exists and is UNLOCKED. The password reaches `security` on STDIN only
  # (no -p: argv is world-readable). Failure = refuse; the VM is never started.
  "$SECURITY" unlock-keychain "$IOS_KEYCHAIN" < "$IOS_KEYCHAIN_PASS" > /dev/null 2>&1 \
    || { ghr_log "ios: cannot unlock the login keychain $IOS_KEYCHAIN (see images/ios/README.md), refusing"; ios_fail "$vm"; return 1; }
  # `tart run` blocks for the VM's whole life: background it, stdin closed, output to our stderr
  # (the slot log).
  "$TART" run "$vm" --no-graphics --no-audio < /dev/null >&2 &
  IOS_RUN_PID=$!
  rc=0
  ios_wait_agent "$vm" || rc=$?
  [ "$rc" -eq 0 ] || { ios_fail "$vm"; return "$rc"; }
  [ "$SIGNALLED" -eq 0 ] || { ios_fail "$vm"; return 143; }
  launch_preflight "$vm" tart || { rc=$?; ios_fail "$vm"; return "$rc"; }
  [ "$SIGNALLED" -eq 0 ] || { ios_fail "$vm"; return 143; }
  # The guest agent runs the command as the guest's default user (admin); read -r pulls the JIT
  # from stdin (-i attaches ours), same convention as the other classes. The dir is an argument,
  # not interpolated into the script.
  # LOGIN shell (-l): pod/fastlane (rbenv), node, pnpm, openjdk and xcbeautify are on PATH only there.
  run_watched "$jit" "$TART" exec -i "$vm" /bin/bash -lc \
    'cd "$1" && read -r J && exec ./run.sh --jitconfig "$J"' _ "$IOS_RUNNER_DIR" || rc=$?
  if ios_destroy "$vm"; then IOS_VM=""; elif [ "$rc" -eq 0 ]; then rc=1; fi
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
  # WHY forced, not defaulted: the keychain and its password file are ghr's own, never caller input.
  IOS_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
  IOS_KEYCHAIN_PASS="$HOME/.ghr/keychain.pass"
  if [ "$GHR_INSTALLED" != 1 ]; then
    IOS_KEYCHAIN="${TEST_IOS_KEYCHAIN:-$IOS_KEYCHAIN}"
    IOS_KEYCHAIN_PASS="${TEST_IOS_KEYCHAIN_PASS:-$IOS_KEYCHAIN_PASS}"
  fi
  launch_validate_args "$1" "$2" || exit 2
  local class=$1 n=$2 cname="ghr-$1-$2" jit=""
  IFS= read -r jit || true
  [[ "$jit" =~ ^[A-Za-z0-9+/=_-]+$ ]] || { echo "launch: stdin is not a JIT config" >&2; exit 2; }
  case "$class" in
    light) launch_validate_image "${LIGHT_IMAGE:-}" || { echo "launch: LIGHT_IMAGE must be pinned by @sha256 digest or be a local sha256: image ID" >&2; exit 2; } ;;
    supabase) launch_validate_supa || exit 2 ;;
    ios) launch_validate_ios || exit 2 ;;
  esac
  TIMEOUT_FLAG=$(mktemp "${TMPDIR:-/tmp}/ghr-launch.XXXXXX") || exit 1
  SIGNALLED=0
  SUPA_VM=""
  IOS_VM=""
  IOS_RUN_PID=""
  # CRITICAL: a signal must still reach the cleanup below; the trap only records it and kills the
  # job, the straight-line code after run_watched() then deletes the VM. The EXIT trap is the
  # backstop for any path that bails out earlier.
  trap 'SIGNALLED=1; [ -z "${LAUNCH_CHILD:-}" ] || kill -TERM "$LAUNCH_CHILD" 2> /dev/null' TERM INT HUP
  trap '[ -z "${SUPA_VM:-}" ] || supa_destroy "$SUPA_VM"; [ -z "${IOS_VM:-}" ] || ios_destroy "$IOS_VM"; rm -f "$TIMEOUT_FLAG"' EXIT
  if [ "$class" = "supabase" ]; then
    supa_run "$n" "$jit"
    exit $?
  fi
  if [ "$class" = "ios" ]; then
    # WHY: `tart clone` prunes the OCI cache to make room unless told not to; the pulled base image
    # is operator-managed and must never be evicted by a job.
    export TART_NO_AUTO_PRUNE=1
    ios_run "$n" "$jit"
    exit $?
  fi
  "$(sibling pool)" ensure || exit 1
  launch_preflight || exit 3
  launch_run "$cname" "$jit"
  exit $?
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
