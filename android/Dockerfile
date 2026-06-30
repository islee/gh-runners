# Android E2E runner — layered on ghcr.io/actions/actions-runner
#
# WHY this base image: the official GitHub Actions runner image provides the runner binary
# (config.sh / run.sh) without any third-party vendor code. Unlike myoung34/github-runner it
# does NOT handle registration — our bootstrap.sh + runner-payload.sh do that. The trade-off is a
# few more lines of our own script; the benefit is a first-party base with no supply-chain risk from
# an intermediary image that injects GitHub credentials and runs PR code.
#
# Build args let you choose API level / target / arch at build time; the defaults cover the
# common case: API 34, google_apis, x86_64 (KVM-accelerated on Linux x86_64 hosts).
#
# NOTE: the official image runs as non-root user `runner`. All apt-get installs must happen under
# USER root, then return to USER runner before ENTRYPOINT — otherwise the runner binary has no
# permission to write its own state files.
#
# hadolint ignore=DL3008

# Base image — PIN before fleet rollout. `:latest` is fine for pilots but is a moving target.
# Override at build: --build-arg BASE_IMAGE=ghcr.io/actions/actions-runner:<tag|digest>.
ARG BASE_IMAGE=ghcr.io/actions/actions-runner:latest
FROM ${BASE_IMAGE}

# NOTE: ARGs declared before the first FROM lose scope after it; re-declare them here
# so they are in scope for RUN/ENV instructions.
ARG ANDROID_API=34
ARG ANDROID_TARGET=google_apis
ARG ANDROID_ARCH=x86_64

# Expose as ENV so runner-payload.sh and hooks can read values baked at build time.
ENV ANDROID_API=${ANDROID_API} \
    ANDROID_TARGET=${ANDROID_TARGET} \
    ANDROID_ARCH=${ANDROID_ARCH}

# Android SDK paths — conventional layout under /opt/android-sdk.
ENV ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    PATH="${PATH}:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/opt/android-sdk/emulator"

# Node LTS major version to install via NodeSource.
ARG NODE_MAJOR=20

# Maestro CLI version — pin and update deliberately.
ARG MAESTRO_VERSION=1.39.13

# Android cmdline-tools build number. Google ROTATES this numeric id and removes old URLs, so
# a stale value makes the build fail with a curl/unzip error. Check the current id at
# https://developer.android.com/studio#command-line-tools-only and override via --build-arg.
ARG CMDLINE_TOOLS_VERSION=11076708

# Switch to root for all package/SDK installs. We return to USER runner at the bottom.
USER root

WORKDIR /opt

