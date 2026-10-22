# images/ios — golden Tart VM for the ios slot class (macOS guest, Xcode builds)

## Purpose

Jobs that build iOS apps need macOS and Xcode. The `ios` class gives each job its own throwaway
**Tart** VM: an APFS copy-on-write clone of the stopped golden (`ghr-ios-golden`), booted headless,
reached only through the Tart guest agent, deleted when the job ends (`slots/launch.sh`, ios path).
This directory builds the golden. The slot is dormant until an iOS job is queued, and the supabase
slots make room for the 8 GiB VM first (`slots/README.md`, gotchas 21-24).

## Files

| File | Does |
|------|------|
| `provision.sh` | Runs in the build VM as the guest's `admin` (sudo): actions/runner (osx-arm64, sha256-verified) into `~/actions-runner`, `/Applications/Xcode_<ver>.app` symlink, Xcode licence + first-launch tasks, sshd off. Last line `PROVISION-OK <runner> <xcode>` |
| `../build-ios.sh` | Host side (as `ghr`): clone the pinned base, boot, provision over the guest agent, stop, swap in as the golden. Prints `GOLDEN-OK <runner> <xcode>` |

## Inputs of a build

```
RUNNER_VERSION=<x.y.z> RUNNER_SHA256=<sha256 of actions-runner-osx-arm64-<x.y.z>.tar.gz> \
  images/build-ios.sh ghcr.io/cirruslabs/macos-<release>-xcode@sha256:<64 hex>
```

- The base image must be pinned by digest (a tag is refused): every job runs on it, with the job's JIT
  credential. Look the digest up in the registry; do not copy it from a tag listing you cannot audit later.
- The runner version and its tarball sha256 are both required (published on the actions/runner release
  page). Nothing is installed unverified.
