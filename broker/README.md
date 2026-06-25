# broker — gh-runner-broker

> Part of [`gh-runners`](../README.md). On Render, deploy via the **repo-root** `render.yaml`
> (`rootDir: broker`); for containers use `docker-compose.yml` / `Dockerfile` in this dir.

A tiny, always-on web service that mints short-lived **GitHub Actions runner registration tokens**,
backed by a **GitHub App**. It lets a fleet of self-hosted runners register with **no standing GitHub
credential on any runner machine** and **without anyone needing org-admin**. The GitHub App private key
lives only in the broker's secret store — never on a runner.

## Why a broker (the problem it solves)

Registering an org-level self-hosted runner normally requires an org-admin `registration token`, which
in turn means either handing out org-admin or parking a long-lived admin PAT on every runner host. Both
are bad: PATs are broad, long-lived, and leak. Instead:

- The broker holds a **single GitHub App private key** (scoped to *Self-hosted runners: read & write*,
  nothing else) in **one** place.
- Each runner authenticates to the broker with a shared `BROKER_SECRET` and pulls a fresh,
  **short-lived** registration token (valid ~1 hour) each time it (re)registers.
- No runner ever holds a GitHub credential, and revoking access is a single secret rotation.

## How it works

```
App JWT (RS256, exp ≤10 min)  →  installation access token (cached ~50 min)  →
  POST /orgs/{org}/actions/runners/{registration|remove}-token
```

The installation token is cached in-process and refreshed a couple minutes early (GitHub installation
tokens live 60 min). Caller auth is a constant-time compare of `Authorization: Bearer $BROKER_SECRET`.

## Files
| File | Purpose |
|------|---------|
| `app.py` | the FastAPI broker (~120 lines): App JWT → installation token → registration/remove token |
| `requirements.txt` | fastapi, uvicorn, httpx, pyjwt[crypto] |
| `Dockerfile` / `docker-compose.yml` | container image + self-host compose for any container host |
| `env.example` | the env vars to set (template; contains no real values) |
| `tests/` | HTTP-surface + rate-limiter tests; run with `pytest` |

(Render Blueprint lives at the **repo root** `render.yaml` with `rootDir: broker`; lint+tests run from
the repo-root `.github/workflows/ci.yml`.)

## Endpoints
| Method | Path | Auth | Returns |
|--------|------|------|---------|
| `POST` | `/token` | `Bearer $BROKER_SECRET` | `{"token","expires_at","url"}` registration token |
| `POST` | `/remove-token` | `Bearer $BROKER_SECRET` | `{"token","expires_at"}` |
| `GET` | `/stats` | `Bearer $BROKER_SECRET` | recent token activity by type / host / runner |
| `GET` | `/health` | none | `{"ok":true}` |

Optional `X-Runner-Name` header is logged for attribution **and feeds `/stats`** (see below).

> **Labels are NOT enforceable by this service.** A runner self-assigns its labels at `config.sh
> --labels` time; they are not encoded in the registration token, so the broker cannot restrict them.
> Scope what runners may do with **GitHub runner groups**, not this broker.

## Rate limiting

The token endpoints are rate-limited per client IP (token bucket) so a leaked or brute-forced
`BROKER_SECRET` can't mint tokens — or hammer the GitHub App — without bound. The check runs *before*
auth, so it also throttles secret-guessing. Tune with `RATE_LIMIT_PER_MINUTE` (default 30) and
`RATE_LIMIT_BURST` (default = per-minute); set `RATE_LIMIT_PER_MINUTE=0` to disable. Over-limit
callers get `429` with a `Retry-After` header. Behind Render the client IP is read from
`X-Forwarded-For`. **State is in-process**, so with multiple instances the limit is per-instance.

## Recent stats

`GET /stats` (auth-gated, rate-limited) returns two top-level fields:

| Field | Source | Durability |
|-------|--------|------------|
| `fleet` | Live GitHub API query — current runner state (online/busy/labels) | Durable by construction (GitHub is the source of truth) |
| `activity` | Token/remove-token call counts per type and host | Durable when Upstash or Supabase is configured; in-memory window otherwise |

