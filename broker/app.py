"""
gh-runner-broker — mints GitHub Actions runner *registration* tokens for a fleet of
self-hosted runners, backed by a GitHub App.

WHY: registering an org-level runner needs org-admin; you don't want that on every runner host, and
you don't want a standing admin PAT anywhere. This broker holds the only credential (a GitHub App
private key), and runners fetch a short-lived registration token from it each cycle. The key lives
ONLY here (in the host's secret store) — never on a runner machine.

FLOW per request: App JWT (RS256, ≤10 min) -> installation access token (cached ~50 min) ->
  POST /orgs/{org}/actions/runners/{registration|remove}-token.
Callers authenticate with a shared BROKER_SECRET (Bearer). See README.md for setup + rationale.

NOTE: labels are chosen by the runner at `config.sh --labels` time and are NOT encoded in the
registration token, so the broker CANNOT enforce them — it only logs the caller (X-Runner-Name)
for attribution. Use GitHub *runner groups* to scope what runners may do.
"""

from __future__ import annotations

import asyncio
import collections
import hmac
import logging
import os
import time
from datetime import datetime, timezone
from typing import Any

import httpx
import jwt
from fastapi import FastAPI, Header, HTTPException, Request

GITHUB_API = "https://api.github.com"
APP_ID = os.environ["GH_APP_ID"]
INSTALLATION_ID = os.environ["GH_INSTALLATION_ID"]
ORG = os.environ["GH_ORG"]
BROKER_SECRET = os.environ["BROKER_SECRET"]

