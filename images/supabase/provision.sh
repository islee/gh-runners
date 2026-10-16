#!/bin/bash
# provision.sh — bake the supabase-class golden VM. Runs INSIDE the VM, as root.
#
# Context: images/build-supabase.sh pipes this script to `sudo bash` in `ghr-supa-golden`. Every
# per-job VM is a copy-on-write clone of the result, so jobs start with: Docker CE, the pinned
# actions/runner (native, user `runner` uid 1001), hosted-parity apt packages, a pre-populated
# tool cache (Node, Deno, Python, Supabase CLI) and the FULL Supabase container image set already
# pulled, which turns a ~2-5 min cold `supabase start` into seconds.
#
# Everything downloaded is checksum-verified (published sha256, or a pin in this file):
#   runner / supabase CLI / python: pinned sha256 below;  node: SHASUMS256.txt;  deno: .sha256sum;
#   docker apt key: fingerprint compared to the pin.
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

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

RUNNER_VERSION="${RUNNER_VERSION:-2.338.0}"
RUNNER_SHA256="${RUNNER_SHA256:-628b4a7258487b80c1d3c221095a7ded349f5ae0175fd3dfab708d07428f041b}"
CLI_VERSION="${CLI_VERSION:-2.107.0}"
CLI_SHA256="${CLI_SHA256:-d54648dd7f46ab824ba483bf4db712235a58c3242c2ff675ac7732a9b4f21e0f}"
NODE_VERSIONS="${NODE_VERSIONS:-20.20.2 22.23.3 24.22.0}"
NODE_DEFAULT="${NODE_DEFAULT:-22.23.3}"
# Deno: the version the workflows pin plus a current 2.x.
DENO_VERSIONS="${DENO_VERSIONS:-2.6.8 2.9.7}"
# <python-version>-<release-tag>|<sha256> of actions/python-versions ubuntu-24.04 arm64 builds.
PYTHON_SPECS="${PYTHON_SPECS:-3.11.17-36876195594|a7a7bb9e6b50483f393d1c44c87aa87677a0464a9e3b07f33ee5b31ce155c6ef 3.12.15-36805895057|c537f7852633f9a6d909181528e263087ad815cc44d52ed226992b70b2648f44 3.13.16-36805956071|0e923697b278f1a21ac403838a4238b659200726d8983c3f271a120e76090f0e}"
DOCKER_KEY_FPR="${DOCKER_KEY_FPR:-9DC858229FC7DD38854AE2D88D81803C0EBFCD88}"
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
die() { log "ERROR $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# fetch URL DEST EXPECTED_SHA256 — download and verify before anyone uses the file.
fetch() {
  curl -fsSL "$1" -o "$2"
  echo "$3  $2" | sha256sum -c - > /dev/null || die "checksum mismatch for $1"
}

install_apt_baseline() {
  log "apt baseline + docker + gh"
  # An unattended-upgrades run holding the dpkg lock would fail a job's `sudo apt-get install`
  # (plpgsql-check does this); hosted runners do not auto-upgrade either.
  systemctl disable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer 2> /dev/null || true
  apt-get update
  apt-get install -y --no-install-recommends \
    git curl ca-certificates gnupg jq unzip zip xz-utils zstd bc \
    python3 python3-venv python3-pip build-essential libatomic1 postgresql-client sudo
  apt-get purge -y unattended-upgrades 2> /dev/null || true
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$TMP/docker.gpg"
  gpg --show-keys --with-colons "$TMP/docker.gpg" | grep -q "^fpr:::::::::${DOCKER_KEY_FPR}:" \
    || die "docker apt key fingerprint does not match the pin"
  gpg --dearmor < "$TMP/docker.gpg" > /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
  chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
  apt-get update
  apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin gh
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
  local tarball="actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz"
  fetch "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${tarball}" "$TMP/$tarball" "$RUNNER_SHA256"
  install -d -m 0755 "$RUNNER_HOME"
  tar -xzf "$TMP/$tarball" -C "$RUNNER_HOME"
  "$RUNNER_HOME/bin/installdependencies.sh" > /dev/null
  chown -R runner:runner "$RUNNER_HOME"
}

cache_node() {
  local v base tarball expected dest
  for v in $NODE_VERSIONS; do
    log "node $v"
    base="https://nodejs.org/dist/v${v}"
    tarball="node-v${v}-linux-${NODE_ARCH}.tar.xz"
    curl -fsSL "$base/SHASUMS256.txt" -o "$TMP/SHASUMS256-$v.txt"
    expected="$(grep " ${tarball}\$" "$TMP/SHASUMS256-$v.txt" | cut -d' ' -f1)"
    [ -n "$expected" ] || die "no checksum for $tarball"
    fetch "$base/$tarball" "$TMP/$tarball" "$expected"
    dest="$TC/node/$v/$TC_ARCH"
    mkdir -p "$dest"
    tar -xJf "$TMP/$tarball" --strip-components=1 -C "$dest"
    touch "$TC/node/$v/$TC_ARCH.complete"
  done
  local b
  for b in node npm npx corepack; do
    [ -e "$TC/node/$NODE_DEFAULT/$TC_ARCH/bin/$b" ] || die "NODE_DEFAULT $NODE_DEFAULT not among NODE_VERSIONS"
    ln -sf "$TC/node/$NODE_DEFAULT/$TC_ARCH/bin/$b" "/usr/local/bin/$b"
  done
}

cache_deno() {
  local v url expected dest
  for v in $DENO_VERSIONS; do
    log "deno $v"
    url="https://github.com/denoland/deno/releases/download/v${v}/deno-${DENO_TARGET}.zip"
    curl -fsSL "$url.sha256sum" -o "$TMP/deno-$v.sha256sum"
    expected="$(cut -d' ' -f1 "$TMP/deno-$v.sha256sum")"
    [ -n "$expected" ] || die "no published checksum for deno $v"
    fetch "$url" "$TMP/deno-$v.zip" "$expected"
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

# prepull — `supabase start` (untrimmed) + stop, so every container image of the stack is local.
prepull() {
  local reg work cli="$TC/supabase/$CLI_VERSION/$TC_ARCH/supabase"
  systemctl start docker
  for reg in $PREPULL_REGISTRIES; do
    log "pre-pulling the supabase stack from $reg"
    work="$(mktemp -d)"
    ( cd "$work" && "$cli" init > /dev/null \
      && SUPABASE_INTERNAL_IMAGE_REGISTRY="$reg" "$cli" start \
      && SUPABASE_INTERNAL_IMAGE_REGISTRY="$reg" "$cli" stop --no-backup ) || die "supabase pre-pull from $reg failed"
    rm -rf "$work"
    docker image ls --format '{{.Repository}}' | grep -q "^${reg}/supabase/postgres\$" || die "postgres image from $reg missing after pre-pull"
    docker image ls --format '{{.Repository}}' | grep -q "^${reg}/supabase/studio\$" || die "studio image from $reg missing (untrimmed start expected)"
  done
  log "images: $(docker image ls -q | wc -l | tr -d ' ')"
}

cleanup() {
  log "cleanup"
  chown -R runner:runner "$TC"
  apt-get clean
  rm -rf /var/lib/apt/lists/* /root/.cache /home/runner/.cache
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