```bash
curl -fsS -H "Authorization: Bearer $BROKER_SECRET" https://<service>/stats | jq .
```
```jsonc
{
  "generated_at": "2026-06-25T08:47:59Z",
  "fleet": {
    "total": 4, "online": 3, "busy": 1,
    "by_type": { "light": { "total": 2, "online": 2, "busy": 0 }, … },
    "by_host": { "ci-linple": { "total": 4, "online": 3, "busy": 1 } },
    "runners": [
      { "name": "gh-runner-light-ci-linple-1", "type": "light", "host": "ci-linple",
        "status": "online", "busy": false, "labels": ["self-hosted","light"] }, … ]
  },
  "activity": {
    "backend": "upstash-redis",
    "durable": true,
    "since": "2026-06-01T00:00:00Z",
    "totals": { "token": 40, "remove-token": 2 },
    "by_type": { "light": { "token": 28, "remove-token": 0, "last_seen": "…" }, … },
    "by_host": { "ci-linple": { "token": 40, "remove-token": 2, "last_seen": "…" } }
  }
}
```

**Fleet field** — populated by `GET /orgs/{org}/actions/runners` (paginated) using the cached
installation token. A GitHub error produces `{"error": "…"}` without blocking the `activity` field.

### Activity backends

Select via `STATS_BACKEND` (default `auto`). All persistence is fire-and-forget (best-effort) — the
hot path is never blocked. `record()` implementations swallow errors and log warnings.

| `STATS_BACKEND` | `backend` in response | `durable` | Requires |
|---|---|---|---|
| `auto` (default) | Upstash → Supabase → memory (first configured wins) | varies | see below |
| `upstash` | `upstash-redis` | `true` | `UPSTASH_REDIS_REST_URL` + `UPSTASH_REDIS_REST_TOKEN` |
| `supabase` | `supabase` | `true` | (`SUPABASE_SECRET_KEY` or `SUPABASE_SERVICE_KEY`) + (`SUPABASE_URL` or `SUPABASE_PROJECT_REF`) |
| `memory` | `memory` | `false` | — (always available) |

**Auto precedence:** Upstash is preferred when both Upstash and Supabase credentials are present.
If neither is configured, in-memory is used automatically — the broker never fails to boot.

**Upstash Redis:** Set `UPSTASH_REDIS_REST_URL` and `UPSTASH_REDIS_REST_TOKEN`. Counters survive
restarts and Render cold starts. The `since` field marks the first ever recorded event.

**Supabase Postgres:** Set either `SUPABASE_SECRET_KEY` (new-style `sb_secret_...` key, preferred)
or `SUPABASE_SERVICE_KEY` (legacy `service_role` JWT; still works). Both use the same
`apikey`/`Authorization` headers — only the env-var name differs. Also set `SUPABASE_URL` (full URL)
or `SUPABASE_PROJECT_REF` (project ref; URL derived as `https://<ref>.supabase.co`). Never use the
publishable key (`sb_publishable_...`) here — it is RLS-restricted and will fail. **One-time
setup:** run `broker/supabase_stats.sql` in the Supabase SQL editor to create `runner_stats`,
`runner_stats_meta`, and the `record_runner_event` upsert RPC.

**In-memory fallback:** `backend: "memory"`, `durable: false`. Resets on restart.
Window = `RUNNER_STATS_WINDOW_SECONDS` (default 24 h); ring-buffer cap = `RUNNER_STATS_MAX_EVENTS`
(default 10000).

**Auth-gated** because it exposes fleet topology (types, hosts, runner names). A runner name that
doesn't fit `gh-runner-<type>-<id>-<n>` is bucketed as type `unknown`.

## Credentials & security

This service is the custodian of a powerful secret. Treat it accordingly.

- **Two secrets exist, both stay out of git:**
  1. the **GitHub App private key** (`.pem`) — full control over runner registration for the org;
  2. the **`BROKER_SECRET`** — the bearer token every runner presents.
  The `.gitignore` here blocks `*.pem`, `*.key`, and `.env*`. Verify with `git status` before the first
  commit that none of them are staged.
