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

@test "tripwire: a slot above the count is retiring only while its own loop keeps its state file fresh" {
  # LIGHT_SLOTS=3: light-4 was just removed by a scale-down; its loop wrote 10 s ago -> not foreign
  slot 4 registered 10 5000
  out=$(printf '1\tghr-light-4\tonline\tfalse\tghr-light\n' | tripwire_names "$NOW")
  [ -z "$out" ]
  # grace runs out once the loop stops writing
  slot 4 idle "$((RETIRE_SECS + 1))" 5000
  out=$(printf '1\tghr-light-4\tonline\tfalse\tghr-light\n' | tripwire_names "$NOW")
  [ "$out" = "ghr-light-4" ]
  # no state file at all (never one of ours), a future ts, or wrong labels -> foreign
  out=$(printf '1\tghr-light-5\tonline\tfalse\tghr-light\n' | tripwire_names "$NOW")
  [ "$out" = "ghr-light-5" ]
  slot 4 registered -60 5000
  out=$(printf '1\tghr-light-4\tonline\tfalse\tghr-light\n' | tripwire_names "$NOW")
  [ "$out" = "ghr-light-4" ]
  slot 4 registered 10 5000
  out=$(printf '1\tghr-light-4\tonline\tfalse\tghr-light,extra\n' | tripwire_names "$NOW")
  [ "$out" = "ghr-light-4" ]
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

# ── remote slots (REMOTE_SLOTS: slots served by another host) ──────────────────

# remote_fixture LOCAL_BUSY REMOTE_ROW — light 3 idle + supabase 1,2 local (fresh) with LOCAL_BUSY
# flag, plus an optional extra TSV row for ghr-supabase-5 (empty = runner absent on GitHub).
remote_fixture() {
  two_classes false "$1"
  if [ -n "$2" ]; then printf '%s\n' "$2" >> "$RUNNERS"; fi
}
remote_row() { printf '9\tghr-supabase-5\t%s\t%s\tghr-supabase' "$1" "$2"; }

@test "remote tripwire: a listed remote runner is accepted; an unlisted ghr-supabase-5 is still flagged" {
  SUPABASE_SLOTS=2
  row="$(printf '9\tghr-supabase-5\tonline\tfalse\tghr-supabase')"
  out=$(printf '%s\n' "$row" | tripwire_names)
  [ "$out" = "ghr-supabase-5" ]
  REMOTE_SLOTS="supabase-5"
  out=$(printf '%s\n' "$row" | tripwire_names)
  [ -z "$out" ]
  # comma lists work, other numbers stay flagged
  REMOTE_SLOTS="supabase-6,supabase-5"
  out=$(printf '%s\n' "$row" "$(printf '8\tghr-supabase-7\tonline\tfalse\tghr-supabase')" | tripwire_names)
  [ "$out" = "ghr-supabase-7" ]
}

@test "remote tripwire: the label check still applies to a listed remote runner" {
  SUPABASE_SLOTS=2
  REMOTE_SLOTS="supabase-5"
  out=$(printf '%s\n' "$(printf '9\tghr-supabase-5\tonline\tfalse\tghr-light')" | tripwire_names)
  [ "$out" = "ghr-supabase-5" ]
}

@test "remote tripwire: a remote entry of the other class does not whitelist this class; invalid entries are ignored" {
  SUPABASE_SLOTS=2
  REMOTE_SLOTS="light-3 supabase-x supabase-0 ghr-supabase-5 supabase-03"
  out=$(printf '%s\n' "$(printf '9\tghr-supabase-5\tonline\tfalse\tghr-supabase')" | tripwire_names)
  [ "$out" = "ghr-supabase-5" ]
}

@test "remote tripwire: an entry colliding with a local slot number (n <= local count) is ignored with a log line" {
  SUPABASE_SLOTS=3
  REMOTE_SLOTS="supabase-3 supabase-5"
  run remote_nums supabase 3
  [ "$status" -eq 0 ]
  [[ "$output" == *"supabase-3 collides with a local slot"* ]]
  [ "$(remote_nums supabase 3 2> /dev/null)" = "5" ]
  # the Mac growing to 4 local slots: 4 collides too, 5 still passes (the remote number may exceed launch.sh's SUPA_MAX)
  SUPABASE_SLOTS=4
  REMOTE_SLOTS="supabase-4 supabase-5"
  [ "$(remote_nums supabase 4 2> /dev/null)" = "5" ]
  out=$(printf '%s\n' "$(printf '9\tghr-supabase-4\tonline\tfalse\tghr-supabase')" | tripwire_names)
  [ -z "$out" ]    # local slot 4: valid by the local count
  SUPABASE_SLOTS=3
  REMOTE_SLOTS="supabase-5"
  out=$(printf '%s\n' "$(printf '9\tghr-supabase-4\tonline\tfalse\tghr-supabase')" | tripwire_names)
  [ "$out" = "ghr-supabase-4" ]   # beyond 3 local and listed nowhere
  REMOTE_SLOTS="supabase-5 supabase-5 bogus"
  [ "$(remote_nums supabase 3 2> /dev/null)" = "5" ]
  run remote_nums supabase 3
  [[ "$output" == *"invalid entry 'bogus'"* ]]
}

@test "remote saturation: 2 local busy + remote idle -> NOT saturated" {
  STALE_SECS=100000
  REMOTE_SLOTS="supabase-5"
  remote_fixture true "$(remote_row online false)"
  [ "$(compute "$NOW")" = "ok" ]
  [ "$(compute "$((NOW + 600))")" = "ok" ]
  [ ! -e "$HB/all_busy_since_supabase" ]
}

@test "remote saturation: 2 local busy + remote busy -> ok/sat=supabase only after SATURATED_SECS" {
  STALE_SECS=100000
  REMOTE_SLOTS="supabase-5"
  remote_fixture true "$(remote_row online true)"
  [ "$(compute "$NOW")" = "ok" ]
  [ "$(compute "$((NOW + 59))")" = "ok" ]
  [ "$(compute "$((NOW + 60))")" = "ok/sat=supabase" ]
}

@test "remote saturation: an offline or absent remote runner counts as busy (no capacity)" {
  STALE_SECS=100000
  REMOTE_SLOTS="supabase-5"
  remote_fixture true "$(remote_row offline false)"
  [ "$(compute "$NOW")" = "ok" ]
  [ "$(compute "$((NOW + 60))")" = "ok/sat=supabase" ]
  rm -f "$HB"/all_busy_since_supabase
  remote_fixture true ""
  [ "$(compute "$NOW")" = "ok" ]
  [ "$(compute "$((NOW + 60))")" = "ok/sat=supabase" ]
}

@test "remote saturation: without REMOTE_SLOTS the same fixture saturates on the two local slots alone" {
  STALE_SECS=100000
  remote_fixture true "$(remote_row online false)"
  [ "$(compute "$NOW")" = "ok" ]
  [ "$(compute "$((NOW + 60))")" = "ok/sat=supabase" ]
}

@test "remote slots never cause down: no state file, offline, stale-looking, or not reachable at all" {
  STALE_SECS=100000
  REMOTE_SLOTS="supabase-5"
  remote_fixture false ""
  [ ! -e "$W/state/supabase-5.json" ]
  [ "$(compute "$NOW")" = "ok" ]
  [ "$(compute "$((NOW + 600))")" = "ok" ]
  remote_fixture false "$(remote_row offline false)"
  [ "$(compute "$((NOW + 1200))")" = "ok" ]
}

@test "remote slots: a remote-only class does not rescue a pool with no local slots (still down)" {
  LIGHT_SLOTS=0
  SUPABASE_SLOTS=0
  REMOTE_SLOTS="supabase-5"
  : > "$RUNNERS"
  [ "$(compute)" = "down" ]
}

# ── ios class ──────────────────────────────────────────────────────────────────────────────────────

# ios_slot STATE AGE SINCE_AGE — fixture slot file of the ios slot (ts = NOW-AGE, since = NOW-SINCE_AGE).
ios_slot() {
  printf '{"slot":"ios-1","class":"ios","n":1,"state":"%s","ts":%s,"since":%s,"last_exit":0}\n' \
    "$1" "$((NOW - $2))" "$((NOW - $3))" > "$W/state/ios-1.json"
}
# sup_slot N STATE — fixture supabase slot file.
sup_slot() {
  printf '{"slot":"supabase-%s","class":"supabase","n":%s,"state":"%s","ts":%s,"since":%s,"last_exit":0}\n' \
    "$1" "$1" "$2" "$((NOW - 5))" "$((NOW - 5))" > "$W/state/supabase-$1.json"
}

# at_ios OFFSET IOS_STATE — compute the state OFFSET seconds after NOW with fresh light + ios slot files
# (the ios runner list is whatever $RUNNERS holds). Runs in a subshell: NOW does not leak.
at_ios() (
  NOW=$((NOW + $1))
  healthy_slots
  ios_slot "$2" 5 20000
  compute "$NOW"
)

@test "ios: dormant and waiting-capacity are healthy -- an ios runner absent for ages is NOT stuck" {
  IOS_SLOTS=1
  for off in 0 60 1000; do [ "$(at_ios "$off" dormant)" = "ok" ]; done
  # waiting-capacity is busy for saturation (ios jobs spill to hosted) but never `down`
  [ "$(at_ios 1100 waiting-capacity)" = "ok" ]
  [ "$(at_ios 1160 waiting-capacity)" = "ok/sat=ios" ]
  [ "$(at_ios 2500 waiting-capacity)" = "ok/sat=ios" ]
}

@test "ios: a yielded supabase slot with no runner is healthy at any time" {
  healthy_slots
  SUPABASE_SLOTS=2
  sup_slot 1 registered; sup_slot 2 yielded
  printf '%s\n' "$(printf '1\tghr-light-1\tonline\tfalse\tghr-light')" "$(printf '2\tghr-light-2\tonline\tfalse\tghr-light')" "$(printf '3\tghr-light-3\tonline\tfalse\tghr-light')" "$(printf '4\tghr-supabase-1\tonline\tfalse\tghr-supabase')" > "$RUNNERS"
  [ "$(compute "$NOW")" = "ok" ]
  # supabase-2 stays without a runner: with `registered` this would be stuck after 45 s
  sup_slot 2 registered
  [ "$(compute "$NOW")" = "ok" ]
  [ "$(compute "$((NOW + 60))")" = "down" ]
  sup_slot 2 yielded
  [ "$(compute "$((NOW + 61))")" = "ok" ]
}

@test "ios: a missing or stale ios slot file is down once IOS_SLOTS=1 (like any configured slot)" {
  healthy_slots
  IOS_SLOTS=1
  [ "$(compute)" = "down" ]
  ios_slot dormant 121 5000
  [ "$(compute)" = "down" ]
  ios_slot dormant 5 5000
  [ "$(compute)" = "ok" ]
  IOS_SLOTS=0
  rm "$W/state/ios-1.json"
  [ "$(compute)" = "ok" ]
}

@test "ios: registered without an online runner is stuck only after IOS_STUCK_SECS (macOS boot), not the 45 s of other classes" {
  IOS_SLOTS=1
  [ "$(at_ios 0 registered)" = "ok" ]              # first sighting
  [ "$(at_ios 60 registered)" = "ok" ]             # a light slot would be down here
  [ "$(at_ios 599 registered)" = "ok" ]            # default 600 > boot (300) + two 60 s marks
  [ "$(at_ios 661 registered)" = "down" ]
  # online again resets the clock
  printf '5\tghr-ios-1\tonline\tfalse\tghr-ios\n' >> "$RUNNERS"
  [ "$(at_ios 700 registered)" = "ok" ]
  [ ! -e "$HB/notonline_ios-1" ]
}

@test "ios/supabase: 'releasing' (runner deleted, launch still tearing its VM down) is healthy for a while, busy for saturation, and a wedge after IOS_STUCK_SECS" {
  IOS_SLOTS=1
  [ "$(at_ios 0 releasing)" = "ok" ]
  [ "$(at_ios 300 releasing)" = "ok/sat=ios" ]     # busy (saturation) but healthy; a supabase `registered` slot would be down after 45 s
  [ "$(at_ios 661 releasing)" = "down" ]
}

@test "ios: IOS_STUCK_SECS is configurable" {
  IOS_SLOTS=1 IOS_STUCK_SECS=100
  [ "$(at_ios 0 registered)" = "ok" ]
  [ "$(at_ios 101 registered)" = "down" ]
}

@test "saturation: a yielded supabase slot counts as busy (the class saturates after 60 s)" {
  healthy_slots
  SUPABASE_SLOTS=2
  sup_slot 1 registered; sup_slot 2 yielded
  printf '%s\n' "$(printf '1\tghr-light-1\tonline\tfalse\tghr-light')" "$(printf '2\tghr-light-2\tonline\tfalse\tghr-light')" "$(printf '3\tghr-light-3\tonline\tfalse\tghr-light')" "$(printf '4\tghr-supabase-1\tonline\ttrue\tghr-supabase')" > "$RUNNERS"
  [ "$(compute "$NOW")" = "ok" ]
  [ "$(compute "$((NOW + 60))")" = "ok/sat=supabase" ]
  # supabase-1 idle: only one of two is unavailable -> not saturated
  printf '%s\n' "$(printf '1\tghr-light-1\tonline\tfalse\tghr-light')" "$(printf '2\tghr-light-2\tonline\tfalse\tghr-light')" "$(printf '3\tghr-light-3\tonline\tfalse\tghr-light')" "$(printf '4\tghr-supabase-1\tonline\tfalse\tghr-supabase')" > "$RUNNERS"
  [ "$(compute "$((NOW + 61))")" = "ok" ]
}

# sat_at OFFSET IOS_STATE — as at_ios, plus a supabase slot and the runner list in $RUNNERS.
sat_at() (
  NOW=$((NOW + $1))
  healthy_slots
  sup_slot 1 registered
  ios_slot "$2" 5 5
  compute "$NOW"
)

@test "saturation: ios is busy while waiting-capacity or with a busy runner; the sat list is sorted (ios before light before supabase)" {
  IOS_SLOTS=1 SUPABASE_SLOTS=1
  light_busy='1\tghr-light-1\tonline\ttrue\tghr-light\n2\tghr-light-2\tonline\ttrue\tghr-light\n3\tghr-light-3\tonline\ttrue\tghr-light\n'
  printf "${light_busy}"'4\tghr-supabase-1\tonline\tfalse\tghr-supabase\n' > "$RUNNERS"
  [ "$(sat_at 0 waiting-capacity)" = "ok" ]
  [ "$(sat_at 60 waiting-capacity)" = "ok/sat=ios,light" ]
  # a busy ios runner counts the same, a busy supabase runner completes the set
  printf "${light_busy}"'4\tghr-supabase-1\tonline\ttrue\tghr-supabase\n5\tghr-ios-1\tonline\ttrue\tghr-ios\n' > "$RUNNERS"
  [ "$(sat_at 61 registered)" = "ok/sat=ios,light" ]   # the supabase clock starts now
  [ "$(sat_at 125 registered)" = "saturated" ]
  # a dormant ios slot (no runner) is never busy
  printf "${light_busy}"'4\tghr-supabase-1\tonline\ttrue\tghr-supabase\n' > "$RUNNERS"
  [ "$(sat_at 126 dormant)" = "ok/sat=light,supabase" ]
}

@test "tripwire: ghr-ios-1 is accepted only with IOS_SLOTS=1 and the ios label set; ghr-ios-2 never" {
  out=$(printf '%s\n' "$(printf '1\tghr-ios-1\tonline\tfalse\tghr-ios')" | tripwire_names "$NOW")
  [ "$out" = "ghr-ios-1" ]                         # IOS_SLOTS=0 (default): foreign
  IOS_SLOTS=1
  out=$(printf '%s\n' "$(printf '1\tghr-ios-1\tonline\tfalse\tghr-ios')" | tripwire_names "$NOW")
  [ -z "$out" ]
  out=$(printf '%s\n' \
    "$(printf '1\tghr-ios-2\tonline\tfalse\tghr-ios')" \
    "$(printf '2\tghr-ios-1\tonline\tfalse\tghr-ios,extra')" \
    "$(printf '3\tghr-ios-1\tonline\tfalse\tghr-light')" | tripwire_names "$NOW")
  [ "$out" = "$(printf 'ghr-ios-2\nghr-ios-1\nghr-ios-1')" ]
  IOS_SLOTS=5                                      # capped at 1
  out=$(printf '%s\n' "$(printf '1\tghr-ios-2\tonline\tfalse\tghr-ios')" | tripwire_names "$NOW")
  [ "$out" = "ghr-ios-2" ]
  IOS_SLOTS=1 IOS_LABELS="ghr-ios custom-ios"
  out=$(printf '%s\n' "$(printf '1\tghr-ios-1\tonline\tfalse\tcustom-ios,ghr-ios')" | tripwire_names "$NOW")
  [ -z "$out" ]
}

@test "tripwire: remote ios slots do not exist (REMOTE_SLOTS entries for ios are ignored)" {
  IOS_SLOTS=1 REMOTE_SLOTS="ios-2"
  out=$(printf '%s\n' "$(printf '1\tghr-ios-2\tonline\tfalse\tghr-ios')" | tripwire_names "$NOW")
  [ "$out" = "ghr-ios-2" ]
}

# demand probe -------------------------------------------------------------------------------------

probe_setup() {
  route_token
  gh_app_init 333 444 "$W/key.pem"
  export GHR_DEMAND_DIR="$W/demand"
  GHR_DEMAND_DIR="$W/demand"
  mkdir -p "$GHR_DEMAND_DIR"
  IOS_SLOTS=1 IOS_DEMAND_REPOS="test-org/repo-a" IOS_LABELS="ghr-ios"
  route GET /repos/test-org/repo-a/actions/runs 200 '{"workflow_runs":[{"id":101},{"id":102}]}'
}
queued_job() { printf '{"id":%s,"status":"%s","labels":%s}' "$1" "$2" "$3"; }

@test "demand probe: a queued ghr-ios job writes '<epoch> <count>'; both run listings are scanned; a run seen twice counts once" {
  probe_setup
  route GET /repos/test-org/repo-a/actions/runs/101/jobs 200 "{\"jobs\":[$(queued_job 1 completed '["ghr-light"]'),$(queued_job 2 queued '["ghr-ios"]')]}"
  route GET /repos/test-org/repo-a/actions/runs/102/jobs 200 "{\"jobs\":[$(queued_job 3 queued '["GHR-IOS"]')]}"
  probe_ios_demand 1234567
  [ "$(cat "$GHR_DEMAND_DIR/ios")" = "1234567 2" ]
  [ "$(grep -c 'CALL GET /repos/test-org/repo-a/actions/runs$' "$CURL_LOG")" -eq 2 ]
  grep -q 'status=queued' "$CURL_ARGV_LOG"
  grep -q 'status=in_progress' "$CURL_ARGV_LOG"
  [ "$(grep -c 'CALL GET /repos/test-org/repo-a/actions/runs/101/jobs' "$CURL_LOG")" -eq 1 ]
  grep -q 'filter=latest' "$CURL_ARGV_LOG"
  # world-readable (the controller account reads it), no leftover tmp
  [ "$(ls -A "$GHR_DEMAND_DIR")" = "ios" ]
  [ "$(stat -f %Lp "$GHR_DEMAND_DIR/ios" 2> /dev/null || stat -c %a "$GHR_DEMAND_DIR/ios")" = "644" ]
}

@test "demand probe: only a QUEUED job whose labels include all of IOS_LABELS and nothing else (bar self-hosted) counts" {
  probe_setup
  route GET /repos/test-org/repo-a/actions/runs/101/jobs 200 "{\"jobs\":[$(queued_job 1 in_progress '["ghr-ios"]'),$(queued_job 2 queued '["ghr-ios","extra"]'),$(queued_job 3 queued '["ghr-light"]'),$(queued_job 4 queued '[]'),$(queued_job 5 waiting '["ghr-ios"]')]}"
  route GET /repos/test-org/repo-a/actions/runs/102/jobs 200 '{"jobs":[]}'
  probe_ios_demand 1234567
  [ ! -e "$GHR_DEMAND_DIR/ios" ]
}

@test "demand probe: [self-hosted, ghr-ios] and mixed case count; the run lists are limited to workflow_dispatch" {
  probe_setup
  route GET /repos/test-org/repo-a/actions/runs/101/jobs 200 "{\"jobs\":[$(queued_job 1 queued '["self-hosted","ghr-ios"]'),$(queued_job 2 queued '["GHR-IOS"]'),$(queued_job 3 queued '["self-hosted","macOS","ghr-ios"]')]}"
  route GET /repos/test-org/repo-a/actions/runs/102/jobs 200 '{"jobs":[]}'
  probe_ios_demand 55
  [ "$(cat "$GHR_DEMAND_DIR/ios")" = "55 2" ]
  [ "$(grep -c 'event=workflow_dispatch' "$CURL_ARGV_LOG")" -eq 2 ]
}

@test "demand probe: it is time-boxed (PROBE_BUDGET_SECS) -- over budget counts as a failure and leaves the file alone" {
  probe_setup
  echo "1111 3" > "$GHR_DEMAND_DIR/ios"
  PROBE_BUDGET_SECS=0 run probe_ios_demand 9
  [[ "$output" == *"WARN ios demand probe failed"* ]]
  [ "$(cat "$GHR_DEMAND_DIR/ios")" = "1111 3" ]
  [ ! -s "$CURL_LOG" ]
}

@test "demand probe: a missing or unwritable demand dir is an ERROR (the slot would never wake)" {
  probe_setup
  rm -rf "$GHR_DEMAND_DIR"
  run probe_ios_demand 9
  [[ "$output" == *"ERROR ios demand dir"* ]]
}

@test "demand probe: no demand removes an existing file; a successful empty answer is authoritative" {
  probe_setup
  echo "1 1" > "$GHR_DEMAND_DIR/ios"
  route GET /repos/test-org/repo-a/actions/runs 200 '{"workflow_runs":[]}'
  probe_ios_demand 1234567
  [ ! -e "$GHR_DEMAND_DIR/ios" ]
}

@test "demand probe: an API failure leaves the file untouched and only warns (no removal, no rewrite)" {
  probe_setup
  echo "1111 3" > "$GHR_DEMAND_DIR/ios"
  route GET /repos/test-org/repo-a/actions/runs 500 '{}'
  run probe_ios_demand 1234567
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN ios demand probe failed for test-org/repo-a"* ]]
  [ "$(cat "$GHR_DEMAND_DIR/ios")" = "1111 3" ]
  # same when the runs list works but a jobs call fails
  route GET /repos/test-org/repo-a/actions/runs 200 '{"workflow_runs":[{"id":101}]}'
  route GET /repos/test-org/repo-a/actions/runs/101/jobs 500 '{}'
  run probe_ios_demand 1234567
  [ "$(cat "$GHR_DEMAND_DIR/ios")" = "1111 3" ]
  # and when the body is not JSON
  route GET /repos/test-org/repo-a/actions/runs/101/jobs 200 'not json'
  run probe_ios_demand 1234567
  [ "$(cat "$GHR_DEMAND_DIR/ios")" = "1111 3" ]
}

@test "demand probe: positive evidence from one repo is written even if another repo failed" {
  probe_setup
  IOS_DEMAND_REPOS="test-org/repo-a test-org/repo-b"
  route GET /repos/test-org/repo-a/actions/runs 200 '{"workflow_runs":[{"id":101}]}'
  route GET /repos/test-org/repo-a/actions/runs/101/jobs 200 "{\"jobs\":[$(queued_job 1 queued '["ghr-ios"]')]}"
  route GET /repos/test-org/repo-b/actions/runs 500 '{}'
  probe_ios_demand 77
  [ "$(cat "$GHR_DEMAND_DIR/ios")" = "77 1" ]
}

@test "demand probe: off without IOS_DEMAND_REPOS or with IOS_SLOTS=0 (no API call at all); invalid repo entries are skipped" {
  probe_setup
  echo "1 1" > "$GHR_DEMAND_DIR/ios"
  IOS_DEMAND_REPOS=""
  probe_ios_demand 5
  IOS_DEMAND_REPOS="test-org/repo-a" IOS_SLOTS=0
  probe_ios_demand 5
  [ "$(cat "$GHR_DEMAND_DIR/ios")" = "1 1" ]
  [ ! -s "$CURL_LOG" ]
  IOS_SLOTS=1 IOS_DEMAND_REPOS='bad repo;id'
  run probe_ios_demand 5
  [[ "$output" == *"skipping invalid IOS_DEMAND_REPOS entry"* ]]
}

@test "end to end: the probe runs and writes the demand file, and a failing probe never changes the published state" {
  route_token
  now=$(date -u +%s)
  for n in 1 2 3; do
    printf '{"slot":"light-%s","class":"light","n":%s,"state":"idle","ts":%s,"since":%s,"last_exit":0}\n' "$n" "$n" "$now" "$now" > "$W/state/light-$n.json"
  done
  printf '{"slot":"ios-1","class":"ios","n":1,"state":"dormant","ts":%s,"since":%s,"last_exit":0}\n' "$now" "$now" > "$W/state/ios-1.json"
  printf 'IOS_SLOTS=1\nIOS_DEMAND_REPOS="test-org/repo-a"\n' >> "$W/slots.env"
  export GHR_DEMAND_DIR="$W/demand"; mkdir -p "$GHR_DEMAND_DIR"
  route GET /orgs/test-org/actions/runners 200 '{"runners":[{"id":1,"name":"ghr-light-1","status":"online","busy":false,"labels":[{"name":"ghr-light","type":"custom"}]}]}'
  route PATCH /repos/test-org/repo-a/actions/variables/SELF_HOSTED_STATE 204 ''
  route PATCH /repos/test-org/repo-b/actions/variables/SELF_HOSTED_STATE 204 ''
  route GET /repos/test-org/repo-a/actions/runs 200 '{"workflow_runs":[{"id":101}]}'
  route GET /repos/test-org/repo-a/actions/runs/101/jobs 200 "{\"jobs\":[$(queued_job 1 queued '["ghr-ios"]')]}"
  run bash "$SLOTS_DIR/heartbeat.sh"
  [ "$status" -eq 0 ]
  grep -Eq '^[0-9]+ 1$' "$GHR_DEMAND_DIR/ios"
  grep -Eq 'value":"ok@[0-9]+"' "$CURL_LOG"
  # the probe runs AFTER the state is published
  [ "$(grep -n 'CALL PATCH' "$CURL_LOG" | tail -1 | cut -d: -f1)" -lt "$(grep -n 'CALL GET /repos/test-org/repo-a/actions/runs$' "$CURL_LOG" | head -1 | cut -d: -f1)" ]
  # the probe now fails (token for the actions API denied): state still published, file untouched
  : > "$CURL_LOG"
  before=$(cat "$GHR_DEMAND_DIR/ios")
  route GET /repos/test-org/repo-a/actions/runs 403 '{"message":"Resource not accessible by integration"}'
  run bash "$SLOTS_DIR/heartbeat.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN ios demand probe failed"* ]]
  [ "$(cat "$GHR_DEMAND_DIR/ios")" = "$before" ]
  grep -Eq 'value":"ok@[0-9]+"' "$CURL_LOG"
}