# ── System packages ──────────────────────────────────────────────────────────
# Single layer: JDK 17, curl, unzip, jq, KVM userspace tools, and packages Maestro needs.
# IMPORTANT: --no-install-recommends keeps the layer small; clean apt lists afterward.
# hadolint ignore=DL3009
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        openjdk-17-jdk-headless \
        curl \
        unzip \
        zip \
        xz-utils \
        zstd \
        jq \
        ca-certificates \
        gnupg \
        qemu-kvm \
        libvirt-clients \
        bridge-utils \
        cpu-checker \
        iproute2 \
        xvfb \
    && rm -rf /var/lib/apt/lists/*

# ── Node LTS ─────────────────────────────────────────────────────────────────
# NodeSource keyring + repo, then install — single layer, clean lists.
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# ── Android SDK — cmdline-tools ───────────────────────────────────────────────
# Download cmdline-tools from the official URL, install under the conventional path so
# sdkmanager resolves it. The path must be .../cmdline-tools/latest/ for self-reference.
RUN mkdir -p "${ANDROID_HOME}/cmdline-tools" && \
    curl -fsSL "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_VERSION}_latest.zip" \
        -o /tmp/cmdline-tools.zip && \
    unzip -q /tmp/cmdline-tools.zip -d /tmp/cmdline-tools-extract && \
    mv /tmp/cmdline-tools-extract/cmdline-tools "${ANDROID_HOME}/cmdline-tools/latest" && \
    rm -rf /tmp/cmdline-tools.zip /tmp/cmdline-tools-extract

# ── Android SDK — platform-tools, emulator, system image, accept licenses ────
# Accept all SDK licenses non-interactively by piping 'y' for each prompt.
# Install: platform-tools, emulator, the requested API platform, and the system image.
# CRITICAL: the system-image package name follows the pattern
#   system-images;android-<API>;<TARGET>;<ARCH>
# so the build ARGs must produce a valid package name.
# hadolint ignore=SC2086
RUN yes | sdkmanager --licenses > /dev/null 2>&1 || true && \
    sdkmanager \
        "platform-tools" \
        "emulator" \
        "platforms;android-${ANDROID_API}" \
        "system-images;android-${ANDROID_API};${ANDROID_TARGET};${ANDROID_ARCH}"

# ── Create headless AVD at build time ────────────────────────────────────────
# WHY shared path: the AVD lives in ANDROID_AVD_HOME (/opt/android-avd), NOT in root's ~/.android.
# The emulator is booted at runtime by the job-started hook AS the `runner` user (so adb is
# owned by the same user the job runs as — cross-user adb permission issues don't arise).
# The emulator process itself starts per-job, not here.
ENV ANDROID_AVD_HOME=/opt/android-avd
RUN mkdir -p "${ANDROID_AVD_HOME}" && \
    echo "no" | avdmanager create avd \
        --name "runner_avd" \
        --package "system-images;android-${ANDROID_API};${ANDROID_TARGET};${ANDROID_ARCH}" \
        --device "pixel_6" \
        --force && \
    chown -R runner "${ANDROID_AVD_HOME}"

# ── Maestro CLI ───────────────────────────────────────────────────────────────
# Install to /usr/local/maestro and add to PATH.
ENV MAESTRO_HOME=/usr/local/maestro
ENV PATH="${PATH}:${MAESTRO_HOME}/bin"

RUN curl -fsSL "https://github.com/mobile-dev-inc/maestro/releases/download/cli-${MAESTRO_VERSION}/maestro.zip" \
        -o /tmp/maestro.zip && \
    unzip -q /tmp/maestro.zip -d /usr/local && \
    rm /tmp/maestro.zip

# ── Runner job hooks (per-job emulator lifecycle) ─────────────────────────────
# WHY per-job hooks rather than per-container: booting the emulator at container start would keep
# a ~3 GB process resident the entire time the runner idled waiting for jobs (significant RAM
# pressure on shared hosts). Per-job hooks boot only while a job runs, then kill it after.
# The hook also boots the emulator AS the runner user for correct adb ownership.
COPY hooks/ /opt/hooks/
RUN chmod +x /opt/hooks/*.sh
ENV ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/hooks/job-started.sh \
    ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/opt/hooks/job-completed.sh

# ── Entrypoint (bootstrap trust root + swappable payload + fleet manifest) ────
# bootstrap.sh is the STABLE ENTRYPOINT/trust root (never self-updated, not in the manifest);
# runner-payload.sh is the swappable register+run script that bootstrap.sh may replace from a
# broker-verified GitHub ref on each container start (X-Fleet-Variant: docker → key android-docker).
# .fleet-manifest carries the version + per-file sha256 the broker anchors against.
COPY bootstrap.sh /opt/bootstrap.sh
COPY runner-payload.sh /opt/runner-payload.sh
COPY .fleet-manifest /opt/.fleet-manifest
RUN chmod +x /opt/bootstrap.sh /opt/runner-payload.sh

# WHY ENV: makes UPDATE_REPO inspectable via `docker inspect` and overridable per-compose service
# without a rebuild. bootstrap.sh reads this at startup.
ENV UPDATE_REPO=islee/gh-runners

# Return to the non-root runner user before handing control to the entrypoint.
# CRITICAL: the official image's runner binary expects to run as `runner` (non-root). Staying
# as root would cause permission errors when the runner writes its own state files.
#
# NOTE: official image user and home directory —
#   user: runner
#   home / runner binary location: /home/runner  (config.sh and run.sh live here)
USER runner

ENTRYPOINT ["/opt/bootstrap.sh"]
# NOTE: the official image's default CMD is not a runner-listener command like myoung34's.
# We do NOT rely on CMD here — runner-payload.sh calls run.sh directly after registering.
