# light — Linux CI runner (no Docker)

Ephemeral, self-hosted GitHub Actions runners for **lightweight jobs** (lint, format, unit tests —
anything that doesn't need Docker). Uses the **official `actions/runner`** driven by **systemd**;
no container, no third-party image. Default: **2 instances** labelled `self-hosted,linux,x64,light`.

Each runner re-registers after every job (`--ephemeral`) and polls GitHub **outbound only** (no
inbound ports).

> Want container-per-job isolation instead of a host-level service? See [`docker/`](docker/) — a
> Docker variant on the official `ghcr.io/actions/actions-runner` image.

## Prerequisites
- Linux host (`x86_64` or `aarch64`) with **systemd**.
- `curl`, `tar`, `python3` (the loop parses token JSON with python3).
- A non-root user to run the runner under (jobs run as this user). `actions/runner` refuses to run as
  root by default — don't use root.
- One credential — see [Credentials](#credentials).

> **Job-runtime baseline (hosted-runner parity).** A bare host lacks tools that GitHub-hosted images
> ship and that `setup-*` actions shell out to, so jobs fail mid-run (`Unable to locate executable
> file: unzip` / `lsb_release`). `install.sh` therefore **installs a declared baseline ahead of
> time** (`unzip zip xz-utils zstd lsb-release ca-certificates`; extend with `--extra-packages`) and
> points the runner at a shared tool cache via `AGENT_TOOLSDIRECTORY`. See
> [Hosted-runner parity](#hosted-runner-parity).

## Install
Copy this `light/` directory to the host, then:

```bash
# Model B — token-broker (recommended)
sudo ./install.sh --org your-org \
  --broker-url https://<your-broker-host> --broker-secret <secret> \
  --user ci --count 2

# PAT fallback (fine-grained, organization_self_hosted_runners scope only)
sudo ./install.sh --org your-org --access-token github_pat_xxx --user ci

# Model A — static token (quick one-off; expires ~1h)
sudo ./install.sh --org your-org --token <REG_TOKEN> --user ci --count 1
```

`install.sh` downloads `actions/runner`, sets up `--count` instance dirs under `--runner-base`
(default `/opt/gh-runner-light/<i>`), writes each a `config.env` (mode 600), installs the
`gh-runner@.service` template as `gh-runner-light@.service` (per-type name prevents collision when
light and supabase runners share a host), and enables `gh-runner-light@1 .. gh-runner-light@N`.

| Flag | Default | Notes |
|------|---------|-------|
| `--org` | `your-org` | Your GitHub org login |
| `--labels` | `self-hosted,linux,x64,light` | Must match the workflow's `runs-on:` |
| `--count` | `2` | Number of concurrent runner instances |
| `--user` | invoking sudo user | Non-root user the runners run as |
| `--owner` | host short name | `<id>` in the runner name `gh-runner-light-<id>-<n>` (use a username on a shared fleet) |
| `--runner-base` | `/opt/gh-runner-light` | Parent dir; instance `i` lives at `<base>/<i>` |
| `--runner-version` | pinned | Bump when GitHub rejects the pinned version |
| `--extra-packages` | — | Extra apt packages to install ahead of time (e.g. `"ripgrep make"`) |
| `--skip-job-deps` | off | Don't install the job-runtime OS baseline |
| `--toolcache-dir` | `/opt/hostedtoolcache` | Shared tool cache (`AGENT_TOOLSDIRECTORY`) |
| `--skip-toolcache` | off | Don't create/stage the tool cache |
| `--stage-python` | — | Repeatable: pre-stage Python `<ver>` (e.g. `3.13`) — **required for setup-python on non-Ubuntu hosts** |
| `--with-playwright` | off | Provision the Playwright browser capability (system libs + shared cache + `playwright` label) |
| `--playwright-version` | latest | Pin the `playwright` npm version used to install deps/browsers |
| `--playwright-browser` | `chromium` | Browser to install deps for and pre-warm |
| `--playwright-browsers-path` | `/opt/ms-playwright` | Shared, persistent browser cache (`PLAYWRIGHT_BROWSERS_PATH`) |

> **Runner names:** each instance registers as `gh-runner-light-<owner>-<i>` (the
> `gh-runner-<type>-<id>-<n>` convention) — fixed per instance, re-registered each cycle with `--replace`.

## Hosted-runner parity
GitHub-hosted runners ship a large toolset and a pre-populated tool cache. A bare self-hosted host has
neither, so `setup-*` actions fail at runtime. `install.sh` closes the gap **ahead of time**:

- **OS baseline** — installs `unzip zip xz-utils zstd lsb-release ca-certificates` (extend with
  `--extra-packages`, opt out with `--skip-job-deps`). On non-apt distros it warns instead.
- **Tool cache** — creates `--toolcache-dir` (default `/opt/hostedtoolcache`) and bakes
  `Environment=AGENT_TOOLSDIRECTORY=…` into the systemd unit. The runner derives `RUNNER_TOOL_CACHE`
  from it, so `setup-python`/`-node`/`-deno` resolve from one shared, persistent cache.
- **setup-python on non-Ubuntu hosts** — `actions/setup-python` only publishes prebuilt Pythons for
  Ubuntu; on Debian/other distros it cannot download and errors *unless the version is already in the
  tool cache*. Pass `--stage-python 3.13` (repeatable) to pre-stage it from `actions/python-versions`.
  On **Ubuntu** hosts this is optional — `setup-python` downloads successfully (just uncached).

## Playwright capability
Browser e2e jobs run `playwright install --with-deps`, whose `--with-deps` half needs **root apt** to
install Chromium's shared libraries — which a job on a non-root runner can't do. `--with-playwright`
provisions this once at install time and splits the two costs (see `docs/fleet-design.md`):

- **System libraries (root, stable)** — runs `playwright install-deps` so the apt set tracks the OS,
  not a hardcoded list. Installs `nodejs`/`npm` first if no `npx` is present.
- **Browser binaries (per-version, cached)** — bakes `Environment=PLAYWRIGHT_BROWSERS_PATH=…` (default
  `/opt/ms-playwright`) into the unit and pre-warms the browser there. The cache is shared across
  instances and persists across jobs; each job's `playwright install` is then a fast cache hit.
- **Label** — appends `playwright` to the runner's labels so browser jobs can target this capability.

Consumer workflows then **drop `--with-deps`** and select the `playwright` capability (still behind a
`pick-runner` with `ubuntu-latest` fallback, where the libs ship by default).

```bash
sudo ./install.sh --broker-url "$BROKER_URL" --broker-secret "$BROKER_SECRET" \
  --org gyeolhada-team --with-playwright --stage-python 3.13
```

## Credentials
Supply exactly one (priority high → low):

| Model | Flag(s) | Use when |
|-------|---------|----------|
| **A — static** | `--token` | One-off/pilot. Expires ~1h, so it survives only the first registration. |
| **B — broker** | `--broker-url` + `--broker-secret` | Recommended. No GitHub credential on the host; the [token-broker](https://github.com/islee/gh-runners/tree/main/broker) mints fresh tokens. |
| **C — PAT** | `--access-token` | Unattended without a broker. Fine-grained PAT, `organization_self_hosted_runners` scope only — **never an admin PAT**. |

## Operate
```bash
systemctl status 'gh-runner-light@*'        # all instances
journalctl -u 'gh-runner-light@1' -f        # follow instance 1
systemctl disable --now gh-runner-light@1   # take instance 1 offline (deregisters via SIGTERM trap)
systemctl enable  --now gh-runner-light@1   # bring it back
```

## Uninstall
```bash
sudo ./uninstall.sh --count 2 --runner-base /opt/gh-runner-light          # keep dirs
sudo ./uninstall.sh --count 2 --runner-base /opt/gh-runner-light --purge  # delete dirs
```

## Security
Runners execute workflow code on this host. Mitigations: **ephemeral** (no state between jobs),
**least-privilege credential** (can only manage runners — use model B or a scoped PAT, never an admin
PAT), **outbound-only**. Don't route untrusted fork-PR workflows here — gate E2E/mobile jobs on
nightly `main` or a maintainer-applied label.
