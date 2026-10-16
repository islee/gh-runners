#!/usr/bin/env bats
# shellcheck disable=SC2034  # globals consumed by the sourced script under test
# Tests for slots/heartbeat.sh: ok/saturated/down computation from fixture state files, the
# foreign-runner tripwire, and the repo-variable write path (PATCH, POST on 404). Offline.

load helpers

NOW=1000000

setup() {
  slots_setup
  export GHR_STATE_DIR="$W/state" GHR_HB_ROOT="$W/hbroot"
  mkdir -p "$GHR_HB_ROOT"
  source "$SLOTS_DIR/heartbeat.sh"
  ghr_load_config      # LIGHT_SLOTS=3
  RUNNERS="$W/runners.tsv"
  HB="$W/hb"
  all_online
}

# slot N STATE AGE SINCE_AGE — write a fixture slot file (ts = NOW-AGE, since = NOW-SINCE_AGE).
slot() {
  printf '{"slot":"light-%s","class":"light","n":%s,"state":"%s","ts":%s,"since":%s,"last_exit":0}\n' \
    "$1" "$1" "$2" "$((NOW - $3))" "$((NOW - $4))" > "$W/state/light-$1.json"
}
healthy_slots() { slot 1 registered 5 5000; slot 2 registered 5 5000; slot 3 registered 5 5000; }
all_online() {
  printf '1\tghr-light-1\tonline\tfalse\n2\tghr-light-2\tonline\tfalse\n3\tghr-light-3\tonline\tfalse\n' > "$RUNNERS"
}
all_busy() {
  printf '1\tghr-light-1\tonline\ttrue\n2\tghr-light-2\tonline\ttrue\n3\tghr-light-3\tonline\ttrue\n' > "$RUNNERS"
}
compute() { compute_state "$W/state" "${1:-$NOW}" "$RUNNERS" "$HB"; }

@test "ok: every slot fresh, runners online, not all busy" {
  healthy_slots
  [ "$(compute)" = "ok" ]
}

@test "down: no state files at all / a missing slot file" {
  [ "$(compute)" = "down" ]
  healthy_slots
  rm "$W/state/light-3.json"
  [ "$(compute)" = "down" ]
}

@test "down: one slot wrote more than 120 s ago (wedged loop); exactly 120 s is still ok" {
  healthy_slots
  slot 2 idle 121 5000
  [ "$(compute)" = "down" ]
  slot 2 idle 120 5000
  [ "$(compute)" = "ok" ]
}

@test "down: a ts or since in the FUTURE by > 5 s (clock jump / forged file); 5 s of skew is tolerated" {
  healthy_slots
  slot 2 idle -6 5000
  [ "$(compute)" = "down" ]
  slot 2 idle -5 5000
  [ "$(compute)" = "ok" ]
  slot 2 idle 5 -6
  [ "$(compute)" = "down" ]
  slot 2 idle -3600 5000
  [ "$(compute)" = "down" ]
}

@test "down: unparseable state file" {
  healthy_slots
  echo 'garbage' > "$W/state/light-1.json"
  [ "$(compute)" = "down" ]
}

@test "down: a slot seen without an online runner on two heartbeats > STUCK_SECS apart" {
  healthy_slots
  printf '1\tghr-light-1\tonline\tfalse\n3\tghr-light-3\tonline\tfalse\n' > "$RUNNERS"   # slot 2 absent
  slot 2 registered 5 20000
  [ "$(compute "$NOW")" = "ok" ]                   # first sighting only starts the clock
  [ "$(compute "$((NOW + 45))")" = "ok" ]          # boundary: STUCK_SECS default 45 (strictly greater)
  [ "$(compute "$((NOW + 60))")" = "down" ]        # next heartbeat: still absent -> stuck
}

