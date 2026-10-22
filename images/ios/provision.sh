#!/bin/bash
# provision.sh <runner-version> <runner-sha256> — guest-side provisioning of the ios golden (macOS).
#
# Context: copied into the build VM and run by images/build-ios.sh through `tart exec` as the guest's
# default user (`admin`, passwordless sudo in the Cirrus base images). It adds exactly what an ephemeral
# runner VM needs on top of the pinned base image and removes the one inbound path the base ships:
#   1. actions/runner (osx-arm64) into ~/actions-runner, sha256-verified. The slot starts it with
#      `cd ~/actions-runner && ./run.sh --jitconfig <stdin>`; no config.sh, no stored credentials.
#   1b. rbenv global = newest installed Ruby 3.x (CocoaPods breaks on the image's Ruby 4 default), with the
#      image's cocoapods/fastlane versions installed for it.
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

# 1b. Ruby for CocoaPods -----------------------------------------------------------------------------
# WHY: the base image's rbenv default is Ruby 4.x, whose json 3.x dropped `quirks_mode`; CocoaPods 1.17
# still passes it, so every `pod install` dies with "ArgumentError - unknown keyword: quirks_mode"
# (first live iOS build, 2026-10-22). Hosted macOS runners ship Ruby 3.x. Make the newest installed
# 3.x the global and give it the same cocoapods/fastlane versions the image installed for the old default.
RBENV="$(PATH=/opt/homebrew/bin:$HOME/.rbenv/bin:$PATH command -v rbenv || true)"
[ -n "$RBENV" ] || die "rbenv not found in the base image"
old_ruby="$("$RBENV" global)"
ruby3="$("$RBENV" versions --bare | grep -E '^3\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 || true)"
[ -n "$ruby3" ] || die "no Ruby 3.x installed under rbenv (have: $("$RBENV" versions --bare | tr '\n' ' '))"
for g in cocoapods fastlane; do
  v="$(RBENV_VERSION=$old_ruby "$RBENV" exec gem list -e "$g" 2> /dev/null | sed -n "s/^$g (\([0-9.]*\).*/\1/p")"
  [ -n "$v" ] || die "base image has no $g under Ruby $old_ruby to copy the version from"
  if ! RBENV_VERSION=$ruby3 "$RBENV" exec gem list -i -e "$g" -v "$v" > /dev/null 2>&1; then
    log "installing $g $v for Ruby $ruby3"
    RBENV_VERSION=$ruby3 "$RBENV" exec gem install "$g" -v "$v" --no-document >&2 || die "gem install $g $v failed"
  fi
done
"$RBENV" global "$ruby3"
"$RBENV" rehash
pod_version="$("$RBENV" exec pod --version 2> /dev/null || true)"
[[ "$pod_version" =~ ^[0-9]+\.[0-9]+ ]] || die "pod does not run under Ruby $ruby3"
log "ruby $old_ruby -> $ruby3 (cocoapods $pod_version)"

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
# WHY not `systemsetup -setremotelogin off`: it asks "Do you really want to turn remote login off?"
# and, with stdin at EOF, re-asks forever; on the first live build that loop wrote 285 GB of prompts
# to the host's build log and filled the host disk (2026-10-22). launchctl never prompts.
sudo launchctl disable system/com.openssh.sshd >&2
sudo launchctl bootout system/com.openssh.sshd >&2 2>&1 || true
if /usr/bin/nc -z -G 2 127.0.0.1 22 > /dev/null 2>&1; then die "sshd still listens on port 22"; fi

echo "PROVISION-OK ${RUNNER_VERSION} ${xcode_version}"
