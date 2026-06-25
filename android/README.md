# android — Linux Android E2E runner

**Purpose:** Docker container that registers as an ephemeral self-hosted GitHub Actions runner
and runs Android Maestro E2E tests via a KVM-accelerated emulator.

**Platform:** Linux x86_64 only (KVM hardware acceleration is required; software emulation is
unusably slow for CI). For iOS or Android-on-macOS, see a separate macOS runner setup.

**Base image:** `ghcr.io/actions/actions-runner` — the official GitHub Actions runner image.
Registration is handled by `entrypoint.sh` (no third-party runner base).

---

## Host prerequisites

### Hardware / OS

- Linux **x86_64** machine — bare-metal or VM with nested virtualization enabled.
- KVM support: `ls -l /dev/kvm` should return a character device, and `kvm-ok` should report ready.
  - On bare metal this is almost always available.
  - In a VM (e.g. Proxmox, ESXi, VirtualBox): enable **nested virtualization** in the hypervisor.
    In Proxmox: Datacenter > Node > VM > Hardware > Processor > Enable KVM.
    In VMware/VirtualBox: enable VT-x/AMD-V passthrough in the VM settings.

### Docker

- Docker Engine 24+ and Compose v2 (`docker compose version`).
- The user running Docker must be in the `kvm` group:

  ```bash
  sudo usermod -aG kvm $USER
  # Log out and back in, then verify:
  groups | grep kvm
  ```

### Disk

- At least **20 GB** free for image layers and AVD data; 30 GB recommended.
- The Android system image and emulator are large — the first `docker compose build` takes
  10–20 minutes. Subsequent starts reuse the cached image.

---

## Onboarding

### 1. Copy this directory onto the Linux host

```bash
# Option A — clone the repo and navigate here
git clone https://github.com/islee/gh-runners.git
cd gh-runners/android

# Option B — copy just this directory
scp -r android/ user@host:/path/to/gh-runner-android
```

### 2. Create `.env` from the template

```bash
cp env.example .env
chmod 600 .env
```

