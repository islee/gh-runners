# rescuer — re-route runs stranded on self-hosted labels

## Purpose

A routing step (for example a `pick-runner` reusable workflow) sends a job to a self-hosted label only
while the pool looks healthy. If the pool dies after that decision (power, network, a wedged slot),
the job sits queued until GitHub's own timeout: GitHub never moves a queued job to another runner,
and the pool's heartbeat can't see GitHub's queue.

`rescue.py` finds jobs queued longer than `MAX_WAIT_MIN` on a `LABEL_PREFIX*` label, cancels their
run and re-runs the whole run. The re-run re-evaluates the routing step, which by then sees a stale
heartbeat and picks a GitHub-hosted runner.

It must run **off the pool**, on another always-on host, so that a pool outage doesn't take it down
too. A GitHub-hosted scheduled workflow works as a backstop, but on a private repo every run bills at
least one minute, so it can't poll often.

## Key files

| File | Role |
|---|---|
| `rescue.py` | The loop: App JWT (openssl) → installation token → scan → cancel + re-run. Stdlib only |
| `usage.py` | The minutes ledger: GET-only collector into SQLite, plus `--report`. Imports `rescue.py` |
| `Dockerfile` | `python:3.13-alpine` (digest-pinned) + openssl; non-root; healthcheck on the last good pass |
| `compose.example.yml` | Hardened stack: `rescuer` and `usage` services, same image (read-only rootfs, no caps, 128 MB each) |
| `rescuer.example.env` | Config template; copy to `rescuer.env` (gitignored) |
| `tests/test_rescue.py` | Offline tests with a fake GitHub client, plus a real-openssl JWT verify |
| `tests/test_usage.py` | Offline ledger tests: minute rounding, idempotency, windowing, report math |

## Setup

1. Create a GitHub App: repository permission **Actions: Read and write**, nothing else, no webhook.
   Install it on the repos whose jobs route to the pool. Download its private key.
2. On the host: copy `rescue.py`, `Dockerfile` and `compose.example.yml` (as `compose.yml`) into a
   stack dir. Add `rescuer.env` (from the template) and `rescuer-app.pem` (mode 0400, owned by the
   uid set in `user:`).
3. `docker compose config` and then `docker compose up -d --build`. One-off check without the loop:
   `docker compose run --rm -e INTERVAL_SEC=0 -e DRY_RUN=true rescuer`.

`REPOS` empty = every repo the installation covers, so adding a repo to the pool means installing the
App on it. There is no second list to keep in sync.

## Choosing the timings

Worst-case rescue latency is about `MAX_WAIT_MIN + INTERVAL_SEC`.

1. `INTERVAL_SEC` (default 300). Each pass costs about `1 + 2 × repos` API calls plus one per active
   run: well under 1% of the installation's 5,000/hour budget even at 60 s. On a self-hosted box,
   polling is free, so 5 min is a balance between latency and log noise rather than a cost.
2. `MAX_WAIT_MIN` (default 15) is the real lever, and it must stay **above the longest wait a
   healthy pool can cause**. Routing reads saturation from a heartbeat that can be a minute or more
   old, so a burst can queue a job behind a busy slot. A job waiting behind a ~10-minute job is not
   stranded. Rescuing it cancels and re-runs the whole run, repeating the jobs that already passed.
   Set it to the longest normal job on the pool plus a margin.
3. **Liveness guard.** A job is rescued only if no job on the same label set *started* within the
   last `MAX_WAIT_MIN`. A pool that is alive but saturated keeps starting jobs, so its queue is left
   alone. The guard is per label set, so a dead class (for example all supabase slots) is still
   rescued while the light class works. It can add up to one `MAX_WAIT_MIN` of delay when the pool
   dies right after starting a job.
4. `MAX_ATTEMPTS` (default 3) caps re-runs. If the pool reports healthy but its runners can't take
   the job, every re-run routes back to the pool. Past the cap the run is logged as `SKIP` and left
   for a human.

## Usage ledger

Self-hosted minutes are free, so GitHub's own usage reports show none for the pool. `usage.py`
records every finished job (pool and hosted) and prices the pool's minutes at the hosted rate, as a
proxy for money saved. It only issues GET calls, so the App needs nothing beyond the Actions read it
already has, and it covers every repo the installation covers (`REPOS` is ignored).

1. **Per-job ceil.** GitHub bills each job and each attempt separately, rounding up to a whole
   minute. Jobs of 21 s, 80 s, 69 s and 3 s bill 1+2+2+1 = 6 min although the run took 89 s. The
   ledger stores one row per job with that rounded figure, never a per-run total.
2. **Run it.** The `usage` compose service loops every `USAGE_INTERVAL_SEC`. Set `USAGE_SINCE` for the
   first run (backfill start); later passes resume from the last clean pass.
3. **Read it.** `docker compose exec usage python3 /app/usage.py --report [YYYY-MM]` reads the DB
   only. Per month: pool minutes (and per label), hosted minutes, job counts, `list_value`
   (pool minutes at `RATE_PER_MIN`) and `free_saving` (what those minutes would have cost beyond the
   `INCLUDED_MINUTES` free tier, after the hosted minutes already used it).
4. **Lookback trade-off.** Each pass re-scans runs created in the last `USAGE_LOOKBACK_DAYS` before
   the last clean pass. A re-run started later than that keeps its original creation date and is
   missed. A wider window costs one list call per repo per day on every pass.
5. **A proxy.** Pool job durations stand in for hosted durations; the hosted runner may be faster or
   slower, and the rate is the Linux 2-core list price regardless of the real runner size.

## Gotchas

1. A run can be re-run only once it is `completed`, so the rescuer waits up to 2 minutes after the
   cancel.
2. It re-runs the **whole** run, not just the failed jobs. Re-running only the cancelled jobs would
   reuse the routing job's earlier output and send them straight back to the dead pool.
3. After a cancel, a run is re-run only if it ended `cancelled`. A run that finished on its own in
   the meantime is left alone. If the re-run can't happen yet (still cancelling, API error), it is
   retried on later passes for up to an hour. That retry list is in memory, so a container restart
   in that window leaves the run cancelled (the cancel is logged).
4. A re-run attempt joins the workflow's `concurrency` group. With `cancel-in-progress`, re-running
   an old commit's run can cancel a newer run in the same group. Stranding is rare, so this is
   accepted, not handled.
5. The healthcheck is refreshed only by a pass with zero errors, so a revoked key or lost
   permission turns the container unhealthy. It can't see coverage, though: if the App is
   uninstalled from a repo, that repo silently drops out of the scan, because the installation
   lists what it covers.
6. The image sets `HEARTBEAT_FILE` for the rescuer, so the `usage` service would inherit it; it sets
   its own in `environment:`. `INTERVAL_SEC` (rescuer) and `USAGE_INTERVAL_SEC` (ledger) are
   separate, so one `rescuer.env` serves both.
7. The first pass backfills from `USAGE_SINCE` at roughly one call per run. A large backlog can hit
   the installation's hourly API budget; the pass is then logged as `DEGRADED`, nothing is lost, and
   the next pass resumes (ingested runs are skipped).
8. `./usage-data` must be writable by the `user:` uid; the rootfs is read-only, so a wrong owner
   fails at start with a SQLite "unable to open database file" error.