# Private key: a Render Secret File path (preferred) or an inline PEM env var.
_pk_path = os.environ.get("GH_APP_PRIVATE_KEY_PATH")
PRIVATE_KEY = (
    open(_pk_path, encoding="utf-8").read() if _pk_path else os.environ["GH_APP_PRIVATE_KEY"]
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("broker")
app = FastAPI(title="runner-token-broker")

# Cached installation token: GitHub installation tokens live 1 h; refresh a little early.
_inst: dict = {"token": None, "exp": 0.0}

# Rate limiting. The only caller credential is a single shared BROKER_SECRET, so a leaked secret —
# or a brute-force attempt against it — could mint tokens (and hammer the GitHub App) without bound.
# A token bucket per client IP caps that. RATE_LIMIT_PER_MINUTE=0 disables it.
# NOTE: state is in-process only; if the broker runs as multiple instances each keeps its own
# buckets, so the effective limit is per-instance. Fine for a single small-fleet deployment.
RATE_LIMIT_PER_MINUTE = int(os.environ.get("RATE_LIMIT_PER_MINUTE", "30"))
RATE_LIMIT_BURST = int(os.environ.get("RATE_LIMIT_BURST", str(RATE_LIMIT_PER_MINUTE)))

# Recent-activity stats. The broker sees every (re)registration as a /token call carrying the
# runner's X-Runner-Name (gh-runner-<type>-<id>-<n>), so it can report which runner types/hosts have
# been active lately. STATS_BACKEND selects the store: "upstash" (Upstash Redis REST), "supabase"
# (Supabase PostgREST), "memory" (in-process ring-buffer), or "auto" (Upstash preferred, then
# Supabase, then memory). Durable backends survive restarts; memory resets on each cold start.
RUNNER_STATS_WINDOW_SECONDS = int(os.environ.get("RUNNER_STATS_WINDOW_SECONDS", "86400"))
RUNNER_STATS_MAX_EVENTS = int(os.environ.get("RUNNER_STATS_MAX_EVENTS", "10000"))

# Background task set: keeps asyncio.Task references alive until they complete so fire-and-forget
# persistence calls are not garbage-collected mid-flight.
_bg_tasks: set[asyncio.Task] = set()


class RateLimiter:
    """In-memory token-bucket limiter keyed by an opaque client id (here, the client IP).

    Each key refills at `rate_per_min/60` tokens/sec up to `burst` capacity; `allow()` spends one
    token and returns False when the bucket is empty. `clock` is injectable for testing.
    """

    def __init__(self, rate_per_min: int, burst: int, clock=time.monotonic, max_keys: int = 10_000):
        self.rate = rate_per_min / 60.0  # tokens per second
        self.capacity = float(burst)
        self._clock = clock
        self._max_keys = max_keys
        self._buckets: dict[str, tuple[float, float]] = {}  # key -> (tokens, last_seen)

    def allow(self, key: str) -> bool:
        now = self._clock()
        tokens, last = self._buckets.get(key, (self.capacity, now))
        # Refill for elapsed time, capped at capacity.
        tokens = min(self.capacity, tokens + (now - last) * self.rate)
        if tokens < 1.0:
            self._buckets[key] = (tokens, now)
            return False
        self._buckets[key] = (tokens - 1.0, now)
        # Bound memory: when the table grows large, evict fully-refilled (idle) buckets — dropping
        # them is lossless since a missing key starts at full capacity anyway.
        if len(self._buckets) > self._max_keys:
            self._buckets = {k: v for k, v in self._buckets.items() if v[0] < self.capacity - 1e-9}
        return True


# Disabled (None) when RATE_LIMIT_PER_MINUTE<=0.
_limiter = (
    RateLimiter(RATE_LIMIT_PER_MINUTE, RATE_LIMIT_BURST) if RATE_LIMIT_PER_MINUTE > 0 else None
)


def parse_runner_name(name: str | None) -> tuple[str, str]:
    """Split a `gh-runner-<type>-<id>-<n>` runner name into (type, host).

    `<id>` (the host/owner tag) may itself contain hyphens (e.g. `my-host`); `<n>` is always the
    last segment, so type is the 3rd field and host is everything between it and the trailing number.
    Anything that doesn't fit the convention maps to ('unknown', name or 'unknown')."""
    if not name:
        return ("unknown", "unknown")
    parts = name.split("-")
    if len(parts) >= 5 and parts[0] == "gh" and parts[1] == "runner":
        return (parts[2], "-".join(parts[3:-1]))
    return ("unknown", name)


def _iso(ts: float) -> str | None:
    """Epoch seconds -> 'YYYY-MM-DDTHH:MM:SSZ' (UTC), or None for a falsy timestamp."""
    if not ts:
        return None
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class RunnerStats:
    """In-process, time-windowed record of recent token activity, keyed by runner.

    Each record() appends (ts, kind, name, type, host); events older than `window` seconds are pruned
    lazily on read/write, and the deque is hard-capped at `max_events` as a memory backstop. `clock`
    is injectable for testing. Single-process / single-worker only (matching the broker's design).

    Implements the async store interface: async record() and async snapshot() so it is interchangeable
    with RedisStatsStore. snapshot() includes "backend": "memory" and "durable": False."""

    backend = "memory"
    durable = False

    def __init__(self, window_s: int, max_events: int, clock=time.time):
        self.window = window_s
        self._clock = clock
        self._events: collections.deque = collections.deque(maxlen=max_events)

    async def record(self, kind: str, name: str | None) -> None:
        rtype, host = parse_runner_name(name)
        self._events.append((self._clock(), kind, name or "?", rtype, host))

    def _prune(self, now: float) -> None:
        cutoff = now - self.window
        while self._events and self._events[0][0] < cutoff:
            self._events.popleft()

    async def snapshot(self) -> dict:
        now = self._clock()
        self._prune(now)
        totals: dict[str, int] = {"token": 0, "remove-token": 0}
        by_type: dict[str, dict] = {}
        by_host: dict[str, dict] = {}
        by_runner: dict[str, dict] = {}

        def _agg(table: dict, key: str) -> dict:
            return table.setdefault(
                key, {"token": 0, "remove-token": 0, "runners": set(), "last_seen": 0.0}
            )

        for ts, kind, name, rtype, host in self._events:
            totals[kind] = totals.get(kind, 0) + 1
            for table, key in ((by_type, rtype), (by_host, host)):
                e = _agg(table, key)
                e[kind] = e.get(kind, 0) + 1
                e["runners"].add(name)
                e["last_seen"] = max(e["last_seen"], ts)
            r = by_runner.setdefault(
                name,
                {"type": rtype, "host": host, "token": 0, "remove-token": 0, "last_seen": 0.0},
            )
            r[kind] = r.get(kind, 0) + 1
            r["last_seen"] = max(r["last_seen"], ts)

        def _fmt_group(table: dict) -> dict:
            return {
                key: {
                    "token": e["token"],
                    "remove-token": e["remove-token"],
                    "runners": len(e["runners"]),
                    "last_seen": _iso(e["last_seen"]),
                }
                for key, e in table.items()
            }

        runners = sorted(
            (
                {
                    "name": name,
                    "type": r["type"],
                    "host": r["host"],
                    "token": r["token"],
                    "remove-token": r["remove-token"],
                    "last_seen": _iso(r["last_seen"]),
                }
                for name, r in by_runner.items()
            ),
            key=lambda x: x["last_seen"] or "",
            reverse=True,
        )

        return {
            "backend": self.backend,
            "durable": self.durable,
            "window_seconds": self.window,
            "total_events": len(self._events),
            "totals": totals,
            "by_type": _fmt_group(by_type),
            "by_host": _fmt_group(by_host),
            "runners": runners,
        }


class SupabaseStatsStore:
    """Durable activity counter store backed by Supabase Postgres via PostgREST.

    Uses two tables and one RPC (see broker/supabase_stats.sql):
      runner_stats       — (dimension, key, kind) primary key; count + last_seen per bucket
      runner_stats_meta  — single row (id=1) holding the since timestamp
      record_runner_event(p_dimension, p_key, p_kind, p_ts) — upsert helper

    record() fires two concurrent RPC calls (one for "type" dimension, one for "host").
    Persistence is best-effort: record() swallows all errors rather than failing the hot path.

    `http` is an injectable async callable (method, path, *, json=None, params=None) -> parsed JSON
    for tests; when None, real calls go to Supabase via httpx with service_role auth headers.
    """

    backend = "supabase"
    durable = True

    def __init__(
        self,
        url: str,
        service_key: str,
        clock=time.time,
        http: Any = None,
    ):
        self._url = url.rstrip("/")
        self._service_key = service_key
        self._clock = clock
        self._http = http

    async def _request(self, method: str, path: str, *, json: Any = None, params: Any = None) -> Any:
        """Issue one HTTP call to the PostgREST API. Returns parsed JSON or None."""
        if self._http is not None:
            return await self._http(method, path, json=json, params=params)
        headers = {
            "apikey": self._service_key,
            "Authorization": f"Bearer {self._service_key}",
            "Content-Type": "application/json",
        }
        async with httpx.AsyncClient(timeout=10) as client:
            r = await client.request(
                method,
                f"{self._url}{path}",
                json=json,
                params=params,
                headers=headers,
            )
            r.raise_for_status()
            # HEAD / no-content responses return None; others return parsed JSON.
            if r.content:
                return r.json()
            return None

    async def record(self, kind: str, name: str | None) -> None:
        """Record a token/remove-token event. Best-effort: never raises on failure."""
        try:
            rtype, host = parse_runner_name(name)
            ts_iso = datetime.fromtimestamp(int(self._clock()), tz=timezone.utc).isoformat()
            await asyncio.gather(
                self._request(
                    "POST",
                    "/rest/v1/rpc/record_runner_event",
                    json={"p_dimension": "type", "p_key": rtype, "p_kind": kind, "p_ts": ts_iso},
                ),
                self._request(
                    "POST",
                    "/rest/v1/rpc/record_runner_event",
                    json={"p_dimension": "host", "p_key": host, "p_kind": kind, "p_ts": ts_iso},
                ),
            )
        except Exception:
            log.warning("supabase record failed for kind=%s name=%s", kind, name, exc_info=True)

    async def snapshot(self) -> dict:
        """Return aggregated counters from Supabase. Returns an error dict on any failure."""
        try:
            rows, meta_rows = await asyncio.gather(
                self._request(
                    "GET",
                    "/rest/v1/runner_stats",
                    params={"select": "dimension,key,kind,count,last_seen"},
                ),
                self._request(
                    "GET",
                    "/rest/v1/runner_stats_meta",
                    params={"select": "since", "id": "eq.1"},
                ),
            )

            rows = rows or []
            meta_rows = meta_rows or []

            by_type: dict[str, dict] = {}
            by_host: dict[str, dict] = {}

            for row in rows:
                dim = row.get("dimension")
                key = row.get("key", "unknown")
                kind = row.get("kind", "token")
                count = int(row.get("count", 0))
                last_seen = row.get("last_seen")  # already ISO from Postgres; pass through as-is

                if dim == "type":
                    target = by_type
                elif dim == "host":
                    target = by_host
                else:
                    continue

                e = target.setdefault(key, {"token": 0, "remove-token": 0, "last_seen": None})
                e[kind] = count
                e["last_seen"] = last_seen

            totals = {
                "token": sum(e["token"] for e in by_type.values()),
                "remove-token": sum(e["remove-token"] for e in by_type.values()),
            }

            since = meta_rows[0].get("since") if meta_rows else None

            return {
                "backend": self.backend,
                "durable": self.durable,
                "since": since,
                "totals": totals,
                "by_type": by_type,
                "by_host": by_host,
            }
        except Exception as e:
            return {"backend": self.backend, "durable": self.durable, "error": str(e)}


class RedisStatsStore:
    """Durable activity counter store backed by Upstash Redis REST API.

    Uses a five-key schema in Redis:
      ghr:count:type  — HASH of "<type>:<kind>" -> int (token / remove-token counts per runner type)
      ghr:count:host  — HASH of "<host>:<kind>" -> int (same, per host)
      ghr:last:type   — HASH of "<type>" -> epoch-second timestamp (most recent activity)
      ghr:last:host   — HASH of "<host>" -> epoch-second timestamp
      ghr:since       — STRING epoch-second of the first ever recorded event (set once via NX)

    All Redis I/O is pipelined to a single HTTP request via the Upstash REST /pipeline endpoint.
    Persistence is best-effort: record() swallows all errors rather than failing the hot path.

    `http` is an injectable async callable `(commands: list[list]) -> list` for tests; when None,
    real calls go to Upstash via httpx.
    """

    backend = "upstash-redis"
    durable = True

    def __init__(
        self,
        url: str,
        token: str,
        clock=time.time,
        http: Any = None,
    ):
        self._url = url.rstrip("/")
        self._token = token
        self._clock = clock
        self._http = http

    async def _pipeline(self, commands: list[list]) -> list:
        """Send a batch of Redis commands via Upstash REST /pipeline. Returns result values."""
        if self._http is not None:
            return await self._http(commands)
        async with httpx.AsyncClient(timeout=10) as client:
            r = await client.post(
                f"{self._url}/pipeline",
                json=commands,
                headers={"Authorization": f"Bearer {self._token}"},
            )
            r.raise_for_status()
            return [item.get("result") for item in r.json()]

    async def record(self, kind: str, name: str | None) -> None:
        """Record a token/remove-token event. Best-effort: never raises on failure."""
        try:
            rtype, host = parse_runner_name(name)
            ts = int(self._clock())
            await self._pipeline([
                ["HINCRBY", "ghr:count:type", f"{rtype}:{kind}", 1],
                ["HINCRBY", "ghr:count:host", f"{host}:{kind}", 1],
                ["HSET", "ghr:last:type", rtype, ts],
                ["HSET", "ghr:last:host", host, ts],
                ["SET", "ghr:since", ts, "NX"],
            ])
        except Exception:
            log.warning("redis record failed for kind=%s name=%s", kind, name, exc_info=True)

    async def snapshot(self) -> dict:
        """Return aggregated counters from Redis. Returns an error dict on any failure."""
        try:
            results = await self._pipeline([
                ["HGETALL", "ghr:count:type"],
                ["HGETALL", "ghr:count:host"],
                ["HGETALL", "ghr:last:type"],
                ["HGETALL", "ghr:last:host"],
                ["GET", "ghr:since"],
            ])
            count_type_raw, count_host_raw, last_type_raw, last_host_raw, since_raw = results

            def _flat_to_dict(flat: list | None) -> dict[str, str]:
                """Upstash returns HGETALL as a flat [field, value, field, value, ...] array."""
                if not flat:
                    return {}
                it = iter(flat)
                return {k: v for k, v in zip(it, it)}

            count_type = _flat_to_dict(count_type_raw)
            count_host = _flat_to_dict(count_host_raw)
            last_type = _flat_to_dict(last_type_raw)
            last_host = _flat_to_dict(last_host_raw)

            def _build_group(counts: dict[str, str], lasts: dict[str, str]) -> dict:
                """Accumulate counts by entity, overlay last_seen timestamps."""
                group: dict[str, dict] = {}
                for field, val in counts.items():
                    # field is "<entity>:<kind>"; kind is "token" or "remove-token"
                    # WHY: rsplit with maxsplit=1 so hyphenated kinds like "remove-token" split cleanly
                    entity, kind = field.rsplit(":", 1)
                    e = group.setdefault(entity, {"token": 0, "remove-token": 0, "last_seen": None})
                    e[kind] = int(val)
                for entity, ts_str in lasts.items():
                    if entity in group:
                        group[entity]["last_seen"] = _iso(float(ts_str))
                return group

            by_type = _build_group(count_type, last_type)
            by_host = _build_group(count_host, last_host)

            totals = {
                "token": sum(e["token"] for e in by_type.values()),
                "remove-token": sum(e["remove-token"] for e in by_type.values()),
            }

            since = _iso(float(since_raw)) if since_raw else None

            return {
                "backend": self.backend,
                "durable": self.durable,
                "since": since,
                "totals": totals,
                "by_type": by_type,
                "by_host": by_host,
            }
        except Exception as e:
            return {"backend": self.backend, "durable": self.durable, "error": str(e)}


# --- Backend selector factory ---
# STATS_BACKEND = "auto" | "memory" | "upstash" | "supabase" (default: "auto").
# "auto" prefers Upstash when configured; falls back to Supabase; then in-memory.
# Explicit values ("upstash"/"supabase") warn and fall back to memory if credentials are absent.
# The factory never raises on boot — a missing/misconfigured backend logs a warning and continues.

_upstash_url = os.environ.get("UPSTASH_REDIS_REST_URL")
_upstash_token = os.environ.get("UPSTASH_REDIS_REST_TOKEN")
_upstash_configured = bool(_upstash_url and _upstash_token)

# SUPABASE_SECRET_KEY is the new Supabase API key format (sb_secret_...); SUPABASE_SERVICE_KEY is
# the legacy service_role JWT alias. Both use the same apikey/Authorization header semantics.
# WHY prefer SUPABASE_SECRET_KEY: Supabase is migrating to the new key system; old service_role
# JWTs still work so we keep the legacy alias for backwards compatibility.
_supabase_service_key = os.environ.get("SUPABASE_SECRET_KEY") or os.environ.get("SUPABASE_SERVICE_KEY")
_supabase_url_env = os.environ.get("SUPABASE_URL")
_supabase_project_ref = os.environ.get("SUPABASE_PROJECT_REF")
if _supabase_url_env:
    _supabase_url = _supabase_url_env.rstrip("/")
elif _supabase_project_ref:
    _supabase_url = f"https://{_supabase_project_ref}.supabase.co"
else:
    _supabase_url = None
_supabase_configured = bool(_supabase_service_key and _supabase_url)

STATS_BACKEND = os.environ.get("STATS_BACKEND", "auto")


def _make_stats() -> RunnerStats | RedisStatsStore | SupabaseStatsStore:
    """Construct the appropriate stats store based on STATS_BACKEND and credential presence."""
    if STATS_BACKEND == "memory":
        return RunnerStats(RUNNER_STATS_WINDOW_SECONDS, RUNNER_STATS_MAX_EVENTS)

    if STATS_BACKEND == "upstash":
        if _upstash_configured:
            return RedisStatsStore(_upstash_url, _upstash_token)  # type: ignore[arg-type]
        log.warning("STATS_BACKEND=upstash but UPSTASH_REDIS_REST_URL/TOKEN not set; falling back to memory")
        return RunnerStats(RUNNER_STATS_WINDOW_SECONDS, RUNNER_STATS_MAX_EVENTS)

    if STATS_BACKEND == "supabase":
        if _supabase_configured:
            return SupabaseStatsStore(_supabase_url, _supabase_service_key)  # type: ignore[arg-type]
        log.warning("STATS_BACKEND=supabase but SUPABASE_SERVICE_KEY/URL not set; falling back to memory")
        return RunnerStats(RUNNER_STATS_WINDOW_SECONDS, RUNNER_STATS_MAX_EVENTS)

    # "auto": Upstash preferred, then Supabase, then in-memory.
    if _upstash_configured:
        return RedisStatsStore(_upstash_url, _upstash_token)  # type: ignore[arg-type]
    if _supabase_configured:
        return SupabaseStatsStore(_supabase_url, _supabase_service_key)  # type: ignore[arg-type]
    return RunnerStats(RUNNER_STATS_WINDOW_SECONDS, RUNNER_STATS_MAX_EVENTS)


_stats: RunnerStats | RedisStatsStore | SupabaseStatsStore = _make_stats()
log.info("stats backend: %s", _stats.backend)


def _persist(kind: str, name: str | None) -> None:
    """Fire-and-forget: schedule a background persistence task for a record() call.

    WHY: the hot path (/token, /remove-token) must not block on store I/O (Redis or Supabase).
    We schedule an asyncio.Task and keep a reference in _bg_tasks so the GC doesn't collect it
    mid-flight. record() implementations are best-effort and swallow their own exceptions.
    """
    t = asyncio.create_task(_stats.record(kind, name))
    _bg_tasks.add(t)
    t.add_done_callback(_bg_tasks.discard)


def _client_key(request: Request) -> str:
    """Identify the caller for rate limiting. Behind Render/most PaaS the real client IP is the
    first hop of X-Forwarded-For; fall back to the socket peer when there's no proxy."""
    xff = request.headers.get("x-forwarded-for")
    if xff:
        return xff.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def _rate_limit(request: Request) -> None:
    if _limiter is not None and not _limiter.allow(_client_key(request)):
        # Retry-After of one refill period is a safe, simple hint.
        retry = max(1, round(60 / RATE_LIMIT_PER_MINUTE))
        raise HTTPException(
            status_code=429, detail="rate limited", headers={"Retry-After": str(retry)}
        )


def _app_jwt() -> str:
    """A short-lived RS256 JWT identifying the App (GitHub caps exp at 10 minutes)."""
    now = int(time.time())
    return jwt.encode(
        {"iat": now - 60, "exp": now + 540, "iss": APP_ID}, PRIVATE_KEY, algorithm="RS256"
    )


async def _installation_token(client: httpx.AsyncClient) -> str:
    if _inst["token"] and _inst["exp"] - 120 > time.time():
        return _inst["token"]
    r = await client.post(
        f"{GITHUB_API}/app/installations/{INSTALLATION_ID}/access_tokens",
        headers={"Authorization": f"Bearer {_app_jwt()}", "Accept": "application/vnd.github+json"},
    )
    r.raise_for_status()
    _inst["token"] = r.json()["token"]
    _inst["exp"] = time.time() + 3000  # ~50 min; tokens are valid 60 min
    return _inst["token"]


def _check_auth(authorization: str | None) -> None:
    expected = f"Bearer {BROKER_SECRET}"
    if not authorization or not hmac.compare_digest(authorization, expected):
        raise HTTPException(status_code=401, detail="unauthorized")


async def _mint(kind: str) -> dict:
    """kind is 'registration-token' or 'remove-token'."""
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            tok = await _installation_token(client)
            r = await client.post(
                f"{GITHUB_API}/orgs/{ORG}/actions/runners/{kind}",
                headers={
                    "Authorization": f"Bearer {tok}",
                    "Accept": "application/vnd.github+json",
                    "X-GitHub-Api-Version": "2022-11-28",
                },
            )
            r.raise_for_status()
            return r.json()
    except httpx.HTTPError as e:
        log.error("github error minting %s: %s", kind, e)
        raise HTTPException(status_code=502, detail="github upstream error") from e


async def _list_runners(client: httpx.AsyncClient) -> list[dict]:
    """Fetch all org runners from GitHub, paginating until a short page.

    WHY: GitHub paginates at per_page=100; we loop until a page shorter than 100 is returned,
    which signals we have consumed all pages. Uses the cached installation token.
    """
    tok = await _installation_token(client)
    headers = {
        "Authorization": f"Bearer {tok}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    runners: list[dict] = []
    page = 1
    while True:
        r = await client.get(
            f"{GITHUB_API}/orgs/{ORG}/actions/runners",
            params={"per_page": 100, "page": page},
            headers=headers,
        )
        r.raise_for_status()
        batch = r.json().get("runners", [])
        runners.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    return runners


def _aggregate_fleet(runners: list[dict]) -> dict:
    """Group raw GitHub runner dicts into a fleet summary by type and host.

    Returns total/online/busy counts at fleet, type, and host level plus a sorted runner list.
    """
    by_type: dict[str, dict] = {}
    by_host: dict[str, dict] = {}
    runner_list: list[dict] = []

    def _group(table: dict, key: str) -> dict:
        return table.setdefault(key, {"total": 0, "online": 0, "busy": 0})

    for r in runners:
        name = r.get("name", "")
        rtype, host = parse_runner_name(name)
        online = r.get("status") == "online"
        busy = bool(r.get("busy"))
        labels = [lbl["name"] for lbl in r.get("labels", [])]

        for table, key in ((by_type, rtype), (by_host, host)):
            g = _group(table, key)
            g["total"] += 1
            if online:
                g["online"] += 1
            if busy:
                g["busy"] += 1

        runner_list.append({
            "name": name,
            "type": rtype,
            "host": host,
            "status": r.get("status", "unknown"),
            "busy": busy,
            "labels": labels,
        })

    runner_list.sort(key=lambda x: (x["type"], x["host"], x["name"]))

    total = len(runners)
    online_total = sum(1 for r in runners if r.get("status") == "online")
    busy_total = sum(1 for r in runners if r.get("busy"))

    return {
        "total": total,
        "online": online_total,
        "busy": busy_total,
        "by_type": by_type,
        "by_host": by_host,
        "runners": runner_list,
    }


@app.get("/health")
async def health() -> dict:
    return {"ok": True}


@app.post("/token")
async def token(
    request: Request,
    authorization: str | None = Header(default=None),
    x_runner_name: str | None = Header(default=None),
) -> dict:
    _rate_limit(request)
    _check_auth(authorization)
    d = await _mint("registration-token")
    _persist("token", x_runner_name)
    log.info("minted registration token for runner=%s", x_runner_name or "?")
    return {"token": d["token"], "expires_at": d["expires_at"], "url": f"https://github.com/{ORG}"}


@app.post("/remove-token")
async def remove_token(
    request: Request,
    authorization: str | None = Header(default=None),
    x_runner_name: str | None = Header(default=None),
) -> dict:
    _rate_limit(request)
    _check_auth(authorization)
    d = await _mint("remove-token")
    _persist("remove-token", x_runner_name)
    log.info("minted remove token for runner=%s", x_runner_name or "?")
    return {"token": d["token"], "expires_at": d["expires_at"]}


@app.get("/stats")
async def stats(
    request: Request,
    authorization: str | None = Header(default=None),
) -> dict:
    """Fleet view + activity counters. Auth-gated (exposes fleet topology) and rate-limited.

    Returns:
      fleet   — live runner state queried from GitHub (durable by construction; fails gracefully).
      activity — token/remove-token counters (durable when Upstash is configured, else in-memory).
    """
    _rate_limit(request)
    _check_auth(authorization)

    # Fleet query: one async client, errors surface as {"error": ...} without blocking activity.
    fleet: dict
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            fleet = _aggregate_fleet(await _list_runners(client))
    except httpx.HTTPError as e:
        fleet = {"error": f"github fleet query failed: {e}"}
    except Exception as e:
        fleet = {"error": f"github fleet query failed: {e}"}

    return {
        "generated_at": _iso(time.time()),
        "fleet": fleet,
        "activity": await _stats.snapshot(),
    }
