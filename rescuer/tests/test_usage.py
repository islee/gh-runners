"""Offline tests for rescuer/usage.py: a fake GitHub client records calls; no network."""

import sys
import urllib.error
import email.message
from datetime import date
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import usage  # noqa: E402

TODAY = date(2026, 10, 20)


def jb(
    jid,
    secs=60,
    labels=("ghr-light",),
    runner="r1",
    run_id=1,
    attempt=1,
    day="2026-10-19",
):
    """A job finishing `secs` after starting (None = never started)."""
    started = None if secs is None else f"{day}T10:00:00Z"
    ended = None
    if secs is not None:
        ended = (
            f"{day}T{10 + secs // 3600:02d}:{secs % 3600 // 60:02d}:{secs % 60:02d}Z"
        )
    return {
        "id": jid,
        "run_id": run_id,
        "run_attempt": attempt,
        "workflow_name": "ci",
        "name": f"job{jid}",
        "labels": list(labels),
        "runner_name": runner,
        "started_at": started,
        "completed_at": ended,
        "conclusion": "success",
    }


class FakeGH:
    """runs: {(repo, 'YYYY-MM-DD'): [run, ...]}; jobs: {run_id: [job, ...]}; errors: {fragment: code}."""

    def __init__(self, runs=None, jobs=None, repos=("o/a",), errors=None):
        self.runs, self.jobs, self.repos = runs or {}, jobs or {}, list(repos)
        self.errors = errors or {}
        self.calls = []

    def api(self, method, path):
        self.calls.append((method, path))
        for frag, code in self.errors.items():
            if frag in path:
                raise urllib.error.HTTPError(
                    path, code, "x", email.message.Message(), None
                )
        if path.startswith("/installation/repositories"):
            return {"repositories": [{"full_name": r} for r in self.repos]}
        if "/jobs?" in path:
            run_id = int(path.split("/runs/")[1].split("/")[0])
            return {"jobs": self.jobs.get(run_id, [])}
        if "/actions/runs?" in path:
            repo = path.split("/repos/")[1].split("/actions")[0]
            day = path.split("created=")[1].split("&")[0]
            return {"workflow_runs": self.runs.get((repo, day), [])}
        raise AssertionError(f"unexpected call {method} {path}")

    def days(self, repo="o/a"):
        return [
            p.split("created=")[1].split("&")[0]
            for _, p in self.calls
            if f"/repos/{repo}/actions/runs?" in p
        ]


def cfg(**kw):
    base = {
        "prefix": "ghr-",
        "since": date(2026, 10, 19),
        "lookback_days": 7,
        "rate": 0.006,
        "included": 2000,
    }
    base.update(kw)
    return base


@pytest.fixture
def db(tmp_path):
    return usage.open_db(str(tmp_path / "usage.sqlite"))


def collect(gh, db, **kw):
    return usage.collect_once(gh, db, cfg(**kw), today=TODAY)


def minutes(db, kind=None):
    q = "SELECT COALESCE(SUM(billable_min),0) FROM jobs"
    if kind:
        return db.execute(q + " WHERE kind=?", (kind,)).fetchone()[0]
    return db.execute(q).fetchone()[0]


# ── billable_minutes / classify ──────────────────────────────────────────────


@pytest.mark.parametrize(
    "secs,want", [(0, 0), (3, 1), (60, 1), (61, 2), (21, 1), (80, 2), (69, 2)]
)
def test_billable_minutes_rounds_up_per_job(secs, want):
    assert usage.billable_minutes(jb(1, secs)) == want


def test_billable_minutes_missing_timestamps_is_zero():
    j = jb(1, 90)
    assert usage.billable_minutes({**j, "started_at": None}) == 0
    assert usage.billable_minutes({**j, "completed_at": None}) == 0
    assert usage.billable_minutes({}) == 0


def test_github_example_bills_six_minutes_not_two():
    assert (
        sum(usage.billable_minutes(jb(i, s)) for i, s in enumerate((21, 80, 69, 3)))
        == 6
    )


def test_classify():
    assert usage.classify(jb(1), "ghr-") == "pool"
    assert usage.classify(jb(1, labels=("GHR-Supabase",)), "ghr-") == "pool"
    assert usage.classify(jb(1, labels=("ubuntu-latest",)), "ghr-") == "hosted"
    assert usage.classify(jb(1, runner=None), "ghr-") == "none"
    assert (
        usage.classify(jb(1, runner=None, labels=("ubuntu-latest",)), "ghr-") == "none"
    )


def test_job_without_runner_is_stored_with_zero_minutes(db):
    gh = FakeGH(
        runs={("o/a", "2026-10-19"): [{"id": 1}]}, jobs={1: [jb(5, 600, runner=None)]}
    )
    collect(gh, db)
    assert db.execute("SELECT kind, billable_min FROM jobs").fetchall() == [("none", 0)]


