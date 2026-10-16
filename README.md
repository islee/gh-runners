# gh-runners

A self-hosted **GitHub Actions runner pool on one Apple Silicon Mac**, with automatic fallback to
GitHub-hosted runners. Every runner is a single-use **JIT** runner (one job, then gone), every job
runs in a fresh container or VM, and the host is **outbound-only** (no inbound ports). Everything
uses the first-party `actions/runner`. All org-specific values live in config files; nothing here is
tied to one organization.

## How it fits together

```
 consumer repo workflow                       Mac (slots/)                          off-pool host (rescuer/)
 ┌────────────────────────┐   repo variable   ┌──────────────────────────────┐     ┌──────────────────────────┐
 │ pick job: reads         │◄─────────────────│ heartbeat: SELF_HOSTED_STATE │     │ every 5 min: jobs queued │
 │ SELF_HOSTED_STATE       │                  │   ok@<ts>[/sat=…] | down@…   │     │ > 15 min on a pool label │
 │ fresh ok -> pool label  │                  │ slot loops: mint JIT, run    │     │ -> cancel + re-run, so   │
 │ else    -> ubuntu-latest│ ───jobs────────► │   1 job per container / VM   │     │ the pick job re-routes   │
 └────────────────────────┘                  └──────────────────────────────┘     └──────────────────────────┘
```

1. **Routing** happens in the consumer repo. A small `pick` job reads the repo variable
   `SELF_HOSTED_STATE` and returns the pool label (for example `ghr-light`) only if the value is a
   fresh `ok` and that class isn't saturated; otherwise it returns `ubuntu-latest`. A dead pool
   stops refreshing the variable, so jobs fall back to hosted runners within minutes without any
   other moving part.
2. **The pool** ([`slots/`](slots/)) runs one launchd loop per slot. Each loop mints a JIT runner
   config through a GitHub App and starts one job, either in a container inside a long-lived Lima VM
   (`light` class) or in a per-job Lima VM cloned from a golden image (`supabase` class). A heartbeat
   daemon publishes the pool's state to every consumer repo.
3. **The rescuer** ([`rescuer/`](rescuer/)) runs on a different always-on host. It catches the one
   case routing can't: the pool dies *after* a job was routed to it. It cancels and re-runs such
   runs so the `pick` job sends them to hosted runners.

## Layout

```
gh-runners/
├── slots/        # macOS host: JIT slot loops, Lima pool, heartbeat, installer (+ tests/, bats)
├── images/       # runner images: light (container, hosted-parity tool cache) and supabase (Lima golden VM)
├── rescuer/      # off-pool container: cancels + re-runs jobs stranded on pool labels (+ tests/, pytest)
├── requirements-dev.txt   # gate deps (pytest, ruff)
├── .pre-commit-config.yaml  .hadolint.yaml  .github/   # gate = CI (same hooks)
└── README.md  LICENSE  .gitignore
```

Each directory has its own README with setup steps, key files and gotchas.

## Credentials

Three GitHub Apps, each with one narrow job, so no host holds a broad credential:

| App role | Permissions | Held by | Used for |
|---|---|---|---|
| runner | org self-hosted runners: write | pool host, controller account | minting JIT runner configs, removing stale runners |
| state | Actions variables: write; org self-hosted runners: read | pool host, heartbeat account | writing `SELF_HOSTED_STATE`, the foreign-runner tripwire |
| rescuer | Actions: write | off-pool host (+ optional hosted backstop secret) | cancelling and re-running stranded runs |

The two keys on the pool host belong to separate role accounts. Jobs run as a third account, inside
a VM, with LAN egress blocked by pf.

## Security model

1. **Single-use runners.** A JIT runner takes exactly one job; its container or VM is destroyed
   afterwards. Labels and runner group are fixed at mint time and checked against an allow-list.
2. **Fail towards hosted.** Any doubt (stale heartbeat, stuck slot, a foreign or out-of-range runner
   in the org) publishes `down`, and routing sends jobs to GitHub-hosted runners.
3. **No secrets on argv.** JIT configs and tokens move through stdin and 0600 files only.
4. **Outbound-only.** Runners poll GitHub; nothing listens on the host.
5. **Don't route untrusted code here.** Fork PRs and other untrusted triggers belong on hosted runners.

## History

The previous generation (a FastAPI token broker on Render, systemd/launchd/Task Scheduler
runner loops for Linux, macOS, Android and Windows, and a fleet self-update mechanism) was removed
after tag [`legacy-fleet-final`](../../tree/legacy-fleet-final). Check out that tag to see it.

## License

MIT — see [`LICENSE`](LICENSE).
