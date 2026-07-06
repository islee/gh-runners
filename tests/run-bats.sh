#!/usr/bin/env bash
# tests/run-bats.sh — fail-loud wrapper for the runner-loop bats suite.
#
# Dev dependency: bats-core 1.13
#   macOS:  brew install bats-core
#   CI/npm: npm install -g bats@1.13.0
#
# Invoked by pre-commit (entry: bash tests/run-bats.sh from repo root) and CI.
# Also safe to run directly from anywhere in the repo tree.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && git rev-parse --show-toplevel)"

if ! command -v bats > /dev/null 2>&1; then
  echo "ERROR: bats required. Install: 'brew install bats-core' (macOS) or 'npm install -g bats@1.13.0'" >&2
  exit 1
fi

exec bats "${REPO_ROOT}/tests/runner-loop.bats" "$@"
