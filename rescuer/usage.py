"""usage.py — ledger of the pool's job minutes, measured the way GitHub bills hosted minutes.

Purpose: self-hosted minutes are free, so GitHub reports none for them. This records every finished
job (pool and hosted) with its duration rounded up to whole minutes, so the pool's minutes can be
priced at the hosted rate as a proxy for money saved. `--report` prints that per month.

Context: runs next to rescue.py (same App, same image, same host). Read-only against GitHub: only
GET calls, so the App needs no permission beyond the Actions read the rescuer already has. Scope is
EVERY repo the installation covers; REPOS is deliberately not read, because the rescuer narrows it
to the repos that route to the pool, and a ledger must also see the hosted side.

Storage: one SQLite file (WAL). Tables: jobs (one row per job id), runs (which (run, attempt) pairs
were ingested), meta (last fully clean pass day).

Dependencies: python3 stdlib + rescue.py (GitHub client, helpers). No third-party packages.
"""

from __future__ import annotations

import json
import math
import os
import re
import signal
import sqlite3
import sys
import time
from datetime import date, datetime, timedelta, timezone

import rescue
from rescue import log

# GitHub caps a search-style listing at 1000 results; one UTC day per query keeps each under it.
DAY_PAGES = 10

SCHEMA = """
CREATE TABLE IF NOT EXISTS jobs (
    job_id INTEGER PRIMARY KEY,
    repo TEXT NOT NULL,
    run_id INTEGER NOT NULL,
    run_attempt INTEGER NOT NULL,
    workflow TEXT,
    name TEXT,
    labels TEXT NOT NULL,
    runner_name TEXT,
    started_at TEXT,
    completed_at TEXT,
    conclusion TEXT,
    kind TEXT NOT NULL,
    billable_min INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS jobs_started ON jobs (started_at);
CREATE TABLE IF NOT EXISTS runs (
    repo TEXT NOT NULL,
    run_id INTEGER NOT NULL,
    run_attempt INTEGER NOT NULL,
    ingested_at TEXT NOT NULL,
    PRIMARY KEY (repo, run_id, run_attempt)
);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""


def billable_minutes(job: dict) -> int:
    """Minutes GitHub would bill this job: its duration rounded UP to a whole minute.

    GitHub's rule (runner pricing reference): "GitHub rounds the minutes and partial minutes each job
    uses up to the nearest whole minute." Per job and per attempt, never per run: jobs of 21 s, 80 s,
    69 s and 3 s bill 1+2+2+1 = 6 min although the run took 89 s. Missing timestamps or a
    non-positive duration (a job that never ran) bill 0.
    """
    start, end = rescue._ts(job.get("started_at")), rescue._ts(job.get("completed_at"))
    if not start or not end:
        return 0
    seconds = (end - start).total_seconds()
    return math.ceil(seconds / 60) if seconds > 0 else 0


def classify(job: dict, prefix: str) -> str:
    """'pool' | 'hosted' | 'none'. A job without a runner never ran, whatever its labels say."""
    if not job.get("runner_name"):
        return "none"
    # Labels match case-insensitively on GitHub, so compare lowercased (prefix is lowercased).
    if any(lb.lower().startswith(prefix) for lb in job.get("labels") or []):
        return "pool"
    return "hosted"


def job_row(repo: str, run: dict, job: dict, prefix: str) -> tuple:
    kind = classify(job, prefix)
    return (
        job["id"],
        repo,
        job.get("run_id") or run["id"],
        job.get("run_attempt") or run.get("run_attempt") or 1,
        job.get("workflow_name") or run.get("name"),
        job.get("name"),
        json.dumps(job.get("labels") or []),
        job.get("runner_name"),
        job.get("started_at"),
        job.get("completed_at"),
        job.get("conclusion"),
        kind,
        # A job with no runner never ran: store 0 even if timestamps are present (skipped/cancelled).
        0 if kind == "none" else billable_minutes(job),
    )


def open_db(path: str) -> sqlite3.Connection:
    db = sqlite3.connect(path)
    db.execute("PRAGMA journal_mode=WAL")
    db.executescript(SCHEMA)
    return db


def window_start(db: sqlite3.Connection, cfg: dict) -> date:
    """First UTC day to scan: max(USAGE_SINCE, last clean day - lookback); USAGE_SINCE when empty.

    NOTE: a re-run started more than USAGE_LOOKBACK_DAYS after the run was created keeps its
    original created_at, so it falls outside the window and is missed. Documented trade-off: a wider
    window costs one list call per repo per day on every pass.
    """
    row = db.execute("SELECT value FROM meta WHERE key='last_complete_day'").fetchone()
    since = cfg["since"]
    if row is None:
        if since is None:
            raise SystemExit(
                "USAGE_SINCE (YYYY-MM-DD) is required while the ledger is empty"
            )
        return since
    base = date.fromisoformat(row[0]) - timedelta(days=cfg["lookback_days"])
    return max(since, base) if since else base


def ingest_run(gh, db: sqlite3.Connection, repo: str, run: dict, prefix: str) -> int:
    """Fetch every attempt's jobs of one run, upsert them and mark (run, attempt) ingested.

    One transaction per run: a crash leaves either the whole run recorded or none of it.
    """
    jobs = rescue._paged(
        gh, f"/repos/{repo}/actions/runs/{run['id']}/jobs?filter=all", "jobs"
    )
    attempt = int(run.get("run_attempt") or 1)
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with db:
        db.executemany(
            "INSERT OR REPLACE INTO jobs VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            [job_row(repo, run, j, prefix) for j in jobs],
        )
        db.execute(
            "INSERT OR REPLACE INTO runs VALUES (?,?,?,?)",
            (repo, run["id"], attempt, now),
        )
    return len(jobs)


def collect_once(gh, db: sqlite3.Connection, cfg: dict, today: date | None = None):
    """One pass. Returns (runs_ingested, errors); a clean pass advances last_complete_day."""
    today = today or datetime.now(timezone.utc).date()
    start = window_start(db, cfg)
    errors = ingested = 0
    try:
        repos = rescue.installation_repos(gh)
    except Exception as e:  # noqa: BLE001
        log(f"ERROR listing installation repos: {rescue._http_detail(e)}")
        return 0, 1
    days = [start + timedelta(days=i) for i in range((today - start).days + 1)]
    for repo in repos:
        for day in days:
            # Errors are per (repo, day) and per run so one bad one doesn't stop the pass.
            try:
                runs = rescue._paged(
                    gh,
                    f"/repos/{repo}/actions/runs?status=completed&created={day}",
                    "workflow_runs",
                    pages=DAY_PAGES,
                )
            except Exception as e:  # noqa: BLE001
                log(f"ERROR listing runs of {repo} {day}: {rescue._http_detail(e)}")
                errors += 1
                continue
            # rescue._paged logs a WARN if the day hits the 1000-run cap.
            for run in runs:
                attempt = int(run.get("run_attempt") or 1)
                seen = db.execute(
                    "SELECT 1 FROM runs WHERE repo=? AND run_id=? AND run_attempt=?",
                    (repo, run["id"], attempt),
                ).fetchone()
                if seen:
                    continue
                try:
                    ingest_run(gh, db, repo, run, cfg["prefix"])
                    ingested += 1
                except Exception as e:  # noqa: BLE001
                    log(
                        f"ERROR ingesting {repo} run {run['id']}: {rescue._http_detail(e)}"
                    )
                    errors += 1
    if errors == 0:
        with db:
            db.execute(
                "INSERT OR REPLACE INTO meta VALUES ('last_complete_day', ?)",
                (today.isoformat(),),
            )
    return ingested, errors


# ── report ──────────────────────────────────────────────────────────────────


def free_plan_saving(pool: int, hosted: int, included: int, rate: float) -> float:
    """Cost the pool's minutes would have added on top of the free tier, at the list rate."""
    return (max(0, pool + hosted - included) - max(0, hosted - included)) * rate


