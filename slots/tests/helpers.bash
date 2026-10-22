# helpers.bash — shared bats fixtures for the slots suite (loaded via `load helpers`).
#
# Everything is offline: `curl`, `limactl` and `sudo` are shims on PATH. A throwaway RSA key is
# generated per test run (nothing key-shaped is committed). Config is a fixture file passed via
# GHR_CONFIG.

SLOTS_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
export SLOTS_DIR

# slots_setup — common per-test environment.
slots_setup() {
  W="${BATS_TEST_TMPDIR}"
  FAKE_BIN="$W/bin"
  FAKE_ROUTES="$W/routes"
  CURL_LOG="$W/curl.log"
  CURL_ARGV_LOG="$W/curl-argv.log"
  mkdir -p "$FAKE_BIN" "$FAKE_ROUTES" "$W/home" "$W/state"
  : > "$CURL_LOG"
  : > "$CURL_ARGV_LOG"
  export HOME="$W/home" TMPDIR="$W" FAKE_ROUTES CURL_LOG CURL_ARGV_LOG
  export PATH="$FAKE_BIN:$PATH"

  openssl genrsa -out "$W/key.pem" 2048 > /dev/null 2>&1
  openssl rsa -in "$W/key.pem" -pubout -out "$W/pub.pem" > /dev/null 2>&1

  cat > "$W/slots.env" <<CFG
ORG=test-org
RUNNER_GROUP_ID=1
RUNNER_APP_ID=111
RUNNER_INSTALLATION_ID=222
RUNNER_APP_KEY=$W/key.pem
STATE_APP_ID=333
STATE_INSTALLATION_ID=444
STATE_APP_KEY=$W/key.pem
CONSUMER_REPOS="test-org/repo-a test-org/repo-b"
ALLOWED_LABELS="ghr-light,ghr-supabase"
LIGHT_SLOTS=3
LIGHT_LABELS="ghr-light"
LIGHT_IMAGE=ghcr.io/actions/actions-runner@sha256:$(printf 'a%.0s' $(seq 1 64))
LAN_PROBE=192.0.2.1:22
CFG
  export GHR_CONFIG="$W/slots.env"

  # curl shim: logs argv + request body, answers from $FAKE_ROUTES/<METHOD><path with / -> _>.
  # Route file: first line = HTTP status, rest = body. Unrouted requests get 404 `{}`.
  cat > "$FAKE_BIN/curl" <<'SHIM'
#!/bin/bash
printf '%s\n' "$@" >> "$CURL_ARGV_LOG"
method=GET out="" url="" data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift 2 ;;
    -o) out=$2; shift 2 ;;
    -w | -H | -K | --max-time) shift 2 ;;
    --data-binary) data=${2#@}; shift 2 ;;
    http*) url=$1; shift ;;
    *) shift ;;
  esac
done
path=${url#*://}; path=/${path#*/}; path=${path%%\?*}
echo "CALL $method $path" >> "$CURL_LOG"
[ -n "$data" ] && echo "BODY $(cat "$data")" >> "$CURL_LOG"
route="$FAKE_ROUTES/$method$(printf '%s' "$path" | tr '/' '_')"
if [ -f "$route" ]; then
  head -1 "$route" | tr -d '\n' > "$FAKE_ROUTES/.code"
  tail -n +2 "$route" > "$out"
else
  printf '404' > "$FAKE_ROUTES/.code"
  echo '{}' > "$out"
fi
cat "$FAKE_ROUTES/.code"
SHIM
  chmod +x "$FAKE_BIN/curl"
}

# route METHOD PATH STATUS BODY — register a canned GitHub response.
route() {
  local f
  f="$FAKE_ROUTES/$1$(printf '%s' "$2" | tr '/' '_')"
  printf '%s\n%s\n' "$3" "$4" > "$f"
}

# route_token — canned installation-token responses for both Apps used in the config.
route_token() {
  route POST /app/installations/222/access_tokens 201 '{"token":"ghs_faketoken_runner"}'
  route POST /app/installations/444/access_tokens 201 '{"token":"ghs_faketoken_state"}'
}

