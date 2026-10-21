#!/bin/bash
# launch-pve.sh <class> <n> — run ONE ephemeral supabase-class runner in a throwaway Proxmox VM.
#
# Context: the Proxmox VE counterpart of the supabase path of launch.sh, for the optional second
# host. Installed root-owned 0755 as /usr/local/libexec/ghr/launch-pve and invoked by slot-loop.sh as
#   printf %s "$JIT" | sudo -n -u root /usr/local/libexec/ghr/launch-pve supabase 5
# (root, because `qm` is root-only). The sudoers rule lets the controller account run exactly this
# one path, which makes THIS SCRIPT the privilege boundary: args, stdin and config are validated.
#
# Per job: a fresh VM `ghr-supa-<n>` (VMID = PVE_VMID_BASE + n) is LINKED-cloned from the STOPPED
# golden template (images/build-supabase-pve.sh), given a per-slot static IP and an egress-isolating
# per-VM firewall file (lib/pve-fw.sh), started, preflighted from INSIDE the guest (the LAN probe
# must be unreachable), handed the JIT config over the qemu guest agent, and destroyed on EVERY exit
# path (success, failure, preflight refusal, timeout, signal). The golden is never started, stopped
# or modified here, and nothing but ghr-supa-* VMs inside the slot VMID range is ever destroyed.
#
# CRITICAL: the JIT config arrives on STDIN only. It never appears in argv (host `ps`, the guest
# agent's exec argv) or the environment: it travels `printf | qm guest exec --pass-stdin` into
# `cat > /run/ghr/jit` (tmpfs) and from there the guest unit ghr-runner.service pipes it to the
# runner (images/supabase/ghr-runner-run).
#
# Exit codes: the runner's own exit code when the guest reports it (the guest writes it to
# /var/lib/ghr/exit and the host polls it through the agent before the VM powers off), else 0 when
# the VM powered off by itself (the job's pass/fail is GitHub's business, not this script's);
# 1 = clone/start/golden/leak failure, 2 = bad args/stdin/config, 3 = preflight refused (guest can
# reach the LAN, or the check could not be interpreted), 124 = job timeout hit, 143 = signalled.
#
# Dependencies: lib/gh-app.sh (config + ghr_log), lib/pve-fw.sh, lib/pve-guest.sh, qm, python3 (stdlib; guest-exec JSON), bash 5.

# shellcheck disable=SC2034  # GE_STDIN is consumed by lib/pve-guest.sh
# CRITICAL (privilege boundary): pin PATH before anything else so no external is resolved from a
# caller-controlled directory (sudo's secure_path is the belt, this is the braces).
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
# WHY a literal marker instead of an env switch: install-pve.sh rewrites this line to 1 in the
# root-owned installed copy. A caller cannot set a shell variable assigned inside the script, so
# only the repo/test copy (0) honours the override variables below.
GHR_INSTALLED=0
if [ "$GHR_INSTALLED" = 1 ]; then
  # Caller overrides AND config-owned settings: the root-owned config file is the only source.
  unset BASH_ENV ENV CDPATH GHR_CONFIG QM PVE_FW_DIR PVE_POLL_SECS PVE_AGENT_WAIT_SECS PVE_EXIT_POLL_EVERY \
    JOB_TIMEOUT_SECS SUPA_DESTROY_TIMEOUT TMPDIR GH_API_BASE ORG RUNNER_GROUP_ID \
    ALLOWED_LABELS LAN_PROBE SUPABASE_SLOTS SUPABASE_LABELS SUPA_CPUS SUPA_MEM_MB \
    PVE_SLOTS PVE_VMID_BASE GOLDEN_VMID PVE_NAMESERVER \
    PVE_IPCONFIG_1 PVE_IPCONFIG_2 PVE_IPCONFIG_3 PVE_IPCONFIG_4 PVE_IPCONFIG_5 \
    PVE_IPCONFIG_6 PVE_IPCONFIG_7 PVE_IPCONFIG_8 PVE_IPCONFIG_9
fi

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=slots/lib/gh-app.sh
. "$HERE/lib/gh-app.sh"
# shellcheck source=slots/lib/pve-fw.sh
. "$HERE/lib/pve-fw.sh"
# shellcheck source=slots/lib/pve-guest.sh
. "$HERE/lib/pve-guest.sh"

