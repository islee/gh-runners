# windows — Windows CI runner (no Docker)

Ephemeral, self-hosted GitHub Actions runners for **lightweight jobs** (lint, format, unit tests —
anything that doesn't need Docker or a container runtime). Uses the **official `actions/runner`**
driven by the **Windows Task Scheduler**; no NSSM, no container, no third-party image. Default:
**1 instance** labelled `self-hosted,windows,x64,light`.

Each runner re-registers after every job (`--ephemeral`) and polls GitHub **outbound only** (no
inbound ports).

## Prerequisites

- Windows 10 / 11 or Windows Server 2019+ (`x64`).
- PowerShell 5.1 or later (ships in-box on all supported Windows versions).
- **Administrator rights** for install: Task Scheduler 'run whether logged on or not' and the
  ACL restriction on `config.env` both require elevation. The runner loop itself runs under
  `NT AUTHORITY\SYSTEM` (set by the scheduled task — no interactive session needed).
- Internet access to `github.com` and `api.github.com` (outbound HTTPS only).
- One credential — see [Credentials](#credentials).

## Install

Copy this `windows\` directory to the host, then open an **elevated PowerShell** prompt:

```powershell
# Model B — token-broker (recommended)
.\install.ps1 -Org your-org `
  -BrokerUrl https://<your-broker-host> -BrokerSecret <secret> `
  -Count 2

# Model C — PAT fallback (fine-grained, organization_self_hosted_runners scope only)
.\install.ps1 -Org your-org -AccessToken github_pat_xxx

# Model A — static token (quick one-off; expires ~1h)
.\install.ps1 -Org your-org -Token <REG_TOKEN> -Count 1
```

`install.ps1` downloads `actions/runner` win-x64 zip, expands it into one dir per instance under
`-RunnerBase` (default `C:\actions-runner-windows\<i>`), writes each a `config.env`
(ACL-restricted to SYSTEM and Administrators — the Windows analogue of Unix mode 600), copies
`runner-loop.ps1` into each instance dir, and registers one Windows Scheduled Task per instance
(`gh-runner-windows@<i>`) that starts at boot and restarts on failure.

| Flag | Default | Notes |
|------|---------|-------|
| `-Org` | `your-org` | Your GitHub org login |
| `-Labels` | `self-hosted,windows,x64,light` | Must match the workflow's `runs-on:` |
| `-Count` | `1` | Number of concurrent runner instances |
| `-Owner` | `$env:COMPUTERNAME` | `<id>` in the runner name `gh-runner-windows-<id>-<n>` (use a username on a shared fleet) |
| `-RunnerBase` | `C:\actions-runner-windows` | Parent dir; instance `i` lives at `<base>\<i>` |
| `-RunnerVersion` | pinned | Bump when GitHub rejects the pinned version |

> **Runner names:** each instance registers as `gh-runner-windows-<owner>-<i>` (the
> `gh-runner-<type>-<id>-<n>` convention) — fixed per instance, re-registered each cycle with `--replace`.

> **Execution policy:** `install.ps1` must be run under an unrestricted or `Bypass` execution policy
> for the current session. The scheduled task itself is registered with `-ExecutionPolicy Bypass`
> so it runs unattended regardless of machine policy.

## Credentials

Supply exactly one (priority high → low):

| Model | Flag(s) | Use when |
|-------|---------|----------|
| **A — static** | `-Token` | One-off/pilot. Expires ~1h, so it survives only the first registration. |
| **B — broker** | `-BrokerUrl` + `-BrokerSecret` | Recommended. No GitHub credential on the host; the [token-broker](https://github.com/islee/gh-runners/tree/main/broker) mints fresh tokens each cycle. |
| **C — PAT** | `-AccessToken` | Unattended without a broker. Fine-grained PAT, `organization_self_hosted_runners` scope only — **never an admin PAT**. |

## Operate

```powershell
# Check task state for all instances
Get-ScheduledTask -TaskName 'gh-runner-windows@*'

# Start / stop a specific instance (stop triggers the finally-block deregister in runner-loop.ps1)
Start-ScheduledTask -TaskName 'gh-runner-windows@1'
Stop-ScheduledTask  -TaskName 'gh-runner-windows@1'

# Recent task events from the Task Scheduler operational log
Get-WinEvent -LogName Microsoft-Windows-TaskScheduler/Operational -MaxEvents 50 |
    Where-Object { $_.Message -like '*gh-runner-windows*' }

# Application event log entries written by runner-loop.ps1 (source: gh-runner)
Get-WinEvent -LogName Application -MaxEvents 100 |
    Where-Object { $_.ProviderName -eq 'gh-runner' }

# Runner's own diagnostic logs (written by run.cmd into each instance dir)
Get-ChildItem 'C:\actions-runner-windows\1\_diag\Runner_*.log' | Select-Object -Last 1 | Get-Content -Tail 50
```

## Uninstall

```powershell
# Keep runner dirs (logs, _work preserved)
.\uninstall.ps1 -Count 2 -RunnerBase C:\actions-runner-windows

# Remove runner dirs entirely
.\uninstall.ps1 -Count 2 -RunnerBase C:\actions-runner-windows -Purge
```

`uninstall.ps1` stops and unregisters each scheduled task, which fires `runner-loop.ps1`'s `finally`
block to deregister the runner from GitHub. Any runner still visible in org → Settings → Actions →
Runners after uninstall was mid-job or had an expired deregister token — remove those manually.

## Security

Runners execute workflow code on this host. Mitigations:

- **Ephemeral** — every job runs on a freshly-registered runner; no workspace state, tokens, or env
  vars persist between jobs.
- **Least-privilege credential** — the runner's credential can only manage runners, not read code or
  secrets. Use model B (broker) or a scoped PAT; never embed an admin PAT.
- **Outbound-only** — runners poll GitHub; no inbound ports or ingress to open or expose.
- **config.env ACL** — `install.ps1` removes all inherited permissions and grants only SYSTEM and
  Administrators read access, preventing other local accounts from reading credentials at rest.
- **Runs as SYSTEM** — the scheduled task runs under `NT AUTHORITY\SYSTEM` with no stored user
  password, so credential rotation never blocks restarts.
- **Don't route untrusted fork PRs here** — gate E2E or time-consuming jobs on nightly `main` builds
  or a maintainer-applied label, never automatically on `pull_request` from forks.

> Labels must match the workflow's `runs-on:` exactly. A mismatch means jobs queue but never pick up.
> Use `runs-on: [self-hosted, windows, x64, light]` to route to these runners.