# b64url_decode STRING — base64url -> raw (re-pads; works with LibreSSL and OpenSSL).
b64url_decode() {
  local s=$1
  s=$(printf '%s' "$s" | tr '_-' '/+')
  while [ $(( ${#s} % 4 )) -ne 0 ]; do s="${s}="; done
  printf '%s' "$s" | openssl base64 -d -A
}

# refute CMD... — assert CMD fails. WHY not bare `! cmd`: bats runs under set -e, which ignores a
# negated command that is not the last line of a test, so `! grep ...` would pass vacuously.
refute() { if "$@"; then return 1; fi; }

# lima_setup — limactl shim shared by the launch suites. Records every call in $LIMA_LOG; every
# call that is not a runner start has its stdin captured in $LIMA_OTHER_STDIN so tests can prove no
# limactl call swallowed the caller's stdin. Knobs (env): FAKE_POOL_STATUS (light pool VM),
# FAKE_GOLDEN_STATUS (default Stopped), FAKE_VM_STATUS (per-job VM, default absent), FAKE_PROBE_RC,
# FAKE_RUN_RC, FAKE_RUN_SLEEP, FAKE_CLONE_RC, FAKE_CLONE_SLEEP, FAKE_START_RC, FAKE_STOP_RC/_SLEEP,
# FAKE_DELETE_RC, FAKE_DELETE_PERSIST (delete "succeeds" but the VM stays listed), FAKE_ALL_VMS (names
# returned by `list --format {{.Name}}`). Every call also appends its environment to $LIMA_ENV.
lima_setup() {
  LIMA_LOG="$W/lima.log"
  LIMA_STDIN="$W/lima.stdin"
  LIMA_OTHER_STDIN="$W/lima.other.stdin"
  LIMA_ENV="$W/lima.env"
  VMSTATE="$W/vmstate"
  mkdir -p "$VMSTATE"
  : > "$LIMA_LOG"
  : > "$LIMA_OTHER_STDIN"
  : > "$LIMA_ENV"
  export LIMA_LOG LIMA_STDIN LIMA_OTHER_STDIN LIMA_ENV VMSTATE GHR_POOL_LOCK="$W/pool.lock"
  cat > "$FAKE_BIN/limactl" <<'SHIM'
#!/bin/bash
echo "$*" >> "$LIMA_LOG"
env >> "$LIMA_ENV"
case "$*" in *"docker run"* | *"sudo -u runner"*) ;; *) cat >> "$LIMA_OTHER_STDIN" ;; esac
# per-job VM name: the last ghr-supa-* argument that is not the golden (clone: its 2nd name)
vm=""
for a in "$@"; do case "$a" in ghr-supa-golden) ;; ghr-supa-*) vm=$a ;; esac; done
case "$*" in
  "list --format"*) printf '%s' "${FAKE_ALL_VMS-}" ;;
  "list ghr-supa-golden"*) printf '%s' "${FAKE_GOLDEN_STATUS-Stopped}" ;;
  "list ghr-supa-"*)
    if [ -f "$VMSTATE/$vm.gone" ]; then :
    elif [ -f "$VMSTATE/$vm" ]; then cat "$VMSTATE/$vm"
    else printf '%s' "${FAKE_VM_STATUS-}"; fi ;;
  "list "*) printf '%s' "${FAKE_POOL_STATUS-Running}" ;;
  "clone "*) sleep "${FAKE_CLONE_SLEEP:-0}"; echo Stopped > "$VMSTATE/$vm"; rm -f "$VMSTATE/$vm.gone"; exit "${FAKE_CLONE_RC:-0}" ;;
  "start ghr-supa-"*) echo Running > "$VMSTATE/$vm"; exit "${FAKE_START_RC:-0}" ;;
  "stop -f ghr-supa-"*) sleep "${FAKE_STOP_SLEEP:-0}"; [ "${FAKE_STOP_RC:-0}" -eq 0 ] && echo Stopped > "$VMSTATE/$vm"; exit "${FAKE_STOP_RC:-0}" ;;
  "delete -f ghr-supa-"*)
    if [ "${FAKE_DELETE_RC:-0}" -eq 0 ] && [ -z "${FAKE_DELETE_PERSIST:-}" ]; then rm -f "$VMSTATE/$vm"; : > "$VMSTATE/$vm.gone"; fi
    exit "${FAKE_DELETE_RC:-0}" ;;
  *dev/tcp*) exit "${FAKE_PROBE_RC:-1}" ;;
  *"docker run"* | *"sudo -u runner"*) cat > "$LIMA_STDIN"; sleep "${FAKE_RUN_SLEEP:-0}"; exit "${FAKE_RUN_RC:-0}" ;;
  *) exit 0 ;;
