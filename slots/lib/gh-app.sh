#!/bin/bash
# gh-app.sh — shared library for the slot controllers: config loading, runner-name validation,
# GitHub App JWT -> installation token (cached) -> `gh_api` curl helper.
#
# Context: sourced (never executed) by mint-jit.sh, reconcile.sh, slot-loop.sh, launch.sh and
# heartbeat.sh. Two roles use it with DIFFERENT Apps and keys: _ghrctl (runner App, org
# self-hosted-runners write) and _ghrstate (state App, repo variables write + runners read).
# Each caller calls `gh_app_init` with its own App id / installation id / key path.
#
# Dependencies: bash 3.2+, /usr/bin/curl, openssl (LibreSSL ok), python3 (JSON parsing only,
# stdlib). No third-party packages. Must also run on Linux (CI runs the bats suite there).
#
# Secrets handling:
#   - JWT and installation token reach curl through a 0600 `-K` config file in a 0700 temp dir,
#     never argv (argv is world-readable via `ps`).
#   - The installation token is cached 0600 in the caller's home so 60 s heartbeats and
#     slot loops don't re-mint every call.

# GH_API_BASE is overridable for tests only; daemons never set it.
GH_API_BASE="${GH_API_BASE:-https://api.github.com}"
# NOTE: installation tokens live 1 h; cache ~50 min so a cached token always has headroom.
GH_TOKEN_TTL="${GH_TOKEN_TTL:-3000}"

# Runner naming convention. CRITICAL: anchored. Also checked against embedded newlines in
# ghr_valid_runner_name because a bare `$` would accept "ghr-light-1\n" in some regex engines
# (the broker needed the same fix: `\Z`).
GHR_NAME_RE='^ghr-(light|supabase)-[0-9]+$'

ghr_log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2; }

# ── Config ──────────────────────────────────────────────────────────────────────

# ghr_valid_runner_name NAME — exit 0 iff NAME is exactly ghr-(light|supabase)-<digits>.
ghr_valid_runner_name() {
  case "$1" in *$'\n'*|*$'\r'*) return 1 ;; esac
  [[ "$1" =~ $GHR_NAME_RE ]]
}

