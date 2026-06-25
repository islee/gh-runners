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

> **Runner names:** each instance registers as `gh-runner-light-<owner>-<i>` (the
> `gh-runner-<type>-<id>-<n>` convention) — fixed per instance, re-registered each cycle with `--replace`.

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
