"""Offline tests for rescuer/rescue.py: a fake GitHub client records calls; no network."""

import base64
import email.message
import json
import subprocess
import sys
import urllib.error
from datetime import datetime, timezone
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import rescue  # noqa: E402

NOW = datetime(2026, 10, 16, 12, 0, tzinfo=timezone.utc)


def iso(minutes_ago):
    t = NOW.timestamp() - minutes_ago * 60
    return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def job(name, status="queued", labels=("ghr-light",), minutes_ago=20, started_ago=None):
    j = {
        "name": name,
        "status": status,
        "labels": list(labels),
        "created_at": iso(minutes_ago),
    }
    j["started_at"] = iso(started_ago) if started_ago is not None else None
    return j


class FakeGH:
    """runs: {repo: {status: [run, ...]}}; jobs: {run_id: [job, ...]}.

    run_states: sequence of (status, conclusion) returned by GET run (last one repeats).
    errors: {substring-of-path: http code} raised for matching calls.
    """

    def __init__(self, runs=None, jobs=None, repos=None, run_states=None, errors=None):
        self.runs, self.jobs, self.repos = runs or {}, jobs or {}, repos or []
        self.run_states = list(run_states or [("completed", "cancelled")])
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
        if method == "POST":
            return {}
        if "/jobs?" in path:
            run_id = int(path.split("/runs/")[1].split("/")[0])
            return {"jobs": self.jobs.get(run_id, [])}
        if "/actions/runs?status=" in path:
            repo = path.split("/repos/")[1].split("/actions")[0]
            status = path.split("status=")[1].split("&")[0]
            return {"workflow_runs": self.runs.get(repo, {}).get(status, [])}
        if "/actions/runs/" in path:
            st = (
                self.run_states.pop(0)
                if len(self.run_states) > 1
                else self.run_states[0]
            )
            return {"status": st[0], "conclusion": st[1]}
        raise AssertionError(f"unexpected call {method} {path}")

    def posts(self):
        return [p for m, p in self.calls if m == "POST"]


def cfg(**kw):
    base = {
        "repos": ["o/a"],
        "prefix": "ghr-",
        "max_wait_s": 15 * 60,
        "max_attempts": 3,
    }
    base["dry_run"] = False
    base.update(kw)
    return base


def no_sleep(_):
    pass


def scan(gh, pending=None, **kw):
    return rescue.scan_once(
        gh, cfg(**kw), {} if pending is None else pending, now=NOW, sleep=no_sleep
    )


# ── stranded_jobs / live_labels ──────────────────────────────────────────────


def test_stranded_only_queued_prefixed_and_old():
    jobs = [
        job("old-ghr"),
        job("young-ghr", minutes_ago=5),
        job("hosted", labels=("ubuntu-latest",)),
        job("running", status="in_progress"),
        job("no-labels", labels=()),
        job("upper", labels=("GHR-Light",)),
    ]
    out = rescue.stranded_jobs(jobs, "ghr-", 15 * 60, NOW)
    assert [o.split(" ")[0] for o in out] == ["old-ghr", "upper"]


def test_stranded_threshold_is_strict():
    assert rescue.stranded_jobs([job("j", minutes_ago=15)], "ghr-", 15 * 60, NOW) == []


def test_live_labels_per_label_set_and_window():
    jobs = [
        job("a", status="in_progress", started_ago=3),
        job("b", status="completed", labels=("ghr-supabase",), started_ago=40),
        job("c", status="in_progress", labels=("ubuntu-latest",), started_ago=1),
    ]
    assert rescue.live_labels(jobs, "ghr-", 15 * 60, NOW) == {("ghr-light",)}


# ── scan_once ────────────────────────────────────────────────────────────────


def test_rescues_stranded_run_cancel_then_rerun():
    gh = FakeGH(
        runs={"o/a": {"in_progress": [{"id": 7, "run_attempt": 1}]}},
        jobs={7: [job("e2e")]},
    )
    assert scan(gh) == (1, 0)
    assert gh.posts() == [
        "/repos/o/a/actions/runs/7/cancel",
        "/repos/o/a/actions/runs/7/rerun",
    ]


def test_rerun_waits_for_completed():
    slept = []
    gh = FakeGH(
        runs={"o/a": {"queued": [{"id": 7}]}},
        jobs={7: [job("e2e")]},
        run_states=[
            ("in_progress", None),
            ("in_progress", None),
            ("completed", "cancelled"),
        ],
    )
    rescue.scan_once(gh, cfg(), {}, now=NOW, sleep=slept.append)
    assert len(slept) == 2
    assert gh.posts()[-1].endswith("/rerun")


