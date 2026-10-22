#!/bin/bash
# build-ios.sh <base-image@sha256:digest> — (re)create the ios-class golden VM (a stopped Tart VM).
#
# Context: operator-invoked on the macOS pool host AS THE `ghr` USER (owner of every Tart VM; the
# ios slot's launch.sh clones the golden for each job). Clones the pinned base image into the build
# VM `ghr-ios-build`, boots it headless, pipes images/ios/provision.sh into it through the guest
# agent, stops it, and swaps it in as the golden. Details and operator steps: images/ios/README.md.
#   Inputs : $1 base image, pinned by digest (refuses a tag)
#            RUNNER_VERSION, RUNNER_SHA256  actions/runner version + the sha256 of its osx-arm64
#                                           tarball (both required: nothing is trusted unpinned)
#            IOS_GOLDEN (ghr-ios-golden), TART (/usr/local/bin/tart), IOS_BUILD_CPUS (4),
#            IOS_BUILD_MEM_MB (8192), IOS_DISK_GB (unset = keep the base image's disk size),
#            IOS_BUILD_BOOT_TIMEOUT (600)
# Output contract: stdout is exactly one line on success:  GOLDEN-OK <runner-version> <xcode-version>
# Everything else goes to stderr; any failure exits non-zero.
#
# CRITICAL: the previous golden is replaced only AFTER the new one is built and stopped, and a failed
# build deletes ONLY its own build VM. A half-provisioned golden would be cloned by launch.sh and run
# jobs on an untrustworthy image; with the old golden intact a failed rebuild just keeps the old one.
#
# Dependencies: tart, python3 (JSON from `tart list`). bash 3.2 compatible. Every tart call that is
# not an intended pipe gets `< /dev/null` (`tart exec -i` would otherwise eat our stdin).

set -euo pipefail

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
# WHY: `tart clone` prunes the OCI cache to make room unless told not to; the base image is
# operator-managed.
export TART_NO_AUTO_PRUNE=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TART="${TART:-/usr/local/bin/tart}"
GOLDEN="${IOS_GOLDEN:-ghr-ios-golden}"
BUILD_VM="ghr-ios-build"
PREV_VM="${GOLDEN}-prev"
PROVISION="$HERE/ios/provision.sh"
BUILD_CPUS="${IOS_BUILD_CPUS:-4}"
BUILD_MEM_MB="${IOS_BUILD_MEM_MB:-8192}"
BOOT_TIMEOUT="${IOS_BUILD_BOOT_TIMEOUT:-600}"
BOOT_POLL="${IOS_BUILD_BOOT_POLL:-5}"

log() { echo "[build-ios] $*" >&2; }
die() { log "ERROR $*"; exit 1; }

BASE="${1:-}"
[ "$#" -eq 1 ] || { echo "usage: RUNNER_VERSION=x.y.z RUNNER_SHA256=<hex> build-ios.sh <base-image@sha256:digest>" >&2; exit 2; }
# WHY digest only: a mutable tag would let an upstream push change the image every job runs on.
[[ "$BASE" =~ ^[a-z0-9][a-z0-9./_-]*(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}$ ]] \
  || { echo "build-ios: base image must be pinned by @sha256:<64 hex> (tags are refused)" >&2; exit 2; }