Edit `.env`. At minimum set `GH_ORG` and one credential (see [Credential models](#credential-models)).

### 3. Set your GitHub org

In `.env`:

```
GH_ORG=your-actual-org-slug
```

### 4. Choose and configure a credential (see [Credential models](#credential-models))

For a quick pilot, mint a registration token:

> **org Settings → Actions → Runners → New self-hosted runner**

Copy the token from the `./config.sh --token <TOKEN>` line. Paste it into `.env`:

```
RUNNER_TOKEN=<paste-here>
```

For a long-lived fleet, use the broker (model B) or a fine-grained PAT (model C).

### 5. Build and start

```bash
docker compose up -d --build
```

The first build takes 10–20 min (Android SDK download). Within 2–3 min the runner appears in:

> **org Settings → Actions → Runners** — look for `gh-runner-android-<id>-1` (the
> `gh-runner-<type>-<id>-<n>` name, `<id>` defaults to the container hostname) with labels
> `self-hosted,linux,x64,mobile,android`.

### Runner name
Registers as **`gh-runner-android-<id>-<n>`** — set `<id>` via `OWNER` and `<n>` via `RUNNER_NUMBER`
in `docker-compose.yml` (or override `RUNNER_NAME` outright). Defaults: `OWNER`=container hostname,
`RUNNER_NUMBER`=1.

### 6. Go offline (availability toggle)

```bash
docker compose down
```

The runner deregisters cleanly. No ingress, webhook, or port-forward required — it polls
GitHub outbound only.

---

## How it works (lifecycle)

```
docker compose up → container starts
  └─ entrypoint.sh
       ├─ 1. Resolve credential (RUNNER_TOKEN → BROKER_URL → ACCESS_TOKEN)
       ├─ 2. Register via config.sh --ephemeral --unattended --replace
       └─ 3. exec run.sh  (blocks, picks up exactly one job)
               ├─ before job: ACTIONS_RUNNER_HOOK_JOB_STARTED
               │     └─ hooks/job-started.sh  — boots KVM emulator, waits for boot_completed
               ├─ job runs (adb / Maestro / etc.)
               └─ after job:  ACTIONS_RUNNER_HOOK_JOB_COMPLETED
                     └─ hooks/job-completed.sh  — kills emulator, cleans up adb
                          └─ run.sh exits → container exits
                               └─ restart: always → fresh container → repeat
```

Each container handles **one job** then is replaced by a clean one. No state (secrets, artifacts,
file system changes) bleeds between jobs.

**WHY per-job emulator (not per-container):** booting the emulator at container start keeps ~3 GB
resident while the runner idles. The hooks boot the emulator only while a job is actually running,
then immediately kill it — reducing idle RAM to the runner agent alone (~100 MB).

---

## Credential models

| Model | Variables | When to use |
|-------|-----------|-------------|
| **A** | `RUNNER_TOKEN` | Short-lived org registration token. Good for a single pilot run. Expires ~1 h after minting — unattended containers will stop re-registering after expiry. |
| **B** | `BROKER_URL` + `BROKER_SECRET` | Recommended for fleets. Deploy [gh-runner-broker](https://github.com/islee/gh-runners/tree/main/broker); broker holds the GitHub App credential and issues fresh tokens. No GitHub credential in this container. |
| **C** | `ACCESS_TOKEN` | Fine-grained PAT scoped to `organization_self_hosted_runners` only. Entrypoint mints a fresh registration token each cycle. CRITICAL: never use an org admin PAT. |

Set exactly one. Priority is A → B → C.

### Broker API contract (model B)

- `POST $BROKER_URL/token`
  - Header: `Authorization: Bearer $BROKER_SECRET`
  - Header (optional): `X-Runner-Name: <name>` (for attribution logging)
  - Response: `{"token": "...", "expires_at": "...", "url": "https://github.com/<org>"}`
- `POST $BROKER_URL/remove-token` — same headers, used for cleanup.

---

## Resource caps

Controlled via `.env`:

| Variable | Default | Notes |
|----------|---------|-------|
| `RUNNER_CPUS` | `4` | Adjust based on your machine's core count. Leave ≥2 for the host OS. |
| `RUNNER_MEM` | `6g` | Floor: ~2 GB emulator + ~2 GB app under test + runner/Maestro overhead. 8 GB comfortable. |
| `KVM_GID` | `kvm` (name) | Numeric GID of the host `kvm` group (`getent group kvm`). Numeric is more reliable than name. |

To change caps without rebuilding: edit `.env`, then `docker compose up -d` (Compose picks up the new values).

---

## Build args

Override at build time:

```bash
docker compose build \
  --build-arg ANDROID_API=35 \
  --build-arg ANDROID_TARGET=google_apis \
  --build-arg ANDROID_ARCH=x86_64 \
  --build-arg NODE_MAJOR=22 \
  --build-arg MAESTRO_VERSION=1.39.13 \
  --build-arg CMDLINE_TOOLS_VERSION=11076708
```

`CMDLINE_TOOLS_VERSION` is a Google-assigned numeric build id that rotates — check the current
value at https://developer.android.com/studio#command-line-tools-only if the build fails on
the SDK download step.

---

## Troubleshooting

**Emulator won't start / boot times out**

1. Verify KVM: `ls -l /dev/kvm` and `kvm-ok`. If `/dev/kvm` is missing, check BIOS
   virtualization settings (VT-x / AMD-V) and confirm the kernel `kvm` module is loaded.
2. Check the `kvm` group: `groups | grep kvm`. Log out and back in after adding yourself.
3. Check logs: `docker compose logs runner-android | grep -i emulator`.
4. On VM hosts: verify the hypervisor exposes VT-x/AMD-V to the guest (nested virtualization).
5. Check `KVM_GID` in `.env` — if the container's `runner` user is not in the correct `kvm`
   GID, `/dev/kvm` will return EACCES. `getent group kvm` on the host gives the numeric GID.

**Runner not appearing in org Settings**

1. Check `GH_ORG` — must match the exact org slug (case-sensitive).
2. Check `RUNNER_TOKEN` — expires ~1 h after minting. Re-mint and update `.env`.
3. Check `RUNNER_LABELS` — must match the `runs-on:` labels in your workflow exactly.
4. Check `docker compose logs runner-android` — look for `config.sh` registration errors.

**Job queued but never picked up**

- The runner may still be in the emulator boot phase (up to ~5 min on first start).
- `docker compose ps` — confirm the container is `running` (not `exited`).
- Check if the runner shows as `Idle` in org Settings (not `Offline`).

**`kvm-ok` says KVM is not available inside the container**

- Confirm `/dev/kvm` is passed through (`devices:` in `docker-compose.yml`).
- Confirm `KVM_GID` is set to the correct numeric GID from the host.
- On some hosts, the `kvm` group GID inside the container does not match the host GID;
  passing the numeric GID explicitly via `group_add` fixes this.

**Official image layout (first-build verification)**

The Dockerfile assumes the runner binary lives at `/home/runner/{config.sh,run.sh}` and that the
user is `runner`. If entrypoint.sh logs `config.sh not found`, run:

```bash
docker run --rm ghcr.io/actions/actions-runner ls -la /home/runner
```

Update `RUNNER_HOME` in `entrypoint.sh` if the layout differs.

---

## Security

Runners execute arbitrary code from GitHub Actions workflows on this machine. Key mitigations:

- **Ephemeral:** every job runs in a fresh container; no prior job's artifacts, secrets, or
  file system state persist. This is enforced in `entrypoint.sh` (`--ephemeral` in `config.sh`)
  and cannot be overridden by `.env`.
- **Untrusted fork gate:** Android E2E jobs should be triggered on `main` HEAD (nightly) or on
  an explicit maintainer-applied label — never automatically on fork PRs. Untrusted code from
  external contributors should not reach this runner without a human approval gate.
- **Least-privilege credential:** prefer model B (broker) or model C (scoped PAT). Do NOT use
  an org admin PAT. A leaked registration token can only register runners; a leaked admin PAT
  can access all org repos and secrets.
- **Resource caps:** `RUNNER_CPUS` / `RUNNER_MEM` prevent a runaway job from starving the host.
- **Credential masking:** `ACCESS_TOKEN` is unset from the environment after the registration
  token is minted; `REG_TOKEN` is unset after `config.sh` consumes it.
