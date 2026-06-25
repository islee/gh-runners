"""Tests for the broker's HTTP surface (no GitHub calls) and the rate limiter.

Functional tests cover the open /health probe and the 401 auth gate. Minting itself calls the
GitHub API and would need a real App key + network, so it is out of scope. The RateLimiter is
unit-tested directly with a fake clock for determinism, plus one endpoint test proving the limit
runs ahead of auth (a throttled request returns 429, not 401).

RunnerStats and RedisStatsStore both implement the async store interface; their async methods are
driven via asyncio.run() in sync tests (no pytest-asyncio dependency).
"""

import asyncio

import app as appmod
from app import (
    RateLimiter,
    RedisStatsStore,
    RunnerStats,
    SupabaseStatsStore,
    app,
    parse_runner_name,
)
from fastapi.testclient import TestClient

client = TestClient(app)


# --- functional HTTP surface ---------------------------------------------------------------------


def test_health_is_open_and_ok():
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"ok": True}


def test_token_without_auth_is_401():
    assert client.post("/token").status_code == 401


def test_token_with_wrong_secret_is_401():
    r = client.post("/token", headers={"Authorization": "Bearer nope"})
    assert r.status_code == 401


def test_remove_token_without_auth_is_401():
    assert client.post("/remove-token").status_code == 401


# --- rate limiter --------------------------------------------------------------------------------


class FakeClock:
    """Deterministic monotonic clock for limiter tests."""

    def __init__(self) -> None:
        self.t = 0.0

    def __call__(self) -> float:
        return self.t

    def advance(self, dt: float) -> None:
        self.t += dt


def test_limiter_allows_burst_then_blocks():
    rl = RateLimiter(rate_per_min=60, burst=3, clock=FakeClock())
    assert [rl.allow("ip") for _ in range(4)] == [True, True, True, False]


def test_limiter_refills_over_time():
    clk = FakeClock()
    rl = RateLimiter(rate_per_min=60, burst=1, clock=clk)  # 1 token/sec
    assert rl.allow("ip") is True
    assert rl.allow("ip") is False
    clk.advance(1.0)  # one token refilled
    assert rl.allow("ip") is True


def test_limiter_keys_are_independent():
    rl = RateLimiter(rate_per_min=60, burst=1, clock=FakeClock())
    assert rl.allow("a") is True
    assert rl.allow("a") is False
    assert rl.allow("b") is True  # separate bucket per key


def test_endpoint_returns_429_when_limited(monkeypatch):
    # burst=2: first two requests pass the limiter (then 401 on auth); the third is throttled.
    monkeypatch.setattr(
        appmod, "_limiter", RateLimiter(rate_per_min=60, burst=2, clock=FakeClock())
    )
    monkeypatch.setattr(appmod, "RATE_LIMIT_PER_MINUTE", 60)
    assert client.post("/token").status_code == 401
    assert client.post("/token").status_code == 401
    r = client.post("/token")
    assert r.status_code == 429
    assert "Retry-After" in r.headers


# --- runner-name parsing -------------------------------------------------------------------------


def test_parse_runner_name_extracts_type_and_hyphenated_host():
    assert parse_runner_name("gh-runner-light-my-host-1") == ("light", "my-host")
    assert parse_runner_name("gh-runner-supabase-my-host-1") == ("supabase", "my-host")
    assert parse_runner_name("gh-runner-android-mymac-2") == ("android", "mymac")


def test_parse_runner_name_falls_back_on_unknown_shapes():
    assert parse_runner_name(None) == ("unknown", "unknown")
    assert parse_runner_name("") == ("unknown", "unknown")
    assert parse_runner_name("weird-name") == ("unknown", "weird-name")


# --- in-memory stats (async interface) -----------------------------------------------------------


def test_stats_aggregate_by_type_host_and_runner():
    clk = FakeClock()
    clk.t = 1000.0
    s = RunnerStats(window_s=100, max_events=100, clock=clk)
    asyncio.run(s.record("token", "gh-runner-light-my-host-1"))
    asyncio.run(s.record("token", "gh-runner-light-my-host-1"))
    asyncio.run(s.record("token", "gh-runner-light-my-host-2"))
    asyncio.run(s.record("remove-token", "gh-runner-supabase-my-host-1"))
    snap = asyncio.run(s.snapshot())

    assert snap["totals"] == {"token": 3, "remove-token": 1}
    assert snap["by_type"]["light"]["token"] == 3
    assert snap["by_type"]["light"]["runners"] == 2  # two distinct light runners
    assert snap["by_type"]["supabase"]["remove-token"] == 1
    assert snap["by_host"]["my-host"]["token"] == 3
    assert {r["name"] for r in snap["runners"]} == {
        "gh-runner-light-my-host-1",
        "gh-runner-light-my-host-2",
        "gh-runner-supabase-my-host-1",
    }