esac
SHIM
  chmod +x "$FAKE_BIN/limactl"
  export LIMACTL="$FAKE_BIN/limactl"
}

# pve_setup — stateful `qm` shim for the Proxmox suites (launch-pve, build-supabase-pve). Per-VM state
# lives in $QMSTATE/<vmid>/{name,status,template,exit}; the golden is VMID 300 (a template) unless
# FAKE_GOLDEN_MISSING / FAKE_GOLDEN_NOT_TEMPLATE / FAKE_GOLDEN_NAME say otherwise. Every call is logged
# to $QM_LOG (argv), its environment to $QM_ENV, stdin of `guest exec --pass-stdin` calls to $QM_STDIN,
# and stdin of every OTHER call to $QM_OTHER_STDIN (must stay empty: no call may swallow the caller's
# stdin). Knobs (env): FAKE_EXTRA_VMS ("vmid name" lines shown by `qm list`), FAKE_CLONE_RC/_SLEEP,
# FAKE_SET_RC, FAKE_START_RC, FAKE_STOP_RC/_SLEEP, FAKE_DESTROY_RC, FAKE_DESTROY_PERSIST, FAKE_NO_FW
# (clone without firewall=1), FAKE_AGENT_RC, FAKE_CI_RC, FAKE_PROBE_RC, FAKE_DELIVER_RC, FAKE_START_UNIT_RC,
# FAKE_RUN_SLEEP (seconds until the guest "powers off"), FAKE_JOB_RC (exit code the guest reports),
# FAKE_PROVISION_RC / FAKE_PROVISION_OUT (build suite). Also exports the launch-pve test overrides.
pve_setup() {
  QM_LOG="$W/qm.log"; QM_ENV="$W/qm.env"; QM_STDIN="$W/qm.stdin"; QM_OTHER_STDIN="$W/qm.other.stdin"
  QMSTATE="$W/qmstate"; PVE_FW_DIR="$W/fw"
  mkdir -p "$QMSTATE/300" "$PVE_FW_DIR" "$W/snippets"
  : > "$QM_LOG"; : > "$QM_ENV"; : > "$QM_STDIN"; : > "$QM_OTHER_STDIN"
  if [ -z "${FAKE_GOLDEN_MISSING:-}" ]; then
    printf '%s' "${FAKE_GOLDEN_NAME:-ghr-supa-golden}" > "$QMSTATE/300/name"
    echo stopped > "$QMSTATE/300/status"
    [ -n "${FAKE_GOLDEN_NOT_TEMPLATE:-}" ] || : > "$QMSTATE/300/template"
  else
    rm -rf "$QMSTATE/300"
  fi
  export QM_LOG QM_ENV QM_STDIN QM_OTHER_STDIN QMSTATE PVE_FW_DIR
  cat > "$FAKE_BIN/qm" <<'SHIM'
#!/bin/bash
echo "$*" >> "$QM_LOG"
env >> "$QM_ENV"
case "$*" in
  *"--pass-stdin 1"*)
    cat > "$QMSTATE/.stdin.$$"
    cat "$QMSTATE/.stdin.$$" >> "$QM_STDIN"
    # a file pushed with `bash -c 'cat > "$1" ...' _ <dest> <mode>` is kept under its basename
    prev=""; for a in "$@"; do if [ "$prev" = _ ]; then mkdir -p "$QMSTATE/.pushed"; cp "$QMSTATE/.stdin.$$" "$QMSTATE/.pushed/$(basename "$a")"; fi; prev=$a; done
    rm -f "$QMSTATE/.stdin.$$" ;;
  *) cat >> "$QM_OTHER_STDIN" ;;
