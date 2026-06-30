#!/usr/bin/env bash
# release.sh — maintainer tool: generate .fleet-manifest files for each native runner type.
#
# Usage: ./release.sh <version>
# Example: ./release.sh 2026.06.26.1
#
# For each type (light supabase ios): computes sha256 of the managed code files
# (runner-loop.sh, self-update.sh), writes <type>/.fleet-manifest, then computes the sha256 of
# each resulting manifest. Prints a JSON map of {type: manifest_sha256} and the git tag to use
# so the operator can set FLEET_DESIRED_REF and FLEET_MANIFEST_SHA256 on the broker.
#
# IMPORTANT — Ordering (MUST be followed every release):
#   1. Run this script to write .fleet-manifest files.
#   2. git add + git commit the manifests AND the updated fleet code in the same commit.
#   3. git push origin main (or the target branch).
#   4. Wait ~60 seconds for raw.githubusercontent.com CDN propagation.
#   5. THEN move/create the release tag: git tag <tag> && git push origin <tag>
#
# WHY the ordering matters: the runtime integrity gate checks the manifest at the tag URL. If
# the tag is moved BEFORE the files propagate, runners fetch a stale or absent manifest and
# fail-safe (no update applied). Always push files first, wait, then tag.
#
# After tagging: set these on the broker (Render env vars or config):
#   FLEET_DESIRED_REF=<tag>
#   FLEET_MANIFEST_SHA256=<type-specific hex from this script's JSON output>
#   (set per-type if variants diverge; set globally if all identical)
#
# This script does NOT git-tag, git-commit, or git-push. Review the output before doing so.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# ── Args ──────────────────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <version>" >&2
  echo "Example: $0 2026.06.26.1" >&2
  exit 1
fi
readonly VERSION="$1"

# Validate: version must be non-empty and contain no whitespace or path chars.
if [[ -z "${VERSION}" || "${VERSION}" =~ [[:space:]/\\] ]]; then
  echo "[ERROR] Invalid version string: '${VERSION}'" >&2; exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
# Compute sha256 of a file; portable across Linux (sha256sum) and macOS (shasum -a 256).
_sha256_file() {
  if command -v sha256sum &>/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# ── Managed file set (must match self-update.sh UPDATE_ALLOWLIST_CSV) ─────────
readonly -a MANAGED_FILES=("runner-loop.sh" "self-update.sh")

# ── Per-type manifest generation ──────────────────────────────────────────────
declare -A MANIFEST_HASHES

for TYPE in light supabase ios; do
  TYPE_DIR="${SCRIPT_DIR}/${TYPE}"
  MANIFEST="${TYPE_DIR}/.fleet-manifest"

  # Verify all managed files exist.
  for F in "${MANAGED_FILES[@]}"; do
    [[ -f "${TYPE_DIR}/${F}" ]] || {
      echo "[ERROR] ${TYPE}/${F} not found — run from the repo root." >&2; exit 1
    }
  done

  # Write manifest.
  {
    printf 'version=%s\n' "${VERSION}"
    printf '# sha256  basename — CODE files only; authoritative for the full managed set\n'
    for F in "${MANAGED_FILES[@]}"; do
      HASH="$(_sha256_file "${TYPE_DIR}/${F}")"
      printf '%s  %s\n' "${HASH}" "${F}"
    done
  } > "${MANIFEST}"

  MANIFEST_HASHES["${TYPE}"]="$(_sha256_file "${MANIFEST}")"
  echo "[INFO]  Wrote ${TYPE}/.fleet-manifest (version=${VERSION})"
done

# ── Docker-variant manifests ────────────────────────────────────────────────────
# Docker runners run a DIFFERENT payload than the native runner of the same type, so they carry their
# own manifest under a "<type>-<variant>" broker key (variant=docker). Managed set = the single
# swappable payload (runner-payload.sh); bootstrap.sh is the baked-in trust root and must NEVER be
# listed. Keys map to the repo dir holding the variant's files — note android lives at its own
# top-level dir (it is docker-only, no native counterpart), unlike light/supabase under <type>/docker.
readonly -a DOCKER_MANAGED_FILES=("runner-payload.sh")
# Fixed key order → deterministic JSON output. Add a variant by extending both arrays.
readonly -a DOCKER_VARIANT_KEYS=("light-docker" "supabase-docker" "android-docker")
declare -A DOCKER_VARIANT_DIRS=(
  ["light-docker"]="light/docker"
  ["supabase-docker"]="supabase/docker"
  ["android-docker"]="android"
)
declare -A DOCKER_MANIFEST_HASHES

for KEY in "${DOCKER_VARIANT_KEYS[@]}"; do
  DDIR="${SCRIPT_DIR}/${DOCKER_VARIANT_DIRS[${KEY}]}"
  DMANIFEST="${DDIR}/.fleet-manifest"
  for F in "${DOCKER_MANAGED_FILES[@]}"; do
    [[ -f "${DDIR}/${F}" ]] || { echo "[ERROR] ${DOCKER_VARIANT_DIRS[${KEY}]}/${F} not found." >&2; exit 1; }
  done
  {
    printf 'version=%s\n' "${VERSION}"
    printf '# sha256  basename — CODE files only; authoritative for the full managed set (docker variant)\n'
    printf '# CRITICAL: bootstrap.sh is the stable trust root and must NEVER appear here.\n'
    for F in "${DOCKER_MANAGED_FILES[@]}"; do
      HASH="$(_sha256_file "${DDIR}/${F}")"
      printf '%s  %s\n' "${HASH}" "${F}"
    done
  } > "${DMANIFEST}"
  DOCKER_MANIFEST_HASHES["${KEY}"]="$(_sha256_file "${DMANIFEST}")"
  echo "[INFO]  Wrote ${DOCKER_VARIANT_DIRS[${KEY}]}/.fleet-manifest (version=${VERSION})"
done

# ── Print operator output ──────────────────────────────────────────────────────
TAG="fleet-${VERSION}"

echo ""
echo "=== manifest sha256 map (set on broker as FLEET_MANIFEST_SHA256 per type) ==="
printf '{\n'
printf '  "light":           "%s",\n' "${MANIFEST_HASHES[light]}"
printf '  "supabase":        "%s",\n' "${MANIFEST_HASHES[supabase]}"
printf '  "ios":             "%s",\n' "${MANIFEST_HASHES[ios]}"
printf '  "light-docker":    "%s",\n' "${DOCKER_MANIFEST_HASHES[light-docker]}"
printf '  "supabase-docker": "%s",\n' "${DOCKER_MANIFEST_HASHES[supabase-docker]}"
printf '  "android-docker":  "%s"\n'  "${DOCKER_MANIFEST_HASHES[android-docker]}"
printf '}\n'
echo ""
echo "NOTE: 'playwright' runs light's code — set the broker 'playwright' key to the SAME hash as 'light'."
echo ""
echo "=== suggested git tag ==="
echo "  ${TAG}"
echo ""
echo "=== next steps ==="
echo "  1. git add light/.fleet-manifest supabase/.fleet-manifest ios/.fleet-manifest \\"
echo "         light/docker/.fleet-manifest supabase/docker/.fleet-manifest android/.fleet-manifest"
echo "  2. git commit -m 'release: fleet-code ${VERSION}'"
echo "  3. git push origin main"
echo "  4. Wait ~60s for raw.githubusercontent.com CDN propagation."
echo "  5. git tag ${TAG} && git push origin ${TAG}"
echo "  6. Set on broker: FLEET_DESIRED_REF=${TAG}"
echo "     FLEET_MANIFEST_SHA256=<type-specific hash from JSON above>"
