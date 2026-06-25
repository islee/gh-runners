# Containerized "supabase" runner — official GitHub runner image + registration entrypoint +
# a Docker CLI (the jobs drive the host Docker daemon to bring up a Supabase stack).
#
# WHY a Docker CLI but NOT a Docker daemon: the job runs `supabase start` / `docker ...` against the
# HOST daemon via the mounted /var/run/docker.sock (see docker-compose.yml) — docker-OUT-of-docker,
# not dind. So we only need the client binary here, plus curl/jq for the entrypoint.
#
# NOTE: the Supabase CLI itself is NOT baked in — install it in your workflow (it changes fast), or
# add it here if you prefer a pinned version.

ARG BASE_IMAGE=ghcr.io/actions/actions-runner:latest
FROM ${BASE_IMAGE}

USER root
# docker CLI via the official Docker apt repo, plus the entrypoint deps (curl, jq) and the
# hosted-runner job baseline the official image lacks. The Ubuntu base already has
# unzip/lsb_release/python3 (setup-deno/setup-python work via download), but is missing zip + the
# actions/cache compressors (xz-utils, zstd) — add them for parity.
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl jq ca-certificates gnupg zip xz-utils zstd postgresql-client && \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" \
        > /etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends docker-ce-cli && \
    rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /opt/entrypoint.sh
RUN chmod +x /opt/entrypoint.sh

# NOTE: the `runner` user must be able to talk to the mounted docker.sock. The socket's group GID on
# the host varies; docker-compose.yml passes it via `group_add: ${DOCKER_GID}`. (Alternatively run
# this image as a user matching the socket's group.)
USER runner
ENTRYPOINT ["/opt/entrypoint.sh"]
