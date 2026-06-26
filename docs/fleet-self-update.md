# Fleet self-update (design)

Status: **design / approved for P1**. Author: fleet maintainers. Reviewed by an architecture pass
(2026-06-26) that hardened the trust model and rollback; this doc reflects the post-review design.

## Problem

Runner *fleet code* (the ephemeral `runner-loop.sh` / entrypoints, not the `actions/runner` binary)
ships inside a teammate kit (`private/handout/`, see `build-package.sh`) as a one-shot zip. When we fix
that code, every already-installed runner is frozen until a human re-downloads the zip and re-runs
`setup.sh`. A real incident: a one-line fix to the `X-Runner-Name` header had to be pushed to every
live runner by hand (git pull on the host + copy the loop into each instance dir + restart units).
Teammates on an old zip would never have received it.

**Goal:** a runner picks up new fleet code on its own, safely, at the ephemeral boundary between jobs.

### Non-goals

- **GitHub `actions/runner` binary self-update** — GitHub already handles that; Docker/Windows variants
  pin it off with `--disableupdate`. This feature tracks *our* code only.
- **Updating `config.env` / `secret.env`** — those are teammate-owned and credential-bearing. Updates
  touch **code files only**, never config or secrets.
- **Inbound control.** Runners stay strictly outbound-only. No listener, no push channel.

## Threat model

The updater fetches code that then runs on a teammate's host — a supply-chain surface. The naive design
("pull files + a checksum manifest from the same public repo/ref") is **circular**: whoever can write
the ref (a compromised account/token, a malicious merged PR, a bad CI push) controls *both* the files
and the checksums that "verify" them. The SHA gate alone proves only CDN consistency, not authenticity.

Trust is therefore anchored **outside the fetched ref**, in the **broker** — a server we operate that
already authenticates every runner (`Authorization: Bearer $BROKER_SECRET`) and sees every registration
cycle. The broker tells the runner *which ref to be on* and *the expected manifest hash*; the runner
still pulls the bulk code from public GitHub (no broker bandwidth). Forging an update then requires
compromising **both** GitHub **and** the broker.

Defense layers:

1. **Broker-anchored integrity** — the expected `manifest_sha256` comes from the broker, not the repo.
2. **Path allowlist** — only a hardcoded set of basenames is updatable; any manifest entry containing
   `/`, `..`, or off the allowlist is rejected. A poisoned manifest can never target `config.env`,
   `secret.env`, `.runner`, credentials, or anything outside the runner dir.
3. **Pinned ref** — the fleet follows a **release tag** the maintainer cuts, never a moving branch.
4. **Ephemeral-boundary-only** — updates apply between jobs, never mid-job.
5. **Fail-safe** — any error (network, hash mismatch, manifest poison, broker unreachable) keeps the
   current code and retries next cycle. An update can never brick a runner.

## Architecture: stable bootstrap + swappable payload

The single most important structural decision. Each native runner is split:

- **Bootstrap** (`runner-bootstrap.sh`) — minimal, **never self-updated**. Owns the crash counter and
  rollback, then `exec`s the payload. Because the bootstrap is the thing that would *repair* a broken
  update, it must not be in the update path. (Updated only via a full re-install, with extra ceremony.)
- **Payload** (`runner-loop.sh` + `self-update.sh`) — the swappable fleet code. The ephemeral loop,
  token acquisition, and the updater itself.

This split solves three problems at once: (1) the updater can't brick its own update path; (2) rollback
is performed by code that isn't the code being rolled back; (3) it is the *same* shape as the Docker
"thin bootstrap" variant (P3), so native and container converge instead of diverging.

```
supervisor (systemd / launchd)
   └─ runner-bootstrap.sh        # stable; crash-counter + last_good rollback; never updated
        └─ exec runner-loop.sh   # swappable payload
             ├─ acquire token (broker) ─ reports X-Fleet-Version, receives {desired_ref, manifest_sha256}
             ├─ register --ephemeral --replace  →  run.sh (exactly one job)
             └─ self-update.sh   # between jobs: fetch→verify→atomic swap→exit 0 (supervisor relaunches)
```

## Native update mechanism (light / supabase / ios → P1; windows → P2)

### Per-variant manifest

Published per release tag at a stable raw URL, e.g.
`raw.githubusercontent.com/<repo>/<ref>/<type>/.fleet-manifest`:

```
version=2026.06.26.1
# sha256<TAB>basename   — CODE files only; the manifest is AUTHORITATIVE for the full managed set
<sha256>  runner-loop.sh
<sha256>  self-update.sh
```

- **Authoritative for the full set, including deletions.** The runner reconciles its managed files to
  exactly this list (add / update / remove within the allowlist) — no orphaned old scripts, and an
  added file not in the manifest is never trusted.