- **Provide the private key as a Secret File, not an env var, when your host supports it.** Set
  `GH_APP_PRIVATE_KEY_PATH=/path/to/key.pem`; it takes precedence over the inline `GH_APP_PRIVATE_KEY`.
  Env-var values are easy to echo into logs by accident; file mounts are not.
- **Scope the GitHub App to the minimum:** Organization permission *Self-hosted runners: Read and write*
  and nothing else; install it on **only** your account/org; disable the webhook.
- **Serve only over TLS.** The `BROKER_SECRET` is a bearer token — anyone who sees it can mint tokens.
  Render and most PaaS terminate TLS for you; do not expose the service over plain HTTP.
- **Rotate on exposure.** If the broker secret leaks, regenerate it and update every runner. If the App
  key leaks, revoke that key in the App settings and generate a new one — outstanding registration
  tokens expire on their own within the hour.
- **Consider locking down callers** (IP allow-list / private networking) if your runners have stable
  egress; the bearer secret is the only gate by default.

## One-time: create the GitHub App
1. Org (or user) → **Settings → Developer settings → GitHub Apps → New GitHub App**.
2. Name it (e.g. `gh-runner-broker`); Homepage URL can be anything. **Uncheck "Active"** under Webhook
   (no webhook needed).
3. **Permissions → Organization → Self-hosted runners → Read and write.** Nothing else.
4. "Where can this be installed" → **Only on this account**. Create.
5. Note the **App ID**. **Generate a private key** → downloads a `.pem` (keep it out of any repo).
6. **Install App** on the org. The install URL ends in `/installations/<INSTALLATION_ID>` — note that
   number (or read it from `GET /orgs/{org}/installations` with an App JWT).

## Deploy on Render
1. Render → **New → Blueprint**, point at this repo (uses `render.yaml`), **or** New → Web Service
   (Python): build `pip install -r requirements.txt`, start
   `uvicorn app:app --host 0.0.0.0 --port $PORT`.
2. Set env in the dashboard: `GH_APP_ID`, `GH_INSTALLATION_ID`, `GH_ORG`, and the key — either paste the
   `.pem` into `GH_APP_PRIVATE_KEY`, or upload it as a **Secret File** and set
   `GH_APP_PRIVATE_KEY_PATH=/etc/secrets/<name>.pem`. `BROKER_SECRET` is auto-generated by the Blueprint
   (or set your own).
3. Note the service URL and the `BROKER_SECRET`.

> Free tier sleeps after ~15 min idle → a 30–60 s cold start on the next token fetch (and a fresh
> installation-token mint, since the cache is in-memory). Use a paid tier or a periodic `/health`
> keep-alive to avoid registration delays.

## Run locally
```bash
pip install -r requirements.txt
# export the vars from env.example first (GH_APP_ID, GH_INSTALLATION_ID, GH_ORG,
# GH_APP_PRIVATE_KEY or GH_APP_PRIVATE_KEY_PATH, BROKER_SECRET)
uvicorn app:app --host 0.0.0.0 --port 8000 --reload
```

## Lint & test
```bash
pip install -r requirements-dev.txt
ruff check . && pytest -q
```
Tests cover `/health`, the 401 auth gate, and the rate limiter (burst/refill/per-key + a 429
endpoint check). Minting isn't unit-tested — it needs a real App key + network.

## Point runners at it
In each runner's `.env` / `config.env`:
```
BROKER_URL=https://<your-service-host>
BROKER_SECRET=<the value from the broker host>
```
Runner loops fetch a fresh registration token from `POST $BROKER_URL/token` each cycle, so no static
runner token needs to be stored.

## Smoke test
```bash
curl -fsS https://<service>/health
curl -fsS -X POST -H "Authorization: Bearer $BROKER_SECRET" https://<service>/token | jq .expires_at
```
JSON with a `token` means the App + install are wired correctly. A **401** means the `BROKER_SECRET`
mismatched; a **502** means the GitHub App call failed (check App ID / installation / key / the
Self-hosted-runners permission).

## License

MIT — see [`LICENSE`](LICENSE).
