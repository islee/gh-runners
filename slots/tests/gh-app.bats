#!/usr/bin/env bats
# Tests for slots/lib/gh-app.sh: JWT shape (throwaway key), token cache, gh_api status mapping,
# runner-list parsing. Offline: curl is a shim.

load helpers

setup() {
  slots_setup
  # shellcheck source=/dev/null
  source "$SLOTS_DIR/lib/gh-app.sh"
}

@test "JWT: header, claims (iat=now-60, exp=now+540, iss) and a verifiable RS256 signature" {
  jwt=$(gh_app_jwt 111 "$W/key.pem" 1000000)
  IFS=. read -r h p s <<< "$jwt"
  [ "$(b64url_decode "$h")" = '{"alg":"RS256","typ":"JWT"}' ]
  [ "$(b64url_decode "$p")" = '{"iat":999940,"exp":1000540,"iss":111}' ]
  # signature must verify against the public half of the throwaway key
  b64url_decode "$s" > "$W/sig.bin"
  printf '%s.%s' "$h" "$p" > "$W/signed.txt"
  run openssl dgst -sha256 -verify "$W/pub.pem" -signature "$W/sig.bin" "$W/signed.txt"
  [ "$status" -eq 0 ]
}

@test "JWT: lifetime is within GitHub's 10 minute limit" {
  jwt=$(gh_app_jwt 111 "$W/key.pem" 5000)
  IFS=. read -r _ p _ <<< "$jwt"
  iat=$(b64url_decode "$p" | python3 -c 'import sys,json; print(json.load(sys.stdin)["iat"])')
  exp=$(b64url_decode "$p" | python3 -c 'import sys,json; print(json.load(sys.stdin)["exp"])')
  [ $((exp - iat)) -le 600 ]
}

@test "JWT: client-id style app id is a JSON string; bad ids and missing keys are rejected" {
  jwt=$(gh_app_jwt Iv23abc "$W/key.pem" 1000)
  IFS=. read -r _ p _ <<< "$jwt"
  [[ "$(b64url_decode "$p")" == *'"iss":"Iv23abc"'* ]]
  run gh_app_jwt 'x";y' "$W/key.pem" 1000
  [ "$status" -ne 0 ]
  run gh_app_jwt 111 "$W/nope.pem" 1000
  [ "$status" -ne 0 ]
}

@test "token: minted once, then served from a 0600 cache; token never in curl argv" {
  route_token
  gh_app_init 111 222 "$W/key.pem"
  t1=$(gh_installation_token)
  t2=$(gh_installation_token)
  [ "$t1" = "ghs_faketoken_runner" ]
  [ "$t2" = "$t1" ]
  [ "$(grep -c 'POST /app/installations/222/access_tokens' "$CURL_LOG")" -eq 1 ]
  [ "$(ls -l "$GH_TOKEN_CACHE" | cut -c1-10)" = "-rw-------" ]
  refute grep -q ghs_faketoken "$CURL_ARGV_LOG"
}

@test "token: an expired cache entry is re-minted" {
  route_token
  gh_app_init 111 222 "$W/key.pem"
  printf '%s %s\n' 1 stale > "$GH_TOKEN_CACHE"
  [ "$(gh_installation_token)" = "ghs_faketoken_runner" ]
}

@test "gh_api: 2xx -> 0 with body, 404 -> 4, 500 -> 1; bearer is not in argv" {
  route_token
  route GET /x/ok 200 '{"a":1}'
  route GET /x/err 500 '{"message":"boom"}'
  gh_app_init 111 222 "$W/key.pem"
  run gh_api GET /x/ok
  [ "$status" -eq 0 ]; [[ "$output" == *'"a":1'* ]]
  run gh_api GET /x/missing
  [ "$status" -eq 4 ]
  run gh_api GET /x/err
  [ "$status" -eq 1 ]
  refute grep -q ghs_faketoken "$CURL_ARGV_LOG"
}

@test "runners TSV: columns parsed, tab/newline in names neutralised" {
  out=$(printf '%s' '{"runners":[{"id":1,"name":"ghr-light-1","status":"online","busy":true},{"id":2,"name":"evil\tname\nx","status":"offline","busy":false}]}' | gh_runners_tsv_from_json)
  [ "$(printf '%s\n' "$out" | sed -n 1p)" = "$(printf '1\tghr-light-1\tonline\ttrue\t')" ]
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 2 ]
  [ "$(printf '%s\n' "$out" | sed -n 2p | cut -f2)" = "evil?name?x" ]
}

@test "runner name regex: anchored, no trailing newline, only light|supabase" {
  ghr_valid_runner_name ghr-light-1
  ghr_valid_runner_name ghr-supabase-12
  refute ghr_valid_runner_name ghr-android-1
  refute ghr_valid_runner_name "ghr-light-1x"
  refute ghr_valid_runner_name "xghr-light-1"
  refute ghr_valid_runner_name "ghr-light-"
  refute ghr_valid_runner_name $'ghr-light-1\n'
  refute ghr_valid_runner_name $'ghr-light-1\nghr-light-2'
  refute ghr_valid_runner_name "gh-runner-light-host-1"
}

@test "runners TSV: 5th column = ALL labels (JIT labels come back type read-only), lowercased and sorted" {
  # Real API shape for a JIT runner (2026-10-16): its only label, type "read-only", id 0.
  out=$(printf '%s' '{"runners":[{"id":1,"name":"ghr-light-1","status":"online","busy":false,"labels":[{"id":0,"name":"ghr-light","type":"read-only"}]}]}' | gh_runners_tsv_from_json)
  [ "$out" = "$(printf '1\tghr-light-1\tonline\tfalse\tghr-light')" ]
  # A token-registered runner also carries system labels -> they are kept, so the tripwire sees a mismatch.
  out=$(printf '%s' '{"runners":[{"id":2,"name":"ghr-light-2","status":"online","busy":false,"labels":[{"name":"self-hosted","type":"read-only"},{"name":"macOS","type":"read-only"},{"name":"ghr-light","type":"custom"}]}]}' | gh_runners_tsv_from_json)
  [ "$out" = "$(printf '2\tghr-light-2\tonline\tfalse\tghr-light,macos,self-hosted')" ]
}

@test "token cache: gh_app_init refuses when HOME is unset/empty/relative (no /tmp fallback)" {
  HOME="" run gh_app_init 111 222 "$W/key.pem"
  [ "$status" -ne 0 ]
  unset HOME
  run gh_app_init 111 222 "$W/key.pem"
  [ "$status" -ne 0 ]
  HOME="relative/dir" run gh_app_init 111 222 "$W/key.pem"
  [ "$status" -ne 0 ]
}

@test "_gh_request: the temp dir holding the bearer is removed even if the request is killed" {
  route_token
  # curl shim that SIGTERMs its parent (the request subshell) mid-request
  cat > "$FAKE_BIN/curl" <<'SHIM'
#!/bin/bash
kill -TERM "$PPID"
sleep 1
SHIM
  gh_app_init 111 222 "$W/key.pem"
  run _gh_request fakebearer GET /x
  [ "$status" -ne 0 ]
  run bash -c "ls -d '$W'/ghr.* 2>/dev/null"
  [ -z "$output" ]
}
