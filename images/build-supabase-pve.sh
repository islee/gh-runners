#!/bin/bash
# build-supabase-pve.sh [--rebuild] — (re)create the Proxmox supabase-class golden template.
#
# Context: run as root ON the Proxmox VE host (qm is root-only). The Proxmox counterpart of
# build-supabase.sh: it builds a VM from the pinned Ubuntu 24.04 (noble) amd64 cloud image, boots it
# once, provisions it over the qemu guest agent with images/supabase/provision.sh (x86_64 pins),
# installs the per-job runner unit (images/supabase/ghr-runner.service + ghr-runner-run), resets the
# cloud-init state so every clone gets a fresh machine-id, shuts it down and converts it to a
# TEMPLATE. slots/launch-pve.sh linked-clones that template for every supabase job.
#   --rebuild  destroy an existing golden first (without it an existing golden is an error).
# Output contract: stdout is exactly one line on success:  GOLDEN-OK <runner-version> <cli-version>
# Everything else goes to stderr; any failure exits non-zero.
#
# CRITICAL: on failure the half-built golden is destroyed. A half-provisioned TEMPLATE would be cloned
# by launch-pve and run jobs on an untrustworthy image; a missing golden makes launch refuse instead
# (fail closed). A failed --rebuild therefore leaves NO golden. Only a VM this run created is ever
# destroyed on failure, and --rebuild only destroys a VM named ghr-supa-golden.
#
# Configuration (environment, all optional):
#   GOLDEN_VMID=300  STORAGE=local-lvm  BRIDGE=vmbr0  DISK_SIZE=40G  SNIPPET_STORAGE=local
#   IPCONFIG=ip=dhcp  PVE_NAMESERVER="1.1.1.1 8.8.8.8"  BUILD_CPUS=4  BUILD_MEM_MB=8192
#   BUILD_TMP=/var/tmp (needs ~1 GiB for the image)  PROVISION_TIMEOUT_SECS=3600
# STORAGE must support linked clones (lvm-thin, zfs, qcow2 on a directory, ceph); SNIPPET_STORAGE must
# have the `snippets` content type enabled (Datacenter > Storage). The golden's firewall file is the
# same egress isolation as a job VM (slots/lib/pve-fw.sh) -- the build only needs the public internet.
#
# Why provisioning is DETACHED: `qm guest exec` waits synchronously and gives up after its --timeout,
# while provisioning takes ~10-40 min. provision.sh runs under systemd-run; we poll for the exit
# status it leaves in a file.
#
# Dependencies: qm, pvesm, curl, python3, sha256sum, slots/lib/{pve-fw,pve-guest}.sh. bash 5.

# shellcheck disable=SC2034  # GE_STDIN is consumed by lib/pve-guest.sh
set -euo pipefail

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=slots/lib/pve-fw.sh
. "$HERE/../slots/lib/pve-fw.sh"
# shellcheck source=slots/lib/pve-guest.sh
. "$HERE/../slots/lib/pve-guest.sh"

QM="${QM:-/usr/sbin/qm}"
PVESM="${PVESM:-/usr/sbin/pvesm}"
CURL="${CURL:-curl}"
FW_DIR="${PVE_FW_DIR:-/etc/pve/firewall}"
GOLDEN_VMID="${GOLDEN_VMID:-300}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
DISK_SIZE="${DISK_SIZE:-40G}"
SNIPPET_STORAGE="${SNIPPET_STORAGE:-local}"
IPCONFIG="${IPCONFIG:-ip=dhcp}"
NAMESERVER="${PVE_NAMESERVER:-1.1.1.1 8.8.8.8}"
BUILD_CPUS="${BUILD_CPUS:-4}"
BUILD_MEM_MB="${BUILD_MEM_MB:-8192}"
BUILD_TMP="${BUILD_TMP:-/var/tmp}"
PROVISION_TIMEOUT_SECS="${PROVISION_TIMEOUT_SECS:-3600}"
AGENT_WAIT_SECS="${PVE_AGENT_WAIT_SECS:-900}"
POLL_SECS="${PVE_POLL_SECS:-20}"
GOLDEN_NAME=ghr-supa-golden
BUILD_SNIPPET=ghr-golden-user.yaml
CLONE_SNIPPET=ghr-clone-user.yaml
# Pinned Ubuntu 24.04 (noble) amd64 cloud image. Taken 2026-10-20 from
# https://cloud-images.ubuntu.com/releases/24.04/release-20260926/SHA256SUMS (the same release as the
# arm64 image pinned in images/supabase/lima.yaml). To move: take the new release-YYYYMMDD directory and
# the matching line of its SHA256SUMS, change both values together. IMAGE_URL / IMAGE_SHA256 may be
# overridden from the environment (the checksum still has to match).
IMAGE_URL="${IMAGE_URL:-https://cloud-images.ubuntu.com/releases/24.04/release-20260926/ubuntu-24.04-server-cloudimg-amd64.img}"
IMAGE_SHA256="${IMAGE_SHA256:-6a81c37564db9b1ee84e141922625e1d7c5b389b99bb3c572e0243607d5bb4d2}"

