#!/bin/bash
# build-supabase.sh [--rebuild] — (re)create the supabase-class golden VM `ghr-supa-golden`.
#
# Context: run on the macOS host as the `ghr` user (owner of all Lima VMs; the pf egress rule
# matches that user). Creates the VM from images/supabase/lima.yaml, boots it (first boot is
# ~2-4 min of cloud-init), pipes images/supabase/provision.sh into it as root, then stops it. The
# stopped golden is what slots/launch.sh clones for every supabase job.
#   --rebuild  delete an existing golden first (without it an existing golden is an error).
# Output contract: stdout is exactly one line on success:  GOLDEN-OK <runner-version> <cli-version>
# Everything else goes to stderr; any failure exits non-zero.
#
# CRITICAL: on failure the half-built golden is deleted. A STOPPED but half-provisioned golden
# would be cloned by launch.sh and run jobs on an untrustworthy image; a missing golden makes
# launch refuse instead (fail closed). A failed --rebuild therefore leaves NO golden.
#
# Dependencies: limactl (LIMACTL, default /usr/local/bin/limactl). bash 3.2 compatible. Every
# non-piping limactl call gets `< /dev/null` (limactl shell would otherwise eat our stdin); the
# one intentional pipe is provision.sh into `limactl shell`.

set -euo pipefail

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIMACTL="${LIMACTL:-/usr/local/bin/limactl}"
GOLDEN="${SUPA_GOLDEN:-ghr-supa-golden}"
TEMPLATE="$HERE/supabase/lima.yaml"
PROVISION="$HERE/supabase/provision.sh"

log() { echo "[build-supabase] $*" >&2; }
die() { log "ERROR $*"; exit 1; }

REBUILD=0
case "${1:-}" in
  "") ;;
  --rebuild) REBUILD=1 ;;
  *) echo "usage: build-supabase.sh [--rebuild]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "usage: build-supabase.sh [--rebuild]" >&2; exit 2; }

[ -f "$TEMPLATE" ] && [ -f "$PROVISION" ] || die "missing lima.yaml/provision.sh next to this script"

status="$("$LIMACTL" list "$GOLDEN" --format '{{.Status}}' < /dev/null 2> /dev/null || true)"
if [ -n "$status" ]; then
  [ "$REBUILD" -eq 1 ] || die "$GOLDEN already exists ($status); use --rebuild to replace it"
  log "deleting existing $GOLDEN ($status)"
  "$LIMACTL" stop -f "$GOLDEN" < /dev/null >&2 || true
  "$LIMACTL" delete -f "$GOLDEN" < /dev/null >&2 || die "cannot delete existing $GOLDEN"
fi

done_ok=0
cleanup() {
  if [ "$done_ok" -ne 1 ]; then
    log "build failed: removing partial $GOLDEN"
    "$LIMACTL" stop -f "$GOLDEN" < /dev/null > /dev/null 2>&1 || true
    "$LIMACTL" delete -f "$GOLDEN" < /dev/null > /dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

log "creating $GOLDEN from $TEMPLATE"
"$LIMACTL" create --name "$GOLDEN" --tty=false "$TEMPLATE" < /dev/null >&2 || die "limactl create failed"
log "starting $GOLDEN (first boot takes a few minutes)"
"$LIMACTL" start "$GOLDEN" --tty=false < /dev/null >&2 || die "limactl start failed"

log "provisioning"
# The script goes in on stdin on purpose; its stdout carries the PROVISION-OK line.
out="$("$LIMACTL" shell "$GOLDEN" -- sudo bash -s < "$PROVISION")" || die "provisioning failed"
line="$(printf '%s\n' "$out" | grep '^PROVISION-OK ' | tail -1 || true)"
[[ "$line" =~ ^PROVISION-OK\ ([0-9][0-9.]*)\ ([0-9][0-9.]*)$ ]] || die "provisioning did not report PROVISION-OK"
runner_version="${BASH_REMATCH[1]}"
cli_version="${BASH_REMATCH[2]}"

log "stopping $GOLDEN"
"$LIMACTL" stop "$GOLDEN" < /dev/null >&2 || die "limactl stop failed"
status="$("$LIMACTL" list "$GOLDEN" --format '{{.Status}}' < /dev/null 2> /dev/null || true)"
[ "$status" = "Stopped" ] || die "$GOLDEN is '$status' after stop, expected Stopped"

done_ok=1
printf 'GOLDEN-OK %s %s\n' "$runner_version" "$cli_version"
