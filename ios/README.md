# iOS / Android-on-Mac self-hosted runner

One-command installer for a self-hosted GitHub Actions runner that picks up
**iOS E2E** and **Android-on-Mac E2E** jobs on Apple Silicon. Runners are
**ephemeral** (re-register after every job) and driven by launchd.

This directory is self-contained — copy it to any Mac and run `install.sh`.

---

## Prerequisites

### Required for iOS E2E

- **Xcode** (full install, not just CLT) — provides the iOS Simulator
- **Xcode Command Line Tools** — `xcode-select --install`
- At least one **iOS Simulator runtime** — Xcode → Settings → Platforms
- **Node** (match the version used in the app repo) — `brew install node` or nvm/fnm
- **Maestro** — `curl -Ls 'https://get.maestro.mobile.dev' | bash`

### Required for Android-on-Mac E2E (optional)

- **Android SDK** with `cmdline-tools` — set `ANDROID_HOME`
- An **`arm64-v8a` system image** (Apple Silicon runs these natively via Hypervisor.framework):
  ```
  sdkmanager "system-images;android-34;google_apis;arm64-v8a"
  avdmanager create avd -n ci-runner-arm64 -k "system-images;android-34;google_apis;arm64-v8a"
  ```
- Headless AVD start: `emulator -avd ci-runner-arm64 -no-window -no-audio`

---

## Onboarding

### Step 1 — Get a credential (ask the operator)

| Model | What you receive | Notes |
|-------|-----------------|-------|
| **A — registration token** | A one-off `RUNNER_TOKEN` minted for your machine | Expires ~1h; survives only the first registration cycle |
| **A — fine-grained PAT** | An `ACCESS_TOKEN` scoped to `organization_self_hosted_runners` | Loop mints fresh tokens via the GitHub REST API each cycle |
| **B — broker** | A `BROKER_URL` + `BROKER_SECRET` pointing at a token-broker instance | No GitHub credential on your machine; broker holds the PAT |

**Never use the org admin PAT.** The credential you receive must only be able to
manage runners — not read code, write issues, or access repository secrets.

### Step 2 — Copy and run the installer

```bash
# Copy this ios/ directory to the Mac (however is convenient — scp, AirDrop, etc.)
# Then from inside the ios/ directory:

# Model A — fine-grained PAT
./install.sh --org your-org --access-token ghp_yourFineGrainedPAT

# Model A — static registration token (short-lived; minted by operator)
./install.sh --org your-org --token AVRXYZ...

# Model B — token-broker
./install.sh --org your-org \
  --broker-url https://broker.example.com \
  --broker-secret your-broker-bearer-secret

# Override other defaults if needed
./install.sh --org your-org --access-token ghp_... \
  --labels "self-hosted,mobile,ios,android" \
  --runner-dir ~/actions-runner-e2e \
  --allow-battery       # not recommended; see Battery section below
```

The installer:
1. Checks macOS + arm64 and warns (non-fatal) on missing tools.
2. Writes `~/actions-runner-e2e/config.env` (chmod 600).
3. Downloads `actions/runner` osx-arm64.
4. Installs `com.example.ci-runner.plist` → `~/Library/LaunchAgents/` and loads it.

The runner starts immediately and re-registers for each job automatically.

---

## Customizing the launchd label

The default LaunchAgent label is `com.example.ci-runner`. If you deploy multiple
runners on the same Mac, or want to match your team's domain, edit the
`PLIST_LABEL` constant in `install.sh` and the `<string>` in
`com.example.ci-runner.plist` before running the installer.

---

## Availability toggle

### Pause (go offline — runner won't pick up new jobs)

```bash
launchctl bootout gui/$(id -u)/com.example.ci-runner
```

### Resume

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.ci-runner.plist
```

### Check status

```bash
launchctl list | grep ci-runner
tail -f ~/Library/Logs/ci-runner.out.log
```

---

## Battery behavior

By default the runner **skips job cycles when on battery** — it checks
`pmset -g batt` each loop iteration and sleeps 60 s before trying again.
This prevents draining your battery during standup or when off-site.

To allow the runner to work on battery (e.g. Mac mini, always plugged in):

```bash
# At install time
./install.sh ... --allow-battery

# Or edit config.env manually, then restart:
echo 'ALLOW_BATTERY=1' >> ~/actions-runner-e2e/config.env
launchctl bootout   gui/$(id -u)/com.example.ci-runner
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.ci-runner.plist
```

---

## Logs

| File | Contents |
|------|----------|
| `~/Library/Logs/ci-runner.out.log` | Runner registration + job stdout |
| `~/Library/Logs/ci-runner.err.log` | Errors, warnings, battery guard messages |

---

## Uninstall

```bash
# Unload agent + deregister + prompt to delete runner dir
./uninstall.sh

# Non-interactive purge
./uninstall.sh --purge --yes
```

---

## Security

**You are running CI job code on your personal machine.** The design limits blast radius:

1. **No untrusted fork PRs.** E2E jobs should only trigger on nightly `main`-branch runs
   or when a maintainer manually applies a trusted label to a PR.
   Do not expose the `pull_request` event for external forks to this runner.
2. **Ephemeral runners.** The runner deregisters after every job; no state (tokens,
   env, workspace) bleeds between jobs.
3. **Least-privilege credential.** Your token must only be able to manage runners — not
   read code, write issues, or access repository secrets.
4. **Battery + nice guard.** The runner process is niced (lower scheduling priority)
   and will not start jobs when you are on battery (unless `ALLOW_BATTERY=1`).

If you ever feel uncomfortable with a job that ran, revoke your credential immediately
and notify the operator.

---

## Token broker

Model B (broker) is the recommended approach for fleets because no GitHub credential
lives on the runner Mac. The broker mints short-lived registration tokens on demand.

The companion broker service is published at:
**https://github.com/islee/ci-runner-token-broker**

Broker API (used by `runner-loop.sh` and `uninstall.sh`):

| Operation | Method | Path | Auth |
|-----------|--------|------|------|
| Mint registration token | `POST` | `/token` | `Authorization: Bearer <BROKER_SECRET>` |
| Mint removal token | `POST` | `/remove-token` | `Authorization: Bearer <BROKER_SECRET>` |

Both endpoints return `{"token": "...", "expires_at": "...", "url": "..."}`.

---

## Files

| File | Purpose |
|------|---------|
| `install.sh` | Installs runner binary, config.env, plist; loads launchd agent |
| `runner-loop.sh` | Ephemeral re-registration loop; driven by launchd |
| `uninstall.sh` | Stops launchd agent, deregisters from GitHub, optionally purges runner dir |
| `com.example.ci-runner.plist` | LaunchAgent template (paths substituted by install.sh) |
| `config.env.example` | Documents all config.env fields (the real config.env is generated) |
