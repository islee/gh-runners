#!/bin/bash
# provision.sh — bake the supabase-class golden VM. Runs INSIDE the VM, as root.
#
# Context: images/build-supabase.sh pipes this script to `sudo bash` in `ghr-supa-golden`. Every
# per-job VM is a copy-on-write clone of the result, so jobs start with: Docker CE, the pinned
# actions/runner (native, user `runner` uid 1001), hosted-parity apt packages, a pre-populated
# tool cache (Node, Deno, Python, Supabase CLI) and the FULL Supabase container image set already
# pulled, which turns a ~2-5 min cold `supabase start` into seconds.
#
# Everything downloaded is verified against a value PINNED IN THIS FILE (a checksum fetched from the
# same origin as the artifact is not a pin): runner, supabase CLI, python, node and deno sha256s
# below; docker and gh apt keys by fingerprint. Node values were taken from nodejs.org
# SHASUMS256.txt.asc after verifying its GPG signature against nodejs/release-keys; deno values
# equal the GitHub release-asset digests.
# Bump versions by editing the defaults (or exporting the variable) and rebuilding the golden.
#
# Final stdout line:  PROVISION-OK <runner-version> <cli-version>   (parsed by build-supabase.sh)
#
# Tool-cache layout notes (verified against action sources, 2026-10-16):
#   actions/setup-node   : tool `node`,   $TC/node/<exact>/<arch>/{bin,lib,...}  + <arch>.complete
#   denoland/setup-deno  : tool `deno`,   $TC/deno/<exact>/<arch>/deno           + <arch>.complete
#   actions/setup-python : tool `Python`, $TC/Python/<exact>/<arch>/...          + <arch>.complete
#                          (installed by the python-versions release's own setup.sh)
#   supabase/setup-cli@v1: does NOT use the tool cache at all (tc.downloadTool + extractTar +
#                          addPath, no tc.find/cacheDir). The CLI is cached below under tool
#                          `supabase` only for provisioning and cache-aware use; the action still
#                          downloads its own copy (a few MB).

# CRITICAL: build-supabase.sh runs this as a FILE with stdin at /dev/null. Make that true for every
# child regardless (installers, apt scriptlets, `supabase init` prompts read stdin and would
# otherwise hang or swallow input).
exec < /dev/null

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

RUNNER_VERSION="${RUNNER_VERSION:-2.338.0}"
RUNNER_SHA256="${RUNNER_SHA256:-628b4a7258487b80c1d3c221095a7ded349f5ae0175fd3dfab708d07428f041b}"
CLI_VERSION="${CLI_VERSION:-2.107.0}"
CLI_SHA256="${CLI_SHA256:-d54648dd7f46ab824ba483bf4db712235a58c3242c2ff675ac7732a9b4f21e0f}"
# <version>|<sha256 of node-v<version>-linux-arm64.tar.xz>
NODE_SPECS="${NODE_SPECS:-20.20.2|73093db209e4e9e09dd7d15a47aeaab1b74833830df03efa5f942a1122c5fa71 22.23.3|a44aeb94849a299b22df10b9e622ec2f605c2183501bc40590705131de7c740f 24.22.0|fef00bb4d36e1c50104a9775a10359beee98f162b4104dd12472c75065c6a143}"
NODE_DEFAULT="${NODE_DEFAULT:-22.23.3}"
# <version>|<sha256 of deno-aarch64-unknown-linux-gnu.zip>: the version the workflows pin plus a current 2.x.
DENO_SPECS="${DENO_SPECS:-2.6.8|09a0a800be639986515540ddae2f2752625ed412f63d36c7152c2a72ee78c2d7 2.9.7|c832298b1ad4422481334855f6003e0f54145762c5a134f20a489511d2f65bbf}"
# <python-version>-<release-tag>|<sha256> of actions/python-versions ubuntu-24.04 arm64 builds.
PYTHON_SPECS="${PYTHON_SPECS:-3.11.17-36876195594|a7a7bb9e6b50483f393d1c44c87aa87677a0464a9e3b07f33ee5b31ce155c6ef 3.12.15-36805895057|c537f7852633f9a6d909181528e263087ad815cc44d52ed226992b70b2648f44 3.13.16-36805956071|0e923697b278f1a21ac403838a4238b659200726d8983c3f271a120e76090f0e}"
DOCKER_KEY_FPR="${DOCKER_KEY_FPR:-9DC858229FC7DD38854AE2D88D81803C0EBFCD88}"
GH_KEY_FPR="${GH_KEY_FPR:-7F38BBB59D064DBCB3D84D725612B36462313325}"
# Postgres majors to pre-pull a full stack for (projects pin one in config.toml
# `major_version`; the CLI default differs from some of them, so cover both).
PREPULL_PG_MAJORS="${PREPULL_PG_MAJORS:-15 17}"
# WHY ghcr.io: supabase/setup-cli@v1 exports SUPABASE_INTERNAL_IMAGE_REGISTRY=ghcr.io for CLI
# versions in [1.28.0, 2.108.0), and the CLI (default registry public.ecr.aws) then pulls
# ghcr.io/supabase/* names. Pre-pull under the registry the job will actually use; add
# public.ecr.aws here if jobs run the CLI without the action.
PREPULL_REGISTRIES="${PREPULL_REGISTRIES:-ghcr.io}"
TC_ARCH=arm64
NODE_ARCH=arm64
DENO_TARGET=aarch64-unknown-linux-gnu
TC=/opt/hostedtoolcache
RUNNER_HOME=/opt/actions-runner

