# images/supabase — golden VM for the supabase slot class

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

## Building

```
images/build-supabase.sh            # first build (first boot takes a few minutes)
images/build-supabase.sh --rebuild  # replace an existing golden
```

A failed build deletes the half-made golden, so slots refuse to start jobs instead of cloning it.
Running per-job VMs are unaffected by a rebuild only if no job is active: rebuild with the class
idle.

## What is pre-warmed and why

- Tool cache `/opt/hostedtoolcache` (`.complete` markers, checksum-verified): Node 20/22/24
  (22 on PATH), Deno 2.6.8 and current 2.x, Python 3.11/3.12/3.13 (`Python` tool, installed by the
  python-versions release's own `setup.sh`), Supabase CLI.
- `supabase/setup-cli@v1` does **not** consult the tool cache (it always downloads and prepends
  PATH), so the CLI entry in the cache is only used by provisioning.
- The container images are pre-pulled from `ghcr.io`: setup-cli@v1 sets
  `SUPABASE_INTERNAL_IMAGE_REGISTRY=ghcr.io` for CLI versions below 2.108.0 and the CLI would
  otherwise pull `public.ecr.aws/...` names. Add registries via `PREPULL_REGISTRIES`. When the CLI
  version moves to 2.108.0 or later the default registry applies; rebuild with
  `PREPULL_REGISTRIES=public.ecr.aws`.

## Bumping

Edit the defaults at the top of `provision.sh` (runner, CLI, Node, Deno, Python specs) and rebuild.
Verify with `limactl shell ghr-supa-golden -- ls /opt/hostedtoolcache/*/*/arm64.complete` and
`docker image ls` after a manual start of the golden (stop it again before slots clone it).