def report(db: sqlite3.Connection, month: str | None, cfg: dict) -> str:
    q = (
        "SELECT substr(started_at,1,7), kind, labels, billable_min FROM jobs "
        "WHERE kind IN ('pool','hosted') AND started_at IS NOT NULL"
    )
    args: tuple = ()
    if month:
        q += " AND substr(started_at,1,7)=?"
        args = (month,)
    months: dict[str, dict] = {}
    for m, kind, labels, mins in db.execute(q, args):
        d = months.setdefault(
            m,
            {"pool": 0, "hosted": 0, "pool_jobs": 0, "hosted_jobs": 0, "by_label": {}},
        )
        d[kind] += mins
        d[f"{kind}_jobs"] += 1
        if kind == "pool":
            pl = sorted(
                lb.lower()
                for lb in json.loads(labels)
                if lb.lower().startswith(cfg["prefix"])
            )
            d["by_label"][",".join(pl)] = d["by_label"].get(",".join(pl), 0) + mins
    if not months:
        return f"no pool/hosted jobs recorded{f' for {month}' if month else ''}"
    rate, included = cfg["rate"], cfg["included"]
    head = (
        f"{'month':<8}{'pool_min':>10}{'hosted_min':>12}{'pool_jobs':>11}"
        f"{'hosted_jobs':>13}{'list_value':>12}{'free_saving':>13}"
    )
    lines = [head]
    for m in sorted(months):
        d = months[m]
        lines.append(
            f"{m:<8}{d['pool']:>10}{d['hosted']:>12}{d['pool_jobs']:>11}{d['hosted_jobs']:>13}"
            f"{d['pool'] * rate:>12.2f}"
            f"{free_plan_saving(d['pool'], d['hosted'], included, rate):>13.2f}"
        )
        for label, mins in sorted(d["by_label"].items()):
            lines.append(f"  {label or '(none)'}: {mins} min")
    lines.append(
        f"list_value = pool_min * ${rate:g}/min; free_saving = extra cost over the "
        f"{included}-min monthly free tier. Minutes are GitHub-rounded per job; pool job "
        "durations are only a proxy for hosted durations."
    )
    return "\n".join(lines)