log() { echo "[build-supabase-pve] $*" >&2; }
die() { log "ERROR $*"; exit 1; }

REBUILD=0
case "${1:-}" in
  "") ;;
  --rebuild) REBUILD=1 ;;
  *) echo "usage: build-supabase-pve.sh [--rebuild]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "usage: build-supabase-pve.sh [--rebuild]" >&2; exit 2; }

[ "$(id -u)" -eq 0 ] || [ -n "${GHR_BUILD_ALLOW_NONROOT:-}" ] || die "must run as root on the Proxmox host"
[[ "$GOLDEN_VMID" =~ ^[1-9][0-9]{2,8}$ ]] || die "GOLDEN_VMID must be a VMID (>= 100)"
[[ "$STORAGE" =~ ^[A-Za-z0-9._-]+$ ]] || die "STORAGE has an unexpected shape"
[[ "$BRIDGE" =~ ^[A-Za-z0-9._-]+$ ]] || die "BRIDGE has an unexpected shape"
[[ "$SNIPPET_STORAGE" =~ ^[A-Za-z0-9._-]+$ ]] || die "SNIPPET_STORAGE has an unexpected shape"
[[ "$DISK_SIZE" =~ ^[1-9][0-9]*G$ ]] || die "DISK_SIZE must look like 40G"
[[ "$IPCONFIG" =~ ^ip=(dhcp|[0-9.]+/[0-9]{1,2}(,gw=[0-9.]+)?)$ ]] || die "IPCONFIG must be ip=dhcp or ip=<addr>/<len>[,gw=<gw>]"
[[ "$NAMESERVER" =~ ^[0-9a-fA-F.:]+( [0-9a-fA-F.:]+)*$ ]] || die "PVE_NAMESERVER must be IP addresses, space separated"
[[ "$BUILD_CPUS" =~ ^[1-9][0-9]?$ ]] && [[ "$BUILD_MEM_MB" =~ ^[1-9][0-9]{2,5}$ ]] || die "BUILD_CPUS / BUILD_MEM_MB invalid"
for f in supabase/provision.sh supabase/pve-user-data.yaml supabase/ghr-runner.service supabase/ghr-runner-run; do
  [ -f "$HERE/$f" ] || die "missing images/$f next to this script"
done

WORK="$(mktemp -d "$BUILD_TMP/ghr-build-pve.XXXXXX")" || die "cannot create a work dir in $BUILD_TMP"
CREATED=0
done_ok=0
cleanup() {
  if [ "$CREATED" -eq 1 ] && [ "$done_ok" -ne 1 ]; then
    log "build failed: destroying partial golden VMID $GOLDEN_VMID"
    "$QM" stop "$GOLDEN_VMID" --skiplock < /dev/null > /dev/null 2>&1 || true
    "$QM" destroy "$GOLDEN_VMID" --purge --destroy-unreferenced-disks 1 --skiplock < /dev/null > /dev/null 2>&1 || true
  fi
  [ "$CREATED" -eq 0 ] || rm -f "$FW_DIR/$GOLDEN_VMID.fw"
  rm -rf "$WORK"
}
trap cleanup EXIT