esac
cmd=$1; id=${2:-}
[ "$cmd" != guest ] || id=${3:-}      # qm guest exec <vmid> ...
d="$QMSTATE/$id"
json() { printf '{"exitcode":%s,"exited":1,"out-data":"%s"}\n' "$1" "$2"; }
case "$cmd" in
  config)
    [ -d "$d" ] || exit 2
    echo "name: $(cat "$d/name")"
    [ ! -e "$d/template" ] || echo "template: 1"
    if [ -n "${FAKE_NO_FW:-}" ]; then echo "net0: virtio=BC:24:11:00:00:01,bridge=vmbr0"; else echo "net0: virtio=BC:24:11:00:00:01,bridge=vmbr0,firewall=1"; fi ;;
  status)
    [ -d "$d" ] || { echo "Configuration file 'nodes/pve/qemu-server/$id.conf' does not exist" >&2; exit 2; }
    echo "status: $(cat "$d/status")" ;;
  list)
    echo "      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID"
    for v in "$QMSTATE"/*/; do
      v=${v%/}; [ -d "$v" ] || continue
      printf '%10s %-20s %-10s 4096 40.00 0\n' "$(basename "$v")" "$(cat "$v/name")" "$(cat "$v/status")"
    done
    printf '%s\n' "${FAKE_EXTRA_VMS:-}" | while read -r vmid name; do
      [ -n "$vmid" ] && printf '%10s %-20s %-10s 4096 40.00 0\n' "$vmid" "$name" stopped
    done ;;
  clone)
    new=$3
    sleep "${FAKE_CLONE_SLEEP:-0}"
    mkdir -p "$QMSTATE/$new"
    name=""; shift 3
    while [ $# -gt 0 ]; do case "$1" in --name) name=$2; shift 2 ;; *) shift ;; esac; done
    printf '%s' "$name" > "$QMSTATE/$new/name"; echo stopped > "$QMSTATE/$new/status"
    exit "${FAKE_CLONE_RC:-0}" ;;
  create)
    [ "${FAKE_CREATE_RC:-0}" -eq 0 ] || exit "$FAKE_CREATE_RC"
    mkdir -p "$d"; echo stopped > "$d/status"
    shift 2; while [ $# -gt 0 ]; do case "$1" in --name) printf '%s' "$2" > "$d/name"; shift 2 ;; *) shift ;; esac; done ;;
  set) exit "${FAKE_SET_RC:-0}" ;;
  resize) exit "${FAKE_RESIZE_RC:-0}" ;;
  shutdown) [ -n "${FAKE_SHUTDOWN_STICKY:-}" ] || echo stopped > "$d/status"; exit "${FAKE_SHUTDOWN_RC:-0}" ;;
  template) [ "${FAKE_TEMPLATE_RC:-0}" -eq 0 ] && : > "$d/template"; exit "${FAKE_TEMPLATE_RC:-0}" ;;
  start)
    # the firewall file must exist BEFORE the first boot
    [ -f "$PVE_FW_DIR/$id.fw" ] && cp "$PVE_FW_DIR/$id.fw" "$d/fw-at-start"
    echo running > "$d/status"; exit "${FAKE_START_RC:-0}" ;;
  stop)
    sleep "${FAKE_STOP_SLEEP:-0}"
    [ -d "$d" ] || exit 0
    [ "${FAKE_STOP_RC:-0}" -eq 0 ] && echo stopped > "$d/status"
    exit "${FAKE_STOP_RC:-0}" ;;
  destroy)
    if [ "${FAKE_DESTROY_RC:-0}" -eq 0 ] && [ -z "${FAKE_DESTROY_PERSIST:-}" ]; then rm -rf "$d"; fi
    exit "${FAKE_DESTROY_RC:-0}" ;;
  agent) exit "${FAKE_AGENT_RC:-0}" ;;
  guest)
    case "$*" in
      *"cloud-init status"*) json "${FAKE_CI_RC:-0}" "" ;;
      *dev/tcp*) json "${FAKE_PROBE_RC:-1}" "" ;;
      *"/run/ghr/jit"*) json "${FAKE_DELIVER_RC:-0}" "" ;;
      *"PROVISION-OK"*) json 0 "${FAKE_PROVISION_OUT-PROVISION-OK 2.338.0 2.107.0}\\n" ;;
      *"cat /var/lib/ghr-provision.rc"*) json 0 "${FAKE_PROVISION_RC:-0}\\n" ;;
      *"tail -n 40"*) json 0 "provision log tail\\n" ;;
      *"systemctl start"*)
        if [ -n "${FAKE_JOB_RC:-}" ]; then echo "$FAKE_JOB_RC" > "$d/exit"; fi
        # the guest "powers off" FAKE_RUN_SLEEP seconds later (0 = immediately)
        if [ "${FAKE_RUN_SLEEP:-0}" = 0 ]; then echo stopped > "$d/status"
        else ( sleep "$FAKE_RUN_SLEEP"; [ -d "$d" ] && echo stopped > "$d/status" ) > /dev/null 2>&1 3>&- & fi
        json "${FAKE_START_UNIT_RC:-0}" "" ;;
      *"/var/lib/ghr/exit"*)
        if [ -f "$d/exit" ]; then json 0 "$(cat "$d/exit")\\n"; else json 1 ""; fi ;;
      *) json 0 "" ;;
    esac ;;
  *) exit 0 ;;
esac
SHIM
  chmod +x "$FAKE_BIN/qm"
  export QM="$FAKE_BIN/qm"
}

# tart_setup — stateful `tart` shim for the ios suites (launch-ios, build-ios). Per-VM state lives in
# $TARTSTATE/vms/<name> (one word: stopped|running|suspended); the golden `ghr-ios-golden` is created
# `stopped` unless FAKE_TART_GOLDEN_STATE says otherwise ("none" = absent). Every call is logged to
# $TART_LOG (argv) and its environment to $TART_ENV; the stdin of the runner start (`exec -i ... run.sh`)
# lands in $TART_STDIN, the stdin of every OTHER call in $TART_OTHER_STDIN (must stay empty). `list
# --format json` prints the expected array shape (Source/Name/State/Running/Disk/Size) incl. an OCI entry.
# Knobs (env): FAKE_TART_LIST_RC/_JSON (override), FAKE_CLONE_RC/_SLEEP, FAKE_SET_RC, FAKE_RUN_DIES
# (`tart run` exits 1 at once), FAKE_AGENT_FAILS=N (first N `exec ... true` fail), FAKE_AGENT_NEVER,
# FAKE_PROBE_RC (nc, default 1 = blocked), FAKE_RUN_RC/_SLEEP (the runner), FAKE_STOP_RC/_SLEEP,
# FAKE_DELETE_RC, FAKE_DELETE_PERSIST, FAKE_PROVISION_OUT/_RC (build suite), FAKE_RENAME_RC/_FAIL_TO (the first rename TO that name fails),
# FAKE_ALL_VMS (extra "name state" lines created at setup).
tart_setup() {
  TART_LOG="$W/tart.log"; TART_ENV="$W/tart.env"; TART_STDIN="$W/tart.stdin"; TART_OTHER_STDIN="$W/tart.other.stdin"
  TARTSTATE="$W/tartstate"
  mkdir -p "$TARTSTATE/vms"
  : > "$TART_LOG"; : > "$TART_ENV"; : > "$TART_OTHER_STDIN"
  case "${FAKE_TART_GOLDEN_STATE-stopped}" in none) ;; *) echo "${FAKE_TART_GOLDEN_STATE-stopped}" > "$TARTSTATE/vms/ghr-ios-golden" ;; esac
  if [ -n "${FAKE_ALL_VMS:-}" ]; then
    while read -r nm st; do [ -z "$nm" ] || echo "$st" > "$TARTSTATE/vms/$nm"; done <<< "$FAKE_ALL_VMS"
  fi
  export TART_LOG TART_ENV TART_STDIN TART_OTHER_STDIN TARTSTATE
  cat > "$FAKE_BIN/tart" <<'SHIM'
#!/bin/bash
echo "$*" >> "$TART_LOG"
env >> "$TART_ENV"
cmd=$1
case "$*" in
  *"exec -i"*"run.sh"*) cat > "$TART_STDIN" ;;
  *) cat >> "$TART_OTHER_STDIN" ;;
esac
vmf() { echo "$TARTSTATE/vms/$1"; }
case "$cmd" in
  list)
    [ "${FAKE_TART_LIST_RC:-0}" -eq 0 ] || exit "$FAKE_TART_LIST_RC"
    if [ -n "${FAKE_TART_LIST_JSON:-}" ]; then printf '%s\n' "$FAKE_TART_LIST_JSON"; exit 0; fi
    printf '[\n'
    printf '{"Source":"OCI","Name":"ghcr.io/example/base@sha256:abc","Disk":50,"Size":20,"Running":false,"State":"stopped"}'
    for f in "$TARTSTATE"/vms/*; do
      [ -e "$f" ] || continue
      st=$(cat "$f")
      running=false; [ "$st" = running ] && running=true
      printf ',\n{"Source":"local","Name":"%s","Disk":50,"Size":20,"Running":%s,"State":"%s"}' "$(basename "$f")" "$running" "$st"
    done
    printf '\n]\n' ;;
  clone)
    sleep "${FAKE_CLONE_SLEEP:-0}"
    echo stopped > "$(vmf "$3")"
    exit "${FAKE_CLONE_RC:-0}" ;;
  set) exit "${FAKE_SET_RC:-0}" ;;
  run)
    vm=$2
    if [ -n "${FAKE_RUN_DIES:-}" ]; then echo stopped > "$(vmf "$vm")"; exit 1; fi
    echo running > "$(vmf "$vm")"
    # a killed `tart run` is a stopped VM (the real list derives the state from the process)
    trap 'echo stopped > "$(vmf "$vm")" 2> /dev/null; exit 143' TERM
    # blocks for the VM's lifetime: ends when the VM is stopped or deleted
    while [ "$(cat "$(vmf "$vm")" 2> /dev/null)" = running ]; do sleep 0.2; done
    exit 0 ;;
  exec)
    shift; [ "$1" != "-i" ] || shift
    vm=$1; shift
    # the guest agent only exists while the VM runs
    [ "$(cat "$(vmf "$vm")" 2> /dev/null)" = running ] || exit 1
    case "$*" in
      "/usr/bin/true")
        [ -z "${FAKE_AGENT_NEVER:-}" ] || exit 1
        n=$(cat "$TARTSTATE/.agent.$vm" 2> /dev/null || echo 0)
        echo $((n + 1)) > "$TARTSTATE/.agent.$vm"
        [ "$n" -ge "${FAKE_AGENT_FAILS:-0}" ] || exit 1
        exit 0 ;;
      *"/usr/bin/nc "*)
        # the probe prints the guest nc's exit code; FAKE_PROBE_EXEC_RC fails `tart exec` itself
        [ -z "${FAKE_PROBE_EXEC_RC:-}" ] || exit "$FAKE_PROBE_EXEC_RC"
        echo "GHR_NC_RC=${FAKE_PROBE_RC:-1}"; exit 0 ;;
      *"run.sh"*) sleep "${FAKE_RUN_SLEEP:-0}"; exit "${FAKE_RUN_RC:-0}" ;;
      "/bin/bash /tmp/ghr-provision.sh"*)
        [ "${FAKE_PROVISION_RC:-0}" -eq 0 ] || exit "$FAKE_PROVISION_RC"
        printf '%s\n' "${FAKE_PROVISION_OUT-PROVISION-OK 2.999.0 26.0}"; exit 0 ;;
      *) exit 0 ;;
    esac ;;
  stop)
    sleep "${FAKE_STOP_SLEEP:-0}"
    [ "${FAKE_STOP_RC:-0}" -eq 0 ] || exit "$FAKE_STOP_RC"
    [ ! -e "$(vmf "$2")" ] || echo stopped > "$(vmf "$2")"
    exit 0 ;;
  delete)
    [ "${FAKE_DELETE_RC:-0}" -eq 0 ] || exit "$FAKE_DELETE_RC"
    # like the real thing, a running VM cannot be deleted
    [ "$(cat "$(vmf "$2")" 2> /dev/null)" != running ] || exit 1
    [ -n "${FAKE_DELETE_PERSIST:-}" ] || rm -f "$(vmf "$2")"
    exit 0 ;;
  rename)
    [ "${FAKE_RENAME_RC:-0}" -eq 0 ] || exit "$FAKE_RENAME_RC"
    # fails ONCE (the restore after a failed swap renames to the same name and must work)
    if [ "$3" = "${FAKE_RENAME_FAIL_TO:-}" ] && [ ! -e "$TARTSTATE/.rename-failed" ]; then : > "$TARTSTATE/.rename-failed"; exit 1; fi
    mv "$(vmf "$2")" "$(vmf "$3")"; exit $? ;;
  *) exit 0 ;;
esac
SHIM
  chmod +x "$FAKE_BIN/tart"
  export TART="$FAKE_BIN/tart"
}
