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

import collections
import hmac
import logging
import os
import time
from datetime import datetime, timezone

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
# been active lately — without any datastore. State is in-process and time-windowed; it resets on
# restart / Render cold start, so treat it as "recent activity", not durable accounting.
RUNNER_STATS_WINDOW_SECONDS = int(os.environ.get("RUNNER_STATS_WINDOW_SECONDS", "86400"))
RUNNER_STATS_MAX_EVENTS = int(os.environ.get("RUNNER_STATS_MAX_EVENTS", "10000"))


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

    `<id>` (the host/owner tag) may itself contain hyphens (e.g. `ci-linple`); `<n>` is always the
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
    is injectable for testing. Single-process / single-worker only (matching the broker's design)."""

    def __init__(self, window_s: int, max_events: int, clock=time.time):
        self.window = window_s
        self._clock = clock
        self._events: collections.deque = collections.deque(maxlen=max_events)

    def record(self, kind: str, name: str | None) -> None:
        rtype, host = parse_runner_name(name)
        self._events.append((self._clock(), kind, name or "?", rtype, host))

    def _prune(self, now: float) -> None:
        cutoff = now - self.window
        while self._events and self._events[0][0] < cutoff:
            self._events.popleft()

    def snapshot(self) -> dict:
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
            "window_seconds": self.window,
            "generated_at": _iso(now),
            "total_events": len(self._events),
            "totals": totals,
            "by_type": _fmt_group(by_type),
            "by_host": _fmt_group(by_host),
            "runners": runners,
        }


_stats = RunnerStats(RUNNER_STATS_WINDOW_SECONDS, RUNNER_STATS_MAX_EVENTS)


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
    _stats.record("token", x_runner_name)
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
    _stats.record("remove-token", x_runner_name)
    log.info("minted remove token for runner=%s", x_runner_name or "?")
    return {"token": d["token"], "expires_at": d["expires_at"]}


@app.get("/stats")
async def stats(
    request: Request,
    authorization: str | None = Header(default=None),
) -> dict:
    """Recent token activity aggregated by runner type, host, and name. Auth-gated (it exposes fleet
    topology) and rate-limited, same as the token endpoints. In-process window; resets on restart."""
    _rate_limit(request)
    _check_auth(authorization)
    return _stats.snapshot()