@test "ok: a just-finished job (old since, runner already deleted) is not stuck; runner back online resets" {
  # Regression (live, 2026-10-16): during a job the slot stays `registered` with the mint time as
  # `since`; GitHub deletes the single-use runner a few seconds before the loop writes its next state.
  healthy_slots
  printf '1\tghr-light-1\tonline\tfalse\n3\tghr-light-3\tonline\tfalse\n' > "$RUNNERS"
  slot 2 registered 5 400                          # registered 400 s ago, runner gone right now
  [ "$(compute "$NOW")" = "ok" ]
  all_online                                       # the loop re-minted: runner online again
  [ "$(compute "$((NOW + 60))")" = "ok" ]
  [ ! -e "$HB/notonline_light-2" ]                 # clock reset
  printf '1\tghr-light-1\tonline\tfalse\n3\tghr-light-3\tonline\tfalse\n' > "$RUNNERS"
  [ "$(compute "$((NOW + 100))")" = "ok" ]         # a later blip starts a NEW clock, not the old one
}

@test "ok: a long-registered slot whose runner IS online is just idle, not stuck" {
  healthy_slots
  slot 2 registered 5 20000
  [ "$(compute)" = "ok" ]
}

@test "down: a slot in backoff with no online runner on two heartbeats (mint/launch keep failing)" {
  healthy_slots
  printf '1\tghr-light-1\tonline\tfalse\n3\tghr-light-3\tonline\tfalse\n' > "$RUNNERS"
  slot 2 backoff 5 400
  [ "$(compute "$NOW")" = "ok" ]
  [ "$(compute "$((NOW + 60))")" = "down" ]
}

@test "saturated: all slots busy for >= 60 s; ok until then; resets when one frees up" {
  healthy_slots
  all_busy
  [ "$(compute "$NOW")" = "ok" ]                 # first sighting
  [ "$(compute "$((NOW + 59))")" = "ok" ]
  [ "$(compute "$((NOW + 60))")" = "saturated" ]
  all_online                                       # one runner frees up
  [ "$(compute "$((NOW + 61))")" = "ok" ]
  [ ! -e "$HB/all_busy_since_light" ]
  all_busy
  [ "$(compute "$((NOW + 62))")" = "ok" ]          # the clock restarted
}

@test "down beats saturated" {
  healthy_slots
  all_busy
  compute "$NOW" > /dev/null
  slot 1 idle 500 5000
  [ "$(compute "$((NOW + 600))")" = "down" ]
}

@test "tripwire: foreign / malformed names flagged, fleet names pass" {
  SUPABASE_SLOTS=12
  out=$(printf '%s\n' \
    "$(printf '1\tghr-light-1\toffline\tfalse\tghr-light')" \
    "$(printf '2\tghr-supabase-12\tonline\tfalse\tghr-supabase')" \
    "$(printf '3\tgh-runner-light-host-1\tonline\tfalse')" \
    "$(printf '4\tghr-light-1x\tonline\tfalse')" \
    "$(printf '5\tghr-android-1\tonline\tfalse')" \
    "$(printf '6\tmallory\tonline\tfalse')" | tripwire_names)
  [ "$out" = "$(printf 'gh-runner-light-host-1\nghr-light-1x\nghr-android-1\nmallory')" ]
}

@test "tripwire: slot number beyond the configured count / zero, and wrong custom labels" {
  out=$(printf '%s\n' \
    "$(printf '1\tghr-light-3\tonline\tfalse\tghr-light')" \
    "$(printf '2\tghr-light-4\tonline\tfalse\tghr-light')" \
    "$(printf '3\tghr-light-0\tonline\tfalse\tghr-light')" \
    "$(printf '4\tghr-light-99999999999\tonline\tfalse\tghr-light')" \
    "$(printf '5\tghr-light-1\tonline\tfalse\tghr-light,extra')" \
    "$(printf '6\tghr-light-2\tonline\tfalse\t')" \
    "$(printf '7\tghr-supabase-1\tonline\tfalse\tghr-supabase')" | tripwire_names)
  [ "$out" = "$(printf 'ghr-light-4\nghr-light-0\nghr-light-99999999999\nghr-light-1\nghr-light-2\nghr-supabase-1')" ]
}

