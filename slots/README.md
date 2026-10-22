# slots/ — slot-loop controller for a self-hosted runner pool (macOS host + Lima VM / Tart VM; optional Proxmox host)

## Purpose

Keeps N single-use ("JIT") GitHub Actions runners alive on one Apple Silicon Mac, inside a Lima VM
(plus, optionally, one on-demand Tart macOS VM for Xcode builds), and publishes whether the pool is
healthy so callers can fall back to GitHub-hosted runners.
Org-level JIT runners need no repo registration; each slot mints a one-job runner, runs it in a
container, and repeats. Everything org-specific comes from one config file; nothing is hardcoded.

```
LaunchDaemon dev.ghr.slot.light-N  (_ghrctl)        LaunchDaemon dev.ghr.heartbeat (_ghrstate)
  slot-loop -> reconcile -> mint-jit                   reads slot state files + org runner list
           -> sudo -u ghr launch  (JIT on stdin)       -> SELF_HOSTED_STATE = "<state>@<epoch>[/sat=<classes>]"
                -> limactl shell ghr-pool -> docker run (JIT on stdin again)   (repo variable per consumer repo)
```

## Key Files

| File | Runs as | Does |
|------|---------|------|
| `lib/gh-app.sh` | sourced | Config load, runner-name regex, App JWT (openssl RS256), cached installation token, `gh_api` |
| `mint-jit.sh <name> <label...>` | `_ghrctl` | Policy gate + `generate-jitconfig`; prints only the JIT config |
| `reconcile.sh <name>` | `_ghrctl` | Deletes a stale offline runner with exactly that name |
| `slot-loop.sh <class> <n>` | `_ghrctl` | Forever loop, state file, backoff 30 to 300 s, graceful SIGTERM; the ios capacity lease and the supabase yield |
| `launch.sh <class> <n>` | `ghr` via sudo | Privilege boundary: validates args/stdin/image, pool ensure, LAN preflight, `docker run` (light) / per-job Lima VM (supabase) / per-job Tart VM (ios) |
| `pool.sh ensure\|rebuild` | `ghr` | Clone/start the Lima pool VM (`rebuild` is a stub) |
| `heartbeat.sh` | `_ghrstate` | Computes the state (`down`, `ok`, `ok@<ts>/sat=<classes>`, `saturated`), writes the repo variable, runs the tripwire and the ios demand probe |
| `install.sh` | root | Accounts, dirs, sudoers, scripts, config, plists; `--dry-run`, `--uninstall [--purge]` |
| `reload-slot.sh` | root (one-shot LaunchDaemon) | Waits for a busy slot daemon to exit, then bootstraps its new plist (scheduled by `install.sh`) |
| `launchd/*.plist` | root | Templates for slot / heartbeat / pool daemons (`@PLACEHOLDER@` rendered by install.sh) |
| `config.example.env` | root | Template for `/usr/local/etc/ghr/slots.env` (no secrets) |
| `../images/light/`, `../images/build-light.sh` | ghr | Derived runner image (hosted-parity tools + pre-warmed tool cache) and its Lima build script |
| `../images/supabase/`, `../images/build-supabase.sh` | ghr | Golden VM for the supabase class (provision, tool cache, full Supabase image pre-pull) |
| `../images/ios/`, `../images/build-ios.sh` | ghr | Golden Tart VM for the ios class (pinned Xcode base image + actions/runner, sshd off); operator steps, pf anchor and Tart install in `images/ios/README.md` |
| `launch-pve.sh <class> <n>` | root via sudo (Proxmox host) | Proxmox counterpart of `launch`'s supabase path: linked clone of the golden template, per-VM firewall file, guest-agent preflight + JIT hand-off, destroy on every exit |
| `install-pve.sh` | root (Proxmox host) | Account `ghrctl`, scripts, sudoers, `ghr-slot@.service` instances for `PVE_SLOTS`; `--dry-run`, `--uninstall [--purge]` |
| `slot-unit.sh <class>-<n>` | `ghrctl` (systemd) | Splits the unit instance name and execs `slot-loop` |
| `systemd/ghr-slot@.service` | root | Template unit rendered by `install-pve.sh` |
| `lib/pve-fw.sh`, `lib/pve-guest.sh` | sourced | The egress-isolation firewall file (single source) and bounded `qm guest exec` helpers |
| `../images/build-supabase-pve.sh`, `../images/supabase/{ghr-runner.service,ghr-runner-run,pve-user-data.yaml}` | root (Proxmox host) | Proxmox golden build and the guest-side per-job runner unit |
| `tests/*.bats`, `tests/helpers.bash`, `tests/run-bats.sh` | CI | Offline suite; curl/limactl/tart/qm/sudo are shims |