log() { echo "[provision] $*" >&2; }
# apt: wait for a competing dpkg lock instead of failing the build.
apt() { apt-get -o DPkg::Lock::Timeout=300 "$@"; }
die() { log "ERROR $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# fetch URL DEST EXPECTED_SHA256 — download and verify before anyone uses the file.
fetch() {
  curl -fsSL "$1" -o "$2"
  echo "$3  $2" | sha256sum -c - > /dev/null || die "checksum mismatch for $1"
}

# fingerprint_ok FILE FPR — true iff the (binary or armored) key file contains a key with this
# primary fingerprint. Captured to a variable first: piping gpg into grep -q under pipefail can
# fail on SIGPIPE even when the key matches.
fingerprint_ok() {
  local out
  out="$(gpg --show-keys --with-colons "$1" 2> /dev/null)" || return 1
  grep -q "^fpr:::::::::${2}:" <<< "$out"
}

install_apt_baseline() {
  log "apt baseline + docker + gh"
  # Let first-boot cloud-init finish (it holds the dpkg lock and may run its own apt).
  cloud-init status --wait > /dev/null 2>&1 || log "WARN cloud-init status --wait returned non-zero"
  # An unattended-upgrades run holding the dpkg lock would fail a job's `sudo apt-get install`
  # (plpgsql-check does this); hosted runners do not auto-upgrade either.
  systemctl disable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer 2> /dev/null || true
  apt update
  # Runner (.NET) runtime dependencies for Ubuntu 24.04 are listed explicitly instead of running
  # the runner's installdependencies.sh, whose package probes (libicu76/libicu75, ...) print
  # "Unable to locate package" noise and whose exit status we do not want to depend on.
  apt install -y --no-install-recommends \
    git curl ca-certificates gnupg jq unzip zip xz-utils zstd bc \
    python3 python3-venv python3-pip build-essential libatomic1 postgresql-client sudo \
    libicu74 libkrb5-3 zlib1g liblttng-ust1t64 libssl3t64
  apt purge -y unattended-upgrades 2> /dev/null || true
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$TMP/docker.gpg"
  fingerprint_ok "$TMP/docker.gpg" "$DOCKER_KEY_FPR" || die "docker apt key fingerprint does not match the pin"
  gpg --dearmor < "$TMP/docker.gpg" > /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o "$TMP/gh.gpg"
  fingerprint_ok "$TMP/gh.gpg" "$GH_KEY_FPR" || die "gh apt key fingerprint does not match the pin"
  install -m 0644 "$TMP/gh.gpg" /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
  apt update
  apt install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin gh
  systemctl enable docker
}

create_runner_user() {
  log "user runner (uid 1001)"
  id runner > /dev/null 2>&1 || useradd -m -u 1001 -s /bin/bash runner
  usermod -aG docker runner
  # Hosted-runner parity: jobs use passwordless sudo (apt-get, playwright --with-deps).
  echo 'runner ALL=(ALL) NOPASSWD:ALL' > "$TMP/runner.sudoers"
  visudo -cf "$TMP/runner.sudoers" > /dev/null || die "sudoers validation failed"
  install -m 0440 -o root -g root "$TMP/runner.sudoers" /etc/sudoers.d/90-runner
}

install_runner() {
  log "actions/runner $RUNNER_VERSION (linux-arm64)"
  local tarball="actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz" reported
  fetch "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${tarball}" "$TMP/$tarball" "$RUNNER_SHA256"
  install -d -m 0755 "$RUNNER_HOME"
  tar -xzf "$TMP/$tarball" -C "$RUNNER_HOME"
  chown -R runner:runner "$RUNNER_HOME"
  # Final check of the runtime deps: the listener must start as `runner` and report the pinned version.
  reported="$(sudo -u runner -H "$RUNNER_HOME/bin/Runner.Listener" --version)" || die "Runner.Listener does not start (missing runtime dependency?)"
  [ "$reported" = "$RUNNER_VERSION" ] || die "Runner.Listener reports '$reported', expected $RUNNER_VERSION"
}

cache_node() {
  local spec v sha tarball dest b
  for spec in $NODE_SPECS; do
    v="${spec%%|*}"
    sha="${spec#*|}"
    log "node $v"
    tarball="node-v${v}-linux-${NODE_ARCH}.tar.xz"
    fetch "https://nodejs.org/dist/v${v}/${tarball}" "$TMP/$tarball" "$sha"
    dest="$TC/node/$v/$TC_ARCH"
    mkdir -p "$dest"
    tar -xJf "$TMP/$tarball" --strip-components=1 -C "$dest"
    touch "$TC/node/$v/$TC_ARCH.complete"
  done
  for b in node npm npx corepack; do
    [ -e "$TC/node/$NODE_DEFAULT/$TC_ARCH/bin/$b" ] || die "NODE_DEFAULT $NODE_DEFAULT not among NODE_SPECS"
    ln -sf "$TC/node/$NODE_DEFAULT/$TC_ARCH/bin/$b" "/usr/local/bin/$b"
  done
}

cache_deno() {
  local spec v sha dest
  for spec in $DENO_SPECS; do
    v="${spec%%|*}"
    sha="${spec#*|}"
    log "deno $v"
    fetch "https://github.com/denoland/deno/releases/download/v${v}/deno-${DENO_TARGET}.zip" "$TMP/deno-$v.zip" "$sha"
    dest="$TC/deno/$v/$TC_ARCH"
    mkdir -p "$dest"
    unzip -q -o "$TMP/deno-$v.zip" -d "$dest"
    chmod 0755 "$dest/deno"
    touch "$TC/deno/$v/$TC_ARCH.complete"
  done
}

cache_cli() {
  log "supabase CLI $CLI_VERSION"
  local dest="$TC/supabase/$CLI_VERSION/$TC_ARCH"
  fetch "https://github.com/supabase/cli/releases/download/v${CLI_VERSION}/supabase_${CLI_VERSION}_linux_arm64.tar.gz" "$TMP/supabase.tgz" "$CLI_SHA256"
  mkdir -p "$dest"
  tar -xzf "$TMP/supabase.tgz" -C "$dest" supabase
  chmod 0755 "$dest/supabase"
  touch "$TC/supabase/$CLI_VERSION/$TC_ARCH.complete"
}

cache_python() {
  local spec rel sha ver dir
  for spec in $PYTHON_SPECS; do
    rel="${spec%%|*}"
    sha="${spec#*|}"
    ver="${rel%%-*}"
    log "python $ver"
    fetch "https://github.com/actions/python-versions/releases/download/${rel}/python-${ver}-linux-24.04-arm64.tar.gz" "$TMP/py-$ver.tgz" "$sha"
    dir="$TMP/py-$ver"
    mkdir -p "$dir"
    tar -xzf "$TMP/py-$ver.tgz" -C "$dir"
    # The release's own installer lays out $TC/Python/<ver>/arm64 and writes the .complete marker.
    ( cd "$dir" && AGENT_TOOLSDIRECTORY="$TC" bash ./setup.sh > /dev/null )
    [ -e "$TC/Python/$ver/$TC_ARCH.complete" ] || die "python $ver install left no .complete marker"
  done
}

# prepull — for each postgres major and registry: `supabase init`, set major_version, full
# (untrimmed) `supabase start`, `stop --no-backup`; then assert the exact images exist locally.
prepull() {
  local reg m work images cli="$TC/supabase/$CLI_VERSION/$TC_ARCH/supabase"
  systemctl start docker
  for reg in $PREPULL_REGISTRIES; do
    for m in $PREPULL_PG_MAJORS; do
      [[ "$m" =~ ^[0-9]+$ ]] || die "bad postgres major: $m"
      log "pre-pulling the supabase stack from $reg (postgres $m)"
      work="$(mktemp -d)"
      ( cd "$work" \
        && "$cli" init < /dev/null > /dev/null \
        && sed -i "s/^major_version = .*/major_version = ${m}/" supabase/config.toml \
        && grep -q "^major_version = ${m}\$" supabase/config.toml \
        && SUPABASE_INTERNAL_IMAGE_REGISTRY="$reg" "$cli" start < /dev/null \
        && SUPABASE_INTERNAL_IMAGE_REGISTRY="$reg" "$cli" stop --no-backup < /dev/null ) || die "supabase pre-pull from $reg (postgres $m) failed"
      rm -rf "$work"
      # Captured first: piping docker into grep -q under pipefail can fail on SIGPIPE.
      images="$(docker image ls --format '{{.Repository}}:{{.Tag}}' < /dev/null)"
      grep -q "^${reg}/supabase/postgres:${m}\." <<< "$images" || die "postgres $m image from $reg missing after pre-pull"
      grep -q "^${reg}/supabase/studio:" <<< "$images" || die "studio image from $reg missing (untrimmed start expected)"
    done
  done
  log "images: $(docker image ls -q < /dev/null | wc -l | tr -d ' ')"
}

cleanup() {
  log "cleanup"
  chown -R runner:runner "$TC"
  apt clean
  rm -rf /var/lib/apt/lists/* /root/.cache /home/runner/.cache /root/ghr-provision.sh
  # Leave docker running state clean: no containers, images kept.
  docker ps -aq | xargs -r docker rm -f > /dev/null
  systemctl stop docker docker.socket
}

install_apt_baseline
create_runner_user
install_runner
install -d -m 0755 "$TC"
cache_node
cache_deno
cache_cli
cache_python
prepull
cleanup
echo "PROVISION-OK $RUNNER_VERSION $CLI_VERSION"
