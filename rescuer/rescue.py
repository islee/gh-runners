"""rescue.py — re-route GitHub Actions runs stranded on self-hosted runner labels.

Purpose: a job routed to a self-hosted label (default prefix `ghr-`) stays queued until GitHub's own
timeout if the pool dies after routing (power, network, wedged slot). GitHub never moves a queued job,
and the pool's own heartbeat can't see the queue. This finds jobs queued longer than MAX_WAIT_MIN on
such a label, cancels their run and re-runs it, so the routing step (e.g. a pick-runner reusable
workflow) re-evaluates and, with the pool down, picks a GitHub-hosted runner.

Context: runs OFF the pool (a container on another always-on host) so a pool outage can't take it
down too. Every INTERVAL_SEC (0 = one pass and exit). Worst-case rescue latency is about
MAX_WAIT_MIN + INTERVAL_SEC.

Credential: a GitHub App with repository permission Actions: read & write, installed on the repos to
watch. REPOS empty = every repo the installation covers (no second list to keep in sync).

Dependencies: python3 stdlib + the `openssl` CLI (RS256 JWT signing). No third-party packages.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from base64 import urlsafe_b64encode
from datetime import datetime, timezone

API = os.environ.get("GH_API_BASE", "https://api.github.com")


def log(msg: str) -> None:
    print(f"[{datetime.now(timezone.utc):%Y-%m-%dT%H:%M:%SZ}] {msg}", flush=True)


def b64url(data: bytes) -> str:
    return urlsafe_b64encode(data).rstrip(b"=").decode()


def app_jwt(app_id: str, key_path: str, now: int | None = None) -> str:
    """RS256 App JWT; iat backdated 60 s for clock skew, exp +540 s (GitHub caps at 10 min)."""
    now = int(time.time()) if now is None else now
    iss = int(app_id) if app_id.isdigit() else app_id
    head = b64url(
        json.dumps({"alg": "RS256", "typ": "JWT"}, separators=(",", ":")).encode()
    )
    body = b64url(
        json.dumps(
            {"iat": now - 60, "exp": now + 540, "iss": iss}, separators=(",", ":")
        ).encode()
    )
    signing_input = f"{head}.{body}".encode()
    sig = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=signing_input,
        capture_output=True,
        check=True,
    ).stdout
    if not sig:
        raise RuntimeError("JWT signing produced no signature")
    return f"{head}.{body}.{b64url(sig)}"


class GitHub:
    """Minimal REST client. The installation token is cached in memory until 10 min before expiry."""

    def __init__(self, app_id: str, installation_id: str, key_path: str):
        self.app_id, self.installation_id, self.key_path = (
            app_id,
            installation_id,
            key_path,
        )
        self._token, self._token_exp = "", 0.0

    def _http(self, method: str, path: str, bearer: str) -> dict:
        req = urllib.request.Request(
            API + path,
            method=method,
            headers={
                "Authorization": f"Bearer {bearer}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "ghr-rescuer",
            },
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
        return json.loads(raw) if raw.strip() else {}

    def token(self) -> str:
        if not self._token or time.time() > self._token_exp - 600:
            jwt = app_jwt(self.app_id, self.key_path)
            r = self._http(
                "POST", f"/app/installations/{self.installation_id}/access_tokens", jwt
            )
            self._token = r["token"]
            self._token_exp = datetime.fromisoformat(
                r["expires_at"].replace("Z", "+00:00")
            ).timestamp()
        return self._token

    def api(self, method: str, path: str) -> dict:
        return self._http(method, path, self.token())


def installation_repos(gh) -> list[str]:
    repos, page = [], 1
    while page <= 20:
        d = gh.api("GET", f"/installation/repositories?per_page=100&page={page}")
        batch = [r["full_name"] for r in d.get("repositories", [])]
        repos += batch
        if len(batch) < 100:
            break
        page += 1
    return sorted(repos)


def _ts(value: str | None) -> datetime | None:
    return datetime.fromisoformat(value.replace("Z", "+00:00")) if value else None


def pool_labels(job: dict, prefix: str) -> tuple[str, ...]:
    """The job's self-hosted labels, lowercased (GitHub matches labels case-insensitively)."""
    return tuple(
        sorted(
            lb.lower()
            for lb in job.get("labels") or []
            if lb.lower().startswith(prefix)
        )
    )


def live_labels(jobs: list[dict], prefix: str, window_s: float, now: datetime) -> set:
    """Label sets the pool demonstrably served recently: some job on them STARTED within window_s.

    WHY: a job queued past MAX_WAIT on a pool that is alive but saturated is not stranded; it will
    start when a slot frees. Rescuing it would cancel healthy work in its run. Liveness is per label
    set, so a dead class (all supabase slots down) is still rescued while the other class works.
    """
    alive = set()
    for j in jobs:
        labels, started = pool_labels(j, prefix), _ts(j.get("started_at"))
        if labels and started and (now - started).total_seconds() <= window_s:
            alive.add(labels)
    return alive