## Patterns

1. **The JIT config never touches argv or the environment on the host.** It lives in an unexported
   shell variable and moves only through pipes (`printf` is a builtin): slot-loop to `sudo` to
   `launch` to `limactl` to the container's `read -r J; exec ./run.sh --jitconfig "$J"`.
2. **`launch` is the privilege boundary.** The sudoers rule lets `_ghrctl` run exactly that one
   path as `ghr`; it re-validates class, slot range, stdin shape and an immutable image reference
   (`repo@sha256:<digest>` or a local image ID `sha256:<64 hex>`; tags and a leading `-` are refused).
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
9. **Capacity is negotiated through two small files, never through signals.** The heartbeat writes
   `demand/ios` (`<epoch> <count>`), the ios loop writes `capacity/ios.lease` (`<epoch>`), and every
   reader judges freshness from the epoch INSIDE the file, with a future-skew check. Stale or
   garbled means "no", so a crashed writer can only ever release capacity, never hold it.

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
6. SIGTERM semantics: TERMINATING is checked before reconcile, mint and launch. If the slot's
   runner is minted but not busy it is deleted (`reconcile.sh --release`) and the launch is
   abandoned; if busy, the job finishes first. A second signal kills the launch. `ExitTimeOut`
   is 21700 s to match the 6 h job limit. The sudo'd launch cannot be signalled by `_ghrctl`;
   deleting the runner makes the in-container listener exit, which ends it.