QM="${QM:-/usr/sbin/qm}"
FW_DIR="${PVE_FW_DIR:-/etc/pve/firewall}"
PVE_MAX=9
# Upper bound for each stop/destroy/list/status of a per-job VM; a hung qm must not hang the slot.
SUPA_DESTROY_TIMEOUT="${SUPA_DESTROY_TIMEOUT:-120}"
# 6 h = GitHub's maximum job time; anything longer is a wedge.
JOB_TIMEOUT_SECS="${JOB_TIMEOUT_SECS:-21600}"
# How long a freshly started VM may take to answer the guest agent.
AGENT_WAIT_SECS="${PVE_AGENT_WAIT_SECS:-240}"
# Poll cadence while the job runs, and how many polls between exit-code reads through the agent.
POLL_SECS="${PVE_POLL_SECS:-5}"
EXIT_POLL_EVERY="${PVE_EXIT_POLL_EVERY:-3}"
GOLDEN_NAME=ghr-supa-golden

# ── validation ────────────────────────────────────────────────────────────────

# slot_listed N — true iff N is one of PVE_SLOTS (space or comma separated).
slot_listed() {
  local s rs=${PVE_SLOTS:-}
  for s in ${rs//,/ }; do [ "$s" = "$1" ] && return 0; done
  return 1
}

launch_validate_args() {
  local class=$1 n=$2
  [ "$class" = supabase ] || { echo "launch-pve: unsupported class: $class (only supabase)" >&2; return 1; }
  [[ "$n" =~ ^[1-9]$ ]] || { echo "launch-pve: invalid slot number (1..$PVE_MAX)" >&2; return 1; }
  slot_listed "$n" || { echo "launch-pve: slot $n is not in PVE_SLOTS" >&2; return 1; }
}

# launch_validate_cfg N — everything below ends up in a `qm` argument or a path, so it is validated
# even though the config is root-owned.
launch_validate_cfg() {
  local n=$1 var
  [[ "${GOLDEN_VMID:-}" =~ ^[1-9][0-9]{2,8}$ ]] || { echo "launch-pve: GOLDEN_VMID must be a VMID (>= 100)" >&2; return 1; }
  [[ "${PVE_VMID_BASE:-}" =~ ^[1-9][0-9]{2,8}$ ]] || { echo "launch-pve: PVE_VMID_BASE must be a VMID base (>= 100)" >&2; return 1; }
  [[ "${PVE_SLOTS:-}" =~ ^[1-9]([\ ,]+[1-9])*$ ]] || { echo "launch-pve: PVE_SLOTS must be digits 1..9, space/comma separated" >&2; return 1; }
  [[ "${SUPA_MEM_MB:-}" =~ ^[1-9][0-9]{2,5}$ ]] || { echo "launch-pve: SUPA_MEM_MB must be MiB, e.g. 4096" >&2; return 1; }
  [[ "${SUPA_CPUS:-}" =~ ^[1-9][0-9]?$ ]] || { echo "launch-pve: SUPA_CPUS must be 1..99" >&2; return 1; }
  [[ "${PVE_NAMESERVER:-}" =~ ^[0-9a-fA-F.:]+( [0-9a-fA-F.:]+)*$ ]] || { echo "launch-pve: PVE_NAMESERVER must be IP addresses, space separated" >&2; return 1; }
  var="PVE_IPCONFIG_$n"
  # WHY a strict shape: the value is spliced into `qm set --ipconfig0`; extra keys (ip6, gw6) are not wanted.
  [[ "${!var:-}" =~ ^ip=(dhcp|[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}(,gw=[0-9]{1,3}(\.[0-9]{1,3}){3})?)$ ]] \
    || { echo "launch-pve: $var must look like ip=192.0.2.50/24,gw=192.0.2.1 (or ip=dhcp)" >&2; return 1; }
  [ "$((PVE_VMID_BASE + n))" -ne "$GOLDEN_VMID" ] || { echo "launch-pve: slot VMID equals GOLDEN_VMID, refusing" >&2; return 1; }
}

# ── helpers ───────────────────────────────────────────────────────────────────

# vm_exists VMID — true iff `qm status` succeeds.
vm_exists() { run_bounded 30 "$QM" status "$1" < /dev/null > /dev/null 2>&1; }

# vm_status VMID — print running|stopped|... or "gone" when qm status fails.
vm_status() {
  local out
  out=$(run_bounded 30 "$QM" status "$1" < /dev/null 2> /dev/null) || { echo gone; return 0; }
  out=${out#status: }
  echo "${out%%[[:space:]]*}"
}

# vmid_in_slot_range VMID — true iff VMID is PVE_VMID_BASE+1 .. +PVE_MAX.
vmid_in_slot_range() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt "$PVE_VMID_BASE" ] && [ "$1" -le "$((PVE_VMID_BASE + PVE_MAX))" ]
}

