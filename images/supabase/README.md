# images/supabase — golden VM for the supabase slot class (Lima on the Mac, Proxmox on the optional second host)

## Purpose

Jobs that run `supabase start` need their own Docker daemon and loopback (the tests talk to
`127.0.0.1:54321/54322`), so each supabase job gets a throwaway Lima VM: an APFS copy-on-write
clone of the stopped golden `ghr-supa-golden` (about 8 s to boot), deleted when the job ends
(`slots/launch.sh`). This directory builds the golden.

## Files

| File | Does |
|------|------|
| `lima.yaml` | VM template: vz, Ubuntu 24.04 arm64, 4 CPU / 4 GiB / 40 GiB, no host mounts, every guest port forward ignored |
| `provision.sh` | Runs in the VM as root: Docker CE, user `runner` (uid 1001, passwordless sudo), actions/runner in `/opt/actions-runner`, hosted-parity apt set, tool cache, full Supabase image pre-pull |
| `../build-supabase.sh` | Host side (as `ghr`): create, boot, provision, stop. Prints `GOLDEN-OK <runner> <cli>` |
| `../build-supabase-pve.sh` | Proxmox host side (as root): pinned noble amd64 cloud image -> VM -> provision over the guest agent -> clean cloud-init -> template. Prints `GOLDEN-OK <runner> <cli>` |
| `pve-user-data.yaml` | First-boot cloud-init user-data of the Proxmox golden (installs the guest agent, nothing else) |
| `ghr-runner.service`, `ghr-runner-run` | Guest-side per-job runner of the Proxmox VMs (read JIT from `/run/ghr/jit`, run the runner, record the exit code, power off) |

## Building

```
images/build-supabase.sh            # first build (first boot takes a few minutes)
images/build-supabase.sh --rebuild  # replace an existing golden
```

The runner needs no `installdependencies.sh`: its .NET deps are installed explicitly and the final
check is `Runner.Listener --version` as `runner`. `provision.sh` is copied into the guest as a file
and run with stdin at `/dev/null`. A failed build deletes the half-made golden, so slots refuse to start jobs instead of cloning it.
Running per-job VMs are unaffected by a rebuild only if no job is active: rebuild with the class
idle.

## Proxmox golden

```
GOLDEN_VMID=300 STORAGE=local-lvm BRIDGE=vmbr0 SNIPPET_STORAGE=local images/build-supabase-pve.sh
images/build-supabase-pve.sh --rebuild   # replace an existing golden (class idle)
```

Run as root on the Proxmox host. Settings come from the environment (`GOLDEN_VMID` 300, `STORAGE`,
`BRIDGE`, `DISK_SIZE` 40G, `SNIPPET_STORAGE` needing the `snippets` content type, `IPCONFIG` `ip=dhcp`,
`PVE_NAMESERVER`). The VM is built from the Ubuntu 24.04 amd64 cloud image pinned (URL of a dated
release directory + sha256) at the top of the script, driven only over the qemu guest agent (no ssh),
and gets the same egress-isolating firewall file as a job VM while it builds. `provision.sh` runs
detached under `systemd-run` because `qm guest exec` gives up after its timeout; the build polls for
its exit status. The Proxmox-only guest pieces (`ghr-runner-run`, `ghr-runner.service`) are installed
by the build script, not by `provision.sh`, so the Lima golden is unchanged. Before `qm template` the
cloud-init state and machine-id are reset and the VM switches to a no-op user-data snippet so clones
boot without apt. Like the Lima build, a failed build destroys the partial VM (only one it created).

`provision.sh` picks the artifact set by `uname -m`: aarch64 uses the arm64 pins, x86_64 the x64 pins
(each with its own sha256, same versions) and the tool cache directories are `arm64` / `x64`.

## What is pre-warmed and why

- Tool cache `/opt/hostedtoolcache` (`.complete` markers, checksum-verified): Node 20/22/24
  (22 on PATH), Deno 2.6.8 and current 2.x, Python 3.11/3.12/3.13 (`Python` tool, installed by the
  python-versions release's own `setup.sh`), Supabase CLI.
- Every artifact is checked against a sha256 pinned in `provision.sh` (Node values from
  `SHASUMS256.txt.asc` after a GPG check, Deno values = GitHub asset digests); the Docker and gh
  apt keys by fingerprint; the Ubuntu cloud image by `digest` in `lima.yaml`.
- `supabase/setup-cli@v1` does **not** consult the tool cache (it always downloads and prepends
  PATH), so the CLI entry in the cache is only used by provisioning.
- The container images are pre-pulled from `ghcr.io` for each Postgres major in
  `PREPULL_PG_MAJORS` (default `15 17`; `major_version` is set in a scratch project's
  `config.toml`): setup-cli@v1 sets
  `SUPABASE_INTERNAL_IMAGE_REGISTRY=ghcr.io` for CLI versions below 2.108.0 and the CLI would
  otherwise pull `public.ecr.aws/...` names. Add registries via `PREPULL_REGISTRIES`. When the CLI
  version moves to 2.108.0 or later the default registry applies; rebuild with
  `PREPULL_REGISTRIES=public.ecr.aws`.

## Bumping

Edit the defaults at the top of `provision.sh` (runner, CLI, Node, Deno, Python specs) and rebuild.
Bump the arm64 AND x64 pins together (GitHub asset `digest` fields; Node from the GPG-verified
`SHASUMS256.txt.asc`). Verify with `limactl shell ghr-supa-golden -- ls /opt/hostedtoolcache/*/*/arm64.complete` and
`docker image ls` after a manual start of the golden (stop it again before slots clone it).