- Optional environment: `IOS_GOLDEN` (default `ghr-ios-golden`), `IOS_BUILD_CPUS` (4), `IOS_BUILD_MEM_MB`
  (8192), `IOS_DISK_GB` (grow the base image's disk), `IOS_BUILD_BOOT_TIMEOUT` (600 s), `TART`.
- Output: one `GOLDEN-OK` line on stdout; the inputs used, the golden's disk size, `xcodebuild -version`
  and `simctl list runtimes` go to stderr. Keep that output with the digest you built from.
- The previous golden is replaced only after the new one is built and stopped. A failed build deletes only
  its own `ghr-ios-build` VM and leaves the old golden. Build with the class idle (no running job VM is
  affected, but a clone made during the swap would fail and the slot would back off).

## Operator steps (once per host)

All as the `ghr` account unless noted. `install.sh` deliberately does **not** install Tart.

1. **Install Tart, pinned, root-owned.** The `ghr` account runs `/usr/local/bin/tart` with job credentials
   in reach, so it must not be writable by `ghr`: unpack a release you have pinned and checked (tag +
   sha256) to `/usr/local/opt/tart` (root:wheel, no write for others) and symlink
   `/usr/local/bin/tart -> /usr/local/opt/tart/tart.app/Contents/MacOS/tart`. Upgrades are a deliberate re-do
   of this step.
2. **Create `ghr`'s login keychain (one time, in `su -l ghr`; `sudo -u ghr` does NOT work for creation).**
   A macOS guest refuses to start (`VZErrorDomain Code=-9`, "Failed to get current host key") unless the VM
   owner's login keychain exists and is unlocked. As `ghr`, in a real login session (`su -l ghr`):
   generate a random password into `~/.ghr/keychain.pass` (mode 0400, owner `ghr`), set `ghr`'s account
   password to the same value, `security create-keychain -p "$(cat ~/.ghr/keychain.pass)" ~/Library/Keychains/login.keychain-db`
   (do it in a shell that does not log the line), make it the default (`security default-keychain -s ...`,
   `security list-keychains -d user -s ...`) and disable auto-lock (`security set-keychain-settings
   ~/Library/Keychains/login.keychain-db`, no timeout). `launch.sh` then runs
   `/usr/bin/security unlock-keychain <keychain> < ~/.ghr/keychain.pass` before every `tart run`: the
   password travels on stdin only, both paths are derived from `ghr`'s home and cannot be overridden in the
   installed copy, and a failed unlock refuses the job (exit 1) without starting the VM.
3. **Pull the base image once** (also fills the OCI cache that `TART_NO_AUTO_PRUNE=1` protects):
   `tart pull ghcr.io/cirruslabs/macos-<release>-xcode@sha256:<64 hex>`. It is tens of GB.
4. **Build the golden** with the command above. The first boot of a base image takes a few minutes.
5. **Load the pf anchor rules** below next to the existing `user ghr` egress rules, then enable the class:
   `IOS_SLOTS=1`, `IOS_DEMAND_REPOS`, `IOS_LAN_PROBES`, `ghr-ios` in `ALLOWED_LABELS`, and give the State App the repo
   permission `Actions: read` (`slots/config.example.env`). Re-run `slots/install.sh`.
6. **Verify egress from inside a guest**, not from the rules: run one job (or clone the golden by hand,
   `tart run`, and `tart exec <vm> /usr/bin/nc -z -G 5 <host> <port>` for each `IOS_LAN_PROBES` entry; each
   must exit 1, and with the rules off the same probes must exit 0, which proves the targets mean something).

## Egress isolation (pf)

Tart's default networking is the Virtualization.framework NAT (vmnet): guest net `192.168.64.0/24`,
gateway and DNS `192.168.64.1`, host interface `bridge100`. That traffic is **forwarded by the kernel**,
not a socket of user `ghr`, so the pf rules that match `user ghr` (which cover the Lima VMs) do **not**
apply to it. Add this to the same anchor (`$private` is the RFC 1918 / link-local set that anchor already
uses for the Lima rules; define it if you keep these rules elsewhere):

```
pass  in quick on bridge100 proto udp from any port 68 to any port 67
pass  in quick on bridge100 proto { tcp, udp } from 192.168.64.0/24 to 192.168.64.1 port 53
block return in quick on bridge100 proto { tcp, udp } from any to $private
block return in quick on bridge100 inet6 proto { tcp, udp } from any to { fc00::/7, fe80::/10 }
```

Order matters: the two `pass quick` rules (DHCP, DNS to the gateway) come before the blocks. The
preflight in `launch.sh` is the **enforcement check**, not the rules: before the runner starts, the
guest must fail to connect to EVERY `IOS_LAN_PROBES` entry (`nc -z -G 5`, exit 1; `tart exec` passes the
guest's exit code through, so a guest-usability check `tart exec <vm> /usr/bin/true` runs first); reachable,
or any other result, refuses the job (exit 3, VM destroyed). The ios class does not use `LAN_PROBE`: that is
the host's own LAN address, which a NAT guest cannot reach even with no filtering. Choose a LAN device that
IS reachable when unfiltered, plus the vmnet gateway's sshd (`192.168.64.1:22`). Fail closed is the point, because pf misconfiguration is silent.

## Gotchas

1. `tart exec` needs the guest agent, which the Cirrus images ship. A base image without it never gets
   past the boot wait (`IOS_BOOT_TIMEOUT`, 300 s) and the VM is destroyed.
2. The guest agent runs commands as the image's default user (`admin`). `IOS_RUNNER_DIR`
   (default `/Users/admin/actions-runner`) must match where `provision.sh` unpacked the runner.
3. `tart run` blocks for the VM's lifetime, so `launch.sh` backgrounds it and reaps it on every exit path.
   `tart stop` is bounded (`IOS_STOP_TIMEOUT`, 30 s); a VM that will not stop is killed with its `tart run`.
4. `tart clone` prunes the OCI cache to make room unless `TART_NO_AUTO_PRUNE` is set; both `launch.sh` and
   `build-ios.sh` export it. The golden and the pulled base are never deleted by a job.
5. macOS licensing allows two VMs per host; the class uses one (`IOS_SLOTS` is 0 or 1) because of memory.
6. The `bridge100` interface exists only while a VM runs; check `pfctl -nf` accepts the rules on your
   release and that the in-guest preflight blocks, before trusting the class with real jobs.
7. The Cirrus base images already carry Xcode at `/Applications/Xcode_<ver>.app`; `provision.sh` creates
   that symlink only when the path does not exist.
8. The runner is started in a login shell (`bash -lc`): rbenv shims (pod, fastlane), node, pnpm, openjdk
   and xcbeautify are on PATH only there. `nc -w` misreports on this guest, so every probe uses `-G` only.
9. `provision.sh` is exercised only by shellcheck in CI (it needs a macOS guest). Disabling Remote Login
   tries `systemsetup`, which can require Full Disk Access, and falls back to disabling the sshd launchd
   service; the script fails the build if port 22 still answers in the guest.
