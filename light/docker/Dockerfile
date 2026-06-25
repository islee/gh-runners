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

# Install the entrypoint's runtime deps. USER root for apt, then drop back to the unprivileged
# `runner` user the official image runs as.
USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl jq ca-certificates && \
    rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /opt/entrypoint.sh
RUN chmod +x /opt/entrypoint.sh

USER runner
ENTRYPOINT ["/opt/entrypoint.sh"]
