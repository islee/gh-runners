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
