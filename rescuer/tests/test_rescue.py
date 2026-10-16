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


def job(name, status="queued", labels=("ghr-light",), minutes_ago=20):
    created = NOW.timestamp() - minutes_ago * 60
    return {
        "name": name,
        "status": status,
        "labels": list(labels),
        "created_at": datetime.fromtimestamp(created, timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        ),
    }


class FakeGH:
    """runs: {repo: {status: [run, ...]}}; jobs: {run_id: [job, ...]}."""

    def __init__(
        self, runs=None, jobs=None, repos=None, cancel_error=None, status_seq=None
    ):
        self.runs, self.jobs, self.repos = runs or {}, jobs or {}, repos or []
        self.cancel_error, self.status_seq = (
            cancel_error,
            list(status_seq or ["completed"]),
        )
        self.calls = []

    def api(self, method, path):
        self.calls.append((method, path))
        if path.startswith("/installation/repositories"):
            return {"repositories": [{"full_name": r} for r in self.repos]}
        if method == "POST" and path.endswith("/cancel"):
            if self.cancel_error:
                raise urllib.error.HTTPError(
                    path, self.cancel_error, "x", email.message.Message(), None
                )
            return {}
        if method == "POST" and path.endswith("/rerun"):
            return {}
        if "/jobs?" in path:
            run_id = int(path.split("/runs/")[1].split("/")[0])
            return {"jobs": self.jobs.get(run_id, [])}
        if "/actions/runs?status=" in path:
            repo = path.split("/repos/")[1].split("/actions")[0]
            status = path.split("status=")[1].split("&")[0]
            return {"workflow_runs": self.runs.get(repo, {}).get(status, [])}
        if method == "GET" and "/actions/runs/" in path:
            st = (
                self.status_seq.pop(0)
                if len(self.status_seq) > 1
                else self.status_seq[0]
            )
            return {"status": st}
        raise AssertionError(f"unexpected call {method} {path}")

    def posts(self):
        return [p for m, p in self.calls if m == "POST"]


def cfg(**kw):
    base = {
        "repos": ["o/a"],
        "prefix": "ghr-",
        "max_wait_s": 15 * 60,
        "max_attempts": 3,
        "dry_run": False,
    }
    base.update(kw)
    return base


def no_sleep(_):
    pass


# ── stranded_jobs ────────────────────────────────────────────────────────────


def test_stranded_only_queued_prefixed_and_old():
    jobs = [
        job("old-ghr"),
        job("young-ghr", minutes_ago=5),
        job("hosted", labels=("ubuntu-latest",)),
        job("running", status="in_progress"),
        job("no-labels", labels=()),
    ]
    out = rescue.stranded_jobs(jobs, "ghr-", 15 * 60, NOW)
    assert len(out) == 1 and out[0].startswith("old-ghr (20 min on ghr-light")


def test_stranded_threshold_is_strict():
    assert rescue.stranded_jobs([job("j", minutes_ago=15)], "ghr-", 15 * 60, NOW) == []


# ── scan_once ────────────────────────────────────────────────────────────────


def test_rescues_stranded_run_cancel_then_rerun():
    gh = FakeGH(
        runs={"o/a": {"in_progress": [{"id": 7, "run_attempt": 1}]}},
        jobs={7: [job("e2e")]},
    )
    assert rescue.scan_once(gh, cfg(), now=NOW, sleep=no_sleep) == 1
    assert gh.posts() == [
        "/repos/o/a/actions/runs/7/cancel",
        "/repos/o/a/actions/runs/7/rerun",
    ]


def test_rerun_waits_for_completed():
    slept = []
    gh = FakeGH(
        runs={"o/a": {"queued": [{"id": 7}]}},
        jobs={7: [job("e2e")]},
        status_seq=["in_progress", "in_progress", "completed"],
    )
    rescue.scan_once(gh, cfg(), now=NOW, sleep=slept.append)
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
    assert rescue.scan_once(gh, cfg(), now=NOW, sleep=no_sleep) == 0
    assert gh.posts() == []


def test_dry_run_reports_but_does_not_post():
    gh = FakeGH(runs={"o/a": {"queued": [{"id": 7}]}}, jobs={7: [job("e2e")]})
    assert rescue.scan_once(gh, cfg(dry_run=True), now=NOW, sleep=no_sleep) == 1
    assert gh.posts() == []


def test_attempt_cap_stops_rescue_loop():
    gh = FakeGH(
        runs={"o/a": {"queued": [{"id": 7, "run_attempt": 3}]}}, jobs={7: [job("e2e")]}
    )
    assert rescue.scan_once(gh, cfg(), now=NOW, sleep=no_sleep) == 0
    assert gh.posts() == []


def test_cancel_409_still_reruns():
    gh = FakeGH(
        runs={"o/a": {"queued": [{"id": 7}]}}, jobs={7: [job("e2e")]}, cancel_error=409
    )
    assert rescue.scan_once(gh, cfg(), now=NOW, sleep=no_sleep) == 1
    assert gh.posts()[-1] == "/repos/o/a/actions/runs/7/rerun"


def test_cancel_other_error_skips_rerun_and_continues():
    gh = FakeGH(
        runs={"o/a": {"queued": [{"id": 7}]}, "o/b": {"queued": [{"id": 8}]}},
        jobs={7: [job("e2e")], 8: [job("e2e")]},
        cancel_error=403,
    )
    rescue.scan_once(gh, cfg(repos=["o/a", "o/b"]), now=NOW, sleep=no_sleep)
    assert not any(p.endswith("/rerun") for p in gh.posts())
    assert "/repos/o/b/actions/runs/8/cancel" in gh.posts()


def test_empty_repos_uses_installation_list():
    gh = FakeGH(repos=["o/x", "o/y"])
    rescue.scan_once(gh, cfg(repos=[]), now=NOW, sleep=no_sleep)
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
