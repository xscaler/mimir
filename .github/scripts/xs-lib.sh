#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Shared helpers for the xs-* workflows. Source this file, do not execute it.
# Every downloaded tool is pinned by version and sha256. Only cosign has an arm64 variant: the
# arm runner only verifies.

XS_OIDC_ISSUER="https://token.actions.githubusercontent.com"

CRANE_VERSION="0.22.1"
CRANE_SHA256="0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0"
COSIGN_VERSION="3.1.4"
COSIGN_SHA256_AMD64="424e2c97d0b45fd7a6b608a87f090f35633f4c23ece5f092d48bba11aaf4bbfa"
COSIGN_SHA256_ARM64="ade83b7aac62e131cacfe96d958948b2150cc9efec46a570a2649b8e27dedad2"
SYFT_VERSION="1.55.0"
SYFT_SHA256="bb65249542db5fedeeb4d3f9b018b75e7264dbfbbb10486f044581a92f90490d"
TRIVY_VERSION="0.76.1"
TRIVY_SHA256="c7cbe3137fb8a48a17574bede3dd6beb16742d1e9772929940fc90082c39d9c0"
HELM_VERSION="4.2.3"
HELM_SHA256="e9b88b4ee95b18c706839c28d3a0220e5bc470e9cd9262410c90793c45ff8b7c"

# _xs_fetch URL SHA256 DEST: download and verify a file.
_xs_fetch() {
  curl -fsSL --retry 3 -o "$3" "$1"
  echo "$2  $3" | sha256sum -c - > /dev/null
}

# _xs_bindir: directory for installed tools, added to PATH for later steps too.
_xs_bindir() {
  local dir="${RUNNER_TEMP:?}/xs-bin"
  mkdir -p "${dir}"
  case ":${PATH}:" in
    *":${dir}:"*) ;;
    *)
      echo "${dir}" >> "${GITHUB_PATH:?}"
      export PATH="${dir}:${PATH}"
      ;;
  esac
  printf '%s' "${dir}"
}

xs_install_crane() {
  local dir tgz
  dir="$(_xs_bindir)"
  tgz="${dir}/crane.tgz"
  _xs_fetch "https://github.com/google/go-containerregistry/releases/download/v${CRANE_VERSION}/go-containerregistry_Linux_x86_64.tar.gz" "${CRANE_SHA256}" "${tgz}"
  tar -xzf "${tgz}" -C "${dir}" crane
  rm -f "${tgz}"
}

xs_install_cosign() {
  local dir arch sha
  dir="$(_xs_bindir)"
  case "$(uname -m)" in
    x86_64) arch=amd64; sha="${COSIGN_SHA256_AMD64}" ;;
    aarch64) arch=arm64; sha="${COSIGN_SHA256_ARM64}" ;;
    *) echo "unsupported architecture $(uname -m)" >&2; return 1 ;;
  esac
  _xs_fetch "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-${arch}" "${sha}" "${dir}/cosign"
  chmod +x "${dir}/cosign"
}

xs_install_syft() {
  local dir tgz
  dir="$(_xs_bindir)"
  tgz="${dir}/syft.tgz"
  _xs_fetch "https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/syft_${SYFT_VERSION}_linux_amd64.tar.gz" "${SYFT_SHA256}" "${tgz}"
  tar -xzf "${tgz}" -C "${dir}" syft
  rm -f "${tgz}"
}

xs_install_trivy() {
  local dir tgz
  dir="$(_xs_bindir)"
  tgz="${dir}/trivy.tgz"
  _xs_fetch "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" "${TRIVY_SHA256}" "${tgz}"
  tar -xzf "${tgz}" -C "${dir}" trivy
  rm -f "${tgz}"
}

xs_install_helm() {
  local dir tgz
  dir="$(_xs_bindir)"
  tgz="${dir}/helm.tgz"
  _xs_fetch "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" "${HELM_SHA256}" "${tgz}"
  tar -xzf "${tgz}" -C "${dir}" --strip-components=1 linux-amd64/helm
  rm -f "${tgz}"
}