# ── config / CLI ────────────────────────────────────────────────────────────


def load_config(env=os.environ, need_app: bool = True) -> dict:
    try:
        cfg = {
            "app_id": env.get("RESCUER_APP_ID", ""),
            "installation_id": env.get("RESCUER_INSTALLATION_ID", ""),
            "key_path": env.get("RESCUER_APP_KEY", "/run/secrets/rescuer-app.pem"),
            "prefix": env.get("LABEL_PREFIX", "ghr-").lower(),
            "db": env.get("USAGE_DB", "/data/usage.sqlite"),
            "since": None,
            "lookback_days": int(env.get("USAGE_LOOKBACK_DAYS", "7")),
            "interval": int(env.get("USAGE_INTERVAL_SEC", "3600")),
            "rate": float(env.get("RATE_PER_MIN", "0.006")),
            "included": int(env.get("INCLUDED_MINUTES", "2000")),
            "heartbeat_file": env.get("HEARTBEAT_FILE", "/tmp/usage.last-ok"),
        }
        if env.get("USAGE_SINCE"):
            cfg["since"] = date.fromisoformat(env["USAGE_SINCE"])
    except ValueError as e:
        raise SystemExit(
            f"invalid USAGE_* / RATE_PER_MIN / INCLUDED_MINUTES value: {e}"
        )
    if need_app and (
        not cfg["app_id"].isalnum() or not cfg["installation_id"].isdigit()
    ):
        raise SystemExit("RESCUER_APP_ID / RESCUER_INSTALLATION_ID missing or invalid")
    if not cfg["prefix"]:
        raise SystemExit("LABEL_PREFIX must not be empty (it would match every job)")
    if (
        cfg["lookback_days"] < 0
        or cfg["interval"] < 0
        or cfg["rate"] < 0
        or cfg["included"] < 0
    ):
        raise SystemExit(
            "USAGE_LOOKBACK_DAYS, USAGE_INTERVAL_SEC, RATE_PER_MIN, INCLUDED_MINUTES must be >= 0"
        )
    return cfg


def healthcheck(env=os.environ, now: float | None = None) -> int:
    """Docker HEALTHCHECK: rescue's freshness rule, fed this service's interval and heartbeat."""
    return rescue.healthcheck(
        {
            "INTERVAL_SEC": env.get("USAGE_INTERVAL_SEC", "3600"),
            "HEARTBEAT_FILE": env.get("HEARTBEAT_FILE", "/tmp/usage.last-ok"),
        },
        now,
    )


def run_report(month: str | None, env=os.environ) -> int:
    if month and not re.fullmatch(r"\d{4}-(0[1-9]|1[0-2])", month):
        raise SystemExit("--report takes YYYY-MM")
    cfg = load_config(env, need_app=False)
    if not os.path.exists(cfg["db"]):
        raise SystemExit(f"no ledger at {cfg['db']}")
    db = sqlite3.connect(cfg["db"])
    print(report(db, month, cfg))
    return 0


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if argv == ["--healthcheck"]:
        return healthcheck()
    if argv and argv[0] == "--report" and len(argv) <= 2:
        return run_report(argv[1] if len(argv) == 2 else None)
    if argv not in ([], ["--once"]):
        raise SystemExit(
            "usage: usage.py [--once | --healthcheck | --report [YYYY-MM]]"
        )
    cfg = load_config()
    if argv == ["--once"]:
        cfg["interval"] = 0
    gh = rescue.GitHub(cfg["app_id"], cfg["installation_id"], cfg["key_path"])
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    db = open_db(cfg["db"])
    log(
        f"start: prefix={cfg['prefix']} since={cfg['since']} lookback={cfg['lookback_days']}d "
        f"interval={cfg['interval']}s db={cfg['db']}"
    )
    while True:
        try:
            n, errors = collect_once(gh, db, cfg)
            log(
                f"pass {'ok' if errors == 0 else 'DEGRADED'}: {n} run(s) ingested, {errors} error(s)"
            )
            # Healthcheck input: refreshed only by a clean pass, as in rescue.py.
            if errors == 0:
                with open(cfg["heartbeat_file"], "w") as f:
                    f.write(f"{int(time.time())}\n")
        except Exception as e:  # noqa: BLE001 — keep looping; a stale heartbeat marks it unhealthy
            errors = 1
            log(f"pass FAILED: {rescue._http_detail(e)}")
        if cfg["interval"] <= 0:
            return 1 if errors else 0
        time.sleep(cfg["interval"])


if __name__ == "__main__":
    sys.exit(main())
