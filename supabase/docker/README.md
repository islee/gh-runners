# supabase / docker — containerized variant

Container-per-job version of the `supabase` runner. **Prefer the host-level systemd variant in
[`../`](../README.md) for this workload** — it's simpler and avoids the plumbing below. Use this only
if you specifically want the runner itself containerized.

Built on the official `ghcr.io/actions/actions-runner` image + a Docker CLI. The runner runs in a
container but the *job's* Docker work (`supabase start`) targets the **host** Docker daemon
(docker-out-of-docker), so a Supabase stack comes up on the host exactly as on a hosted runner.

## The three gotchas this variant has to solve
(All handled in `docker-compose.yml` — this is *why* the systemd variant is simpler.)
1. **Host networking** (`network_mode: host`) — the job does `curl http://127.0.0.1:54321`; it must
   resolve where Supabase published its ports (the host).
2. **Host Docker socket** (`/var/run/docker.sock` mount + `group_add: ${DOCKER_GID}`) — the job runs
   `supabase`/`docker` against the host daemon. Only the Docker **client** is in the image, not a daemon.
3. **Identical-path workspace bind** (`RUNNER_WORKDIR` mounted at the same absolute path in and out) —
   the host daemon resolves the job's bind-mounts by **host** path, so they must match.

## Use
```bash
cp env.example .env
# set GH_ORG + ONE credential, plus DOCKER_GID (getent group docker | cut -d: -f3)
docker compose up -d --build
docker compose logs -f
docker compose down
```
Count is **1** by design (a Supabase stack is several GB). The Supabase CLI is **not** baked into the
image — install it in your workflow (or add it to the `Dockerfile`).

## Credentials
Set one in `.env` (priority high → low): `RUNNER_TOKEN` (static, ~1h) → `BROKER_URL`+`BROKER_SECRET`
([broker](https://github.com/islee/ci-runner-token-broker), recommended) → `ACCESS_TOKEN` (fine-grained
PAT, `organization_self_hosted_runners` only — never admin).

## Cleanup
Ephemeral container, but the Docker state lives on the **host** — have your workflow stop the stack in
an `if: always()` step (`supabase stop --no-backup || true`) so stacks don't accumulate across jobs.

## Security
The mounted Docker socket gives this container **root-equivalent control of the host Docker daemon** —
only ever route trusted workflows here (nightly `main` / maintainer-labeled), never untrusted fork PRs.
Ephemeral; least-privilege GitHub credential; outbound-only.
