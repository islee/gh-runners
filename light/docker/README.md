# light / docker — containerized variant

Container-per-job version of the `light` runner, for hosts where you want **Docker isolation**
instead of the host-level systemd setup in [`../`](../README.md). Built on the **official
`ghcr.io/actions/actions-runner`** image plus a small registration entrypoint (curl + jq). Each
container runs exactly one job (`--ephemeral`) then exits; `restart: always` spawns a fresh one.

Choose this over the systemd variant when you want each job to run in a throwaway container; choose
the [systemd variant](../README.md) when you want the simplest setup with no Docker on the host.

## Use
```bash
cp env.example .env      # set GH_ORG + ONE credential (see below); .env is gitignored
docker compose up -d --build                 # 1 runner
docker compose up -d --build --scale runner=2  # N concurrent runners
docker compose logs -f
docker compose down      # stop (ephemeral runners deregister themselves after each job)
```

## Credentials
Set exactly one in `.env` (priority high → low):

| Model | Var(s) | Notes |
|-------|--------|-------|
| **A — static** | `RUNNER_TOKEN` | One-off; expires ~1h. |
| **B — broker** | `BROKER_URL` + `BROKER_SECRET` | Recommended. No GitHub credential in the container; the [token-broker](https://github.com/islee/gh-runners/tree/main/broker) mints fresh tokens. |
| **C — PAT** | `ACCESS_TOKEN` | Fine-grained PAT, `organization_self_hosted_runners` scope only — never an admin PAT. |

## Notes
- **Runner names** follow `gh-runner-light-<id>-<n>` — set `<id>` via `OWNER` and `<n>` via
  `RUNNER_NUMBER` in `.env` / compose (defaults: container hostname / `1`). `docker compose --scale`
  gives each replica the container's hostname as `<id>` (unique but not sequential); for clean
  `<id>-<n>` names define separate services with explicit `OWNER`+`RUNNER_NUMBER`.
- The official runner image is **minimal**. If your jobs need a language toolchain and don't install
  it via `setup-*` actions, add the packages to the `Dockerfile`.
- **Pin the base image** before real use: `--build-arg BASE_IMAGE=ghcr.io/actions/actions-runner:<tag|digest>`
  (`:latest` is a moving target for an image that runs PR code).
- First-build TODO: confirm the runner home path with
  `docker run --rm ghcr.io/actions/actions-runner ls /home/runner` (should show `config.sh`/`run.sh`);
  update `RUNNER_HOME` in `runner-payload.sh` if different.

## Fleet self-update

On each container start, `bootstrap.sh` (the stable ENTRYPOINT) checks for a `fleet_update` object
in the broker `/token` response. If present, it fetches `light/docker/.fleet-manifest` from the
declared `desired_ref`, verifies its sha256 against the broker-supplied `manifest_sha256` (the
out-of-repo trust anchor), downloads and verifies `runner-payload.sh`, then execs the staged copy.

| Env var | Default | Effect |
|---------|---------|--------|
| `AUTO_UPDATE` | `1` | Set to `0` to always use the baked-in payload (disables self-update). |
| `UPDATE_REPO` | `islee/gh-runners` | Source repo for manifest and payload downloads. |

**Fail-safe:** any failure in the update path (network, hash mismatch, bad manifest, disallowed
path) logs a warning and falls back to the baked-in `runner-payload.sh`. A job is never blocked
by an update failure.

**Broker requirement:** the broker must include `fleet_update.manifest_sha256` in the `/token`
response (e.g. via a `FLEET_MANIFEST_SHA256` config keyed to `light-docker`) for updates to
flow. Without it, the runner silently uses the baked-in payload — always safe.

**What is updatable:** only `runner-payload.sh`. `bootstrap.sh` is the trust root and is never
in the manifest or subject to self-update; rebuild the image to update it.

## Security
Ephemeral container per job; least-privilege credential (model B or scoped PAT, never admin);
outbound-only. Don't route untrusted fork PRs here.