def test_young_or_hosted_runs_untouched():
    gh = FakeGH(
        runs={"o/a": {"queued": [{"id": 1}, {"id": 2}]}},
        jobs={
            1: [job("young", minutes_ago=3)],
            2: [job("hosted", labels=("ubuntu-latest",))],
        },
    )
    assert scan(gh) == (0, 0)
    assert gh.posts() == []


def test_alive_pool_queue_is_not_stranded():
    # Saturated but alive: another ghr-light job started 4 min ago, so the old queued one just waits.
    gh = FakeGH(
        runs={"o/a": {"in_progress": [{"id": 7}, {"id": 8}]}},
        jobs={
            7: [job("queued-light")],
            8: [job("busy", status="in_progress", started_ago=4)],
        },
    )
    assert scan(gh) == (0, 0)
    assert gh.posts() == []


def test_dead_class_rescued_while_other_class_alive():
    gh = FakeGH(
        runs={"o/a": {"in_progress": [{"id": 7}, {"id": 8}]}},
        jobs={
            7: [job("e2e", labels=("ghr-supabase",))],
            8: [job("busy", status="in_progress", started_ago=4)],
        },
    )
    assert scan(gh) == (1, 0)
    assert "/repos/o/a/actions/runs/7/cancel" in gh.posts()


def test_dry_run_reports_but_does_not_post():
    gh = FakeGH(runs={"o/a": {"queued": [{"id": 7}]}}, jobs={7: [job("e2e")]})
    assert scan(gh, dry_run=True) == (1, 0)
    assert gh.posts() == []


def test_attempt_cap_stops_rescue_loop():
    gh = FakeGH(
        runs={"o/a": {"queued": [{"id": 7, "run_attempt": 3}]}}, jobs={7: [job("e2e")]}
    )
    assert scan(gh) == (0, 0)
    assert gh.posts() == []


def test_cancel_409_on_cancelled_run_reruns():
    gh = FakeGH(
        runs={"o/a": {"queued": [{"id": 7}]}},
        jobs={7: [job("e2e")]},
        errors={"/cancel": 409},
    )
    assert scan(gh) == (1, 0)
    assert gh.posts()[-1] == "/repos/o/a/actions/runs/7/rerun"


def test_run_that_finished_on_its_own_is_not_rerun():
    gh = FakeGH(
        runs={"o/a": {"queued": [{"id": 7}]}},
        jobs={7: [job("e2e")]},
        errors={"/cancel": 409},
        run_states=[("completed", "success")],
    )
    scan(gh)
    assert not any(p.endswith("/rerun") for p in gh.posts())


def test_still_cancelling_goes_pending_then_reruns_next_pass():
    pending = {}
    gh = FakeGH(
        runs={"o/a": {"queued": [{"id": 7}]}},
        jobs={7: [job("e2e")]},
        run_states=[("in_progress", None)],
    )
    assert scan(gh, pending) == (1, 0)
    assert pending and not any(p.endswith("/rerun") for p in gh.posts())
    gh.run_states, gh.runs = [("completed", "cancelled")], {}
    assert scan(gh, pending) == (0, 0)
    assert gh.posts()[-1] == "/repos/o/a/actions/runs/7/rerun" and pending == {}


def test_rerun_failure_is_retried_next_pass():
    pending = {}
    gh = FakeGH(
        runs={"o/a": {"queued": [{"id": 7}]}},
        jobs={7: [job("e2e")]},
        errors={"/rerun": 500},
    )
    assert scan(gh, pending) == (1, 1)
    assert (("o/a", 7)) in pending
    gh.errors, gh.runs = {}, {}
    scan(gh, pending)
    assert gh.posts()[-1].endswith("/rerun") and pending == {}


def test_cancel_other_error_counts_and_continues():
    gh = FakeGH(
        runs={"o/a": {"queued": [{"id": 7}]}, "o/b": {"queued": [{"id": 8}]}},
        jobs={7: [job("e2e")], 8: [job("e2e")]},
        errors={"/cancel": 403},
    )
    assert scan(gh, repos=["o/a", "o/b"]) == (2, 2)
    assert not any(p.endswith("/rerun") for p in gh.posts())
    assert "/repos/o/b/actions/runs/8/cancel" in gh.posts()


def test_one_bad_repo_does_not_stop_the_pass():
    gh = FakeGH(
        runs={"o/b": {"queued": [{"id": 8}]}},
        jobs={8: [job("e2e")]},
        errors={"/repos/o/a/": 404},
    )
    assert scan(gh, repos=["o/a", "o/b"]) == (1, 1)
    assert "/repos/o/b/actions/runs/8/cancel" in gh.posts()


