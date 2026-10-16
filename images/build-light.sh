#!/bin/bash
# build-light.sh [instance] — build images/light/Dockerfile inside a Lima instance.
#
# Context: run on the macOS host as the `ghr` user (owner of the Lima VMs). Default instance is
# the golden pool VM (`ghr-pool-golden`) so the image is baked into what pool instances clone.
# The instance is started if stopped and stopped again ONLY if this script started it.
# Output contract: stdout is exactly one line, `IMAGE_ID=sha256:<64 hex>` (the docker image ID,
# usable as LIGHT_IMAGE); everything else goes to stderr. The image is also tagged
# ghr/light:<UTC date>. Any failure exits non-zero with no IMAGE_ID line.
#
# Dependencies: limactl (LIMACTL, default /usr/local/bin/limactl), the Dockerfile directory next
# to this script. bash 3.2 compatible. Every non-piping limactl call gets `< /dev/null`
# (limactl shell would otherwise swallow the caller's stdin).

set -euo pipefail

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIMACTL="${LIMACTL:-/usr/local/bin/limactl}"
INSTANCE="${1:-ghr-pool-golden}"
CONTEXT_SRC="$HERE/light"
REMOTE_DIR="/tmp/ghr-light-build"

log() { echo "[build-light] $*" >&2; }
die() { log "ERROR $*"; exit 1; }

[[ "$INSTANCE" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "invalid instance name"
[ -f "$CONTEXT_SRC/Dockerfile" ] || die "missing $CONTEXT_SRC/Dockerfile"

# Instance state decides whether we stop it afterwards.
status="$("$LIMACTL" list "$INSTANCE" --format '{{.Status}}' < /dev/null 2> /dev/null || true)"
started_by_us=0
case "$status" in
  Running) ;;
  Stopped)
    log "starting $INSTANCE"
    "$LIMACTL" start "$INSTANCE" --tty=false < /dev/null >&2 || die "cannot start $INSTANCE"
    started_by_us=1
    ;;
  *) die "instance $INSTANCE not found or in state '${status:-unknown}'" ;;
esac

cleanup() {
  "$LIMACTL" shell "$INSTANCE" -- rm -rf "$REMOTE_DIR" < /dev/null > /dev/null 2>&1 || true
  if [ "$started_by_us" -eq 1 ]; then
    log "stopping $INSTANCE (we started it)"
    "$LIMACTL" stop "$INSTANCE" < /dev/null >&2 || log "WARN could not stop $INSTANCE"
  fi
}
trap cleanup EXIT

"$LIMACTL" shell "$INSTANCE" -- rm -rf "$REMOTE_DIR" < /dev/null >&2 || die "cannot clear remote dir"
"$LIMACTL" copy -r "$CONTEXT_SRC" "$INSTANCE:$REMOTE_DIR" < /dev/null >&2 || die "copy of build context failed"

tag="ghr/light:$(date -u +%Y%m%d)"
log "building $tag in $INSTANCE"
"$LIMACTL" shell "$INSTANCE" -- sudo docker build -t "$tag" "$REMOTE_DIR" < /dev/null >&2 || die "docker build failed"

id="$("$LIMACTL" shell "$INSTANCE" -- sudo docker image inspect --format '{{.Id}}' "$tag" < /dev/null)" || die "cannot inspect $tag"
id="$(printf '%s' "$id" | tr -d '[:space:]')"
[[ "$id" =~ ^sha256:[0-9a-f]{64}$ ]] || die "unexpected image id: $id"
printf 'IMAGE_ID=%s\n' "$id"