# ── collection ───────────────────────────────────────────────────────────────


def test_only_get_calls():
    gh = FakeGH(runs={("o/a", "2026-10-19"): [{"id": 1}]}, jobs={1: [jb(5)]})
    collect(gh, usage.open_db(":memory:"))
    assert gh.calls and {m for m, _ in gh.calls} == {"GET"}


def test_two_passes_do_not_double_count(db):
    gh = FakeGH(
        runs={("o/a", "2026-10-19"): [{"id": 1}]},
        jobs={1: [jb(5, 61), jb(6, 10, labels=("ubuntu-latest",))]},
    )
    assert collect(gh, db) == (1, 0)
    jobs_calls = len([p for _, p in gh.calls if "/jobs?" in p])
    assert collect(gh, db) == (0, 0)
    assert len([p for _, p in gh.calls if "/jobs?" in p]) == jobs_calls
    assert (minutes(db, "pool"), minutes(db, "hosted")) == (2, 1)


def test_new_run_attempt_is_ingested(db):
    gh = FakeGH(
        runs={("o/a", "2026-10-19"): [{"id": 1, "run_attempt": 1}]},
        jobs={1: [jb(5, 60, attempt=1)]},
    )
    collect(gh, db)
    gh.runs[("o/a", "2026-10-19")] = [{"id": 1, "run_attempt": 2}]
    gh.jobs[1] = [jb(5, 60, attempt=1), jb(9, 120, attempt=2)]
    assert collect(gh, db) == (1, 0)
    assert db.execute("SELECT COUNT(*) FROM jobs").fetchone()[0] == 2
    assert minutes(db) == 3


def test_windowing_one_query_per_day_and_lookback_base(db):
    gh = FakeGH()
    collect(gh, db, since=date(2026, 10, 18))
    assert gh.days() == ["2026-10-18", "2026-10-19", "2026-10-20"]
    # Next pass starts lookback days before the last clean day (TODAY), not at USAGE_SINCE.
    gh = FakeGH()
    collect(gh, db, lookback_days=2, since=date(2026, 10, 1))
    assert gh.days() == ["2026-10-18", "2026-10-19", "2026-10-20"]
    # USAGE_SINCE still bounds the window from below.
    gh = FakeGH()
    collect(gh, db, lookback_days=5, since=date(2026, 10, 19))
    assert gh.days() == ["2026-10-19", "2026-10-20"]


def test_empty_ledger_requires_since(db):
    with pytest.raises(SystemExit):
        collect(FakeGH(), db, since=None)


def test_scope_is_every_installation_repo(db):
    gh = FakeGH(repos=("o/a", "o/b"))
    collect(gh, db)
    assert gh.days("o/a") and gh.days("o/b")


def test_one_repo_erroring_does_not_stop_the_others(db):
    gh = FakeGH(
        repos=("o/a", "o/b"),
        runs={("o/b", "2026-10-19"): [{"id": 2}]},
        jobs={2: [jb(7, 60, run_id=2)]},
        errors={"/repos/o/a/": 500},
    )
    ingested, errors = collect(gh, db)
    assert ingested == 1 and errors > 0
    assert minutes(db) == 1
    # An unclean pass does not advance the base day.
    assert db.execute("SELECT 1 FROM meta").fetchone() is None


def test_failing_run_is_retried_next_pass(db):
    gh = FakeGH(
        runs={("o/a", "2026-10-19"): [{"id": 1}]},
        jobs={1: [jb(5, 60)]},
        errors={"/runs/1/jobs": 502},
    )
    assert collect(gh, db) == (0, 1)
    gh.errors = {}
    assert collect(gh, db) == (1, 0)


def test_listing_repos_failure_counts_as_error(db):
    assert collect(FakeGH(errors={"/installation/": 401}), db) == (0, 1)


# ── report ───────────────────────────────────────────────────────────────────


def seed(db, rows):
    """rows: (month, kind, labels, minutes)."""
    import json

    for i, (m, kind, labels, mins) in enumerate(rows):
        db.execute(
            "INSERT INTO jobs VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (
                i,
                "o/a",
                i,
                1,
                "ci",
                "j",
                json.dumps(labels),
                "r",
                f"{m}-05T10:00:00Z",
                None,
                "success",
                kind,
                mins,
            ),
        )
    db.commit()