@test "variable write: PATCH on the repo; POST to create when PATCH 404s" {
  route_token
  route PATCH /repos/test-org/repo-a/actions/variables/SELF_HOSTED_STATE 204 ''
  # repo-b has no PATCH route -> 404 -> POST
  route POST /repos/test-org/repo-b/actions/variables 201 '{}'
  write_state_var_setup() { gh_app_init 333 444 "$W/key.pem"; }
  write_state_var_setup
  write_state_var test-org/repo-a "ok@123"
  write_state_var test-org/repo-b "ok@123"
  grep -q 'CALL PATCH /repos/test-org/repo-a/actions/variables/SELF_HOSTED_STATE' "$CURL_LOG"
  grep -q 'BODY {"name":"SELF_HOSTED_STATE","value":"ok@123"}' "$CURL_LOG"
  grep -q 'CALL PATCH /repos/test-org/repo-b/actions/variables/SELF_HOSTED_STATE' "$CURL_LOG"
  grep -q 'CALL POST /repos/test-org/repo-b/actions/variables' "$CURL_LOG"
  [ "$(grep -c 'CALL POST /repos/test-org/repo-a' "$CURL_LOG")" -eq 0 ]
}

@test "end to end: publishes '<state>@<epoch>' to every consumer repo and latches the tripwire" {
  route_token
  now=$(date -u +%s)
  # fixtures stamped "now" so the real clock inside heartbeat.sh sees them fresh
  for n in 1 2 3; do
    printf '{"slot":"light-%s","class":"light","n":%s,"state":"registered","ts":%s,"since":%s,"last_exit":0}\n' "$n" "$n" "$now" "$now" > "$W/state/light-$n.json"
  done
  route GET /orgs/test-org/actions/runners 200 '{"runners":[{"id":1,"name":"ghr-light-1","status":"online","busy":false},{"id":2,"name":"ghr-light-2","status":"online","busy":false},{"id":3,"name":"ghr-light-3","status":"online","busy":false},{"id":99,"name":"intruder","status":"online","busy":false}]}'
  route PATCH /repos/test-org/repo-a/actions/variables/SELF_HOSTED_STATE 204 ''
  route PATCH /repos/test-org/repo-b/actions/variables/SELF_HOSTED_STATE 204 ''
  run bash "$SLOTS_DIR/heartbeat.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TRIPWIRE"*"intruder"* ]]
  # the foreign runner latches the tripwire in this very run, so the published state is down
  grep -Eq 'BODY \{"name":"SELF_HOSTED_STATE","value":"down@[0-9]+"\}' "$CURL_LOG"
  [ "$(grep -c 'CALL PATCH' "$CURL_LOG")" -eq 2 ]
  grep -q intruder "$GHR_HB_ROOT/tripwire"
}

@test "end to end: while the tripwire file exists the published state is down, even with healthy slots" {
  route_token
  now=$(date -u +%s)
  for n in 1 2 3; do
    printf '{"slot":"light-%s","class":"light","n":%s,"state":"idle","ts":%s,"since":%s,"last_exit":0}\n' "$n" "$n" "$now" "$now" > "$W/state/light-$n.json"
  done
  route GET /orgs/test-org/actions/runners 200 '{"runners":[{"id":1,"name":"ghr-light-1","status":"online","busy":false,"labels":[{"name":"ghr-light","type":"custom"}]}]}'
  route PATCH /repos/test-org/repo-a/actions/variables/SELF_HOSTED_STATE 204 ''
  route PATCH /repos/test-org/repo-b/actions/variables/SELF_HOSTED_STATE 204 ''
  echo latched > "$GHR_HB_ROOT/tripwire"
  run bash "$SLOTS_DIR/heartbeat.sh"
  [ "$status" -eq 0 ]
  grep -Eq 'BODY \{"name":"SELF_HOSTED_STATE","value":"down@[0-9]+"\}' "$CURL_LOG"
  rm "$GHR_HB_ROOT/tripwire"
  : > "$CURL_LOG"
  run bash "$SLOTS_DIR/heartbeat.sh"
  grep -Eq 'value":"ok@' "$CURL_LOG"
}