- **Comparison is by manifest content-hash, not `version` alone** — so a maintainer reverting a bad
  release by moving the tag backward still propagates (a version-only check would think it's current).

### Config knobs (`config.env`, written by `setup.sh` / `install.sh`)

| Key | Default | Meaning |
|---|---|---|
| `AUTO_UPDATE` | `1` | master on/off (teammate may set `0`) |
| `UPDATE_REPO` | repo slug | source repo for raw fetches |
| `UPDATE_REF` | release tag | the pinned ref the box follows (broker may override per cycle) |
| `UPDATE_MIN_INTERVAL` | `300` | seconds; floor between update checks regardless of cycle rate |

### Broker channel (rides the existing `/token` call — no extra request)

The runner already POSTs `/token` every cycle with `X-Runner-Name`. Extend that exchange:

- **Request header** `X-Fleet-Version: <local manifest version>` → broker records it per runner, so
  `/stats` shows fleet-code version distribution (we already attribute per runner). Distinguish
  **fleet-code-version** from **runner-binary-version** so neither masks the other.
- **Response fields** `{ desired_ref, manifest_sha256, min_version }`:
  - `desired_ref` — lets the maintainer **canary** by handing a new ref to a name-hashed subset.
  - `manifest_sha256` — the out-of-repo trust anchor the updater checks the fetched manifest against.
  - `min_version` — **advisory only** (see Decisions). Surfaced to `/stats`; never overrides opt-out.

Because both ride the cycle's existing token request, broker availability/cold-start is unchanged.

### The update step (`self-update.sh`, invoked by the loop after `run.sh`, before next register)

```
1. AUTO_UPDATE=1 and now - last_check >= UPDATE_MIN_INTERVAL ?           else return.
2. Fetch the manifest for desired_ref (conditional GET / ETag; 304 = nothing to do).
3. Verify sha256(manifest) == broker-supplied manifest_sha256.           mismatch → fail-safe, return.
4. If manifest content-hash == local stamp → return (already current).
5. For each entry: reject if basename ∉ allowlist or contains '/'..  →   any bad entry aborts the whole update.
6. Download each file to a tmp staged in the SAME dir; verify per-file sha256.
7. `bash -n` + a SELFTEST dry-run (source config, assert required functions/paths, exit without registering).
8. Commit atomically: mv each staged file over its target (preserve mode/owner), reconcile deletions,
   snapshot prior managed set → last_good/, write the version stamp LAST.
9. exit 0 → the supervisor relaunches the NEW payload.
```

Ordering guarantees an interrupted update is at worst "old code + stale/absent stamp" → retried, never
a partial cross-file state.

### Rollback (owned by the bootstrap, not the payload)

- A crash counter persisted to a file is incremented by the bootstrap **at startup** and cleared on the
  **first completed job** since a swap. "Good" is gated on *completing a job*, not a wall-clock window
  (an idle runner may sit hours between jobs).
- If the counter exceeds K since the last swap, the bootstrap restores `last_good/` (a snapshot tied to
  a version that completed ≥1 job — not merely `.prev`, which may never have run) and pins it.
- **Supervisor reconciliation:** widen systemd `StartLimitBurst` / `StartLimitIntervalSec` on the unit
  (and verify launchd `KeepAlive` *relaunches on clean exit* — a `SuccessfulExit=false` dict will not)
  so the supervisor's own rate-limiter can't mark the unit failed and stop it *before* rollback runs.

## Release process (`release.sh`, maintainer-run)

1. Compute per-file SHA-256s for each variant's managed set; write each `<type>/.fleet-manifest`.
2. Commit; **push files first**, wait for `raw.githubusercontent.com` propagation, **then** move the
   tag (same ordering as the runtime integrity gate).
3. Publish the new `{desired_ref, manifest_sha256}` to the broker (config/env), optionally to a canary
   subset first.

`build-package.sh` stamps each bundled variant with its `.fleet-version` so a freshly-installed box
knows its baseline.

## Per-supervisor relaunch semantics (verify before relying on `exit 0`)

| Variant | Supervisor | Relaunch on clean `exit 0`? | Note |
|---|---|---|---|
| light / supabase | systemd `Restart=always` | yes | widen `StartLimitBurst` so crash-loops don't get the unit killed pre-rollback |
| ios | launchd `KeepAlive` | **verify** | bare `true` relaunches; a `SuccessfulExit=false` dict does **not** |
| windows (P2) | Task Scheduler | **no** | clean exit does not relaunch by default → **needs its own supervision design** |
| docker (P3) | compose `restart: always` | yes | but baked image carries old entrypoint → needs thin-bootstrap, not exit-relaunch |

## Decisions

1. **Track a release tag, not `main`.** The fleet follows a tag the maintainer cuts → a staging gate
   and a single propagation action. (Decided.)
2. **`min_version` is advisory, never an override.** It does **not** force updates onto hosts that set
   `AUTO_UPDATE=0`. Rationale: an unauthenticated forced-update lever is a fleet-wide forced-RCE switch,
   and it can't even reach the runners from the motivating incident (they have no updater). Opt-out
   means opt-out; emergencies for opted-out hosts are handled by notifying the teammate, or — if ever
   truly needed — an authenticated, revocable broker-side mechanism, not a raw-GitHub file.
3. **Docker = option A (thin bootstrap), deferred to P3.** A fetches+checksums the loop at container
   start → parity with native, no registry. (B) published images + a pull timer adds a registry
   pipeline and updates mid-idle (loses the ephemeral-boundary invariant). P1's value is the native
   fleet (the incident was native hosts).

## Phasing

- **P1** — native `light` / `supabase` / `ios`: bootstrap/payload split, `self-update.sh`, broker
  `/token` channel, `release.sh`, manifests. This alone auto-ships fixes to native teammate runners.
- **P2** — Windows port (own supervision design; Task Scheduler won't relaunch on clean exit).
- **P3** — Docker thin-bootstrap (option A).

## Open risks / future work

- **Manifest signing as a second anchor.** Broker-supplied hash is the primary anchor; an out-of-repo
  signed manifest (minisign/cosign, public key in the package) would add defense even if the broker is
  compromised. Deferred.
- **Multi-instance dedup.** light/supabase run N instances from N dirs. P1 uses a per-host single
  updater (host-level lock + shared staged payload) to avoid N× fetches and transient version skew.
- **Canary policy** lives in the broker (name-hashed subset → `desired_ref`); staged rollout TBD.
- **`/stats` surfacing** of fleet-code vs binary version per runner, and a "below-floor / stale" flag.
