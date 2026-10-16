#!/bin/bash
# slots/tests/run-bats.sh — fail-loud wrapper for the slots bats suite.
#
# Dev dependency: bats-core 1.13 (macOS: brew install bats-core; CI: npm install -g bats@1.13.0).
# Invoked by the pre-commit slots-bats hook; runnable from anywhere in the repo.
# Also needs openssl and python3 on PATH (JWT/JSON tests); everything else is shimmed.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v bats > /dev/null 2>&1; then
  echo "ERROR: bats required. Install: 'brew install bats-core' (macOS) or 'npm install -g bats@1.13.0'" >&2
  exit 1
fi

exec bats "$HERE"/*.bats "$@"
