#!/usr/bin/env bash
# tests/run-selftests.sh — network-free gate: SELFTEST modes (runner-loop.sh) + bash -n (self-update.sh).
#
# Invoked by the pre-commit runner-selftest hook; runnable standalone from any directory.
# Covers light / supabase / ios — the three variants with a SELFTEST harness in runner-loop.sh.
# Also syntax-checks each self-update.sh via bash -n (no SELFTEST mode exists for updaters).
#
# SELFTEST mode sources a minimal config.env, verifies required function definitions are present,
# and exits 0 without registering or running any job. It is safe on both macOS (dev) and
# Linux (ubuntu-latest CI) — mac-only helpers such as pmset live inside function bodies that
# are defined but never called before the SELFTEST exit point in each runner-loop.sh.
#
# Script paths are derived from BASH_SOURCE so the script is cwd-independent.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

_TMPDIR="$(mktemp -d)"
_cleanup() { rm -rf "${_TMPDIR}"; }
trap _cleanup EXIT

# Minimal config.env — sets RUNNER_NAME to skip the uuidgen/hostname default and blanks all
# credentials so no network paths are attempted.  Future selftests that read a specific var
# will find it here rather than hit a set -u error when sourcing /dev/null.
CONFIG_ENV="${_TMPDIR}/config.env"
cat > "${CONFIG_ENV}" <<'ENVEOF'
GH_ORG=selftest-org
RUNNER_NAME=selftest-runner
RUNNER_LABELS=self-hosted,linux,x64,light
RUNNER_TOKEN=
BROKER_URL=
ACCESS_TOKEN=
BROKER_SECRET=
AUTO_UPDATE=0
ENVEOF

_FAILED=0

_run_selftest() {
  local runner="$1"
  local script="${REPO_ROOT}/${runner}/runner-loop.sh"
  printf '  SELFTEST %s/runner-loop.sh ... ' "${runner}"
  if SELFTEST=1 SELFTEST_CONFIG="${CONFIG_ENV}" bash "${script}" 2>/dev/null; then
    echo "pass"
  else
    echo "FAIL"
    _FAILED=1
  fi
}

_syntax_check() {
  local runner="$1"
  local script="${REPO_ROOT}/${runner}/self-update.sh"
  printf '  bash -n  %s/self-update.sh ... ' "${runner}"
  if bash -n "${script}" 2>/dev/null; then
    echo "pass"
  else
    echo "FAIL"
    _FAILED=1
  fi
}

for _runner in light supabase ios; do
  _run_selftest "${_runner}"
  _syntax_check "${_runner}"
done

if [[ "${_FAILED}" != "0" ]]; then
  echo "ERROR: one or more runner selftests/syntax checks failed (see above)." >&2
  exit 1
fi

echo "All runner selftests and syntax checks passed."