def test_free_plan_saving_across_the_boundary():
    assert usage.free_plan_saving(1000, 1500, 2000, 0.006) == pytest.approx(3.0)
    # Fully under the free tier: pool minutes cost nothing extra.
    assert usage.free_plan_saving(100, 100, 2000, 0.006) == 0
    # Hosted alone already over: every pool minute would have been billed.
    assert usage.free_plan_saving(1000, 2500, 2000, 0.006) == pytest.approx(6.0)


def test_report_columns_and_month_filter(db):
    seed(
        db,
        [
            ("2026-10", "hosted", ["ubuntu-latest"], 1500),
            ("2026-10", "pool", ["ghr-light"], 600),
            ("2026-10", "pool", ["GHR-Supabase"], 400),
            ("2026-09", "pool", ["ghr-light"], 50),
        ],
    )
    out = usage.report(db, "2026-10", cfg())
    row = next(ln for ln in out.splitlines() if ln.startswith("2026-10"))
    assert row.split() == ["2026-10", "1000", "1500", "2", "1", "6.00", "3.00"]
    assert "ghr-light: 600 min" in out and "ghr-supabase: 400 min" in out
    assert "2026-09" not in out
    assert "rounded per job" in out and "proxy" in out
    assert "2026-09" in usage.report(db, None, cfg())


def test_report_empty(db):
    assert "no pool/hosted jobs" in usage.report(db, "2026-10", cfg())


def test_report_cli_needs_no_app_env(tmp_path, monkeypatch, capsys):
    path = str(tmp_path / "u.sqlite")
    seed(usage.open_db(path), [("2026-10", "pool", ["ghr-light"], 10)])
    for k in ("RESCUER_APP_ID", "RESCUER_INSTALLATION_ID", "RESCUER_APP_KEY"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("USAGE_DB", path)
    assert usage.main(["--report", "2026-10"]) == 0
    assert "2026-10" in capsys.readouterr().out
    assert usage.main(["--report"]) == 0


def test_report_rejects_bad_month_and_missing_db(tmp_path, monkeypatch):
    monkeypatch.setenv("USAGE_DB", str(tmp_path / "none.sqlite"))
    with pytest.raises(SystemExit):
        usage.main(["--report", "2026-13"])
    with pytest.raises(SystemExit):
        usage.main(["--report"])


# ── config / main / healthcheck ──────────────────────────────────────────────

APP = {"RESCUER_APP_ID": "123", "RESCUER_INSTALLATION_ID": "456"}


def test_config_defaults_ignore_repos():
    c = usage.load_config({**APP, "REPOS": "o/a"})
    assert (c["prefix"], c["db"], c["since"], c["lookback_days"], c["interval"]) == (
        "ghr-",
        "/data/usage.sqlite",
        None,
        7,
        3600,
    )
    assert (c["rate"], c["included"], c["heartbeat_file"]) == (
        0.006,
        2000,
        "/tmp/usage.last-ok",
    )
    assert "repos" not in c


@pytest.mark.parametrize(
    "env",
    [
        {},
        {**APP, "USAGE_SINCE": "16-10-2026"},
        {**APP, "LABEL_PREFIX": ""},
        {**APP, "USAGE_LOOKBACK_DAYS": "-1"},
        {**APP, "RATE_PER_MIN": "abc"},
        {**APP, "USAGE_INTERVAL_SEC": "-5"},
    ],
)
def test_config_rejects_bad_input(env):
    with pytest.raises(SystemExit):
        usage.load_config(env)


@pytest.mark.parametrize("errors,fresh", [(0, True), (1, False)])
def test_main_once_heartbeat_only_on_clean_pass(monkeypatch, tmp_path, errors, fresh):
    hb = tmp_path / "hb"
    monkeypatch.setattr(usage.rescue, "GitHub", lambda *a: object())
    monkeypatch.setattr(usage, "collect_once", lambda *a, **k: (0, errors))
    for k, v in {
        **APP,
        "USAGE_DB": str(tmp_path / "u.sqlite"),
        "HEARTBEAT_FILE": str(hb),
        "USAGE_SINCE": "2026-10-16",
    }.items():
        monkeypatch.setenv(k, v)
    assert usage.main(["--once"]) == (1 if errors else 0)
    assert hb.exists() == fresh


def test_healthcheck_uses_usage_env(tmp_path):
    hb = tmp_path / "hb"
    hb.write_text("1\n")
    mtime = hb.stat().st_mtime
    env = {"USAGE_INTERVAL_SEC": "3600", "HEARTBEAT_FILE": str(hb), "INTERVAL_SEC": "1"}
    assert usage.healthcheck(env, now=mtime + 3 * 3600 - 1) == 0
    assert usage.healthcheck(env, now=mtime + 3 * 3600 + 1) == 1
    assert usage.healthcheck({"HEARTBEAT_FILE": str(tmp_path / "missing")}) == 1