# xs_package_exists NAME: NAME is the container package name, for example mimir or
# rehearsal/mimir. Asks the GitHub Packages API, which needs GH_TOKEN. Return 0: exists. Return 1:
# the API answered 404, so the package does not exist yet and no tag can exist either. Return 2:
# any other failure.
xs_package_exists() {
  local name="${1//\//%2F}" out rc
  set +e
  out="$(gh api "orgs/xscaler/packages/container/${name}" 2>&1)"
  rc=$?
  set -e
  if [ "${rc}" -eq 0 ]; then
    return 0
  fi
  if printf '%s' "${out}" | grep -q 'HTTP 404'; then
    return 1
  fi
  printf '%s\n' "${out}" >&2
  return 2
}

# xs_digest REF: prints the manifest digest of REF (crane, honouring XS_CRANE_FLAGS).
# Return 0: present. Return 1: absent, which means the registry answered MANIFEST_UNKNOWN or
# NAME_UNKNOWN. Return 2: any other failure (network, auth, server error). Call xs_package_exists
# first for GHCR, which does not answer NAME_UNKNOWN for a package that does not exist yet.
xs_digest() {
  local out rc
  set +e
  # shellcheck disable=SC2086
  out="$(crane digest ${XS_CRANE_FLAGS:-} "$1" 2>&1)"
  rc=$?
  set -e
  if [ "${rc}" -eq 0 ]; then
    printf '%s\n' "${out}"
    return 0
  fi
  if printf '%s' "${out}" | grep -Eq 'MANIFEST_UNKNOWN|NAME_UNKNOWN'; then
    return 1
  fi
  printf '%s\n' "${out}" >&2
  return 2
}

# xs_tag_digest PACKAGE REF: like xs_digest, but checks the package first. A package that does not
# exist yet means the tag is absent.
xs_tag_digest() {
  local rc=0
  xs_package_exists "$1" || rc=$?
  case "${rc}" in
    0) xs_digest "$2" ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# xs_sign REF IDENTITY [sign flags...]: sign an artifact this run built, then verify the signature
# with the exact identity. Never call this for a digest that was found in the registry.
xs_sign() {
  local ref="$1" identity="$2"
  shift 2
  cosign sign --yes "$@" "${ref}"
  cosign verify --certificate-identity "${identity}" \
    --certificate-oidc-issuer "${XS_OIDC_ISSUER}" "${ref}" > /dev/null
  echo "signed and verified: ${ref}"
}

# xs_verify_trusted REPO DIGEST IDENTITY COMMIT [attest-repo]: decide whether an image found in the
# registry may be reused. It must carry the requested commit in its revision label, a valid cosign
# signature from the exact IDENTITY, and a valid provenance attestation from that identity. Only
# verifies: it never signs or attests. Prints "exists without trusted provenance" and returns 1
# otherwise.
xs_verify_trusted() {
  local repo="$1" digest="$2" identity="$3" commit="$4" amd64 revision
  _xs_untrusted() {
    echo "::error::tag exists without trusted provenance (${1}): investigate, then bump -xs.n"
    return 1
  }
  # shellcheck disable=SC2086
  amd64="$(crane manifest ${XS_CRANE_FLAGS:-} "${repo}@${digest}" | jq -r '.manifests[] | select(.platform.architecture=="amd64") | .digest')" ||
    { _xs_untrusted "cannot read the manifest"; return 1; }
  # shellcheck disable=SC2086
  revision="$(crane config ${XS_CRANE_FLAGS:-} "${repo}@${amd64}" | jq -r '.config.Labels["org.opencontainers.image.revision"]')" ||
    { _xs_untrusted "cannot read the image config"; return 1; }
  if [ "${revision}" != "${commit}" ]; then
    _xs_untrusted "revision label ${revision} is not ${commit}"
    return 1
  fi
  cosign verify --certificate-identity "${identity}" --certificate-oidc-issuer "${XS_OIDC_ISSUER}" \
    "${repo}@${digest}" > /dev/null 2>&1 || { _xs_untrusted "no valid signature from ${identity}"; return 1; }
  gh attestation verify "oci://${repo}@${digest}" --repo xscaler/mimir --cert-identity "${identity}" \
    > /dev/null 2>&1 || { _xs_untrusted "no valid provenance attestation from ${identity}"; return 1; }
}
