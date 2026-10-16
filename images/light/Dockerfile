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

# Bump here (see README). NODE_DEFAULT must be one of NODE_VERSIONS.
ARG NODE_VERSIONS="20.20.2 22.23.3 24.22.0"
ARG NODE_DEFAULT="22.23.3"
ARG DENO_VERSION="2.9.7"
# Optional extra pin for the deno zip; the published .sha256sum is always checked as well.
ARG DENO_SHA256=""
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
        git curl ca-certificates gnupg jq unzip zip xz-utils zstd \
        python3 python3-venv python3-pip build-essential libatomic1 postgresql-client \
    && install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && DEBIAN_FRONTEND=noninteractive apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gh \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Node (all NODE_VERSIONS) and Deno into the tool cache; checksums verified before extraction.
RUN set -eu; \
    tc="${AGENT_TOOLSDIRECTORY}"; \
    tmp="$(mktemp -d)"; \
    mkdir -p "${tc}/node" "${tc}/deno"; \
    for v in ${NODE_VERSIONS}; do \
        base="https://nodejs.org/dist/v${v}"; \
        tarball="node-v${v}-linux-${NODE_ARCH}.tar.xz"; \
        curl -fsSL "${base}/${tarball}" -o "${tmp}/${tarball}"; \
        curl -fsSL "${base}/SHASUMS256.txt" -o "${tmp}/SHASUMS256-${v}.txt"; \
        expected="$(grep " ${tarball}\$" "${tmp}/SHASUMS256-${v}.txt" | cut -d' ' -f1)"; \
        test -n "${expected}"; \
        echo "${expected}  ${tmp}/${tarball}" | sha256sum -c -; \
        dest="${tc}/node/${v}/${TC_ARCH}"; \
        mkdir -p "${dest}"; \
        tar -xJf "${tmp}/${tarball}" --strip-components=1 -C "${dest}"; \
        touch "${tc}/node/${v}/${TC_ARCH}.complete"; \
    done; \
    deno_url="https://github.com/denoland/deno/releases/download/v${DENO_VERSION}/deno-${DENO_TARGET}.zip"; \
    curl -fsSL "${deno_url}" -o "${tmp}/deno.zip"; \
    curl -fsSL "${deno_url}.sha256sum" -o "${tmp}/deno.zip.sha256sum"; \
    deno_expected="$(cut -d' ' -f1 "${tmp}/deno.zip.sha256sum")"; \
    test -n "${deno_expected}"; \
    echo "${deno_expected}  ${tmp}/deno.zip" | sha256sum -c -; \
    if [ -n "${DENO_SHA256}" ]; then echo "${DENO_SHA256}  ${tmp}/deno.zip" | sha256sum -c -; fi; \
    deno_dest="${tc}/deno/${DENO_VERSION}/${TC_ARCH}"; \
    mkdir -p "${deno_dest}"; \
    unzip -q "${tmp}/deno.zip" -d "${deno_dest}"; \
    chmod 0755 "${deno_dest}/deno"; \
    touch "${tc}/deno/${DENO_VERSION}/${TC_ARCH}.complete"; \
    for b in node npm npx corepack; do \
        test -e "${tc}/node/${NODE_DEFAULT}/${TC_ARCH}/bin/${b}"; \
        ln -sf "${tc}/node/${NODE_DEFAULT}/${TC_ARCH}/bin/${b}" "/usr/local/bin/${b}"; \
    done; \
    chown -R 1001 "${tc}"; \
    rm -rf "${tmp}"; \
    node --version; npm --version; "${deno_dest}/deno" --version

USER 1001