def stranded_jobs(
    jobs: list[dict], prefix: str, max_wait_s: float, now: datetime
) -> list[str]:
    """Descriptions of jobs still queued on a `prefix*` label for longer than max_wait_s.

    NOTE: GitHub creates a job only once its `needs:` have finished (observed 2026-10-16), so
    created_at is when it became runnable, not when the run started.
    """
    out = []
    for j in jobs:
        labels = pool_labels(j, prefix)
        if j.get("status") != "queued" or not labels:
            continue
        waited = (now - _ts(j["created_at"])).total_seconds()
        if waited > max_wait_s:
            out.append(f"{j['name']} ({int(waited // 60)} min on {','.join(labels)})")
    return out


def _http_detail(e: Exception) -> str:
    if isinstance(e, urllib.error.HTTPError):
        try:
            body = e.read()[:200].decode(errors="replace").replace("\n", " ")
        except Exception:  # noqa: BLE001
            body = ""
        return f"HTTP {e.code} {body}".strip()
    if isinstance(e, subprocess.CalledProcessError):
        return f"{e} {(e.stderr or b'')[:200].decode(errors='replace').strip()}"
    return str(e)


def _paged(gh, path: str, key: str, pages: int = 5) -> list[dict]:
    out, page = [], 1
    while page <= pages:
        batch = gh.api("GET", f"{path}&per_page=100&page={page}").get(key, [])
        out += batch
        if len(batch) < 100:
            return out
        page += 1
    log(
        f"WARN {path}: more than {pages * 100} {key}; the rest are not scanned this pass"
    )
    return out


def try_rerun(gh, repo: str, run_id: int) -> str:
    """Re-run a run iff it ended CANCELLED. Returns "rerun", "wait" (not completed yet) or "done".

    WHY check the conclusion: if the stranded job got a runner after all and the run finished
    (success or failure) before our cancel landed, re-running it would repeat finished work.
    """
    run = gh.api("GET", f"/repos/{repo}/actions/runs/{run_id}")
    if run.get("status") != "completed":
        return "wait"
    if run.get("conclusion") != "cancelled":
        log(
            f"  -> {repo} run {run_id} finished on its own ({run.get('conclusion')}); not re-running"
        )
        return "done"
    gh.api("POST", f"/repos/{repo}/actions/runs/{run_id}/rerun")
    log(f"  -> re-run {repo} run {run_id}")
    return "rerun"


def rescue_run(gh, repo: str, run_id: int, sleep=time.sleep) -> str:
    """Cancel, wait (<= 2 min) for completed (a run can't be re-run before that), then re-run it all.

    WHY the whole run and not rerun-failed-jobs: the routing job already succeeded with the
    self-hosted label in its output; re-running only the cancelled jobs would reuse that output and
    route them straight back to the dead pool. Returns as try_rerun; "wait" = caller retries later.
    """
    try:
        gh.api("POST", f"/repos/{repo}/actions/runs/{run_id}/cancel")
    except urllib.error.HTTPError as e:
        # 409 = already completed or cancelling; try_rerun decides from the conclusion.
        if e.code != 409:
            raise
    for _ in range(24):
        state = try_rerun(gh, repo, run_id)
        if state != "wait":
            return state
        sleep(5)
    return "wait"


