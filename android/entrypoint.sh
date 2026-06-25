#!/usr/bin/env bash
# entrypoint.sh — Android runner startup (per-job emulator model).
#
# Purpose: resolve a GitHub Actions runner registration token, register the runner as
# ephemeral, and exec run.sh to handle exactly one job. On exit, `restart: always` in
# docker-compose.yml brings up a fresh container to re-register and wait for the next job.
#
# WHY this entrypoint exists: unlike myoung34/github-runner, the official
# ghcr.io/actions/actions-runner image ships ONLY the runner binary (config.sh / run.sh).
# It does not handle registration or token ingestion. We do that here.
#
# WHY per-job emulator (not per-container): the Android emulator is ~3 GB in RAM. Booting it
# at container start keeps it resident the entire time the runner is idle. Instead, the
# job-started hook boots the emulator AS the runner user (correct adb ownership), and the
# job-completed hook tears it down. This script does NOT boot the emulator — that is the
# hook's responsibility.
#
# Dependencies: curl, jq (installed in Dockerfile)

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
# NOTE: the official image installs the runner binary at /home/runner. config.sh and run.sh
# live there. If the image layout changes, update RUNNER_HOME here.
# TODO: verify on first build: `docker run --rm ghcr.io/actions/actions-runner ls /home/runner`
#   should show config.sh and run.sh. If they are elsewhere, update this variable.
RUNNER_HOME="${RUNNER_HOME:-/home/runner}"

# Org this runner registers under. Must match the GitHub org slug (case-sensitive).
# Override via GH_ORG environment variable (set in .env / docker-compose.yml).
GH_ORG="${GH_ORG:-your-org}"  # NOTE: set GH_ORG in your .env file

# Runner display name — gh-runner-<type>-<id>-<n>. <id>=OWNER (default host), <n>=RUNNER_NUMBER.
# Override RUNNER_NAME directly (e.g. from compose) when running more than one.
RUNNER_NAME="${RUNNER_NAME:-gh-runner-android-${OWNER:-$(hostname -s)}-${RUNNER_NUMBER:-1}}"

# Labels that workflows must match to route jobs to this runner.
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,mobile,android}"

# ── Credential resolution ─────────────────────────────────────────────────────
# Priority: RUNNER_TOKEN (model A) → BROKER_URL+BROKER_SECRET (model B) → ACCESS_TOKEN (PAT).
#
# Model A — RUNNER_TOKEN: a static registration token minted from org Settings > Actions > Runners.
#   Expires ~1 h after minting. Good for single-run pilots; ephemeral re-registration will fail
#   after expiry, so the container will fail to restart. Use model B or ACCESS_TOKEN for production.
#
# Model B — BROKER_URL + BROKER_SECRET: a deployed gh-runner-broker instance
#   (https://github.com/islee/gh-runners/tree/main/broker) holds the GitHub App credential.
#   This container POSTs to $BROKER_URL/token and gets a fresh token each cycle.
#   No GitHub credential ever lives in this container — only the broker secret.
#
# Model C — ACCESS_TOKEN: a fine-grained PAT scoped to `organization_self_hosted_runners` only.
#   We mint a registration token from it via the GitHub REST API. The PAT lives in this container's
#   env, which is less ideal than the broker model but sufficient for small fleets.
#   CRITICAL: never use an org admin PAT here. Scope it to self-hosted runners only.

