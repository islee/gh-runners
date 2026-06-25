# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A ~120-line FastAPI service (`app.py`) that mints short-lived **GitHub Actions runner registration
tokens** for a fleet of self-hosted runners. It exists so runners can register with **no standing GitHub
credential on any machine** and **no operator holding org-admin**. The README covers setup/deploy and the
security model.

It is meant to run as an **always-on, TLS-terminated web service** (Render Blueprint in `render.yaml`, or
the `Dockerfile` on any container host). It is the **sole holder of a GitHub App private key** — that key
must never land on a runner or in this repo.

## Architecture (the whole flow)

Every token request walks this chain in `app.py`:

```
App JWT (RS256, exp ≤10 min)  →  installation access token (cached ~50 min)  →
  POST /orgs/{org}/actions/runners/{registration|remove}-token
```

- `_app_jwt()` — signs a short RS256 JWT identifying the App (`iss=GH_APP_ID`).
- `_installation_token()` — exchanges the JWT for an installation token; **cached in the module-global
  `_inst` dict** and refreshed ~2 min early (GitHub tokens live 60 min). In-process cache only — it
  resets on every restart / cold start.
- `_mint(kind)` — the shared GitHub call for both endpoints; wraps upstream failures as HTTP 502.
- `_check_auth()` — constant-time (`hmac.compare_digest`) check of the caller's `Bearer $BROKER_SECRET`.
- `RateLimiter` / `_rate_limit()` — in-process token-bucket per client IP (`X-Forwarded-For` first hop
  behind Render). Runs **before** auth on both token endpoints, so it also throttles secret
  brute-forcing; over-limit → `429` + `Retry-After`. Tunable via `RATE_LIMIT_PER_MINUTE` /
  `RATE_LIMIT_BURST` env (0 disables). `_limiter` is the module-global instance.

Endpoints: `POST /token`, `POST /remove-token` (both rate-limited then auth'd), `GET /health` (open).
Optional `X-Runner-Name` header is **logged only** for attribution.

## Critical invariants

- **Labels are NOT enforceable here.** Runners self-assign labels at `config.sh --labels` time; they are
  not encoded in the registration token, so the broker cannot restrict them. Scope runner access with
  **GitHub runner groups**, not this service.
- **All config is required env at import time** (`GH_APP_ID`, `GH_INSTALLATION_ID`, `GH_ORG`,
  `BROKER_SECRET`, and a key). The process fails fast if any are missing — that is intentional.
- The private key is provided one of two ways: `GH_APP_PRIVATE_KEY_PATH` (a Secret File, preferred)
  **takes precedence** over inline `GH_APP_PRIVATE_KEY` PEM.
- **No secret ever enters git.** `.gitignore` blocks `*.pem`, `*.key`, `.env*`; `env.example` is the only
  committed config and holds placeholders.

## Commands

```bash
# Run locally (export the env vars from env.example first)
uvicorn app:app --host 0.0.0.0 --port 8000 --reload

# Lint + tests (CI runs both — see .github/workflows/ci.yml)
pip install -r requirements-dev.txt
ruff check .
pytest -q

# Smoke test against a deployed instance
curl -fsS https://<service>/health
curl -fsS -X POST -H "Authorization: Bearer $BROKER_SECRET" https://<service>/token | jq .expires_at
```

Tests (`tests/`) cover the non-GitHub HTTP surface (`/health`, 401 auth gate) and the rate limiter
(burst/refill/per-key + a 429 endpoint check). `tests/conftest.py` sets the required env (placeholder
key, high rate limit) before `app.py`'s import-time config read; minting needs a real key + network
and is not unit-tested.

## Gotchas

- Render free/starter tier sleeps after ~15 min idle → 30–60 s cold start on the next token fetch (and a
  fresh installation-token mint, since the cache is in-memory). Use a `/health` keep-alive or paid tier.
- `env.example` is intentionally dot-less so it isn't caught by the `.env*` gitignore — it's the shareable
  template, never the real secrets.
