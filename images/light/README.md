# images/light — derived light-class runner image

## Purpose

The official `actions-runner` image has no Node and an empty tool cache, so every job re-downloads
Node/Deno and `npm` is missing unless the workflow adds `setup-node`. This image adds hosted-runner
parity tools and a pre-populated tool cache so `actions/setup-node` and `denoland/setup-deno`
resolve as cache hits.

## What is in it

- Base: official runner image, pinned by digest (Ubuntu 24.04, user `runner` uid 1001).
- apt: git curl ca-certificates gnupg jq unzip zip xz-utils zstd python3 python3-venv python3-pip
  build-essential libatomic1 postgresql-client bc, plus `gh` from GitHub's signed apt repo.
- `AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache` (the runner exports it as `RUNNER_TOOL_CACHE`),
  owned by uid 1001, holding Node 20.20.2 / 22.23.3 / 24.22.0, Deno 2.9.7 and 2.6.8, and Python 3.11 / 3.12 / 3.13
  (see `Dockerfile` ARGs).
- Node 22 on the default PATH (`/usr/local/bin/{node,npm,npx,corepack}` symlinks), like hosted.
- Not included: Playwright system deps (a later variant).

## Bumping versions

Edit the `ARG` defaults in `Dockerfile` (`NODE_SPECS`, `NODE_DEFAULT`, `DENO_SPECS`, `PYTHON_SPECS`, and the
base image digest), rebuild, and update `LIGHT_IMAGE`. Every artifact is verified against a sha256 pinned in the `ARG` (a checksum fetched from the same
origin is not a pin): Node values come from `SHASUMS256.txt.asc` after checking its GPG signature
against nodejs/release-keys, Deno values equal the GitHub release-asset digests; Python builds (actions/python-versions, ubuntu-24.04 arm64) against pinned sha256 values in `PYTHON_SPECS`. `setup-node: 22` only hits the cache while it resolves to
a cached exact version, so bump the list when a new minor ships.

## Building

```
images/build-light.sh [lima-instance]     # default ghr-pool-golden; run as the ghr user
# stdout: IMAGE_ID=sha256:<64 hex>        # also tagged ghr/light:<UTC date>
```

Put the printed ID (or a pushed `repo@sha256:` digest) in `LIGHT_IMAGE`; pool instances cloned
from the golden VM then contain the image. Recreate pool instances after a rebuild.

## Verifying cache hits

In a job on the slot, `actions/setup-node` should log `Found in cache @ /opt/hostedtoolcache/node/...`
and no download; `ls /opt/hostedtoolcache/node/*/arm64.complete` must list one marker per version.
`node --version` before any setup step should print the default (22.x) version.