resolve_credential() {
    # ── Model A: static registration token ───────────────────────────────────
    if [[ -n "${RUNNER_TOKEN:-}" ]]; then
        echo "[entrypoint] Credential: RUNNER_TOKEN (model A — static registration token)" >&2
        # REG_TOKEN is what we pass to config.sh --token; set it from RUNNER_TOKEN.
        REG_TOKEN="${RUNNER_TOKEN}"
        return 0
    fi

    # ── Model B: broker ───────────────────────────────────────────────────────
    if [[ -n "${BROKER_URL:-}" ]]; then
        echo "[entrypoint] Credential: BROKER_URL (model B — fetching registration token from broker)" >&2
        # Broker API: POST $BROKER_URL/token
        #   Request header: Authorization: Bearer $BROKER_SECRET
        #   Optional header: X-Runner-Name (for broker-side attribution logging)
        #   Response JSON: {"token": "...", "expires_at": "...", "url": "https://github.com/<org>"}
        local _tok
        _tok="$(curl --silent --fail --max-time 15 -X POST \
            -H "Authorization: Bearer ${BROKER_SECRET:-}" \
            -H "X-Runner-Name: ${RUNNER_NAME}" \
            "${BROKER_URL%/}/token" | jq -r '.token')" || {
            echo "[entrypoint] FATAL: broker token fetch failed (check BROKER_URL / BROKER_SECRET)." >&2
            exit 1
        }
        if [[ -z "${_tok}" || "${_tok}" == "null" ]]; then
            echo "[entrypoint] FATAL: broker returned an empty token." >&2
            exit 1
        fi
        REG_TOKEN="${_tok}"
        return 0
    fi

    # ── Model C: PAT — mint a registration token via GitHub REST ─────────────
    if [[ -n "${ACCESS_TOKEN:-}" ]]; then
        echo "[entrypoint] Credential: ACCESS_TOKEN (model C — minting registration token via GitHub REST)" >&2
        # WHY we mint here rather than passing ACCESS_TOKEN to config.sh: the official image's
        # config.sh does not accept a PAT directly (unlike myoung34 which wrapped that). We must
        # exchange the PAT for a short-lived registration token first.
        # CRITICAL: ACCESS_TOKEN must be scoped to `organization_self_hosted_runners` only.
        local _tok
        _tok="$(curl --silent --fail --max-time 15 -X POST \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "https://api.github.com/orgs/${GH_ORG}/actions/runners/registration-token" \
            | jq -r '.token')" || {
            echo "[entrypoint] FATAL: GitHub REST token mint failed (check ACCESS_TOKEN scope and GH_ORG)." >&2
            exit 1
        }
        if [[ -z "${_tok}" || "${_tok}" == "null" ]]; then
            echo "[entrypoint] FATAL: GitHub returned an empty registration token." >&2
            exit 1
        fi
        # Mask the PAT from any process-argument listings after we have the token.
        unset ACCESS_TOKEN
        REG_TOKEN="${_tok}"
        return 0
    fi

    echo "[entrypoint] FATAL: no credential found." >&2
    echo "[entrypoint]        Set one of:" >&2
    echo "[entrypoint]          RUNNER_TOKEN  — static registration token (model A, pilots only)" >&2
    echo "[entrypoint]          BROKER_URL + BROKER_SECRET  — token broker (model B, recommended)" >&2
    echo "[entrypoint]          ACCESS_TOKEN  — fine-grained PAT (model C, self-contained)" >&2
    echo "[entrypoint]        See env.example for documentation on each variable." >&2
    exit 1
}

resolve_credential

# ── Validate runner home ──────────────────────────────────────────────────────
if [[ ! -d "${RUNNER_HOME}" ]]; then
    echo "[entrypoint] FATAL: runner home ${RUNNER_HOME} not found." >&2
    echo "[entrypoint]        The official image layout may have changed — update RUNNER_HOME." >&2
    exit 1
fi
if [[ ! -x "${RUNNER_HOME}/config.sh" ]]; then
    echo "[entrypoint] FATAL: ${RUNNER_HOME}/config.sh not found or not executable." >&2
    echo "[entrypoint]        TODO: verify path with: docker run --rm ghcr.io/actions/actions-runner ls /home/runner" >&2
    exit 1
fi

cd "${RUNNER_HOME}" || {
    echo "[entrypoint] FATAL: cannot cd to ${RUNNER_HOME}." >&2
    exit 1
}

# ── Register the runner ───────────────────────────────────────────────────────
# --ephemeral: runner exits after one job and deregisters itself automatically.
# --unattended: no interactive prompts.
# --replace: if a stale runner with the same name exists (e.g. from an unclean prior shutdown),
#   replace it rather than failing.
# WHY no --disableupdate: we rely on the image being rebuilt for updates, but the runner binary
# may still try to self-update within the container. Adding --disableupdate prevents that noise.
echo "[entrypoint] Registering runner '${RUNNER_NAME}' in org '${GH_ORG}' with labels '${RUNNER_LABELS}' ..." >&2
./config.sh \
    --url "https://github.com/${GH_ORG}" \
    --token "${REG_TOKEN}" \
    --labels "${RUNNER_LABELS}" \
    --name "${RUNNER_NAME}" \
    --ephemeral \
    --unattended \
    --replace \
    --disableupdate || {
    echo "[entrypoint] FATAL: config.sh failed — check GH_ORG, RUNNER_LABELS, and the registration token." >&2
    exit 1
}

# Clear the registration token from memory now that config.sh has consumed it.
# WHY: config.sh stores what it needs; keeping REG_TOKEN in the environment beyond this point
# is unnecessary and creates a window where it could appear in /proc/<pid>/environ.
unset REG_TOKEN

# ── Run one job ───────────────────────────────────────────────────────────────
# run.sh blocks until the runner picks up and completes exactly one job (--ephemeral),
# then exits. docker-compose.yml's `restart: always` brings up a fresh container to
# re-register and wait for the next job.
echo "[entrypoint] Registration complete. Starting runner (will handle one job then exit) ..." >&2
exec ./run.sh