7. `ok` does not look at the job queue, so a queue stuck behind a healthy-looking pool is invisible to
   the published state; the org-side rescuer covers that case. (Only the optional ios demand probe
   reads the queue, and only to wake the ios slot; it needs the State App's `Actions: read`.)
   "Stuck" is judged from GitHub runner status instead: a slot in idle-prep/registered/backoff
   for over 120 s whose runner is not `online` marks the pool `down`. Slot files with a
   timestamp more than 5 s in the future also read as `down`.
8. `sudo` may leave the caller's `HOME`; `launch` re-derives `ghr`'s home before touching Lima.
9. Tripwire: a foreign runner name, a slot number beyond the configured count, or custom labels
   differing from the class label are latched in `/var/db/ghr/tripwire`; while it exists the
   published state is `down`. Delete the file after fixing the org. Exception for scale-down: a slot
   above the count is *retiring*, not foreign, while its own loop keeps its state file fresh
   (`RETIRE_SECS`, 180 s), so lowering `LIGHT_SLOTS`/`SUPABASE_SLOTS` doesn't trip on runners it is
   still releasing.
10. `launch` and `pool` are installed with `GHR_INSTALLED=1`, which makes them ignore every
   override variable (LIMACTL, GHR_CONFIG, TMPDIR, ...); the repo copy honours them for tests.
   The sudoers drop-in also sets `!setenv` and a fixed `secure_path`.
11. The pool lock is a symlink under `~ghr/.ghr/pool.lock` (atomic create, no garbled pid file).
12. launchd keeps log files open, so newsyslog rotation (installed to `/etc/newsyslog.d/ghr.conf`)
   takes full effect only after a daemon restart.
13. Role-account UIDs default to 451/452 (`GHRCTL_UID`/`GHRSTATE_UID` override) and the `sysadminctl
   -roleAccount` flags were not exercised on a real host by the test suite.
14. supabase class: `SUPABASE_SLOTS=0` (default) disables it; at most 3. Each job clones the STOPPED
   golden `ghr-supa-golden`, runs the runner natively in the VM and deletes the VM on every exit
   path (success, failure, timeout, signal, preflight refusal). `launch` never starts, stops or
   edits the golden; a missing or running golden is a refusal. Build it with
   `images/build-supabase.sh`; the LAN preflight runs inside each VM.
15. Saturation is per class: a class is saturated when ALL its configured slots have been busy for
   60 s. Published as `ok@<ts>/sat=supabase` (sorted, comma-joined classes) when only some classes
   are saturated, plain `saturated@<ts>` only when every configured class is, `down@<ts>` beats
   everything. Consumers route a job to hosted when its label's class is listed in `sat=`.
16. Re-running `install.sh` while jobs run is safe: a slot whose plist is unchanged only gets
   `launchctl kill SIGTERM` (the loop finishes its job, KeepAlive relaunches it within the 30 s
   ThrottleInterval with the new scripts). A changed plist is installed, booted out and, if the old
   loop is still mid-job after 30 s, handed to a one-shot `dev.ghr.reload.<slot>` job
   (`reload-slot.sh`, plist under `/usr/local/etc/ghr/reload`, waits up to 7 h) and reported as
   `[install] deferred: ...` with exit 0.
17. Remote slots: `REMOTE_SLOTS="supabase-5"` in the Mac's config lists slots served by another
   host. The heartbeat accepts those runner names in the tripwire (labels still checked), counts each
   as one more slot of its class for saturation, and treats a remote runner that is busy OR
   offline/absent as busy (an unreachable host adds no capacity, so jobs still spill to hosted). A
   remote slot has no state file and never makes the state `down`. Entries must match
   `(light|supabase)-<n>`, and `n` must be above the class's local count; others are ignored with a
   log line. An unlisted `ghr-supabase-5` still latches the tripwire.
18. Proxmox slot (`launch-pve`): runs as root via sudo because `qm` is root-only; `PVE_SLOTS` (not
   `SUPABASE_SLOTS`, keep that 0 on that host) lists its slots and `slot-loop` accepts them through
   `LAUNCH_USER=root` / `LAUNCH_BIN=.../launch-pve` set by the systemd unit. The Mac must not set
   `PVE_SLOTS`. VMID = `PVE_VMID_BASE + n`; the sweep only destroys VMs whose name AND VMID range
   match, and a different VM on the slot's VMID is never touched.
19. `qm guest exec` is synchronous with its own `--timeout` (default 30 s); on expiry the guest
   process keeps running but `qm` fails. So every step is bounded (`guest_exec` in `lib/pve-guest.sh`),
   the JIT is written by a short `cat` (stdin via `--pass-stdin`, 1 MiB max), and the long-running
   runner is started with `systemctl start --no-block`. The job's end is detected by polling
   `qm status`; the guest writes the runner's exit code to `/var/lib/ghr/exit`, which the host reads
   through the agent (every `PVE_EXIT_POLL_EVERY` polls) during a 60 s grace before the guest powers
   off. A VM that powers off before the code is read is reported as exit 0.
20. Per-VM firewall rules only apply when the NIC has `firewall=1` AND the datacenter firewall is
   enabled (`/etc/pve/firewall/cluster.fw`, `enable: 1`; enabling it also applies the default
   host rules, so allow management access first). `launch-pve` therefore never trusts the file: it
   checks `firewall=1` on the clone and probes `LAN_PROBE` from inside the guest after cloud-init
   finished (a guest whose network is not up yet would "cannot reach" anything). IPv6: only link-local
   and ULA ranges are dropped; give the VM no global IPv6 route to the LAN. The golden's storage must
   support linked clones (lvm-thin, zfs, qcow2 on a directory).
21. ios class (`IOS_SLOTS=1`, hard max 1): ONE Tart macOS VM per job for Xcode builds, cloned from the
   STOPPED golden (`images/build-ios.sh`), booted headless by a background `tart run`, reached only
   through the Tart guest agent (`tart exec`, as the guest's `admin`; sshd is off in the golden). The
   slot is DORMANT (no runner, no VM) until a job labelled `IOS_LABELS` is queued in one of
   `IOS_DEMAND_REPOS`: the heartbeat probes `actions/runs?status=queued|in_progress` (+ each run's
   jobs) every minute and writes `demand/ios`; a JIT runner registered on demand is assigned the
   already-queued job. Probe cost is 2 + (distinct queued/in-progress runs) API calls per repo per
   minute, so list only repos that really use the label. An API failure leaves the file alone (it
   ages out after `DEMAND_FRESH_SECS`, 150 s) and never changes the published state.
22. Why the supabase slots yield: a macOS VM needs 8 GiB, so with the light VM (8) and 4 GiB per
   supabase VM it fits only while at most `IOS_SUPA_KEEP` (default 1) supabase VMs exist. Order, as
   enforced by `slot-loop.sh`: demand -> ios takes the lease (`waiting-capacity`) -> each supabase slot
   above KEEP releases its idle runner or finishes its job, destroys its VM, and ONLY THEN writes
   `yielded` -> ios sees every such slot `yielded` (fresh) -> mint + launch. The wait is bounded by
   `IOS_YIELD_WAIT_SECS` (3600): on expiry the lease is dropped and the cycle backs off. The lease is
   refreshed every `TICK` while the ios slot waits or runs; it is removed when demand is gone, on
   SIGTERM and on any exit, and a lease older than `LEASE_FRESH_SECS` (60 s) is ignored. After a job
   with demand still fresh the lease is kept and the next job starts without letting supabase back in.
   An ios runner that is idle while the demand has gone (job cancelled) is released like a SIGTERM'd
   one, so a vanished job cannot pin the lease; a busy runner is asked again only every
   `BUSY_REPROBE_SECS`. While yielded or waiting, those slots count as busy for saturation, so
   supabase/ios jobs spill to hosted runners instead of queueing; they are healthy states, and an ios
   runner may be absent for `IOS_STUCK_SECS` (600) before the pool reads `down` (macOS boot).
   Releasing is never a kill: the `do_launch` subshell is not the process that owns the VM, so after
   `reconcile --release` succeeds the loop keeps waiting (state `releasing`, lease still refreshed for
   ios) until the launch has really exited; deleting the runner makes the launch fail and destroy its VM.
   After a failed ios cycle the slot takes no lease for a cooldown (900 s, doubling, max 3600) so the
   supabase slots are not starved by retry thrash. The demand probe runs after the state publish, within
   a 20 s budget, and only sees `workflow_dispatch` runs (ios workflows must be dispatch-only); a job wakes
   the slot when its labels include all of `IOS_LABELS` and nothing beyond them plus `self-hosted`.
23. Tart egress: the guest sits on Virtualization.framework NAT (`bridge100`, 192.168.64.0/24,
   gateway/DNS 192.168.64.1). That traffic is forwarded by the kernel and is NOT a socket of user
   `ghr`, so the existing `user ghr` pf rules do not cover it; `images/ios/README.md` gives the extra
   anchor rules. The in-guest preflight (`tart exec ... /bin/sh -c 'nc -z -G 5 ...; echo GHR_NC_RC=$?'` for
   EVERY `IOS_LAN_PROBES` entry, after a `/usr/bin/true` usability check) is the enforcement check: only a
   printed `GHR_NC_RC=1` counts as blocked (a `tart exec` transport error cannot pass as such), everything else refuses (exit 3). `LAN_PROBE` is not used for ios (a NAT
   guest cannot reach the host's own LAN address even unfiltered). Before `tart run`, `launch.sh`
   unlocks `ghr`'s login keychain (`security unlock-keychain` with the password on stdin; a macOS guest
   will not start otherwise); setup is an operator step in `images/ios/README.md`.
24. ios VM lifecycle hygiene: `TART_NO_AUTO_PRUNE=1` is exported so a clone can never evict the
   operator-pulled OCI base; the orphan sweep only touches canonical `ghr-ios-<n>` names that are not
   a configured slot (never the golden, never the `ghr-ios-build` VM); destroy is stop (bounded) ->
   reap the background `tart run` -> delete (bounded) -> verify via `tart list`, and an unreadable list
   is a LEAK, not "gone". The `tart list --format json` shape (`Name`, `State`/`Running`, `Source`) is
   parsed in ONE function (`tart_vm_states` in `launch.sh`, mirrored by `vm_field` in
   `build-ios.sh`) and was taken from Tart's source, not from a populated list.
