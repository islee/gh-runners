# Fleet design — comprehensive runner coverage for `gyeolhada-team`

Status: **proposal + in-progress**. Authored 2026-06-26 from an audit of all `gyeolhada-team` repos.
This doc is the cross-cutting map: who needs CI compute, what capability classes exist, the target
fleet topology, and the roadmap. Per-runner-type mechanics stay in each dir's README.

## Why

CI compute for the org is currently ad-hoc: three repos (`gyeolhada-be`/api, `staff-portal`,
`gyeolhada-fe`/frontend) self-select a self-hosted runner via a copy-pasted `pick-runner` job; every
other repo runs on GitHub-hosted `ubuntu-latest` (or has no CI). The goal is a **comprehensive,
capability-classed fleet** that every repo can target uniformly, with GitHub-hosted as the always-safe
fallback — never a hard dependency.

## Demand map (audit, 2026-06-26)

| Repo | Stack | CI today | Capability class needed |
|------|-------|----------|--------------------------|
| `gyeolhada-be` (api) | Deno + Supabase fns | self-hosted `light`+`supabase` | light, **supabase** |
| `staff-portal` | React Router + Vite | self-hosted `light` | light, **playwright** |
| `gyeolhada-fe` (frontend) | Expo / RN | self-hosted `light`+`mobile` | light, **android**, **ios** |
| `gyeolhada-match` | Python 3.11 | ubuntu-latest | light (+ supabase for integration) |
| `tier-service` | Python 3.13 | ubuntu-latest | light (+ supabase for integration) |
| `post-match-service` | Python 3.12/3.13 | ubuntu-latest (weekly) | light |
| `location-service` | Python 3.13 + Playwright | ubuntu-latest | light, **playwright** |
| `test-profiles` | Python + torch/transformers | ubuntu-latest (nightly) | **heavy/ml** |
| `schemas` | Deno → npm | ubuntu-latest (publish) | light |
| `dashboard-service` | Evidence.dev | Vercel | — (no GH Actions) |
| `DashboardService`, `verification-service`, `gyeolhada-marketing-data`, `marketing_tool`, `homepage`, `linple-homepage`, `referral-portal` | various | none / Vercel / Cloud Run | — |

## Capability classes

The fleet is organised by **capability label**, not by host. A job declares the capability it needs;
any online runner carrying that label (on any host) can serve it.

| Label | Built on | Adds over `light` | Consumers |
|-------|----------|-------------------|-----------|
| `light` | vanilla actions/runner + systemd | hosted-runner package baseline + tool cache (Python staging) | everyone (lint/typecheck/unit/build) |
| `playwright` | `light` | Chromium **system libs** (root apt) + shared browser cache (`PLAYWRIGHT_BROWSERS_PATH`) | staff-portal, location-service |
| `supabase` | `light` + host Docker | local `supabase start` stack, postgresql-client | api e2e, Python integration tests |
| `mobile,android` | official runner image + KVM | emulator, Java/adb/SDK, Maestro | frontend android-e2e |
| `mobile,ios` | macOS launchd | Xcode, iOS simulator, Maestro | frontend ios / maestro suites |
| `heavy` / `ml` | `light` + persistent dep cache | pre-warmed torch/transformers, big RAM | test-profiles nightly |

`light`/`supabase`/`android`/`ios` already exist as gh-runners types. `playwright` and `heavy` are the
new capability layers — both are thin extensions of `light`, not new runner types.

## The `playwright` capability (this PR)

**Problem.** `staff-portal` and `location-service` run `playwright install --with-deps`, which needs
**root apt** to install Chromium's shared libraries. On the Debian LXC `light` host that either fails
or forces a fallback to `ubuntu-latest`, and even when it works it re-downloads browsers (~5–10 min)
every job.

**Design.** Split the two costs:
1. **System libs (root, stable):** install once at provision time via `playwright install-deps`
   (`light/install.sh --with-playwright`). This is the part that genuinely needs root; it changes
   rarely (tied to the OS, not the repo's Playwright version).
2. **Browser binaries (per-version, cacheable):** point every job at a shared, persistent
   `PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright` (baked into the systemd unit, chowned to the run user).
   The first job that needs a given browser version populates it; all later jobs reuse it. Jobs then
   run plain `playwright install chromium` (no `--with-deps`, no root) and it's a cache hit.
3. **Label:** `--with-playwright` appends `playwright` to the runner's labels so browser jobs target it.

Consumer change: drop `--with-deps` and add `runs-on` of the `playwright` capability (still behind
`pick-runner` with `ubuntu-latest` fallback). On the fallback path `--with-deps` is unnecessary because
GitHub-hosted images already ship the libs.

## Target topology (end-state)

| Pool / label | Host | Count (now → target) | Serves |
|---|---|---|---|
| `light` | pve CT102 | 2 → 3 | all lint/unit/build, Python services, schemas |
| `playwright` | pve CT102 (light + browsers) | 0 → 1 | staff-portal, location-service e2e |
| `supabase` | pve CT102 (host Docker) | 1 → 2 | api e2e + Python DB integration |
| `mobile,android` | pve CT102 (KVM) | 1 | frontend android-e2e |
| `mobile,ios` | Mac(s) | 1 → 2 | frontend ios / maestro suites |
| `heavy`/`ml` | pve (persistent cache) | 0 → 1 | test-profiles nightly |

Capacity is the real constraint (one pve host + one M4 Mac). "Comprehensive" means **capability
coverage first**, then headroom where a queue actually forms (supabase serialises behind api; macOS is
the scarce premium tier).

## Roadmap

1. **`playwright` capability** — provision in `light/install.sh`; document; (this PR).
2. **Onboard Python services** — give `gyeolhada-match`, `tier-service`, `post-match-service`,
   `location-service` the self-hosted selector → `light` pool (ubuntu fallback); `location-service`
   also takes `playwright`.
3. **DB integration on the `supabase` pool** — migrate Python integration tests off shared
   staging/prod Supabase onto an ephemeral local stack. Caveat: one stack per host (16 GB, shared
   ports) → needs a 2nd `supabase` runner or concurrency gating.
4. **macOS cost** — move the heavy Maestro suites (`maestro-e2e` 120m, `me-migration-e2e` 90m) off
   GitHub-hosted `macos-15` onto the self-hosted Mac; add a 2nd Mac if a queue forms.
5. **`heavy`/`ml`** — persistent uv/pip cache + pre-warmed torch for `test-profiles`.
6. **DRY the selector (deferred)** — once all runners are online, extract the copy-pasted
   `pick-runner` job into a reusable workflow in `gyeolhada-team/.github` so every repo adopts
   self-hosted with one `uses:` line. Deferred deliberately until the fleet is proven up.

## Non-goals

- No third-party runner images (first-party `actions/runner` only — see CLAUDE.md).
- The broker does not enforce labels; scope access with GitHub runner groups.
- GitHub-hosted fallback is permanent, not a migration step — a degraded/offline fleet must never
  block a merge.