def scan_once(
    gh, cfg: dict, pending: dict, now: datetime | None = None, sleep=time.sleep
):
    """One pass. Returns (rescued, errors).

    pending: {(repo, run_id): first_seen_epoch} for runs we cancelled but could not re-run yet
    (still cancelling, or the re-run call failed). Retried every pass for up to an hour.
    NOTE: in memory only; a container restart between cancel and re-run loses it (logged at cancel).
    """
    now = now or datetime.now(timezone.utc)
    rescued = errors = 0

    for key, first in list(pending.items()):
        repo, run_id = key
        try:
            state = try_rerun(gh, repo, run_id)
            if state != "wait" or now.timestamp() - first > 3600:
                if state == "wait":
                    log(
                        f"  -> GAVE UP on {repo} run {run_id}: still not completed after 1 h"
                    )
                    errors += 1
                del pending[key]
        except Exception as e:  # noqa: BLE001
            log(f"  -> RETRY FAILED {repo} run {run_id}: {_http_detail(e)}")
            errors += 1

    try:
        repos = cfg["repos"] or installation_repos(gh)
    except Exception as e:  # noqa: BLE001
        log(f"ERROR listing installation repos: {_http_detail(e)}")
        return 0, errors + 1

    # Phase 1: gather every active run's latest jobs (one bad repo/run must not stop the pass).
    gathered, all_jobs = [], []
    for repo in repos:
        try:
            runs = []
            for status in ("queued", "in_progress"):
                runs += _paged(
                    gh, f"/repos/{repo}/actions/runs?status={status}", "workflow_runs"
                )
        except Exception as e:  # noqa: BLE001
            log(f"ERROR listing runs of {repo}: {_http_detail(e)}")
            errors += 1
            continue
        for run in runs:
            try:
                q = f"/repos/{repo}/actions/runs/{run['id']}/jobs?filter=latest"
                jobs = _paged(gh, q, "jobs")
            except Exception as e:  # noqa: BLE001
                log(f"ERROR listing jobs of {repo} run {run['id']}: {_http_detail(e)}")
                errors += 1
                continue
            gathered.append((repo, run, jobs))
            all_jobs += jobs

    # Phase 2: decide. A label set the pool served recently is alive, so its queue is just a queue.
    alive = live_labels(all_jobs, cfg["prefix"], cfg["max_wait_s"], now)
    for repo, run, jobs in gathered:
        stuck = [
            desc
            for j in jobs
            if pool_labels(j, cfg["prefix"]) not in alive
            for desc in stranded_jobs([j], cfg["prefix"], cfg["max_wait_s"], now)
        ]
        if not stuck or (repo, run["id"]) in pending:
            continue
        attempt = int(run.get("run_attempt") or 1)
        where = f"{repo} run {run['id']} attempt {attempt} ({run.get('name', '')})"
        # CRITICAL: cap re-runs. If the pool's heartbeat says "ok" while its runners can't take the
        # job (label mismatch, wedged runner), every re-run routes back to the pool; without a cap
        # this would cancel and re-run the same run forever.
        if attempt >= cfg["max_attempts"]:
            log(
                f"SKIP {where}: stranded but already at attempt {attempt}: {'; '.join(stuck)}"
            )
            continue
        log(f"STRANDED {where}: {'; '.join(stuck)}")
        rescued += 1
        if cfg["dry_run"]:
            continue
        try:
            if rescue_run(gh, repo, run["id"], sleep=sleep) == "wait":
                pending[(repo, run["id"])] = now.timestamp()
                log(
                    f"  -> cancelled {repo} run {run['id']}; re-run pending (not completed yet)"
                )
        except Exception as e:  # noqa: BLE001
            log(f"  -> RESCUE FAILED {repo} run {run['id']}: {_http_detail(e)}")
            errors += 1
            # The cancel may have landed: retry the re-run (conclusion-checked) on later passes.
            pending[(repo, run["id"])] = now.timestamp()
    return rescued, errors


def load_config(env=os.environ) -> dict:
    cfg = {
        "app_id": env.get("RESCUER_APP_ID", ""),
        "installation_id": env.get("RESCUER_INSTALLATION_ID", ""),
        "key_path": env.get("RESCUER_APP_KEY", "/run/secrets/rescuer-app.pem"),
        "repos": env.get("REPOS", "").split(),
        "prefix": env.get("LABEL_PREFIX", "ghr-"),
        "max_wait_s": float(env.get("MAX_WAIT_MIN", "15")) * 60,
        "interval": int(env.get("INTERVAL_SEC", "300")),
        "max_attempts": int(env.get("MAX_ATTEMPTS", "3")),
        "dry_run": env.get("DRY_RUN", "false").lower() == "true",
        "heartbeat_file": env.get("HEARTBEAT_FILE", "/tmp/rescuer.last-ok"),
    }
    if not cfg["app_id"].isalnum() or not cfg["installation_id"].isdigit():
        raise SystemExit("RESCUER_APP_ID / RESCUER_INSTALLATION_ID missing or invalid")
    if not cfg["prefix"]:
        raise SystemExit("LABEL_PREFIX must not be empty (it would match every job)")
    cfg["prefix"] = cfg["prefix"].lower()
    if cfg["max_wait_s"] <= 0 or cfg["max_attempts"] < 1 or cfg["interval"] < 0:
        raise SystemExit(
            "MAX_WAIT_MIN must be > 0, MAX_ATTEMPTS >= 1, INTERVAL_SEC >= 0"
        )
    return cfg


def main() -> int:
    cfg = load_config()
    gh = GitHub(cfg["app_id"], cfg["installation_id"], cfg["key_path"])
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    log(
        f"start: prefix={cfg['prefix']} max_wait={cfg['max_wait_s'] / 60:g}m "
        f"interval={cfg['interval']}s max_attempts={cfg['max_attempts']} "
        f"repos={' '.join(cfg['repos']) or '(installation)'} dry_run={cfg['dry_run']}"
    )
    pending: dict = {}
    while True:
        try:
            n, errors = scan_once(gh, cfg, pending)
            verb = "would be rescued" if cfg["dry_run"] else "rescued"
            log(
                f"pass {'ok' if errors == 0 else 'DEGRADED'}: {n} run(s) {verb}, {errors} error(s)"
            )
            # Healthcheck input: refreshed only by a clean pass, so persistent errors (lost
            # permission, revoked key) turn the container unhealthy.
            if errors == 0:
                with open(cfg["heartbeat_file"], "w") as f:
                    f.write(f"{int(time.time())}\n")
        except Exception as e:  # noqa: BLE001 — keep looping; a stale heartbeat marks it unhealthy
            errors = 1
            log(f"pass FAILED: {_http_detail(e)}")
        if cfg["interval"] <= 0:
            return 1 if errors else 0
        time.sleep(cfg["interval"])


if __name__ == "__main__":
    sys.exit(main())
