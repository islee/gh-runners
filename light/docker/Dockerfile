# Containerized "light" runner — official GitHub runner image + our registration entrypoint.
#
# WHY layered on the official image: ghcr.io/actions/actions-runner ships the first-party runner
# (config.sh / run.sh) with no third-party vendor code. It does NOT include a registration loop, so
# we add a small entrypoint (curl + jq) that mints/fetches a token and registers ephemerally.
#
# This base is intentionally minimal. If your "light" jobs need a language toolchain (node, python,
# etc.) and don't install it themselves via setup-* actions, add the apt/install lines here.

# Pin before fleet rollout: `:latest` is a moving target for an image that runs PR code.
# Override at build: --build-arg BASE_IMAGE=ghcr.io/actions/actions-runner:<tag|digest>.
ARG BASE_IMAGE=ghcr.io/actions/actions-runner:latest
FROM ${BASE_IMAGE}

# Install the entrypoint's runtime deps (curl, jq) plus the hosted-runner job baseline the official
# image lacks. The Ubuntu base already ships unzip/lsb_release/python3 (so setup-deno/setup-python
# work — setup-python downloads a prebuilt Python, since the base IS Ubuntu, unlike the native Debian
# host), but it is missing zip + the actions/cache compressors (xz-utils, zstd). Add them for parity.
# USER root for apt, then drop back to the unprivileged `runner` user the official image runs as.
USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        curl jq ca-certificates zip xz-utils zstd && \
    rm -rf /var/lib/apt/lists/*

COPY bootstrap.sh /opt/bootstrap.sh
COPY runner-payload.sh /opt/runner-payload.sh
COPY .fleet-manifest /opt/.fleet-manifest
RUN chmod +x /opt/bootstrap.sh /opt/runner-payload.sh

# WHY ENV: makes UPDATE_REPO inspectable via `docker inspect` and overridable per-compose service
# without having to rebuild. bootstrap.sh reads this at startup.
ENV UPDATE_REPO=islee/gh-runners

USER runner
ENTRYPOINT ["/opt/bootstrap.sh"]