@test "end to end: a clean org writes no tripwire file; a runner-list failure publishes nothing" {
  route_token
  now=$(date -u +%s)
  for n in 1 2 3; do
    printf '{"slot":"light-%s","class":"light","n":%s,"state":"idle","ts":%s,"since":%s,"last_exit":0}\n' "$n" "$n" "$now" "$now" > "$W/state/light-$n.json"
  done
  route GET /orgs/test-org/actions/runners 200 '{"runners":[{"id":1,"name":"ghr-light-1","status":"online","busy":false,"labels":[{"name":"ghr-light","type":"custom"}]}]}'
  route PATCH /repos/test-org/repo-a/actions/variables/SELF_HOSTED_STATE 204 ''
  route PATCH /repos/test-org/repo-b/actions/variables/SELF_HOSTED_STATE 204 ''
  run bash "$SLOTS_DIR/heartbeat.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$GHR_HB_ROOT/tripwire" ]
  : > "$CURL_LOG"
  route GET /orgs/test-org/actions/runners 500 '{}'
  run bash "$SLOTS_DIR/heartbeat.sh"
  [ "$status" -ne 0 ]
  refute grep -q 'CALL PATCH' "$CURL_LOG"
}

@test "supabase class: counted in the state (missing slot file -> down; fresh -> ok; stuck -> down)" {
  healthy_slots
  SUPABASE_SLOTS=2
  [ "$(compute)" = "down" ]
  for n in 1 2; do
    printf '{"slot":"supabase-%s","class":"supabase","n":%s,"state":"registered","ts":%s,"since":%s,"last_exit":0}\n' "$n" "$n" "$((NOW - 5))" "$((NOW - 5))" > "$W/state/supabase-$n.json"
  done
  printf '%s\n' "$(printf '1\tghr-light-1\tonline\tfalse\tghr-light')" "$(printf '2\tghr-light-2\tonline\tfalse\tghr-light')" "$(printf '3\tghr-light-3\tonline\tfalse\tghr-light')" "$(printf '4\tghr-supabase-1\tonline\tfalse\tghr-supabase')" "$(printf '5\tghr-supabase-2\tonline\tfalse\tghr-supabase')" > "$RUNNERS"
  [ "$(compute)" = "ok" ]
  printf '{"slot":"supabase-2","class":"supabase","n":2,"state":"registered","ts":%s,"since":%s,"last_exit":0}\n' "$((NOW - 5))" "$((NOW - 500))" > "$W/state/supabase-2.json"
  printf '%s\n' "$(printf '1\tghr-light-1\tonline\tfalse\tghr-light')" "$(printf '2\tghr-light-2\tonline\tfalse\tghr-light')" "$(printf '3\tghr-light-3\tonline\tfalse\tghr-light')" "$(printf '4\tghr-supabase-1\tonline\tfalse\tghr-supabase')" > "$RUNNERS"
  # stuck = absent on two consecutive heartbeats: first sighting is still ok, the next one is down
  [ "$(compute "$NOW")" = "ok" ]
  [ "$(compute "$((NOW + 60))")" = "down" ]
}

@test "supabase tripwire: slot above SUPABASE_SLOTS, wrong labels, or class disabled (count 0)" {
  SUPABASE_SLOTS=2
  out=$(printf '%s\n' \
    "$(printf '1\tghr-supabase-1\tonline\tfalse\tghr-supabase')" \
    "$(printf '2\tghr-supabase-2\tonline\tfalse\tghr-supabase')" \
    "$(printf '3\tghr-supabase-3\tonline\tfalse\tghr-supabase')" \
    "$(printf '4\tghr-supabase-1\tonline\tfalse\tghr-light')" | tripwire_names)
  [ "$out" = "$(printf 'ghr-supabase-3\nghr-supabase-1')" ]
  SUPABASE_SLOTS=0
  out=$(printf '%s\n' "$(printf '1\tghr-supabase-1\tonline\tfalse\tghr-supabase')" | tripwire_names)
  [ "$out" = "ghr-supabase-1" ]
  SUPABASE_SLOTS=2
  SUPABASE_LABELS="custom-supa"
  out=$(printf '%s\n' "$(printf '1\tghr-supabase-1\tonline\tfalse\tcustom-supa')" | tripwire_names)
  [ -z "$out" ]
}

