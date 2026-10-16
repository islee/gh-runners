# slots/ — slot-loop controller for a self-hosted runner pool (macOS host + Lima VM)

## Purpose

Keeps N single-use ("JIT") GitHub Actions runners alive on one Apple Silicon Mac, inside a Lima VM,
and publishes whether the pool is healthy so callers can fall back to GitHub-hosted runners.
Org-level JIT runners need no repo registration; each slot mints a one-job runner, runs it in a
container, and repeats. Everything org-specific comes from one config file; nothing is hardcoded.

```
LaunchDaemon dev.ghr.slot.light-N  (_ghrctl)        LaunchDaemon dev.ghr.heartbeat (_ghrstate)
  slot-loop -> reconcile -> mint-jit                   reads slot state files + org runner list
           -> sudo -u ghr launch  (JIT on stdin)       -> SELF_HOSTED_STATE = "<ok|saturated|down>@<epoch>"
                -> limactl shell ghr-pool -> docker run (JIT on stdin again)   (repo variable per consumer repo)
```

## Key Files

| File | Runs as | Does |
|------|---------|------|
| `lib/gh-app.sh` | sourced | Config load, runner-name regex, App JWT (openssl RS256), cached installation token, `gh_api` |
| `mint-jit.sh <name> <label...>` | `_ghrctl` | Policy gate + `generate-jitconfig`; prints only the JIT config |
| `reconcile.sh <name>` | `_ghrctl` | Deletes a stale offline runner with exactly that name |
| `slot-loop.sh <class> <n>` | `_ghrctl` | Forever loop, state file, backoff 30 to 300 s, graceful SIGTERM |
| `launch.sh <class> <n>` | `ghr` via sudo | Privilege boundary: validates args/stdin/image, pool ensure, LAN preflight, `docker run` |
| `pool.sh ensure\|rebuild` | `ghr` | Clone/start the Lima pool VM (`rebuild` is a stub) |
| `heartbeat.sh` | `_ghrstate` | Computes ok/saturated/down, writes the repo variable, runs the tripwire |
| `install.sh` | root | Accounts, dirs, sudoers, scripts, config, plists; `--dry-run`, `--uninstall [--purge]` |
| `launchd/*.plist` | root | Templates for slot / heartbeat / pool daemons (`@PLACEHOLDER@` rendered by install.sh) |
| `config.example.env` | root | Template for `/usr/local/etc/ghr/slots.env` (no secrets) |
| `tests/*.bats`, `tests/helpers.bash`, `tests/run-bats.sh` | CI | Offline suite; curl/limactl/sudo are shims |

## Patterns

1. **The JIT config never touches argv or the environment on the host.** It lives in an unexported
   shell variable and moves only through pipes (`printf` is a builtin): slot-loop to `sudo` to
   `launch` to `limactl` to the container's `read -r J; exec ./run.sh --jitconfig "$J"`.
2. **`launch` is the privilege boundary.** The sudoers rule lets `_ghrctl` run exactly that one
   path as `ghr`; it re-validates class, slot range, stdin shape and a digest-pinned image.
3. **Label policy is centralised in `mint-jit.sh`**: hosted labels refused first, then
   `ALLOWED_LABELS` (empty = refuse everything), then a JSON-safe charset. Name regex is anchored.
4. **Two Apps, two keys, two accounts.** Runner App (mint/delete runners) and state App (variables +
   runner read) are never mixed; each key is 0400 and owned by its role account.
5. **Fail toward hosted.** Any doubt (stale slot file, stuck slot, runner list unreachable) means
   `down` or no update; `pick-runner` treats anything but a fresh `ok` as "use hosted".
6. **Scripts are source-guarded** (`main` runs only when executed) so bats can call the functions.
7. **Tests are offline.** `tests/helpers.bash` generates a throwaway RSA key per test and shims
   `curl`/`limactl`/`sudo`; negative assertions use `refute` (a bare `! cmd` is a no-op under `set -e`).
8. **bash 3.2 compatible** (macOS `/bin/bash`): no associative arrays, `mapfile`, or `${v,,}`.

## Install / operate

```
sudo slots/install.sh --dry-run                      # review the plan
sudo slots/install.sh --config my-slots.env --runner-key r.pem --state-key s.pem
sudo slots/install.sh --uninstall [--purge]
bash slots/tests/run-bats.sh                         # or: pre-commit run --all-files
```

Operator clears a tripwire by deleting `/var/db/ghr/tripwire` after removing the foreign runner.

## Gotchas

1. `nohup` fails without a controlling terminal on macOS; use launchd, not shell backgrounding.
2. `limactl shell` consumes stdin: every non-piping call here redirects `< /dev/null`.
3. `limactl start` forks a long-lived host agent; daemons that can start the VM set
   `AbandonProcessGroup` or launchd kills the VM when the job exits.
4. `*.env` is gitignored; `config.example.env` is re-included explicitly in `.gitignore`.
5. Org variables do not reach private repos on GitHub Free, so the heartbeat writes a repo-level
   variable per consumer repo.
6. A first SIGTERM to an idle slot waits for its (not yet started) job; send a second signal to
   force-exit. The plist's `ExitTimeOut` is 21700 s to match the 6 h job limit.
7. "Stuck" detection uses GitHub runner status, not the job queue: the state App has no
   `Actions: read`. A slot in idle-prep/registered/backoff for over 180 s whose runner is not
   `online` marks the whole pool `down`.
8. `sudo` may leave the caller's `HOME`; `launch` re-derives `ghr`'s home before touching Lima.
9. Role-account UIDs default to 451/452 (`GHRCTL_UID`/`GHRSTATE_UID` override) and the `sysadminctl
   -roleAccount` flags were not exercised on a real host by the test suite.
