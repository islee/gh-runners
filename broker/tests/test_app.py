"""Tests for the broker's HTTP surface (no GitHub calls) and the rate limiter.

Functional tests cover the open /health probe and the 401 auth gate. Minting itself calls the
GitHub API and would need a real App key + network, so it is out of scope. The RateLimiter is
unit-tested directly with a fake clock for determinism, plus one endpoint test proving the limit
runs ahead of auth (a throttled request returns 429, not 401).
"""

import app as appmod
from app import RateLimiter, RunnerStats, app, parse_runner_name
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
    assert parse_runner_name("gh-runner-light-ci-linple-1") == ("light", "ci-linple")
    assert parse_runner_name("gh-runner-supabase-ci-linple-1") == ("supabase", "ci-linple")
    assert parse_runner_name("gh-runner-android-mymac-2") == ("android", "mymac")


def test_parse_runner_name_falls_back_on_unknown_shapes():
    assert parse_runner_name(None) == ("unknown", "unknown")
    assert parse_runner_name("") == ("unknown", "unknown")
    assert parse_runner_name("weird-name") == ("unknown", "weird-name")


# --- recent-activity stats -----------------------------------------------------------------------


def test_stats_aggregate_by_type_host_and_runner():
    clk = FakeClock()
    clk.t = 1000.0
    s = RunnerStats(window_s=100, max_events=100, clock=clk)
    s.record("token", "gh-runner-light-ci-linple-1")
    s.record("token", "gh-runner-light-ci-linple-1")
    s.record("token", "gh-runner-light-ci-linple-2")
    s.record("remove-token", "gh-runner-supabase-ci-linple-1")
    snap = s.snapshot()

    assert snap["totals"] == {"token": 3, "remove-token": 1}
    assert snap["by_type"]["light"]["token"] == 3
    assert snap["by_type"]["light"]["runners"] == 2  # two distinct light runners
    assert snap["by_type"]["supabase"]["remove-token"] == 1
    assert snap["by_host"]["ci-linple"]["token"] == 3
    assert {r["name"] for r in snap["runners"]} == {
        "gh-runner-light-ci-linple-1",
        "gh-runner-light-ci-linple-2",
        "gh-runner-supabase-ci-linple-1",
    }


def test_stats_prunes_events_outside_window():
    clk = FakeClock()
    clk.t = 1000.0
    s = RunnerStats(window_s=100, max_events=100, clock=clk)
    s.record("token", "gh-runner-light-host-1")
    clk.advance(101)  # first event now falls outside the 100s window
    s.record("token", "gh-runner-light-host-2")
    snap = s.snapshot()
    assert snap["total_events"] == 1
    assert snap["by_type"]["light"]["runners"] == 1


def test_stats_endpoint_requires_auth():
    assert client.get("/stats").status_code == 401
    assert client.get("/stats", headers={"Authorization": "Bearer nope"}).status_code == 401


def test_stats_endpoint_returns_snapshot_with_auth():
    r = client.get("/stats", headers={"Authorization": "Bearer test-broker-secret"})
    assert r.status_code == 200
    body = r.json()
    assert {"window_seconds", "totals", "by_type", "by_host", "runners"} <= body.keys()