# ── per-class saturation ──────────────────────────────────────────────────────

# two_classes — light 3 slots + supabase 2 slots, all fresh. $1/$2 = busy flag per class.
two_classes() {
  SUPABASE_SLOTS=2
  healthy_slots
  for n in 1 2; do
    printf '{"slot":"supabase-%s","class":"supabase","n":%s,"state":"registered","ts":%s,"since":%s,"last_exit":0}\n' "$n" "$n" "$((NOW - 5))" "$((NOW - 5))" > "$W/state/supabase-$n.json"
  done
  {
    for n in 1 2 3; do printf '%s\tghr-light-%s\tonline\t%s\tghr-light\n' "$n" "$n" "$1"; done
    for n in 1 2; do printf '%s\tghr-supabase-%s\tonline\t%s\tghr-supabase\n' "$((n + 3))" "$n" "$2"; done
  } > "$RUNNERS"
}

@test "per-class: supabase busy + light free -> ok/sat=supabase only from 60 s on; resets when a slot frees" {
  STALE_SECS=100000   # fixtures are not re-stamped as the fake clock advances
  two_classes false true
  [ "$(compute "$NOW")" = "ok" ]                       # clock starts
  [ "$(compute "$((NOW + 59))")" = "ok" ]
  [ "$(compute "$((NOW + 60))")" = "ok/sat=supabase" ]
  [ -e "$HB/all_busy_since_supabase" ] && [ ! -e "$HB/all_busy_since_light" ]
  # one supabase slot frees up: reset
  printf '%s\n' "$(printf '1\tghr-light-1\tonline\tfalse\tghr-light')" "$(printf '2\tghr-light-2\tonline\tfalse\tghr-light')" "$(printf '3\tghr-light-3\tonline\tfalse\tghr-light')" "$(printf '4\tghr-supabase-1\tonline\ttrue\tghr-supabase')" "$(printf '5\tghr-supabase-2\tonline\tfalse\tghr-supabase')" > "$RUNNERS"
  [ "$(compute "$((NOW + 61))")" = "ok" ]
  [ ! -e "$HB/all_busy_since_supabase" ]
  two_classes false true
  [ "$(compute "$((NOW + 62))")" = "ok" ]              # the clock restarted
  [ "$(compute "$((NOW + 122))")" = "ok/sat=supabase" ]
}

@test "per-class: light busy + supabase free -> ok/sat=light" {
  two_classes true false
  [ "$(compute "$NOW")" = "ok" ]
  [ "$(compute "$((NOW + 60))")" = "ok/sat=light" ]
}

@test "per-class: both classes saturated -> plain 'saturated' (back-compat)" {
  two_classes true true
  [ "$(compute "$NOW")" = "ok" ]
  [ "$(compute "$((NOW + 60))")" = "saturated" ]
}

@test "per-class: classes are timed independently" {
  two_classes false true
  [ "$(compute "$NOW")" = "ok" ]
  two_classes true true                                 # light becomes busy 30 s later
  [ "$(compute "$((NOW + 30))")" = "ok" ]
  [ "$(compute "$((NOW + 60))")" = "ok/sat=supabase" ]  # supabase 60 s, light only 30 s
  [ "$(compute "$((NOW + 90))")" = "saturated" ]
}

