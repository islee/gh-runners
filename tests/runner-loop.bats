#!/usr/bin/env bats
# Behavioral tests for light/runner-loop.sh.
#
# Each test sources a copy of runner-loop.sh placed next to a minimal config.env in a
# temp RUNNER_DIR. External calls are shim-mocked via a FAKE_BIN prepended to PATH:
#   curl  — records all args to $CURL_LOG, returns $CURL_RESPONSE_FILE, exits $CURL_EXIT_FILE.
#   config.sh / run.sh / self-update.sh — per-test scripts created in $RUNNER_DIR.
# python3 is real (used by _json_field / _parse_fleet_update).
#
# NOTE: supabase/ios runner-loops share ancestry with light; bats coverage is a
# deliberate follow-up (not duplicated here).

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && git rev-parse --show-toplevel)"

# ── Setup / teardown ──────────────────────────────────────────────────────────

setup() {
  TMPDIR_WORK="${BATS_TEST_TMPDIR}"
  SCRIPT_COPY_DIR="${TMPDIR_WORK}/runner"
  FAKE_BIN="${TMPDIR_WORK}/bin"
  CURL_LOG="${TMPDIR_WORK}/curl.log"
  CURL_RESPONSE_FILE="${TMPDIR_WORK}/curl_response"
  CURL_EXIT_FILE="${TMPDIR_WORK}/curl_exit"
  RUN_LOG="${TMPDIR_WORK}/run.log"
  CONFIG_LOG="${TMPDIR_WORK}/config.log"

  mkdir -p "${SCRIPT_COPY_DIR}" "${FAKE_BIN}"

  # Place the script next to a minimal config.env so the load-or-die block succeeds.
  cp "${REPO_ROOT}/light/runner-loop.sh" "${SCRIPT_COPY_DIR}/runner-loop.sh"
  printf 'GH_ORG=test-org\nRUNNER_NAME=test-runner-1\nRUNNER_LABELS=self-hosted,linux,x64,light\n' \
    > "${SCRIPT_COPY_DIR}/config.env"

  # Initialize fake curl state files.
  printf '0'  > "${CURL_EXIT_FILE}"
  printf ''   > "${CURL_LOG}"
  printf '{}' > "${CURL_RESPONSE_FILE}"

  # Fake curl: records all argv to CURL_LOG (one arg per line), returns CURL_RESPONSE_FILE,
  # exits with the code stored in CURL_EXIT_FILE. Reads those paths from the environment
  # (they are exported below so subshells see them too).
  cat > "${FAKE_BIN}/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${CURL_LOG}"
_ec=$(cat "${CURL_EXIT_FILE}" 2>/dev/null || printf '0')
if [ "${_ec}" -ne 0 ]; then exit "${_ec}"; fi
cat "${CURL_RESPONSE_FILE}"
FAKE_CURL
  chmod +x "${FAKE_BIN}/curl"

  # Export all paths/vars that fakes and the sourced script reference.
  export PATH="${FAKE_BIN}:${PATH}"
  export CURL_LOG CURL_RESPONSE_FILE CURL_EXIT_FILE RUN_LOG CONFIG_LOG

  # Pre-set all credential globals to empty; overridden per test.
  export BROKER_URL="" BROKER_SECRET="" RUNNER_TOKEN="" ACCESS_TOKEN="" USE_JIT="0"
  # NICE_PRIORITY is inside the sourced-guard so won't be set by sourcing; provide it here.
  export NICE_PRIORITY="0"

  # Source the script. The sourced-guard (BASH_SOURCE[0] != $0) prevents the main loop
  # and SELFTEST block from running; only function definitions execute.
  # shellcheck source=/dev/null
  source "${SCRIPT_COPY_DIR}/runner-loop.sh"

  # Restore permissive error-handling so bats can manage its own assertions.
  # runner-loop.sh enables set -euo pipefail; we reset it after sourcing.
  set +e; set +u; set +o pipefail

  # RUNNER_DIR is set by the sourced script to SCRIPT_COPY_DIR (via SCRIPT_DIR).
  # Re-export so subshells spawned by `run` inherit it.
  export RUNNER_DIR="${SCRIPT_COPY_DIR}"
}

teardown() {
  rm -rf "${TMPDIR_WORK}"
}

# ── 1. Token path — broker success ───────────────────────────────────────────

@test "token path: broker success sets REG_TOKEN" {
  BROKER_URL="http://fake-broker"
  BROKER_SECRET="fakesecret"
  printf '{"token":"REGTOK"}\n' > "${CURL_RESPONSE_FILE}"

  _acquire_reg_token
  [ "${REG_TOKEN}" = "REGTOK" ]
}

# ── 2. Token path — broker failure → retryable ───────────────────────────────

@test "token path: broker failure returns non-zero and leaves REG_TOKEN empty" {
  BROKER_URL="http://fake-broker"
  BROKER_SECRET="fakesecret"
  # Simulate network/auth failure: fake curl exits 1 (--fail semantics).
  printf '1' > "${CURL_EXIT_FILE}"

  _acquire_reg_token
  local _status=$?
  [ "${_status}" -ne 0 ]
  [ -z "${REG_TOKEN}" ]
}