[[ "${RUNNER_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "build-ios: RUNNER_VERSION (x.y.z) is required" >&2; exit 2; }
[[ "${RUNNER_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || { echo "build-ios: RUNNER_SHA256 (64 hex, of the osx-arm64 tarball) is required" >&2; exit 2; }
[[ "$GOLDEN" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && ! [[ "$GOLDEN" =~ ^ghr-ios-[0-9]+$ ]] || { echo "build-ios: bad IOS_GOLDEN" >&2; exit 2; }
[[ "$BUILD_CPUS" =~ ^[1-9][0-9]?$ ]] && [[ "$BUILD_MEM_MB" =~ ^[1-9][0-9]{3,5}$ ]] \
  && [[ "$BOOT_TIMEOUT" =~ ^[1-9][0-9]{0,4}$ ]] && [[ "$BOOT_POLL" =~ ^[1-9][0-9]?$ ]] \
  && [[ "${IOS_DISK_GB:-0}" =~ ^[0-9]{1,4}$ ]] || { echo "build-ios: bad IOS_BUILD_*/IOS_DISK_GB value" >&2; exit 2; }
[ -f "$PROVISION" ] || die "missing images/ios/provision.sh next to this script"

# vm_field NAME FIELD — print FIELD ("State", "Disk", "Size") of the local VM NAME; empty if absent.
# NOTE: same `tart list --format json` shape assumption as tart_vm_states in slots/launch.sh
# (UNVERIFIED on a populated list); fix both together. Fails (rc 1) if the list is unusable.
vm_field() {
  "$TART" list --format json < /dev/null 2> /dev/null | python3 -I -c '
import sys, json
d = json.load(sys.stdin)
if not isinstance(d, list):
    sys.exit(1)
for v in d:
    if isinstance(v, dict) and str(v.get("Source", "local")).lower() != "oci" and v.get("Name") == sys.argv[1]:
        if sys.argv[2] == "State":
            print(str(v.get("State") or ("running" if v.get("Running") else "stopped")).lower())
        elif v.get(sys.argv[2]) is not None:
            print(v.get(sys.argv[2]))
        break
' "$1" "$2"
}
vm_state() { vm_field "$1" State; }

RUN_PID=""
done_ok=0
swapping=0

# destroy_vm NAME — best-effort stop + delete of a VM THIS script owns.
destroy_vm() {
  "$TART" stop "$1" < /dev/null > /dev/null 2>&1 || true
  [ -z "$RUN_PID" ] || { kill -TERM "$RUN_PID" 2> /dev/null || true; wait "$RUN_PID" 2> /dev/null || true; RUN_PID=""; }
  "$TART" delete "$1" < /dev/null > /dev/null 2>&1 || true
}

cleanup() {
  if [ "$done_ok" -ne 1 ]; then
    log "build failed: removing $BUILD_VM"
    destroy_vm "$BUILD_VM"
    # interrupted mid-swap: put the previous golden back
    if [ "$swapping" -eq 1 ] && [ -z "$(vm_state "$GOLDEN" 2> /dev/null || true)" ] && [ -n "$(vm_state "$PREV_VM" 2> /dev/null || true)" ]; then
      log "restoring the previous golden"
      "$TART" rename "$PREV_VM" "$GOLDEN" < /dev/null >&2 || log "ERROR could not restore $PREV_VM -> $GOLDEN: rename it by hand"
    fi
  fi
}
trap cleanup EXIT

st="$(vm_state "$GOLDEN")" || die "cannot read the VM list"
[ -z "$st" ] || [ "$st" = "stopped" ] || die "existing golden $GOLDEN is '$st'; stop it first (build jobs idle)"
[ -z "$(vm_state "$PREV_VM")" ] || die "leftover $PREV_VM from an interrupted build: inspect it, then delete or rename it"
st="$(vm_state "$BUILD_VM")"
if [ -n "$st" ]; then
  log "removing leftover $BUILD_VM ($st)"
  destroy_vm "$BUILD_VM"
  [ -z "$(vm_state "$BUILD_VM")" ] || die "cannot remove leftover $BUILD_VM"
fi

log "cloning $BASE -> $BUILD_VM (pulls the image if it is not cached)"
"$TART" clone "$BASE" "$BUILD_VM" < /dev/null >&2 || die "tart clone failed"
"$TART" set "$BUILD_VM" --cpu "$BUILD_CPUS" --memory "$BUILD_MEM_MB" < /dev/null >&2 || die "tart set failed"
if [ "${IOS_DISK_GB:-0}" -gt 0 ]; then
  "$TART" set "$BUILD_VM" --disk-size "$IOS_DISK_GB" < /dev/null >&2 || die "tart set --disk-size failed"
fi

log "booting $BUILD_VM"
"$TART" run "$BUILD_VM" --no-graphics --no-audio < /dev/null >&2 &
RUN_PID=$!
t0=$(date -u +%s)
until "$TART" exec "$BUILD_VM" /usr/bin/true < /dev/null > /dev/null 2>&1; do
  kill -0 "$RUN_PID" 2> /dev/null || die "tart run exited before the guest agent answered"
  [ "$(( $(date -u +%s) - t0 ))" -lt "$BOOT_TIMEOUT" ] || die "guest agent not up after ${BOOT_TIMEOUT}s"
  sleep "$BOOT_POLL"
done

log "provisioning"
# CRITICAL: the script is streamed to a FILE in the guest first and then run with stdin at /dev/null,
# so a child that reads stdin (installers, sudo prompts) cannot swallow the rest of it.
"$TART" exec -i "$BUILD_VM" /bin/bash -c 'cat > /tmp/ghr-provision.sh' < "$PROVISION" || die "cannot copy provision.sh into $BUILD_VM"
out="$("$TART" exec "$BUILD_VM" /bin/bash /tmp/ghr-provision.sh "$RUNNER_VERSION" "$RUNNER_SHA256" < /dev/null)" || die "provisioning failed"
"$TART" exec "$BUILD_VM" /bin/rm -f /tmp/ghr-provision.sh < /dev/null > /dev/null 2>&1 || true
line="$(printf '%s\n' "$out" | grep '^PROVISION-OK ' | tail -1 || true)"
[[ "$line" =~ ^PROVISION-OK\ ([0-9]+\.[0-9]+\.[0-9]+)\ ([0-9][0-9.]*)$ ]] || die "provisioning did not report PROVISION-OK"
runner_version="${BASH_REMATCH[1]}"
xcode_version="${BASH_REMATCH[2]}"
[ "$runner_version" = "$RUNNER_VERSION" ] || die "provisioned runner $runner_version, expected $RUNNER_VERSION"

log "stopping $BUILD_VM"
"$TART" stop "$BUILD_VM" < /dev/null >&2 || die "tart stop failed"
wait "$RUN_PID" 2> /dev/null || true
RUN_PID=""
st="$(vm_state "$BUILD_VM")"
[ "$st" = "stopped" ] || die "$BUILD_VM is '$st' after stop, expected stopped"

# Swap: only now does the old golden go. If the second rename fails the trap restores it.
log "replacing $GOLDEN"
swapping=1
if [ -n "$(vm_state "$GOLDEN")" ]; then
  "$TART" rename "$GOLDEN" "$PREV_VM" < /dev/null >&2 || die "cannot move the old golden aside"
fi
"$TART" rename "$BUILD_VM" "$GOLDEN" < /dev/null >&2 || die "cannot rename $BUILD_VM to $GOLDEN"
done_ok=1
if [ -n "$(vm_state "$PREV_VM")" ]; then
  "$TART" delete "$PREV_VM" < /dev/null >&2 || log "WARN could not delete the previous golden $PREV_VM"
fi

log "inputs: base=$BASE runner=$runner_version (sha256 $RUNNER_SHA256) xcode=$xcode_version golden=$GOLDEN"
log "golden disk: $(vm_field "$GOLDEN" Disk || true) GB (size on disk: $(vm_field "$GOLDEN" Size || true) GB)"
printf 'GOLDEN-OK %s %s\n' "$runner_version" "$xcode_version"
