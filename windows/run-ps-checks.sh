#!/usr/bin/env bash
# windows/run-ps-checks.sh — PSScriptAnalyzer lint + runner-loop.ps1 SELFTEST gate.
#
# Invoked by pre-commit (language: system). Fails loudly when pwsh is absent so
# contributors get an actionable error rather than a silent skip that would fake
# local == CI parity. Two phases:
#   1. Invoke-ScriptAnalyzer over windows/ at Warning/Error severity.
#   2. SELFTEST mode in runner-loop.ps1 (checks all required functions are defined).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
WINDOWS_DIR="$REPO_ROOT/windows"
SETTINGS_FILE="$WINDOWS_DIR/PSScriptAnalyzerSettings.psd1"

# Fail loudly if pwsh is absent — no silent skip (that fakes local == CI parity).
if ! command -v pwsh > /dev/null 2>&1; then
    printf 'ERROR: pwsh required for the windows gate. Install:\n' >&2
    printf '  macOS:   brew install powershell\n' >&2
    printf '  Linux:   see https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux\n' >&2
    printf '  Windows: winget install Microsoft.PowerShell  (or already present)\n' >&2
    printf 'Then install PSScriptAnalyzer:\n' >&2
    printf '  pwsh -Command "Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser"\n' >&2
    exit 1
fi

echo '--- PSScriptAnalyzer lint ---'
pwsh -NoProfile -Command \
    "Invoke-ScriptAnalyzer -Path '${WINDOWS_DIR}' -Recurse -Severity Warning,Error -EnableExit -Settings '${SETTINGS_FILE}'"

echo '--- runner-loop.ps1 SELFTEST ---'
TMP_CFG="$(mktemp)"
trap 'rm -f "$TMP_CFG"' EXIT

# Minimal stub config — SELFTEST only checks that functions are defined, not that they work.
printf 'GH_ORG="selftest"\n' > "$TMP_CFG"
printf 'RUNNER_TOKEN="selftest-tok"\n' >> "$TMP_CFG"
printf 'RUNNER_NAME="gh-runner-selftest-1"\n' >> "$TMP_CFG"

SELFTEST=1 SELFTEST_CONFIG="$TMP_CFG" pwsh -NoProfile -File "${WINDOWS_DIR}/runner-loop.ps1"
echo 'runner-loop.ps1 SELFTEST passed.'
