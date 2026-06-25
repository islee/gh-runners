# supabase — Linux CI runner for Docker-stack jobs

Ephemeral, self-hosted GitHub Actions runner for **jobs that spin up a Docker stack** — e.g.
`supabase start` (Postgres + Studio + storage/realtime/edge), integration/E2E tests, `plpgsql-check`.
Uses the **official `actions/runner`** driven by **systemd** (no container around the runner itself).
Default: **1 instance** labelled `self-hosted,linux,x64,supabase`.

> **Why 1 instance:** a Supabase stack is several GB of RAM. A single runner bounds heavy CI to one
> concurrent job; GitHub queues and drains the rest in order. Raise `--count` only if the host has the
> RAM headroom.

> Prefer this host-level setup for supabase. A container-per-job variant exists in [`docker/`](docker/),
> but it reintroduces docker-out-of-docker plumbing (host network + socket + same-path bind) that this
> variant avoids.

## Why the runner is NOT containerized here
Running the **runner on the host** (not in a container) is deliberate and avoids the classic
docker-in-docker networking trap:

- The job does things like `curl http://127.0.0.1:54321/…`. With a host-level runner, `127.0.0.1`
  and bind-mount paths are simply the host's — **no `network_mode: host` hack, no identical-path bind
  workaround, no `/var/run/docker.sock` juggling**. The job's `docker`/`supabase` commands talk to the
  host Docker daemon directly, exactly as they would on a GitHub-hosted runner.

## Prerequisites
- Linux host (`x86_64` or `aarch64`) with **systemd**.
- **Docker installed and running on the host**, and the runner's user able to use it
  (`sudo usermod -aG docker <user>`), since the *jobs* invoke Docker.
- The **Supabase CLI** available to jobs (or installed by the workflow).
- `curl`, `tar`, `python3`.
- A non-root user to run the runner under (don't use root).
- One credential — see [Credentials](#credentials).

## Install
Copy this `supabase/` directory to the host, then:

```bash
# Model B — token-broker (recommended)
sudo ./install.sh --org your-org \
  --broker-url https://<your-broker-host> --broker-secret <secret> \
  --user ci --count 1

# PAT fallback (fine-grained, organization_self_hosted_runners scope only)
sudo ./install.sh --org your-org --access-token github_pat_xxx --user ci
```

`install.sh` downloads `actions/runner`, sets up the instance dir under `--runner-base` (default
`/opt/ci-runner-supabase/<i>`), writes `config.env` (mode 600), installs the `ci-runner@.service`
systemd template, and enables `ci-runner@1 .. ci-runner@N`. Flags are identical to
[`../light`](../light/README.md) (the only different defaults are labels, `--count 1`, and the base dir).

## Credentials
Supply exactly one (priority high → low):

| Model | Flag(s) | Use when |
|-------|---------|----------|
| **A — static** | `--token` | One-off/pilot. Expires ~1h. |
| **B — broker** | `--broker-url` + `--broker-secret` | Recommended. No GitHub credential on the host; the [token-broker](https://github.com/islee/gh-runners/tree/main/broker) mints fresh tokens. |
| **PAT** | `--access-token` | Unattended without a broker. Fine-grained PAT, `organization_self_hosted_runners` scope only — **never an admin PAT**. |

## Leftover cleanup (important)
Because the runner is ephemeral but **Docker state lives on the host**, a job that doesn't tear down
its stack can leave containers/volumes behind that accumulate across runs. Make your workflow stop the
stack in a final step that always runs, e.g.:

```yaml
- name: Stop Supabase
  if: always()
  run: supabase stop --no-backup || true
```

The persistent Docker image cache on the host (Postgres, Studio, …) is the **main speedup** over
hosted runners — it's the *running* stacks you must clean, not the image cache.

## Operate
```bash
systemctl status 'ci-runner@*'
journalctl -u 'ci-runner@1' -f
systemctl disable --now ci-runner@1   # offline (deregisters via SIGTERM trap)
```

## Uninstall
```bash
sudo ./uninstall.sh --count 1 --runner-base /opt/ci-runner-supabase           # keep dirs
sudo ./uninstall.sh --count 1 --runner-base /opt/ci-runner-supabase --purge   # delete dirs
```

## Security
**Ephemeral**, **least-privilege credential** (use model B or a scoped PAT, never an admin PAT),
**outbound-only**. Note this runner can use the host Docker daemon — only route trusted workflows
here (nightly `main` or maintainer-labeled), never untrusted fork PRs.