sha256_of() { if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

# snippet_dir — filesystem directory behind SNIPPET_STORAGE:snippets (content type must be enabled).
snippet_dir() {
  local content p
  content=$("$PVESM" status --content snippets < /dev/null 2> /dev/null || true)
  awk -v s="$SNIPPET_STORAGE" 'NR > 1 && $1 == s { f = 1 } END { exit !f }' <<< "$content" \
    || die "storage '$SNIPPET_STORAGE' has no 'snippets' content type (Datacenter > Storage > Edit > Content)"
  p=$("$PVESM" path "$SNIPPET_STORAGE:snippets/$BUILD_SNIPPET" < /dev/null) || die "cannot resolve the snippet path on $SNIPPET_STORAGE"
  dirname "$p"
}

# guest_ok VMID TIMEOUT CMD... — guest_exec that must exit 0.
guest_ok() {
  local vmid=$1 t=$2 rc=0
  shift 2
  guest_exec "$vmid" "$t" "$@" || rc=$?
  [ "$rc" -eq 0 ] || die "guest command failed (rc=$rc): $1 ${2:-}"
}

# push_file VMID SRC DEST MODE — copy a small text file into the guest over the agent's stdin.
push_file() {
  local vmid=$1 src=$2 dest=$3 mode=$4
  # shellcheck disable=SC2016  # $1/$2 are expanded by the GUEST shell
  GE_STDIN="$(cat "$src")"
  guest_ok "$vmid" 60 bash -c 'cat > "$1" && chmod "$2" "$1"' _ "$dest" "$mode"
  GE_STDIN=""
}

# ── existing golden ───────────────────────────────────────────────────────────

if "$QM" status "$GOLDEN_VMID" < /dev/null > /dev/null 2>&1; then
  existing="$("$QM" config "$GOLDEN_VMID" < /dev/null 2> /dev/null | sed -n 's/^name: //p' | head -1 || true)"
  [ "$existing" = "$GOLDEN_NAME" ] || die "VMID $GOLDEN_VMID is in use by '${existing:-?}', not by $GOLDEN_NAME; pick another GOLDEN_VMID"
  [ "$REBUILD" -eq 1 ] || die "$GOLDEN_NAME (VMID $GOLDEN_VMID) already exists; use --rebuild to replace it"
  log "destroying existing $GOLDEN_NAME (VMID $GOLDEN_VMID)"
  "$QM" stop "$GOLDEN_VMID" --skiplock < /dev/null > /dev/null 2>&1 || true
  "$QM" destroy "$GOLDEN_VMID" --purge --destroy-unreferenced-disks 1 --skiplock < /dev/null >&2 \
    || die "cannot destroy the existing golden (linked clones still present? wait for running jobs)"
fi

# ── image ─────────────────────────────────────────────────────────────────────

SNIPDIR="$(snippet_dir)"
IMG="$WORK/noble-amd64.img"
log "downloading $IMAGE_URL"
"$CURL" -fsSL "$IMAGE_URL" -o "$IMG" < /dev/null || die "image download failed"
[ "$(sha256_of "$IMG")" = "$IMAGE_SHA256" ] || die "cloud image checksum does not match the pin"

# ── VM ────────────────────────────────────────────────────────────────────────

install -m 0644 "$HERE/supabase/pve-user-data.yaml" "$SNIPDIR/$BUILD_SNIPPET"
# WHY a no-op for clones: the build user-data runs apt (package_update) on first boot; clones already
# have the agent and must not need the network for that.
printf '#cloud-config\n# no-op: the golden is already provisioned\nssh_pwauth: false\n' > "$SNIPDIR/$CLONE_SNIPPET"

log "creating $GOLDEN_NAME (VMID $GOLDEN_VMID) on $STORAGE"
CREATED=1
"$QM" create "$GOLDEN_VMID" --name "$GOLDEN_NAME" --ostype l26 --machine q35 --cpu host \
  --cores "$BUILD_CPUS" --memory "$BUILD_MEM_MB" --balloon 0 --agent enabled=1 \
  --scsihw virtio-scsi-single --net0 "virtio,bridge=$BRIDGE,firewall=1" --serial0 socket --onboot 0 \
  < /dev/null >&2 || die "qm create failed"
"$QM" set "$GOLDEN_VMID" --scsi0 "$STORAGE:0,import-from=$IMG,discard=on" --boot order=scsi0 < /dev/null >&2 || die "disk import failed"
"$QM" resize "$GOLDEN_VMID" scsi0 "$DISK_SIZE" < /dev/null >&2 || die "disk resize failed"
"$QM" set "$GOLDEN_VMID" --ide2 "$STORAGE:cloudinit" --ipconfig0 "$IPCONFIG" --nameserver "$NAMESERVER" \
  --cicustom "user=$SNIPPET_STORAGE:snippets/$BUILD_SNIPPET" < /dev/null >&2 || die "cloud-init drive setup failed"
rm -f "$WORK/noble-amd64.img"
pve_fw_rules > "$FW_DIR/$GOLDEN_VMID.fw" || die "cannot write $FW_DIR/$GOLDEN_VMID.fw"

log "starting (first boot installs the guest agent; a few minutes)"
"$QM" start "$GOLDEN_VMID" < /dev/null >&2 || die "qm start failed"
start=$SECONDS
until "$QM" agent "$GOLDEN_VMID" ping < /dev/null > /dev/null 2>&1; do
  [ "$((SECONDS - start))" -lt "$AGENT_WAIT_SECS" ] || die "guest agent did not answer within ${AGENT_WAIT_SECS}s"
  sleep "$POLL_SECS"
done
guest_ok "$GOLDEN_VMID" 600 cloud-init status --wait

# ── provision (detached) ──────────────────────────────────────────────────────

log "provisioning"
# CRITICAL: the script is copied to a FILE and run with stdin at /dev/null (systemd's default), so
# no child can swallow the rest of it.
push_file "$GOLDEN_VMID" "$HERE/supabase/provision.sh" /root/ghr-provision.sh 0700
guest_ok "$GOLDEN_VMID" 30 rm -f /var/lib/ghr-provision.rc
# shellcheck disable=SC2016  # expanded by the GUEST shell
guest_ok "$GOLDEN_VMID" 30 systemd-run --unit ghr-provision bash -c \
  'bash /root/ghr-provision.sh > /var/log/ghr-provision.log 2>&1; echo $? > /var/lib/ghr-provision.rc'
start=$SECONDS
prc=""
while :; do
  [ "$((SECONDS - start))" -lt "$PROVISION_TIMEOUT_SECS" ] || die "provisioning did not finish within ${PROVISION_TIMEOUT_SECS}s"
  sleep "$POLL_SECS"
  rc=0
  guest_exec "$GOLDEN_VMID" 20 cat /var/lib/ghr-provision.rc || rc=$?
  # rc 1 = the file does not exist yet; 125 = the agent did not answer (busy / rebooting): keep polling.
  if [ "$rc" -eq 0 ] && [[ "${GE_OUT//$'\n'/}" =~ ^[0-9]+$ ]]; then prc=${GE_OUT//$'\n'/}; break; fi
done
guest_exec "$GOLDEN_VMID" 30 tail -n 40 /var/log/ghr-provision.log || true
printf '%s\n' "$GE_OUT" >&2
[ "$prc" = 0 ] || die "provisioning failed (exit $prc; log tail above)"
guest_exec "$GOLDEN_VMID" 30 grep '^PROVISION-OK ' /var/log/ghr-provision.log || true
line="$(printf '%s\n' "$GE_OUT" | tail -1)"
[[ "$line" =~ ^PROVISION-OK\ ([0-9][0-9.]*)\ ([0-9][0-9.]*)$ ]] || die "provisioning did not report PROVISION-OK"
runner_version="${BASH_REMATCH[1]}"
cli_version="${BASH_REMATCH[2]}"

# ── per-job runner unit, clean state, template ────────────────────────────────

# Decision: the Proxmox-only guest pieces are installed HERE, not by provision.sh, so the Lima golden
# stays byte-for-byte what it was.
log "installing the per-job runner unit"
guest_ok "$GOLDEN_VMID" 30 install -d -m 0755 /usr/local/libexec
push_file "$GOLDEN_VMID" "$HERE/supabase/ghr-runner-run" /usr/local/libexec/ghr-runner-run 0755
push_file "$GOLDEN_VMID" "$HERE/supabase/ghr-runner.service" /etc/systemd/system/ghr-runner.service 0644
guest_ok "$GOLDEN_VMID" 60 systemctl daemon-reload
guest_ok "$GOLDEN_VMID" 30 systemd-analyze verify /etc/systemd/system/ghr-runner.service

log "resetting cloud-init state and shutting down"
# shellcheck disable=SC2016  # expanded by the GUEST shell
guest_ok "$GOLDEN_VMID" 120 bash -c 'rm -f /root/ghr-provision.sh /var/lib/ghr-provision.rc /var/log/ghr-provision.log /etc/ssh/ssh_host_* && cloud-init clean --logs --machine-id'
"$QM" shutdown "$GOLDEN_VMID" --timeout 180 < /dev/null >&2 || log "WARN qm shutdown failed, forcing a stop"
st="$("$QM" status "$GOLDEN_VMID" < /dev/null 2> /dev/null || true)"
if [ "$st" != "status: stopped" ]; then
  "$QM" stop "$GOLDEN_VMID" --skiplock < /dev/null >&2 || die "cannot stop the golden"
fi
st="$("$QM" status "$GOLDEN_VMID" < /dev/null 2> /dev/null || true)"
[ "$st" = "status: stopped" ] || die "$GOLDEN_NAME is '$st' after shutdown, expected stopped"

"$QM" set "$GOLDEN_VMID" --cicustom "user=$SNIPPET_STORAGE:snippets/$CLONE_SNIPPET" < /dev/null >&2 || die "cannot switch to the clone user-data"
rm -f "$FW_DIR/$GOLDEN_VMID.fw"
"$QM" template "$GOLDEN_VMID" < /dev/null >&2 || die "qm template failed"
cfg="$("$QM" config "$GOLDEN_VMID" < /dev/null 2> /dev/null || true)"
grep -qx 'template: 1' <<< "$cfg" || die "$GOLDEN_NAME is not a template after qm template"

done_ok=1
printf 'GOLDEN-OK %s %s\n' "$runner_version" "$cli_version"