def test_stats_prunes_events_outside_window():
    clk = FakeClock()
    clk.t = 1000.0
    s = RunnerStats(window_s=100, max_events=100, clock=clk)
    asyncio.run(s.record("token", "gh-runner-light-host-1"))
    clk.advance(101)  # first event now falls outside the 100s window
    asyncio.run(s.record("token", "gh-runner-light-host-2"))
    snap = asyncio.run(s.snapshot())
    assert snap["total_events"] == 1
    assert snap["by_type"]["light"]["runners"] == 1


def test_stats_snapshot_includes_backend_fields():
    s = RunnerStats(window_s=100, max_events=100)
    snap = asyncio.run(s.snapshot())
    assert snap["backend"] == "memory"
    assert snap["durable"] is False


# --- RedisStatsStore tests -----------------------------------------------------------------------


class FakeRedisHttp:
    """Injectable fake for RedisStatsStore._pipeline. Captures commands, returns canned results."""

    def __init__(self, results: list):
        self.captured: list[list] = []
        self._results = results

    async def __call__(self, commands: list[list]) -> list:
        self.captured = commands
        return self._results


def test_redis_store_record_emits_correct_commands():
    fake = FakeRedisHttp(results=[1, 1, 0, 0, None])  # HINCRBY/HSET/SET return values (ignored)
    store = RedisStatsStore(url="https://redis.example.com", token="tok", http=fake)
    asyncio.run(store.record("token", "gh-runner-light-my-host-1"))

    cmds = fake.captured
    # Must include HINCRBY on ghr:count:type for "light:token"
    assert any(
        c[0] == "HINCRBY" and c[1] == "ghr:count:type" and c[2] == "light:token" for c in cmds
    ), f"missing HINCRBY ghr:count:type light:token in {cmds}"
    # Must include HINCRBY on ghr:count:host for "my-host:token"
    assert any(
        c[0] == "HINCRBY" and c[1] == "ghr:count:host" and c[2] == "my-host:token" for c in cmds
    ), f"missing HINCRBY ghr:count:host my-host:token in {cmds}"
    # Must include HSET on ghr:last:type for "light"
    assert any(
        c[0] == "HSET" and c[1] == "ghr:last:type" and c[2] == "light" for c in cmds
    ), f"missing HSET ghr:last:type light in {cmds}"
    # Must include HSET on ghr:last:host for "my-host"
    assert any(
        c[0] == "HSET" and c[1] == "ghr:last:host" and c[2] == "my-host" for c in cmds
    ), f"missing HSET ghr:last:host my-host in {cmds}"
    # Must include SET ghr:since ... NX
    assert any(
        c[0] == "SET" and c[1] == "ghr:since" and c[-1] == "NX" for c in cmds
    ), f"missing SET ghr:since NX in {cmds}"


def test_redis_store_snapshot_parses_pipeline_response():
    # Canned flat HGETALL responses from Upstash ([field, value, field, value, ...])
    # and a since value. Simulates two runner types: light (5 tokens) and supabase (1 remove-token).
    count_type_flat = ["light:token", "5", "supabase:remove-token", "1"]
    count_host_flat = ["my-host:token", "5", "my-host:remove-token", "1"]
    last_type_flat = ["light", "1700000000", "supabase", "1700000100"]
    last_host_flat = ["my-host", "1700000100"]
    since_val = "1699999999"

    fake = FakeRedisHttp(
        results=[
            count_type_flat,
            count_host_flat,
            last_type_flat,
            last_host_flat,
            since_val,
        ]
    )
    store = RedisStatsStore(url="https://redis.example.com", token="tok", http=fake)
    snap = asyncio.run(store.snapshot())

    assert snap["backend"] == "upstash-redis"
    assert snap["durable"] is True
    assert snap["totals"]["token"] == 5
    assert snap["totals"]["remove-token"] == 1
    assert snap["by_type"]["light"]["token"] == 5
    assert snap["by_type"]["light"]["remove-token"] == 0
    assert snap["by_type"]["supabase"]["remove-token"] == 1
    assert snap["by_host"]["my-host"]["token"] == 5
    assert snap["by_host"]["my-host"]["remove-token"] == 1
    assert snap["since"] is not None  # ISO string from since_val


def test_redis_store_record_swallows_errors():
    """record() must not raise even when the http callable raises."""

    async def bad_http(commands):
        raise RuntimeError("connection refused")

    store = RedisStatsStore(url="https://redis.example.com", token="tok", http=bad_http)
    # Must not raise
    asyncio.run(store.record("token", "gh-runner-light-my-host-1"))


# --- SupabaseStatsStore tests --------------------------------------------------------------------