# vm_name VMID — the VM's configured name (empty if unreadable).
vm_name() {
  local cfg
  cfg=$(run_bounded 30 "$QM" config "$1" < /dev/null 2> /dev/null) || return 0
  sed -n 's/^name: //p' <<< "$cfg" | head -1
}

# ── lifecycle ─────────────────────────────────────────────────────────────────

# pve_destroy VMID — stop + destroy (bounded), then VERIFY the VM is gone via `qm status`. Returns 1
# and logs a loud LEAK error if it is not. Refuses the golden and anything outside the slot range.
pve_destroy() {
  local vmid=$1 attempt
  if [ "$vmid" = "$GOLDEN_VMID" ] || ! vmid_in_slot_range "$vmid"; then
    ghr_log "ERROR refusing to destroy VMID $vmid (golden or outside the slot range)"
    return 1
  fi
  for attempt in 1 2; do
    run_bounded "$SUPA_DESTROY_TIMEOUT" "$QM" stop "$vmid" --skiplock < /dev/null > /dev/null 2>&1 \
      || ghr_log "WARN qm stop $vmid failed or timed out (attempt $attempt)"
    run_bounded "$SUPA_DESTROY_TIMEOUT" "$QM" destroy "$vmid" --purge --destroy-unreferenced-disks 1 --skiplock < /dev/null > /dev/null 2>&1 \
      || ghr_log "WARN qm destroy $vmid failed or timed out (attempt $attempt)"
    rm -f "$FW_DIR/$vmid.fw"
    vm_exists "$vmid" || return 0
  done
  ghr_log "ERROR LEAK: VM $vmid still present after cleanup"
  return 1
}

# pve_sweep — destroy ghr-supa-<k> VMs inside the slot VMID range whose k is not a configured slot
# (crashed runs, a shrunk PVE_SLOTS, hand-made strays). Configured slots may be mid-job on another
# slot loop and are never touched; BOTH the name and the VMID range must match, so neither the
# golden nor any unrelated VM can be hit.
pve_sweep() {
  local list vmid name k
  list=$(run_bounded "$SUPA_DESTROY_TIMEOUT" "$QM" list < /dev/null 2> /dev/null | awk '$1 ~ /^[0-9]+$/ { print $1, $2 }' || true)
  while read -r vmid name; do
    [ -n "$vmid" ] || continue
    [[ "$name" =~ ^ghr-supa-([1-9][0-9]*)$ ]] || continue
    k=${BASH_REMATCH[1]}
    vmid_in_slot_range "$vmid" || continue
    [ "$vmid" != "$GOLDEN_VMID" ] || continue
    slot_listed "$k" && continue
    ghr_log "pve: sweeping orphan VM $vmid ($name)"
    pve_destroy "$vmid" || true
  done <<< "$list"
}

# golden_ok — the golden must exist, carry the golden's name and be a template (fail closed).
golden_ok() {
  local cfg
  cfg=$(run_bounded 30 "$QM" config "$GOLDEN_VMID" < /dev/null 2> /dev/null) || { ghr_log "pve: golden VMID $GOLDEN_VMID not found"; return 1; }
  grep -qx 'template: 1' <<< "$cfg" || { ghr_log "pve: VMID $GOLDEN_VMID is not a template"; return 1; }
  grep -qx "name: $GOLDEN_NAME" <<< "$cfg" || { ghr_log "pve: VMID $GOLDEN_VMID is not named $GOLDEN_NAME"; return 1; }
}

# wait_agent VMID — bounded wait for the guest agent to answer.
wait_agent() {
  local vmid=$1 start=$SECONDS
  while [ "$((SECONDS - start))" -lt "$AGENT_WAIT_SECS" ]; do
    [ "$SIGNALLED" -eq 0 ] || return 143
    if run_bounded 15 "$QM" agent "$vmid" ping < /dev/null > /dev/null 2>&1; then return 0; fi
    sleep "$POLL_SECS"
  done
  ghr_log "pve: guest agent of $vmid did not answer within ${AGENT_WAIT_SECS}s"
  return 1
}

