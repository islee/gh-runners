#!/usr/bin/env bash
# runner-payload.sh — swappable job-runner payload for the containerized "light" runner.
#
# Purpose: register this runner as ephemeral and exec run.sh for exactly one job. On exit,
# docker-compose's `restart: always` brings up a fresh container to re-register.
#
# Self-update target: bootstrap.sh may replace this file on each container start.
# This script can also be run standalone (without bootstrap.sh).
#
# REG_TOKEN in env: if bootstrap.sh already fetched the registration token, skip credential
# resolution to avoid a redundant broker call. If absent, resolve the credential here.
#
# Dependencies: curl, jq (installed by the Dockerfile).

set -euo pipefail

# NOTE: the official image installs the runner binary at /home/runner (config.sh / run.sh there).
# TODO: verify on first build — `docker run --rm ghcr.io/actions/actions-runner ls /home/runner`.
RUNNER_HOME="${RUNNER_HOME:-/home/runner}"
GH_ORG="${GH_ORG:-your-org}"                                  # set in .env
RUNNER_NAME="${RUNNER_NAME:-gh-runner-light-${OWNER:-$(hostname -s)}-${RUNNER_NUMBER:-1}}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,x64,light}"
# Runner work dir. Default `_work` is the runner's own default (fine for plain jobs). For a
# docker-in-job runner (e.g. supabase) this is bind-mounted at the SAME absolute path host↔container
# so the host Docker daemon resolves job bind-mounts correctly — set RUNNER_WORKDIR there.
RUNNER_WORKDIR="${RUNNER_WORKDIR:-_work}"

# ── Credential resolution ──────────────────────────────────────────────────────
# Priority: REG_TOKEN (from bootstrap) → RUNNER_TOKEN (A) → BROKER_URL+BROKER_SECRET (B)
#           → ACCESS_TOKEN (PAT).
# Sets REG_TOKEN (the short-lived registration token passed to config.sh).
resolve_credential() {
  if [[ -n "${REG_TOKEN:-}" ]]; then
    echo "[payload] Credential: REG_TOKEN from bootstrap (already resolved)." >&2
    return 0
  fi

  if [[ -n "${RUNNER_TOKEN:-}" ]]; then
    echo "[payload] Credential: RUNNER_TOKEN (model A — static registration token)" >&2
    REG_TOKEN="${RUNNER_TOKEN}"; return 0
  fi

  if [[ -n "${BROKER_URL:-}" ]]; then
    # Broker API: POST $BROKER_URL/token, header Authorization: Bearer $BROKER_SECRET,
    # response {"token","expires_at","url"}. No GitHub credential lives in this container.
    echo "[payload] Credential: BROKER_URL (model B — fetching token from broker)" >&2
    local _tok
    _tok="$(curl --silent --fail --max-time 15 -X POST \
      -H "Authorization: Bearer ${BROKER_SECRET:-}" \
      -H "X-Runner-Name: ${RUNNER_NAME}" \
      "${BROKER_URL%/}/token" | jq -r '.token')" || {
      echo "[payload] FATAL: broker token fetch failed (check BROKER_URL / BROKER_SECRET)." >&2; exit 1; }
    [[ -n "${_tok}" && "${_tok}" != "null" ]] || {
      echo "[payload] FATAL: broker returned an empty token." >&2; exit 1; }
    REG_TOKEN="${_tok}"; return 0
  fi

  if [[ -n "${ACCESS_TOKEN:-}" ]]; then
    # Mint a registration token via GitHub REST from a fine-grained PAT scoped to
    # organization_self_hosted_runners. CRITICAL: never an org-admin PAT.
    echo "[payload] Credential: ACCESS_TOKEN (PAT — minting registration token via GitHub REST)" >&2
    local _tok
    _tok="$(curl --silent --fail --max-time 15 -X POST \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/orgs/${GH_ORG}/actions/runners/registration-token" | jq -r '.token')" || {
      echo "[payload] FATAL: GitHub REST token mint failed (check ACCESS_TOKEN scope and GH_ORG)." >&2; exit 1; }
    [[ -n "${_tok}" && "${_tok}" != "null" ]] || {
      echo "[payload] FATAL: GitHub returned an empty token." >&2; exit 1; }
    unset ACCESS_TOKEN  # drop the PAT from the environment once we have the token
    REG_TOKEN="${_tok}"; return 0
  fi

  echo "[payload] FATAL: no credential found. Set RUNNER_TOKEN, BROKER_URL(+BROKER_SECRET), or ACCESS_TOKEN." >&2
  echo "[payload]        See env.example for each variable." >&2
  exit 1
}

resolve_credential

# ── Validate runner home ───────────────────────────────────────────────────────
[[ -x "${RUNNER_HOME}/config.sh" ]] || {
  echo "[payload] FATAL: ${RUNNER_HOME}/config.sh not found — official image layout changed; update RUNNER_HOME." >&2
  exit 1; }
cd "${RUNNER_HOME}"

# ── Register (ephemeral) + run one job ────────────────────────────────────────
echo "[payload] Registering '${RUNNER_NAME}' in org '${GH_ORG}' labels '${RUNNER_LABELS}' ..." >&2
./config.sh \
  --url "https://github.com/${GH_ORG}" \
  --token "${REG_TOKEN}" \
  --labels "${RUNNER_LABELS}" \
  --name "${RUNNER_NAME}" \
  --work "${RUNNER_WORKDIR}" \
  --ephemeral --unattended --replace --disableupdate || {
  echo "[payload] FATAL: config.sh failed — check GH_ORG, labels, and the token." >&2; exit 1; }

# Drop the token now that config.sh consumed it (avoid lingering in /proc/<pid>/environ).
unset REG_TOKEN

echo "[payload] Registered. Running one job then exiting (restart: always re-registers) ..." >&2
exec ./run.sh