def test_runs_are_paginated():
    class Paged(FakeGH):
        def api(self, method, path):
            if "/actions/runs?status=queued" in path:
                self.calls.append((method, path))
                page = int(path.rsplit("&page=", 1)[1])
                return {
                    "workflow_runs": [{"id": 1000 + i} for i in range(100)]
                    if page == 1
                    else [{"id": 7}]
                }
            return super().api(method, path)

    gh = Paged(jobs={7: [job("e2e")]})
    assert scan(gh) == (1, 0)


def test_empty_repos_uses_installation_list():
    gh = FakeGH(repos=["o/x", "o/y"])
    scan(gh, repos=[])
    scanned = {
        p.split("/repos/")[1].split("/actions")[0]
        for _, p in gh.calls
        if "/repos/" in p
    }
    assert scanned == {"o/x", "o/y"}


# ── config ───────────────────────────────────────────────────────────────────


def test_config_defaults():
    c = rescue.load_config({"RESCUER_APP_ID": "123", "RESCUER_INSTALLATION_ID": "456"})
    assert (c["max_wait_s"], c["interval"], c["max_attempts"], c["prefix"]) == (
        900,
        300,
        3,
        "ghr-",
    )
    assert c["repos"] == [] and c["dry_run"] is False


@pytest.mark.parametrize(
    "env",
    [
        {"RESCUER_INSTALLATION_ID": "456"},
        {"RESCUER_APP_ID": "123", "RESCUER_INSTALLATION_ID": "x"},
        {"RESCUER_APP_ID": "1;rm", "RESCUER_INSTALLATION_ID": "456"},
        {"RESCUER_APP_ID": "123", "RESCUER_INSTALLATION_ID": "456", "LABEL_PREFIX": ""},
        {
            "RESCUER_APP_ID": "123",
            "RESCUER_INSTALLATION_ID": "456",
            "MAX_WAIT_MIN": "0",
        },
        {
            "RESCUER_APP_ID": "123",
            "RESCUER_INSTALLATION_ID": "456",
            "MAX_ATTEMPTS": "0",
        },
    ],
)
def test_config_rejects_bad_input(env):
    with pytest.raises(SystemExit):
        rescue.load_config(env)


# ── JWT ──────────────────────────────────────────────────────────────────────


def test_app_jwt_verifies_with_public_key(tmp_path):
    key, pub = tmp_path / "k.pem", tmp_path / "p.pem"
    subprocess.run(
        ["openssl", "genrsa", "-out", str(key), "2048"], check=True, capture_output=True
    )
    subprocess.run(
        ["openssl", "rsa", "-in", str(key), "-pubout", "-out", str(pub)],
        check=True,
        capture_output=True,
    )
    tok = rescue.app_jwt("123", str(key), now=1_000_000)
    head, body, sig = tok.split(".")
    claims = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))
    assert claims == {"iat": 999_940, "exp": 1_000_540, "iss": 123}
    sig_file = tmp_path / "sig"
    sig_file.write_bytes(base64.urlsafe_b64decode(sig + "=" * (-len(sig) % 4)))
    v = subprocess.run(
        [
            "openssl",
            "dgst",
            "-sha256",
            "-verify",
            str(pub),
            "-signature",
            str(sig_file),
        ],
        input=f"{head}.{body}".encode(),
        capture_output=True,
    )
    assert v.returncode == 0, v.stdout + v.stderr


# ── main (heartbeat drives the container healthcheck) ───────────────────────


@pytest.mark.parametrize("errors,rc,fresh", [(0, 0, True), (2, 1, False)])
def test_main_heartbeat_only_on_clean_pass(monkeypatch, tmp_path, errors, rc, fresh):
    hb = tmp_path / "hb"
    env = {"RESCUER_APP_ID": "1", "RESCUER_INSTALLATION_ID": "2", "INTERVAL_SEC": "0"}
    env["HEARTBEAT_FILE"] = str(hb)
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    monkeypatch.setattr(rescue, "scan_once", lambda gh, cfg, pending: (0, errors))
    assert rescue.main() == rc
    assert hb.exists() is fresh


@pytest.mark.parametrize("age,rc", [(10, 0), (899, 0), (901, 1)])
def test_healthcheck_freshness(tmp_path, age, rc):
    hb = tmp_path / "hb"
    hb.write_text("x")
    mtime = hb.stat().st_mtime
    env = {"HEARTBEAT_FILE": str(hb), "INTERVAL_SEC": "300"}
    assert rescue.healthcheck(env, now=mtime + age) == rc


def test_healthcheck_missing_file_is_unhealthy(tmp_path):
    assert rescue.healthcheck({"HEARTBEAT_FILE": str(tmp_path / "none")}) == 1