# launch_preflight VMID — exit 0 iff the guest CANNOT reach the LAN probe target.
# WHY from inside the guest: the per-VM firewall file only works with firewall=1 on the NIC AND the
# datacenter firewall enabled; probing from the host would prove neither. Fails closed: an unset
# LAN_PROBE, an unready guest or an uninterpretable result is a refusal.
launch_preflight() {
  [[ "${LAN_PROBE:-}" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] || { ghr_log "preflight: LAN_PROBE unset/invalid, refusing"; return 3; }
  local vmid=$1 host=${LAN_PROBE%:*} port=${LAN_PROBE##*:} rc=0
  # A guest whose network is not configured yet "cannot reach" anything, which would pass vacuously:
  # wait for cloud-init (it applies the static IP) first. 0 = done, 2 = done with recoverable errors.
  guest_exec "$vmid" 240 cloud-init status --wait || rc=$?
  case $rc in 0 | 2) ;; *) ghr_log "preflight: guest not ready (cloud-init rc=$rc), refusing"; return 3 ;; esac
  rc=0
  # Only rc 1 (connect refused/unreachable) and 124 (timeout: packets dropped) mean "blocked". 0 =
  # reachable; anything else (2 syntax, 125 agent failure, 126/127 missing tool) cannot be interpreted
  # and an uninterpretable probe must not pass.
  guest_exec "$vmid" 30 /usr/bin/timeout 5 bash -c "exec 3<>/dev/tcp/${host}/${port}" || rc=$?
  case $rc in
    1 | 124) return 0 ;;
    0) ghr_log "preflight: guest CAN reach $LAN_PROBE -- egress isolation broken, refusing"; return 3 ;;
    *) ghr_log "preflight: probe result uninterpretable (rc=$rc), refusing"; return 3 ;;
  esac
}

