# gh-runners

Self-hosted **GitHub Actions runner** setups for a small, distributed CI fleet, **plus the token
broker** that registers them. Every runner is **ephemeral** (re-registers after each job, no state
bleeds between jobs) and **outbound-only** (polls GitHub — no inbound ports, no ingress). All of them
use the **official first-party `actions/runner`** — no third-party runner images.

Credentials are designed so **no runner host holds a standing GitHub admin credential**: the
[`broker/`](broker/) service mints short-lived registration tokens from a GitHub App, and runners
fetch one each cycle.

## The broker

[`broker/`](broker/) is a tiny FastAPI service that turns a GitHub App into short-lived runner
registration tokens. Deploy it once (always-on), then point every runner at it via `BROKER_URL` +
`BROKER_SECRET`. Deploy options: **Render** (root [`render.yaml`](render.yaml), `rootDir: broker`),
or **Docker** ([`broker/docker-compose.yml`](broker/docker-compose.yml) / `broker/Dockerfile`). See
[`broker/README.md`](broker/README.md).

## Runner types

| Dir | Workload | Runtime | Default labels |
|-----|----------|---------|----------------|
| [`light/`](light/) | Lint / unit / anything without Docker | Vanilla `actions/runner` + **systemd** (no Docker) | `self-hosted,linux,x64,light` |
| [`supabase/`](supabase/) | Jobs that run a Docker stack (e.g. `supabase start`) | Vanilla `actions/runner` + **systemd**, on a host that has Docker | `self-hosted,linux,x64,supabase` |
| [`android/`](android/) | Android E2E (emulator + Maestro) | **Docker** on the official `ghcr.io/actions/actions-runner` image, KVM-accelerated | `self-hosted,linux,x64,mobile,android` |
| [`ios/`](ios/) | iOS E2E (+ Android-on-Mac) | Vanilla `actions/runner` + **launchd** (macOS, Apple Silicon) | `self-hosted,mobile,ios,android` |

Each directory is **self-contained** — copy just the one you need onto its host and follow its README.
`light/` and `supabase/` also ship an optional container-per-job variant under their `docker/`
subdir (official `ghcr.io/actions/actions-runner` image) for hosts that want Docker isolation.

### Naming

Runners register as **`gh-runner-<type>-<id>-<n>`** — `<type>` is the runner type
(`light`/`supabase`/`android`/`ios`), `<id>` identifies the host or user (defaults to the host short
name; set with `--owner` on the installers or `OWNER` in compose), `<n>` is the instance number
(auto from `--count` for systemd installs; `RUNNER_NUMBER` for the Docker variants). E.g. two light
runners on host `ci-linple` register as `gh-runner-light-ci-linple-1` and `-2`. The name is **fixed
per instance** — each ephemeral cycle re-registers it with `--replace`.

> Why Docker only for android: the emulator wants a reproducible SDK/Maestro image and clean per-job
> teardown. The others run jobs directly on the host, which is simpler and — for the `supabase` case —
> actually avoids a networking workaround (a host-level runner sees `127.0.0.1` and bind paths
> natively, with no `network_mode: host` hack).

## Credential models

Every runner accepts exactly one of three credentials (priority high → low):

| Model | Variable(s) | Use when |
|-------|-------------|----------|
| **A — static token** | `RUNNER_TOKEN` | Quick one-off/pilot. A bare registration token **expires ~1h**, so it only survives the first registration of a re-registering runner. |
| **B — broker** (recommended) | `BROKER_URL` + `BROKER_SECRET` | Fleet/unattended. No GitHub credential on the runner; the [`broker/`](broker/) holds the GitHub App key and mints fresh tokens each cycle. |
| **C — PAT** | `ACCESS_TOKEN` | Unattended without a broker. A **fine-grained PAT scoped to `organization_self_hosted_runners` only** — the runner mints fresh registration tokens via the GitHub REST API each cycle. **Never an org-admin PAT.** |

## Security model

These runners execute code from GitHub Actions workflows on the host. Blast radius is bounded by:

1. **Ephemeral** — every job runs on a freshly-registered runner; tokens/workspace/env don't persist.
2. **No untrusted fork PRs** — wire the mobile/E2E jobs to trigger only on nightly `main` runs or an
   explicit maintainer-applied label, never automatically on `pull_request` from forks.
3. **Least-privilege credential** — the runner's credential can only manage runners, not read code or
   secrets. Use model B or a scoped PAT; never paste an admin PAT.
4. **Outbound-only** — runners poll GitHub; no inbound ports or ingress to expose.

## Deployment env files

Per-target env files at the repo root capture the config shared by everything on a given host.
**Real ones are gitignored; `*.example` templates are committed** (rule: `.env*` is ignored except
`.env*.example`).

| File | Target | Holds |
|------|--------|-------|
| [`.env.render.example`](.env.render.example) | Render (the broker) | `GH_ORG`, GitHub App id/installation/key, `BROKER_SECRET` |
| [`.env.pve.example`](.env.pve.example) | A Linux host (light/supabase/android) | `GH_ORG`, `BROKER_URL`, `BROKER_SECRET` |
| [`.env.mac.example`](.env.mac.example) | A Mac (ios) | `GH_ORG`, `BROKER_URL`, `BROKER_SECRET`, labels, runner dir |

Copy the relevant `.example` to its real name (e.g. `.env.pve`), fill it, and feed the values to the
runner installer / compose / Render dashboard.

## Layout

```
gh-runners/
├── broker/       # token broker (FastAPI): GitHub App → short-lived registration tokens
│                 #   Dockerfile, docker-compose.yml, tests/  (Render via root render.yaml)
├── light/        # Linux, systemd, no Docker        (+ docker/ container variant)
├── supabase/     # Linux, systemd, host has Docker   (+ docker/ container variant)
├── android/      # Docker (official ghcr.io/actions/actions-runner) + KVM emulator
├── ios/          # macOS, launchd
├── render.yaml   # Render Blueprint for broker/ (rootDir: broker)
├── .env.{render,pve,mac}.example   # per-target env templates (real ones gitignored)
├── README.md  LICENSE  .gitignore  .hadolint.yaml
```

## License

MIT — see [`LICENSE`](LICENSE).
