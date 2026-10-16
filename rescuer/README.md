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
| `Dockerfile` | `python:3.13-alpine` (digest-pinned) + openssl; non-root; healthcheck on the last good pass |
| `compose.example.yml` | Hardened single-container stack (read-only rootfs, no caps, 128 MB) |
| `rescuer.example.env` | Config template; copy to `rescuer.env` (gitignored) |
| `tests/test_rescue.py` | Offline tests with a fake GitHub client, plus a real-openssl JWT verify |

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
3. `MAX_ATTEMPTS` (default 3) caps re-runs. If the pool reports healthy but its runners can't take
   the job, every re-run routes back to the pool. Past the cap the run is logged as `SKIP` and left
   for a human.

## Gotchas

1. A run can be re-run only once it is `completed`, so the rescuer waits up to 2 minutes after the
   cancel.
2. It re-runs the **whole** run, not just the failed jobs. Re-running only the cancelled jobs would
   reuse the routing job's earlier output and send them straight back to the dead pool.
3. The healthcheck only proves that passes succeed. If the App is uninstalled from a repo, that repo
   silently drops out of the scan, because the installation lists what it covers.