@test "per-class: a partially busy class is never saturated; down beats per-class saturation" {
  STALE_SECS=100000
  two_classes false true
  printf '%s\n' "$(printf '1\tghr-light-1\tonline\tfalse\tghr-light')" "$(printf '2\tghr-light-2\tonline\tfalse\tghr-light')" "$(printf '3\tghr-light-3\tonline\tfalse\tghr-light')" "$(printf '4\tghr-supabase-1\tonline\ttrue\tghr-supabase')" "$(printf '5\tghr-supabase-2\tonline\tfalse\tghr-supabase')" > "$RUNNERS"
  [ "$(compute "$NOW")" = "ok" ]
  [ "$(compute "$((NOW + 300))")" = "ok" ]
  two_classes false true
  compute "$NOW" > /dev/null
  STALE_SECS=120
  slot 1 idle 500 5000                                  # a light slot stops writing
  [ "$(compute "$((NOW + 600))")" = "down" ]
}

@test "published format: down@ts, ok@ts, ok@ts/sat=classes, saturated@ts (exact), tripwire forces down@" {
  route_token
  now=$(date -u +%s)
  SUPABASE_SLOTS=2
  printf 'SUPABASE_SLOTS=2\n' >> "$W/slots.env"
  for c in light:3 supabase:2; do
    cls=${c%%:*}; cnt=${c##*:}
    for n in $(seq 1 "$cnt"); do
      printf '{"slot":"%s-%s","class":"%s","n":%s,"state":"registered","ts":%s,"since":%s,"last_exit":0}\n' "$cls" "$n" "$cls" "$n" "$now" "$now" > "$W/state/$cls-$n.json"
    done
  done
  runners_json() { # $1 light busy, $2 supabase busy
    python3 - "$1" "$2" <<'PY'
import json, sys
lb, sb = sys.argv[1] == "true", sys.argv[2] == "true"
r = [{"id": n, "name": "ghr-light-%d" % n, "status": "online", "busy": lb, "labels": [{"name": "ghr-light", "type": "custom"}]} for n in (1, 2, 3)]
r += [{"id": 10 + n, "name": "ghr-supabase-%d" % n, "status": "online", "busy": sb, "labels": [{"name": "ghr-supabase", "type": "custom"}]} for n in (1, 2)]
print(json.dumps({"runners": r}))
PY
  }
  for repo in repo-a repo-b; do route PATCH /repos/test-org/$repo/actions/variables/SELF_HOSTED_STATE 204 ''; done
  last_value() { grep '^BODY ' "$CURL_LOG" | tail -1 | sed -n 's/.*"value":"\([^"]*\)".*/\1/p'; }
  # 1) nothing saturated
  route GET /orgs/test-org/actions/runners 200 "$(runners_json false false)"
  run bash "$SLOTS_DIR/heartbeat.sh"
  [[ "$(last_value)" =~ ^ok@[0-9]+$ ]]
  # 2) supabase saturated: pre-seed the class clock 61 s in the past so this run crosses the threshold
  route GET /orgs/test-org/actions/runners 200 "$(runners_json false true)"
  mkdir -p "$GHR_HB_ROOT/hb"; echo "$((now - 61))" > "$GHR_HB_ROOT/hb/all_busy_since_supabase"
  : > "$CURL_LOG"
  run bash "$SLOTS_DIR/heartbeat.sh"
  [[ "$(last_value)" =~ ^ok@[0-9]+/sat=supabase$ ]]
  # 3) both
  route GET /orgs/test-org/actions/runners 200 "$(runners_json true true)"
  echo "$((now - 61))" > "$GHR_HB_ROOT/hb/all_busy_since_light"
  : > "$CURL_LOG"
  run bash "$SLOTS_DIR/heartbeat.sh"
  [[ "$(last_value)" =~ ^saturated@[0-9]+$ ]]
  # 4) tripwire latch beats everything
  echo latched > "$GHR_HB_ROOT/tripwire"
  : > "$CURL_LOG"
  run bash "$SLOTS_DIR/heartbeat.sh"
  [[ "$(last_value)" =~ ^down@[0-9]+$ ]]
  # both repos get the identical value
  [ "$(grep -c '"value":"down@' "$CURL_LOG")" -eq 2 ]
}
