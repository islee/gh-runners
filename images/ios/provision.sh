#!/bin/bash
# provision.sh <runner-version> <runner-sha256> — guest-side provisioning of the ios golden (macOS).
#
# Context: copied into the build VM and run by images/build-ios.sh through `tart exec` as the guest's
# default user (`admin`, passwordless sudo in the Cirrus base images). It adds exactly what an ephemeral
# runner VM needs on top of the pinned base image and removes the one inbound path the base ships:
#   1. actions/runner (osx-arm64) into ~/actions-runner, sha256-verified. The slot starts it with
#      `cd ~/actions-runner && ./run.sh --jitconfig <stdin>`; no config.sh, no stored credentials.
#   2. /Applications/Xcode_<version>.app symlink to the image's selected Xcode, so workflows that pin
#      that path (xcode-select / DEVELOPER_DIR) find it whatever the base image calls its copy.
#   3. Xcode first-launch tasks and licence, so the first job does not spend minutes on them.
#   4. Remote Login (sshd) OFF: Cirrus images ship admin:admin over ssh; the guest agent is the only
#      way in. The golden is only ever run behind the in-guest egress preflight, but an open sshd on
#      the VM network is not something to carry.
# Output: diagnostics on stderr/stdout; the last line is `PROVISION-OK <runner-version> <xcode-version>`.
#
# Dependencies: curl, shasum, tar, xcodebuild, sudo (all in the base image). bash 3.2 compatible.

set -euo pipefail

PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin
export PATH

die() { echo "[provision] ERROR $*" >&2; exit 1; }
log() { echo "[provision] $*" >&2; }

[ "$#" -eq 2 ] || die "usage: provision.sh <runner-version> <runner-sha256>"
RUNNER_VERSION=$1
RUNNER_SHA256=$2
[[ "$RUNNER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "bad runner version"
[[ "$RUNNER_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "bad runner sha256"

# 1. runner ------------------------------------------------------------------------------------------
RUNNER_DIR="$HOME/actions-runner"
TARBALL="$(mktemp -d)/runner.tar.gz"
log "downloading actions/runner $RUNNER_VERSION"
curl -fsSL --retry 3 -o "$TARBALL" \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz"
# CRITICAL: verify BEFORE extracting; this tarball runs with the job's JIT credential.
echo "${RUNNER_SHA256}  ${TARBALL}" | shasum -a 256 -c - >&2 || die "runner tarball sha256 mismatch"
rm -rf "$RUNNER_DIR"
mkdir -p "$RUNNER_DIR"
tar xzf "$TARBALL" -C "$RUNNER_DIR"
rm -f "$TARBALL"
[ -x "$RUNNER_DIR/run.sh" ] || die "run.sh missing after extraction"

# 2/3. Xcode -----------------------------------------------------------------------------------------
sudo xcodebuild -license accept >&2 || log "WARN xcodebuild -license accept failed"
sudo xcodebuild -runFirstLaunch >&2 || die "xcodebuild -runFirstLaunch failed"
dev="$(xcode-select -p)"
app="${dev%/Contents/Developer}"
case "$app" in /*.app) ;; *) die "xcode-select -p is not inside an .app bundle: $dev" ;; esac
xcode_version="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
[[ "$xcode_version" =~ ^[0-9][0-9.]*$ ]] || die "cannot read the Xcode version"
link="/Applications/Xcode_${xcode_version}.app"
if [ ! -e "$link" ]; then
  log "linking $link -> $app"
  sudo ln -s "$app" "$link"
fi
# For the record (the build script shows stderr to the operator).
xcodebuild -version >&2
xcrun simctl list runtimes >&2 || log "WARN simctl list runtimes failed"

# 4. no sshd -----------------------------------------------------------------------------------------
# NOTE: `systemsetup` needs Full Disk Access on recent macOS and may refuse; disabling the launchd
# service is the fallback that does not.
sudo systemsetup -setremotelogin off >&2 2>&1 \
  || { log "systemsetup refused; disabling the sshd launchd service instead"; sudo launchctl disable system/com.openssh.sshd >&2; }
sudo launchctl bootout system/com.openssh.sshd >&2 2>&1 || true
if /usr/bin/nc -z -w 2 127.0.0.1 22 > /dev/null 2>&1; then die "sshd still listens on port 22"; fi

echo "PROVISION-OK ${RUNNER_VERSION} ${xcode_version}"
