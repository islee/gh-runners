#!/usr/bin/env bash
# job-completed.sh — ACTIONS_RUNNER_HOOK_JOB_COMPLETED.
#
# Purpose: tear down the Android emulator after each job. Registered via
# ACTIONS_RUNNER_HOOK_JOB_COMPLETED in the Dockerfile.
#
# WHY best-effort (no set -e): a failure here must never block job completion
# reporting back to GitHub. If cleanup fails the job result is already determined;
# failing the hook would mark the job as errored and obscure the real result.
# The container is ephemeral — any stale state is thrown away on the next restart.

set -uo pipefail

echo "[hook:job-completed] Stopping emulator ..."

# Graceful stop via adb first; fall back to SIGTERM on the recorded PID.
adb emu kill 2>/dev/null || true

if [[ -f /tmp/emulator.pid ]]; then
    kill "$(cat /tmp/emulator.pid)" 2>/dev/null || true
    rm -f /tmp/emulator.pid
fi

# Kill the adb server so the next job's hook starts with a clean adb state.
adb kill-server 2>/dev/null || true

echo "[hook:job-completed] Emulator stopped."
exit 0
