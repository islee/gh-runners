#!/usr/bin/env bash
# job-started.sh — ACTIONS_RUNNER_HOOK_JOB_STARTED.
#
# Purpose: boot the headless Android emulator before each job and block until the device
# is fully ready (sys.boot_completed). Registered via ACTIONS_RUNNER_HOOK_JOB_STARTED in
# the Dockerfile.
#
# WHY per-job, not per-container: booting the emulator at container start would keep a
# ~3 GB process resident the entire idle time between jobs. Per-job hooks boot only while a
# job is running, then the job-completed hook kills the process. This also boots the emulator
# AS the `runner` user (the job user), so the adb server is owned by the same user that runs
# adb/maestro commands — cross-user adb permission issues do not arise.
#
# WHY non-zero exit fails the job: if the emulator fails to boot we want a loud, immediate
# CI failure rather than a job that silently runs against a dead device and produces
# misleading test output.
#
# /dev/kvm is made accessible to the `runner` user via the `kvm` group (group_add in compose).

set -euo pipefail

AVD_NAME="${AVD_NAME:-runner_avd}"
EMULATOR_BOOT_TIMEOUT="${EMULATOR_BOOT_TIMEOUT:-300}"

echo "[hook:job-started] Booting emulator '${AVD_NAME}' (timeout ${EMULATOR_BOOT_TIMEOUT}s, AVD_HOME=${ANDROID_AVD_HOME:-default}) ..."

emulator \
    -avd "${AVD_NAME}" \
    -no-window -no-audio -no-snapshot \
    -gpu swiftshader_indirect \
    -memory 2048 -cores 2 -accel on \
    &
echo $! > /tmp/emulator.pid

# Wait for the adb device to appear before polling boot_completed.
if ! timeout "${EMULATOR_BOOT_TIMEOUT}" adb wait-for-device; then
    echo "[hook:job-started] FATAL: ADB device never appeared — emulator failed to start (check /dev/kvm and KVM_GID)." >&2
    kill "$(cat /tmp/emulator.pid 2>/dev/null)" 2>/dev/null || true
    exit 1
fi

# Poll sys.boot_completed until the system is fully booted.
ELAPSED=0
until [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; do
    if (( ELAPSED >= EMULATOR_BOOT_TIMEOUT )); then
        echo "[hook:job-started] FATAL: emulator did not reach boot_completed within ${EMULATOR_BOOT_TIMEOUT}s." >&2
        kill "$(cat /tmp/emulator.pid 2>/dev/null)" 2>/dev/null || true
        exit 1
    fi
    sleep 5
    ELAPSED=$(( ELAPSED + 5 ))
done

# Dismiss the lock screen so UI test flows start on the home screen rather than a lock prompt.
adb shell input keyevent 82 >/dev/null 2>&1 || true

echo "[hook:job-started] Emulator ready after ${ELAPSED}s."
adb devices
