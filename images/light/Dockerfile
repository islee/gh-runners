# Derived light-class runner image: the official actions-runner image plus hosted-runner parity
# tools and a PRE-POPULATED tool cache, so actions/setup-node and denoland/setup-deno are cache
# hits instead of per-job downloads (a 20 s hosted job otherwise takes 60-80 s on a slot).
#
# Context: built inside the Lima pool VM by images/build-light.sh; the resulting local image ID
# (or a pushed repo@sha256 digest) goes into LIGHT_IMAGE in slots/config. Generic and public-safe:
# nothing org-specific. Architecture defaults are arm64 (Apple Silicon host); override the
# *_ARCH / DENO_TARGET build args for another architecture.
#
# Tool-cache layout (@actions/tool-cache): $TOOLCACHE/<tool>/<exact-version>/<arch>/... plus a
# sibling marker $TOOLCACHE/<tool>/<exact-version>/<arch>.complete -- without the marker
# tc.find() ignores the directory.
#
# NOTE: Playwright system deps are intentionally absent; they belong in a later variant.
# NOTE: numeric USER (hadolint DL3066); uid 1001 is `runner` in the base image.

# Pinned by digest: a mutable tag would let an upstream push change what runs with the JIT config.
FROM ghcr.io/actions/actions-runner@sha256:4ffadc0002b2581327e06101fc8c06cd189232baf79fe561fac9caeb76f5e807

# Bump here (see README). NODE_DEFAULT must be one of NODE_SPECS.
# <version>|<sha256 of node-v<version>-linux-<arch>.tar.xz>, taken from nodejs.org SHASUMS256.txt.asc
# after verifying its GPG signature against nodejs/release-keys. A checksum fetched from the same
# origin as the artifact is not a pin, so the values live here.
ARG NODE_SPECS="20.20.2|73093db209e4e9e09dd7d15a47aeaab1b74833830df03efa5f942a1122c5fa71 22.23.3|a44aeb94849a299b22df10b9e622ec2f605c2183501bc40590705131de7c740f 24.22.0|fef00bb4d36e1c50104a9775a10359beee98f162b4104dd12472c75065c6a143"
ARG NODE_DEFAULT="22.23.3"
# <version>|<sha256 of deno-<target>.zip>: current 2.x plus 2.6.8 (the version the workflows pin).
# Values equal the GitHub release-asset digests (`gh api repos/denoland/deno/releases/tags/v<ver>`).
ARG DENO_SPECS="2.9.7|c832298b1ad4422481334855f6003e0f54145762c5a134f20a489511d2f65bbf 2.6.8|09a0a800be639986515540ddae2f2752625ed412f63d36c7152c2a72ee78c2d7"
# <python-version>-<release-tag>|<sha256> of the actions/python-versions ubuntu-24.04 arm64 builds,
# installed with each release's own setup.sh into the layout actions/setup-python searches
# ($TOOLCACHE/Python/<exact-version>/arm64 + arm64.complete).
ARG PYTHON_SPECS="3.11.17-36876195594|a7a7bb9e6b50483f393d1c44c87aa87677a0464a9e3b07f33ee5b31ce155c6ef 3.12.15-36805895057|c537f7852633f9a6d909181528e263087ad815cc44d52ed226992b70b2648f44 3.13.16-36805956071|0e923697b278f1a21ac403838a4238b659200726d8983c3f271a120e76090f0e"
ARG TC_ARCH="arm64"
ARG NODE_ARCH="arm64"
ARG DENO_TARGET="aarch64-unknown-linux-gnu"

# The runner exports RUNNER_TOOL_CACHE from AGENT_TOOLSDIRECTORY.
ENV AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache

USER 0
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Hosted-parity apt baseline + gh from GitHub's signed apt repo.
RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        git curl ca-certificates gnupg jq unzip zip xz-utils zstd bc \
        python3 python3-venv python3-pip build-essential libatomic1 postgresql-client \
    && install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && DEBIAN_FRONTEND=noninteractive apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gh \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Node (all NODE_SPECS) and Deno into the tool cache; checksums verified before extraction.
RUN set -eu; \
    tc="${AGENT_TOOLSDIRECTORY}"; \
    tmp="$(mktemp -d)"; \
    mkdir -p "${tc}/node" "${tc}/deno"; \
    for nspec in ${NODE_SPECS}; do \
        v="${nspec%%|*}"; \
        nsha="${nspec#*|}"; \
        tarball="node-v${v}-linux-${NODE_ARCH}.tar.xz"; \
        curl -fsSL "https://nodejs.org/dist/v${v}/${tarball}" -o "${tmp}/${tarball}"; \
        echo "${nsha}  ${tmp}/${tarball}" | sha256sum -c -; \
        dest="${tc}/node/${v}/${TC_ARCH}"; \
        mkdir -p "${dest}"; \
        tar -xJf "${tmp}/${tarball}" --strip-components=1 -C "${dest}"; \
        touch "${tc}/node/${v}/${TC_ARCH}.complete"; \
    done; \
    for dspec in ${DENO_SPECS}; do \
        dv="${dspec%%|*}"; \
        dsha="${dspec#*|}"; \
        curl -fsSL "https://github.com/denoland/deno/releases/download/v${dv}/deno-${DENO_TARGET}.zip" -o "${tmp}/deno-${dv}.zip"; \
        echo "${dsha}  ${tmp}/deno-${dv}.zip" | sha256sum -c -; \
        deno_dest="${tc}/deno/${dv}/${TC_ARCH}"; \
        mkdir -p "${deno_dest}"; \
        unzip -q "${tmp}/deno-${dv}.zip" -d "${deno_dest}"; \
        chmod 0755 "${deno_dest}/deno"; \
        touch "${tc}/deno/${dv}/${TC_ARCH}.complete"; \
    done; \
    for spec in ${PYTHON_SPECS}; do \
        rel="${spec%%|*}"; \
        pysha="${spec#*|}"; \
        pyver="${rel%%-*}"; \
        curl -fsSL "https://github.com/actions/python-versions/releases/download/${rel}/python-${pyver}-linux-24.04-arm64.tar.gz" -o "${tmp}/py-${pyver}.tgz"; \
        echo "${pysha}  ${tmp}/py-${pyver}.tgz" | sha256sum -c -; \
        mkdir -p "${tmp}/py-${pyver}"; \
        tar -xzf "${tmp}/py-${pyver}.tgz" -C "${tmp}/py-${pyver}"; \
        env -C "${tmp}/py-${pyver}" bash ./setup.sh > /dev/null; \
        test -e "${tc}/Python/${pyver}/${TC_ARCH}.complete"; \
    done; \
    for b in node npm npx corepack; do \
        test -e "${tc}/node/${NODE_DEFAULT}/${TC_ARCH}/bin/${b}"; \
        ln -sf "${tc}/node/${NODE_DEFAULT}/${TC_ARCH}/bin/${b}" "/usr/local/bin/${b}"; \
    done; \
    chown -R 1001 "${tc}"; \
    rm -rf "${tmp}"; \
    node --version; npm --version; "${tc}/deno/${DENO_SPECS%%|*}/${TC_ARCH}/deno" --version

USER 1001