class FakeSupabaseHttp:
    """Injectable fake for SupabaseStatsStore._request. Captures calls, returns canned data."""

    def __init__(self, responses: dict | None = None):
        # responses maps path -> return value; unmatched paths return None
        self.calls: list[tuple[str, str, dict]] = []  # (method, path, kwargs)
        self._responses = responses or {}

    async def __call__(self, method: str, path: str, *, json=None, params=None) -> object:
        self.calls.append((method, path, {"json": json, "params": params}))
        return self._responses.get(path)


def test_supabase_store_record_issues_two_rpc_calls():
    fake = FakeSupabaseHttp(responses={"/rest/v1/rpc/record_runner_event": None})
    store = SupabaseStatsStore(url="https://proj.supabase.co", service_key="svckey", http=fake)
    asyncio.run(store.record("token", "gh-runner-light-my-host-1"))

    rpc_calls = [c for c in fake.calls if c[1] == "/rest/v1/rpc/record_runner_event"]
    assert len(rpc_calls) == 2, f"expected 2 RPC calls, got {len(rpc_calls)}: {rpc_calls}"

    dims = {c[2]["json"]["p_dimension"] for c in rpc_calls}
    assert dims == {"type", "host"}, f"unexpected dimensions: {dims}"

    type_call = next(c for c in rpc_calls if c[2]["json"]["p_dimension"] == "type")
    host_call = next(c for c in rpc_calls if c[2]["json"]["p_dimension"] == "host")

    assert type_call[2]["json"]["p_key"] == "light"
    assert type_call[2]["json"]["p_kind"] == "token"
    assert host_call[2]["json"]["p_key"] == "my-host"
    assert host_call[2]["json"]["p_kind"] == "token"


def test_supabase_store_snapshot_parses_rows():
    # Canned PostgREST row responses: two type rows + two host rows, plus meta.
    stats_rows = [
        {
            "dimension": "type",
            "key": "light",
            "kind": "token",
            "count": 5,
            "last_seen": "2026-06-25T08:00:00+00:00",
        },
        {
            "dimension": "type",
            "key": "supabase",
            "kind": "remove-token",
            "count": 1,
            "last_seen": "2026-06-25T09:00:00+00:00",
        },
        {
            "dimension": "host",
            "key": "my-host",
            "kind": "token",
            "count": 5,
            "last_seen": "2026-06-25T08:00:00+00:00",
        },
        {
            "dimension": "host",
            "key": "my-host",
            "kind": "remove-token",
            "count": 1,
            "last_seen": "2026-06-25T09:00:00+00:00",
        },
    ]
    meta_rows = [{"since": "2026-06-01T00:00:00+00:00"}]

    fake = FakeSupabaseHttp(
        responses={
            "/rest/v1/runner_stats": stats_rows,
            "/rest/v1/runner_stats_meta": meta_rows,
        }
    )
    store = SupabaseStatsStore(url="https://proj.supabase.co", service_key="svckey", http=fake)
    snap = asyncio.run(store.snapshot())

    assert snap["backend"] == "supabase"
    assert snap["durable"] is True
    assert snap["totals"]["token"] == 5
    assert snap["totals"]["remove-token"] == 1
    assert snap["by_type"]["light"]["token"] == 5
    assert snap["by_type"]["light"]["remove-token"] == 0
    assert snap["by_type"]["supabase"]["remove-token"] == 1
    assert snap["by_host"]["my-host"]["token"] == 5
    assert snap["by_host"]["my-host"]["remove-token"] == 1
    assert snap["since"] == "2026-06-01T00:00:00+00:00"


def test_supabase_store_record_swallows_errors():
    """record() must not raise even when the http callable raises."""

    async def bad_http(method, path, *, json=None, params=None):
        raise RuntimeError("network error")

    store = SupabaseStatsStore(url="https://proj.supabase.co", service_key="svckey", http=bad_http)
    asyncio.run(store.record("token", "gh-runner-light-my-host-1"))


def test_selector_defaults_to_memory_when_no_creds():
    """Without Upstash or Supabase credentials the module-level _stats is an in-memory store."""
    # The test environment has no UPSTASH_* or SUPABASE_* vars set, so the factory chose memory.
    assert appmod._stats.backend == "memory"


# --- stats endpoint ------------------------------------------------------------------------------


def test_stats_endpoint_requires_auth():
    assert client.get("/stats").status_code == 401
    assert client.get("/stats", headers={"Authorization": "Bearer nope"}).status_code == 401


def test_stats_endpoint_returns_snapshot_with_auth():
    # The endpoint will attempt a real GitHub fleet call and fail (no network/key in CI).
    # That's fine: fleet should be {"error": ...}. We only assert the envelope shape is correct.
    r = client.get("/stats", headers={"Authorization": "Bearer test-broker-secret"})
    assert r.status_code == 200
    body = r.json()
    assert "generated_at" in body
    assert "fleet" in body
    assert "activity" in body
