#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Push the per-platform OCI archives by digest and create the multi-arch index.
# Used by xs-release.yml for the real publish and for the pull request dry run against a local
# registry, so the same code path is exercised before a release.
#
# Usage: xs-push-index.sh <repo> <tag> <dir containing mimir-amd64.tar and mimir-arm64.tar>
# Env: XS_CRANE_FLAGS (for example --insecure for a local registry), GITHUB_OUTPUT.
# Writes digest, amd64_digest and arm64_digest to GITHUB_OUTPUT.
set -euo pipefail

REPO="${1:?repo}"
TAG="${2:?tag}"
DIR="${3:?directory with the OCI archives}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=xs-lib.sh
. "${SCRIPT_DIR}/xs-lib.sh"

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/xs-push.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

declare -A digests
for arch in amd64 arm64; do
  mkdir "${work}/layout-${arch}"
  tar -xf "${DIR}/mimir-${arch}.tar" -C "${work}/layout-${arch}"
  d="$(jq -r '.manifests[0].digest' "${work}/layout-${arch}/index.json")"
  # Push by digest: no per-arch tags.
  # shellcheck disable=SC2086
  crane push ${XS_CRANE_FLAGS:-} "${work}/layout-${arch}" "${REPO}@${d}"
  got="$(xs_digest "${REPO}@${d}")"
  [ "${got}" = "${d}" ]
  digests[${arch}]="${d}"
done

# Right before creating the index the tag must still be absent.
rc=0
xs_digest "${REPO}:${TAG}" > /dev/null || rc=$?
if [ "${rc}" -ne 1 ]; then
  echo "::error::${REPO}:${TAG} appeared while publishing, refusing to overwrite it"
  exit 1
fi
docker buildx imagetools create --metadata-file "${work}/index-metadata.json" \
  -t "${REPO}:${TAG}" "${REPO}@${digests[amd64]}" "${REPO}@${digests[arm64]}"
index="$(jq -r '.["containerimage.descriptor"].digest' "${work}/index-metadata.json")"
[[ "${index}" =~ ^sha256:[0-9a-f]{64}$ ]]

# Platform digests come from the index itself.
# shellcheck disable=SC2086
manifest="$(crane manifest ${XS_CRANE_FLAGS:-} "${REPO}@${index}")"
amd64="$(jq -r '.manifests[] | select(.platform.architecture=="amd64") | .digest' <<< "${manifest}")"
arm64="$(jq -r '.manifests[] | select(.platform.architecture=="arm64") | .digest' <<< "${manifest}")"
[ "${amd64}" = "${digests[amd64]}" ] && [ "${arm64}" = "${digests[arm64]}" ]
{
  echo "digest=${index}"
  echo "amd64_digest=${amd64}"
  echo "arm64_digest=${arm64}"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"