# ── 3. Backoff progression ────────────────────────────────────────────────────

@test "backoff progression: _compute_backoff yields expected capped sequence" {
  # REGISTRATION_RETRY_SECONDS=30 is set by the sourced script.
  # Expected: 30*2^0=30, 30*2^1=60, ..., 30*2^3=240, capped at 300 from attempt 5 on.
  local -a expected=(30 60 120 240 300 300 300)
  local i got
  for i in 1 2 3 4 5 6 7; do
    got=$(_compute_backoff "${i}")
    [ "${got}" -eq "${expected[$(( i - 1 ))]}" ]
  done
}

# ── 4. Credential priority — RUNNER_TOKEN wins ───────────────────────────────

@test "credential priority: RUNNER_TOKEN wins over BROKER_URL without calling curl" {
  RUNNER_TOKEN="STATIC_TOK"
  BROKER_URL="http://fake-broker"
  BROKER_SECRET="fakesecret"
  printf '{"token":"BROKERTOK"}\n' > "${CURL_RESPONSE_FILE}"
  : > "${CURL_LOG}"  # clear

  _acquire_reg_token
  [ "${REG_TOKEN}" = "STATIC_TOK" ]
  # curl must NOT have been called (RUNNER_TOKEN path returns before broker/PAT logic).
  local _lines
  _lines=$(wc -l < "${CURL_LOG}" | tr -d ' ')
  [ "${_lines}" -eq 0 ]
}

# ── 5. Credential priority — ACCESS_TOKEN (PAT) path ────────────────────────

@test "credential priority: ACCESS_TOKEN used when only credential set" {
  ACCESS_TOKEN="pat-token-xyz"
  printf '{"token":"PATTOK"}\n' > "${CURL_RESPONSE_FILE}"
  : > "${CURL_LOG}"

  _acquire_reg_token
  [ "${REG_TOKEN}" = "PATTOK" ]
  # Curl must have been called with the GitHub REST API URL.
  grep -q "api.github.com" "${CURL_LOG}"
}

# ── 6. JIT path — _acquire_jitconfig sets JIT_CONFIG ────────────────────────

@test "JIT path: _acquire_jitconfig sets JIT_CONFIG from broker response" {
  BROKER_URL="http://fake-broker"
  BROKER_SECRET="fakesecret"
  printf '{"encoded_jit_config":"JITBLOB"}\n' > "${CURL_RESPONSE_FILE}"

  _acquire_jitconfig
  [ "${JIT_CONFIG}" = "JITBLOB" ]
}

# ── 7. JIT cycle — run.sh invoked with --jitconfig ───────────────────────────

@test "JIT path: _jit_cycle invokes run.sh with --jitconfig JITBLOB" {
  BROKER_URL="http://fake-broker"
  BROKER_SECRET="fakesecret"
  printf '{"encoded_jit_config":"JITBLOB"}\n' > "${CURL_RESPONSE_FILE}"
  : > "${RUN_LOG}"

  # Fake run.sh: record argv and exit 0 so _jit_cycle treats it as a successful job.
  cat > "${RUNNER_DIR}/run.sh" <<'RUN_SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${RUN_LOG}"
RUN_SH
  chmod +x "${RUNNER_DIR}/run.sh"

  _jit_cycle
  grep -q -- "--jitconfig" "${RUN_LOG}"
  grep -q "JITBLOB"        "${RUN_LOG}"
}

# ── 8. Shutdown — JIT mode skips remove-token ────────────────────────────────

@test "shutdown: JIT mode skips remove-token broker call" {
  USE_JIT=1
  BROKER_URL="http://fake-broker"
  BROKER_SECRET="fakesecret"
  : > "${CURL_LOG}"

  # _shutdown calls exit — use `run` to capture it in a subshell.
  # Subshell inherits PATH (fake curl) and all exported vars.
  run _shutdown
  [ "$status" -eq 0 ]
  # Curl must NOT have been called (JIT exits immediately before any remove-token logic).
  local _lines
  _lines=$(wc -l < "${CURL_LOG}" | tr -d ' ')
  [ "${_lines}" -eq 0 ]
}

# ── 9. Shutdown — non-JIT mode attempts remove-token via broker ───────────────

@test "shutdown: non-JIT mode calls broker remove-token" {
  USE_JIT=0
  BROKER_URL="http://fake-broker"
  BROKER_SECRET="fakesecret"
  printf '{"token":"RMTOK"}\n' > "${CURL_RESPONSE_FILE}"

  # Fake config.sh so the remove --token step doesn't fail on a missing binary.
  cat > "${RUNNER_DIR}/config.sh" <<'CONFIG_SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${CONFIG_LOG}"
CONFIG_SH
  chmod +x "${RUNNER_DIR}/config.sh"
  : > "${CURL_LOG}"

  run _shutdown
  [ "$status" -eq 0 ]
  # Fake curl must have been called with the /remove-token path.
  grep -q "remove-token" "${CURL_LOG}"
}
