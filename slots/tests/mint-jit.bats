#!/usr/bin/env bats
# Tests for slots/mint-jit.sh and slots/reconcile.sh: the label/name policy gate and the
# exact-name stale-runner cleanup. Offline (curl shim).

load helpers

setup() {
  slots_setup
  source "$SLOTS_DIR/lib/gh-app.sh"
  ghr_load_config
  source "$SLOTS_DIR/mint-jit.sh"
  source "$SLOTS_DIR/reconcile.sh"
}

@test "hosted-runner labels are refused (ubuntu/macos/windows, any case)" {
  for l in ubuntu-latest ubuntu-24.04 macos-14 macos-latest windows-2022 Windows-Latest UBUNTU-22.04 ubuntu macos windows; do
    run jit_validate ghr-light-1 "$l"
    [ "$status" -ne 0 ]
  done
}

@test "hosted label wins even if an operator put it in ALLOWED_LABELS" {
  ALLOWED_LABELS="ghr-light,ubuntu-latest"
  run jit_validate ghr-light-1 ubuntu-latest
  [ "$status" -ne 0 ]
  run jit_validate ghr-light-1 ghr-light ubuntu-latest
  [ "$status" -ne 0 ]
}

@test "self-hosted alone is refused; with an allowed label it still needs to be allowlisted" {
  ALLOWED_LABELS="self-hosted,ghr-light"
  run jit_validate ghr-light-1 self-hosted
  [ "$status" -ne 0 ]
  run jit_validate ghr-light-1 self-hosted ghr-light
  [ "$status" -eq 0 ]
  ALLOWED_LABELS="ghr-light"
  run jit_validate ghr-light-1 self-hosted ghr-light
  [ "$status" -ne 0 ]
}

@test "ALLOWED_LABELS enforced case-insensitively; unknown label refused" {
  run jit_validate ghr-light-1 ghr-light
  [ "$status" -eq 0 ]
  run jit_validate ghr-light-1 GHR-LIGHT
  [ "$status" -eq 0 ]
  run jit_validate ghr-light-1 ghr-light extra
  [ "$status" -ne 0 ]
  run jit_validate ghr-light-1 ghr-android
  [ "$status" -ne 0 ]
}

@test "empty ALLOWED_LABELS fails closed" {
  ALLOWED_LABELS=""
  run jit_validate ghr-light-1 ghr-light
  [ "$status" -ne 0 ]
}

@test "labels with JSON-significant characters are refused" {
  ALLOWED_LABELS='a"b'
  run jit_validate ghr-light-1 'a"b'
  [ "$status" -ne 0 ]
  run jit_validate ghr-light-1 ghr-light 'x y'
  [ "$status" -ne 0 ]
}

@test "runner name regex: bad names and a trailing newline are refused" {
  for n in ghr-light-1x ghr-android-1 "gh-runner-light-h-1" "ghr-light-" "../ghr-light-1" $'ghr-light-1\n'; do
    run jit_validate "$n" ghr-light
    [ "$status" -ne 0 ]
  done
  run jit_validate ghr-supabase-2 ghr-supabase
  [ "$status" -eq 0 ]
}

@test "no labels -> refused" {
  run jit_validate ghr-light-1
  [ "$status" -ne 0 ]
}

@test "request body shape" {
  [ "$(jit_body ghr-light-3 1 ghr-light x)" = '{"name":"ghr-light-3","runner_group_id":1,"labels":["ghr-light","x"],"work_folder":"_work"}' ]
}

@test "end to end: stdout is ONLY the jit config; request sent to the org endpoint; no secret in argv" {
  route_token
  route POST /orgs/test-org/actions/runners/generate-jitconfig 201 '{"runner":{"id":9},"encoded_jit_config":"QUJDREVGRw=="}'
  run bash "$SLOTS_DIR/mint-jit.sh" ghr-light-2 ghr-light
  [ "$status" -eq 0 ]
  [ "$output" = "QUJDREVGRw==" ]
  grep -q 'CALL POST /orgs/test-org/actions/runners/generate-jitconfig' "$CURL_LOG"
  grep -q 'BODY {"name":"ghr-light-2","runner_group_id":1,"labels":\["ghr-light"\]' "$CURL_LOG"
  refute grep -q -e ghs_faketoken -e QUJDREVGRw "$CURL_ARGV_LOG"
}

@test "end to end: a refused request makes NO network call" {
  route_token
  run bash "$SLOTS_DIR/mint-jit.sh" ghr-light-2 ubuntu-latest
  [ "$status" -eq 2 ]
  [ ! -s "$CURL_LOG" ]
  run bash "$SLOTS_DIR/mint-jit.sh" ghr-light-2 evil-label
  [ "$status" -eq 2 ]
  [ ! -s "$CURL_LOG" ]
}

# ── reconcile.sh ──────────────────────────────────────────────────────────────

tsv_fixture() {
  printf '1\tghr-light-1\toffline\tfalse\n10\tghr-light-10\toffline\tfalse\n2\tghr-light-2\tonline\ttrue\n'
}

@test "reconcile_pick: exact name only (ghr-light-1 must not match ghr-light-10)" {
  [ "$(tsv_fixture | reconcile_pick ghr-light-1)" = "1 offline" ]
  [ "$(tsv_fixture | reconcile_pick ghr-light-10)" = "10 offline" ]
  [ -z "$(tsv_fixture | reconcile_pick ghr-light-3)" ]
}

@test "reconcile: deletes the offline same-name runner, nothing else" {
  route_token
  route GET /orgs/test-org/actions/runners 200 '{"total_count":3,"runners":[{"id":1,"name":"ghr-light-1","status":"offline","busy":false},{"id":10,"name":"ghr-light-10","status":"offline","busy":false},{"id":5,"name":"other","status":"offline","busy":false}]}'
  route DELETE /orgs/test-org/actions/runners/1 204 ''
  run bash "$SLOTS_DIR/reconcile.sh" ghr-light-1
  [ "$status" -eq 0 ]
  grep -q 'CALL DELETE /orgs/test-org/actions/runners/1$' "$CURL_LOG"
  [ "$(grep -c 'CALL DELETE' "$CURL_LOG")" -eq 1 ]
}

@test "reconcile: an ONLINE runner with the name is left alone" {
  route_token
  route GET /orgs/test-org/actions/runners 200 '{"runners":[{"id":2,"name":"ghr-light-2","status":"online","busy":true}]}'
  run bash "$SLOTS_DIR/reconcile.sh" ghr-light-2
  [ "$status" -eq 0 ]
  refute grep -q 'CALL DELETE' "$CURL_LOG"
}

@test "reconcile: absent runner is a no-op; invalid name refused before any call" {
  route_token
  route GET /orgs/test-org/actions/runners 200 '{"runners":[]}'
  run bash "$SLOTS_DIR/reconcile.sh" ghr-light-3
  [ "$status" -eq 0 ]
  refute grep -q 'CALL DELETE' "$CURL_LOG"
  : > "$CURL_LOG"
  run bash "$SLOTS_DIR/reconcile.sh" some-other-runner
  [ "$status" -eq 2 ]
  [ ! -s "$CURL_LOG" ]
}