# ghr_load_config — source the root-owned, secret-free config and apply defaults.
# WHY env override GHR_CONFIG: tests point it at a fixture. launch.sh runs under sudo
# (env_reset), so a caller cannot smuggle an override into the privileged path.
ghr_load_config() {
  GHR_CONFIG="${GHR_CONFIG:-/usr/local/etc/ghr/slots.env}"
  [ -r "$GHR_CONFIG" ] || { ghr_log "ERROR config not readable: $GHR_CONFIG"; return 1; }
  # shellcheck source=/dev/null
  . "$GHR_CONFIG"
  : "${RUNNER_GROUP_ID:=1}"
  : "${LIGHT_SLOTS:=6}"
  : "${LIGHT_LABELS:=ghr-light}"
  : "${ALLOWED_LABELS:=}"
  : "${CONSUMER_REPOS:=}"
  : "${LAN_PROBE:=}"
  : "${LIGHT_IMAGE:=}"
  : "${ORG:=}"
  [[ "$ORG" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || { ghr_log "ERROR ORG missing/invalid in config"; return 1; }
  [[ "$RUNNER_GROUP_ID" =~ ^[0-9]+$ ]] || { ghr_log "ERROR RUNNER_GROUP_ID must be numeric"; return 1; }
  return 0
}

# ── JSON helpers (python3 stdlib, stdin -> stdout) ───────────────────────────────

# gh_json_get KEY — print top-level string/number field KEY of the JSON object on stdin;
# exit 1 if absent or not an object.
gh_json_get() {
  python3 -I -c '
import sys, json
try:
    d = json.load(sys.stdin)
    v = d.get(sys.argv[1])
except Exception:
    sys.exit(1)
if v is None or isinstance(v, (dict, list)):
    sys.exit(1)
print(v)
' "$1"
}

# gh_runners_tsv_from_json — runners list JSON on stdin -> TSV lines `id name status busy labels`.
# labels = the CUSTOM labels only (read-only system labels such as self-hosted/OS/arch are not
# controlled by whoever registers the runner), lowercased, sorted, comma-joined.
# WHY sanitize: a runner name containing a tab/newline must not forge extra columns/rows; it
# then simply fails the name regex and trips the tripwire.
gh_runners_tsv_from_json() {
  python3 -I -c '
import sys, json
def clean(v):
    v = str(v)
    for ch in ("\t", "\n", "\r"):
        v = v.replace(ch, "?")
    return v
d = json.load(sys.stdin)
for r in d.get("runners", []):
    # ALL labels, whatever their type: GitHub reports the labels of a JIT runner as
    # {"id": 0, "type": "read-only"} (seen 2026-10-16), so filtering read-only emptied them.
    # The fleet is JIT-only and JIT runners carry no system labels, so any extra label
    # (self-hosted/os/arch from a token-registered runner) must count as a mismatch.
    labels = sorted({clean(l.get("name", "")).lower() for l in r.get("labels", [])})
    print("%s\t%s\t%s\t%s\t%s" % (r.get("id", ""), clean(r.get("name", "")), r.get("status", ""),
                                  "true" if r.get("busy") else "false", ",".join(labels)))
'
}

# ── App auth ────────────────────────────────────────────────────────────────────

gh_b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# gh_app_jwt APP_ID KEY_PATH [NOW] — print an RS256 App JWT.
# Claims mirror broker/app.py: iat = now-60 (clock skew), exp = now+540 (<10 min limit).
gh_app_jwt() {
  local app_id=$1 key=$2 now=${3:-}
  [ -n "$now" ] || now=$(date -u +%s)
  [[ "$app_id" =~ ^[A-Za-z0-9]+$ ]] || { ghr_log "ERROR invalid app id"; return 1; }
  [ -r "$key" ] || { ghr_log "ERROR app key not readable: $key"; return 1; }
  # numeric app id -> JSON number (as the broker does); client-id strings (Iv...) -> JSON string
  local iss="\"$app_id\""
  [[ "$app_id" =~ ^[0-9]+$ ]] && iss=$app_id
  local header payload sig
  header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | gh_b64url)
  payload=$(printf '{"iat":%s,"exp":%s,"iss":%s}' "$((now - 60))" "$((now + 540))" "$iss" | gh_b64url)
  sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$key" | gh_b64url)
  # WHY explicit check: without pipefail a failed openssl yields an empty signature silently.
  [ -n "$sig" ] || { ghr_log "ERROR JWT signing failed"; return 1; }
  printf '%s.%s.%s\n' "$header" "$payload" "$sig"
}

# gh_app_init APP_ID INSTALLATION_ID KEY_PATH — select which App subsequent gh_api calls use.
gh_app_init() {
  GH_APP_ID=$1
  GH_INSTALLATION_ID=$2
  GH_APP_KEY=$3
  [[ "$GH_INSTALLATION_ID" =~ ^[0-9]+$ ]] || { ghr_log "ERROR invalid installation id"; return 1; }
  # Cache lives in the caller's home (0700 role-account dir), keyed by app id so two Apps
  # never share a token. WHY no /tmp fallback: a world-writable dir would let another local user
  # pre-plant or read the cache.
  local cache_dir="${GH_CACHE_DIR:-${HOME:-}}"
  [[ "$cache_dir" == /* ]] || { ghr_log "ERROR HOME unset/relative: refusing to cache tokens"; return 1; }
  GH_TOKEN_CACHE="$cache_dir/.ghr-token-${GH_APP_ID}"
}

# _gh_request BEARER METHOD PATH [JSON] — one curl call, run in a subshell whose EXIT/TERM/INT
# trap removes the 0700 temp dir holding the bearer (a plain trap here would clobber the caller's,
# e.g. slot-loop's SIGTERM handler).
_gh_request() { ( _gh_request_inner "$@" ); }

# _gh_request_inner — body of _gh_request. Body to stdout, status via return:
# 0 = 2xx, 4 = 404, 1 = anything else (body still printed, truncated message on stderr).
_gh_request_inner() {
  local bearer=$1 method=$2 path=$3 json=${4-}
  # NOTE: tmp is deliberately NOT local: the EXIT trap fires after this function has returned.
  local code="" rc=0
  tmp=""
  tmp=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/ghr.XXXXXX") || return 1
  trap 'rm -rf "$tmp"' EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  # mktemp -d is 0700, so the files below are private to this user.
  printf 'header = "Authorization: Bearer %s"\n' "$bearer" > "$tmp/cfg"
  local args=(-sS --max-time 30 -X "$method" -K "$tmp/cfg"
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28'
    -o "$tmp/out" -w '%{http_code}')
  if [ -n "$json" ]; then
    printf '%s' "$json" > "$tmp/body"
    args+=(-H 'Content-Type: application/json' --data-binary "@$tmp/body")
  fi
  code=$(curl "${args[@]}" "$GH_API_BASE$path") || rc=$?
  [ -f "$tmp/out" ] && cat "$tmp/out"
  local snippet=""
  [ -f "$tmp/out" ] && snippet=$(head -c 200 "$tmp/out" | tr '\n' ' ')
  if [ "$rc" -ne 0 ] || [ -z "$code" ]; then
    ghr_log "ERROR curl failed (rc=$rc) $method $path"
    return 1
  fi
  case "$code" in
    2??) return 0 ;;
    404) return 4 ;;
    *) ghr_log "ERROR HTTP $code $method $path ${snippet}"; return 1 ;;
  esac
}

# gh_installation_token — print a valid installation token for the App chosen by gh_app_init.
gh_installation_token() {
  local now exp="" tok=""
  now=$(date -u +%s)
  if [ -r "$GH_TOKEN_CACHE" ]; then
    read -r exp tok < "$GH_TOKEN_CACHE" || true
    if [[ "$exp" =~ ^[0-9]+$ ]] && [ -n "$tok" ] && [ "$exp" -gt "$((now + 60))" ]; then
      printf '%s\n' "$tok"
      return 0
    fi
  fi
  local jwt resp
  jwt=$(gh_app_jwt "$GH_APP_ID" "$GH_APP_KEY" "$now") || return 1
  resp=$(_gh_request "$jwt" POST "/app/installations/${GH_INSTALLATION_ID}/access_tokens") || return 1
  tok=$(printf '%s' "$resp" | gh_json_get token) || { ghr_log "ERROR no token in response"; return 1; }
  # Atomic 0600 write: a half-written cache must never be readable as a token.
  ( umask 077; printf '%s %s\n' "$((now + GH_TOKEN_TTL))" "$tok" > "${GH_TOKEN_CACHE}.$$" ) \
    && mv -f "${GH_TOKEN_CACHE}.$$" "$GH_TOKEN_CACHE" \
    || ghr_log "WARN could not write token cache"
  printf '%s\n' "$tok"
}

# gh_api METHOD PATH [JSON] — authenticated GitHub REST call; return codes as _gh_request.
gh_api() {
  local tok
  tok=$(gh_installation_token) || return 1
  _gh_request "$tok" "$1" "$2" "${3-}"
}

# gh_list_runners — all org runners as TSV `id name status busy` (paginated, max 20 pages).
gh_list_runners() {
  local page=1 page_json lines n
  while [ "$page" -le 20 ]; do
    page_json=$(gh_api GET "/orgs/${ORG}/actions/runners?per_page=100&page=${page}") || return 1
    lines=$(printf '%s' "$page_json" | gh_runners_tsv_from_json) || return 1
    [ -n "$lines" ] && printf '%s\n' "$lines"
    n=0
    [ -n "$lines" ] && n=$(printf '%s\n' "$lines" | wc -l | tr -d ' ')
    [ "$n" -lt 100 ] && return 0
    page=$((page + 1))
  done
  return 0
}
