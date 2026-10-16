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
