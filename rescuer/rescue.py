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


def stranded_jobs(
    jobs: list[dict], prefix: str, max_wait_s: float, now: datetime
) -> list[str]:
    """Descriptions of jobs still queued on a `prefix*` label for longer than max_wait_s."""
    out = []
    for j in jobs:
        labels = j.get("labels") or []
        if j.get("status") != "queued" or not any(
            lb.startswith(prefix) for lb in labels
        ):
            continue
        created = datetime.fromisoformat(j["created_at"].replace("Z", "+00:00"))
        waited = (now - created).total_seconds()
        if waited > max_wait_s:
            out.append(f"{j['name']} ({int(waited // 60)} min on {','.join(labels)})")
    return out


def rescue_run(gh, repo: str, run_id: int, sleep=time.sleep) -> bool:
    """Cancel, wait until the run is completed (a run can't be re-run before that), re-run it all.

    WHY the whole run and not rerun-failed-jobs: the routing job already succeeded with the
    self-hosted label in its output; re-running only the cancelled jobs would reuse that output and
    route them straight back to the dead pool.
    """
    try:
        gh.api("POST", f"/repos/{repo}/actions/runs/{run_id}/cancel")
    except urllib.error.HTTPError as e:
        # 409 = already completed/cancelling; the re-run below still applies.
        if e.code != 409:
            raise
    for _ in range(24):
        if (
            gh.api("GET", f"/repos/{repo}/actions/runs/{run_id}").get("status")
            == "completed"
        ):
            break
        sleep(5)
    gh.api("POST", f"/repos/{repo}/actions/runs/{run_id}/rerun")
    return True


def scan_once(gh, cfg: dict, now: datetime | None = None, sleep=time.sleep) -> int:
    """One pass over all repos; returns the number of runs rescued (or that would be, on dry run)."""
    now = now or datetime.now(timezone.utc)
    repos = cfg["repos"] or installation_repos(gh)
    rescued = 0
    for repo in repos:
        runs = []
        for status in ("queued", "in_progress"):
            q = f"/repos/{repo}/actions/runs?status={status}&per_page=50"
            runs += gh.api("GET", q).get("workflow_runs", [])
        for run in runs:
            q = f"/repos/{repo}/actions/runs/{run['id']}/jobs?filter=latest&per_page=100"
            jobs = gh.api("GET", q).get("jobs", [])
            stuck = stranded_jobs(jobs, cfg["prefix"], cfg["max_wait_s"], now)
            if not stuck:
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
                rescue_run(gh, repo, run["id"], sleep=sleep)
                log(f"  -> cancelled + re-run {repo} run {run['id']}")
            except Exception as e:  # noqa: BLE001 — one bad run must not stop the pass
                log(f"  -> RESCUE FAILED {repo} run {run['id']}: {e}")
    return rescued


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
    while True:
        try:
            n = scan_once(gh, cfg)
            log(f"pass ok: {n} run(s) {'would be ' if cfg['dry_run'] else ''}rescued")
            # Healthcheck input: the container is healthy while this file is fresh.
            with open(cfg["heartbeat_file"], "w") as f:
                f.write(f"{int(time.time())}\n")
        except Exception as e:  # noqa: BLE001 — keep looping; a stale heartbeat marks it unhealthy
            log(f"pass FAILED: {e}")
            if cfg["interval"] <= 0:
                return 1
        if cfg["interval"] <= 0:
            return 0
        time.sleep(cfg["interval"])


if __name__ == "__main__":
    sys.exit(main())