# pve_wait_job VMID — wait for the job: the VM powers off by itself, the guest reports an exit code,
# the timeout fires, or we are signalled. Sets JOB_RC; returns 0 (job ended), 124 or 143.
pve_wait_job() {
  local vmid=$1 start=$SECONDS i=0 st rc
  JOB_RC=""
  while :; do
    [ "$SIGNALLED" -eq 0 ] || return 143
    if [ "$((SECONDS - start))" -ge "$JOB_TIMEOUT_SECS" ]; then
      ghr_log "launch-pve: job timeout after ${JOB_TIMEOUT_SECS}s"
      return 124
    fi
    st=$(vm_status "$vmid")
    case "$st" in
      running) ;;
      gone) ghr_log "pve: VM $vmid vanished during the job"; JOB_RC=1; return 0 ;;
      *) return 0 ;;   # stopped (or paused/shutdown): the guest powered itself off
    esac
    i=$((i + 1))
    if [ $((i % EXIT_POLL_EVERY)) -eq 0 ]; then
      rc=0
      guest_exec "$vmid" 20 cat /var/lib/ghr/exit || rc=$?
      if [ "$rc" -eq 0 ] && [[ "${GE_OUT//$'\n'/}" =~ ^[0-9]{1,3}$ ]]; then
        JOB_RC=$((10#${GE_OUT//$'\n'/}))
        return 0
      fi
    fi
    # WHY sleep+wait: a trapped signal interrupts `wait` at once instead of after the nap.
    sleep "$POLL_SECS" &
    wait $! 2> /dev/null
  done
}

# pve_run N JIT — clone the golden, boot, preflight, run the runner, always destroy.
pve_run() {
  local n=$1 jit=$2 vmid vm="ghr-supa-$1" rc=0 ipvar cfg existing
  vmid=$((PVE_VMID_BASE + n))
  [ "$vmid" -ne "$GOLDEN_VMID" ] || return 2
  golden_ok || return 1
  pve_sweep
  # Leftover from a crashed run (same slot, same VMID) must go before we clone over it -- but only if
  # it really is one of ours: an unrelated VM that happens to sit on this VMID is never destroyed.
  if vm_exists "$vmid"; then
    existing=$(vm_name "$vmid")
    [ "$existing" = "$vm" ] || { ghr_log "pve: VMID $vmid is taken by '${existing:-?}', refusing to touch it"; return 1; }
    ghr_log "pve: removing leftover $vm (VMID $vmid)"
    pve_destroy "$vmid" || return 1
  fi
  # From here on the VM must not outlive this call, whatever happens.
  PVE_VM=$vmid
  ipvar="PVE_IPCONFIG_$n"
  # Linked clone (no --full): a base-image reference, ready in seconds.
  run_bounded "$SUPA_DESTROY_TIMEOUT" "$QM" clone "$GOLDEN_VMID" "$vmid" --name "$vm" < /dev/null > /dev/null 2>&1 \
    || { ghr_log "pve: clone failed"; pve_destroy "$vmid"; return 1; }
  run_bounded 60 "$QM" set "$vmid" --memory "$SUPA_MEM_MB" --cores "$SUPA_CPUS" --balloon 0 \
    --ipconfig0 "${!ipvar}" --nameserver "$PVE_NAMESERVER" < /dev/null > /dev/null 2>&1 \
    || { ghr_log "pve: qm set failed"; pve_destroy "$vmid"; return 1; }
  # Egress isolation: the file BEFORE the first boot, and the NIC must really carry firewall=1.
  pve_fw_rules > "$FW_DIR/$vmid.fw" 2> /dev/null \
    || { ghr_log "pve: cannot write $FW_DIR/$vmid.fw"; pve_destroy "$vmid"; return 1; }
  cfg=$(run_bounded 30 "$QM" config "$vmid" < /dev/null 2> /dev/null || true)
  grep -Eq '^net0:.*firewall=1' <<< "$cfg" \
    || { ghr_log "pve: net0 of the clone has no firewall=1, refusing"; pve_destroy "$vmid"; return 1; }
  run_bounded "$SUPA_DESTROY_TIMEOUT" "$QM" start "$vmid" < /dev/null > /dev/null 2>&1 \
    || { ghr_log "pve: start failed"; pve_destroy "$vmid"; return 1; }
  # A signal that arrived during the (slow) clone/start must not be followed by a job.
  [ "$SIGNALLED" -eq 0 ] || { pve_destroy "$vmid"; return 143; }
  wait_agent "$vmid" || { rc=$?; pve_destroy "$vmid"; return "$rc"; }
  launch_preflight "$vmid" || { rc=$?; pve_destroy "$vmid"; return "$rc"; }
  [ "$SIGNALLED" -eq 0 ] || { pve_destroy "$vmid"; return 143; }
  # Deliver the JIT: stdin -> guest file on tmpfs (root 0600) -> unit. Argv carries no secret.
  GE_STDIN=$jit
  guest_exec "$vmid" 30 bash -c 'umask 077; mkdir -p /run/ghr && cat > /run/ghr/jit' || rc=$?
  GE_STDIN=""
  [ "$rc" -eq 0 ] || { ghr_log "pve: JIT delivery failed (rc=$rc)"; pve_destroy "$vmid"; return 1; }
  # --no-block: the unit runs for the whole job; qm guest exec must not wait for it.
  guest_exec "$vmid" 30 systemctl start --no-block ghr-runner.service || rc=$?
  [ "$rc" -eq 0 ] || { ghr_log "pve: cannot start ghr-runner.service (rc=$rc)"; pve_destroy "$vmid"; return 1; }
  rc=0
  pve_wait_job "$vmid" || rc=$?
  if [ "$rc" -eq 0 ] && [ -n "${JOB_RC:-}" ]; then rc=$JOB_RC; fi
  # A leaked VM is a failure even when the job passed: surface it so the slot backs off and the next
  # job's sweep retries.
  if pve_destroy "$vmid"; then PVE_VM=""; elif [ "$rc" -eq 0 ]; then rc=1; fi
  return "$rc"
}

main() {
  # cwd must exist for every child; sudo keeps the caller's cwd (the controller's 0700 home).
  cd / || exit 2
  [ "$#" -eq 2 ] || { echo "usage: launch-pve <class> <n>   (JIT config on stdin)" >&2; exit 2; }
  ghr_load_config || exit 2
  : "${PVE_SLOTS:=}" "${PVE_VMID_BASE:=300}" "${GOLDEN_VMID:=300}" "${SUPA_MEM_MB:=4096}" \
    "${PVE_NAMESERVER:=1.1.1.1 8.8.8.8}"
  launch_validate_args "$1" "$2" || exit 2
  launch_validate_cfg "$2" || exit 2
  local n=$2 jit=""
  IFS= read -r jit || true
  [[ "$jit" =~ ^[A-Za-z0-9+/=_-]+$ ]] || { echo "launch-pve: stdin is not a JIT config" >&2; exit 2; }
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/ghr-launch-pve.XXXXXX") || exit 1
  SIGNALLED=0
  PVE_VM=""
  # CRITICAL: a signal must still reach the cleanup; the trap only records it, the straight-line code
  # in pve_run then destroys the VM. The EXIT trap is the backstop for any path that bails out earlier.
  trap 'SIGNALLED=1' TERM INT HUP
  trap '[ -z "${PVE_VM:-}" ] || pve_destroy "$PVE_VM"; rm -rf "$WORK"' EXIT
  pve_run "$n" "$jit"
  exit $?
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
