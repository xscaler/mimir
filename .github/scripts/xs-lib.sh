#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Shared helpers for the xs-* workflows. Source this file, do not execute it.
# Every downloaded tool is pinned by version and sha256.

XS_OIDC_ISSUER="https://token.actions.githubusercontent.com"

CRANE_VERSION="0.22.1"
CRANE_SHA256="0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0"
COSIGN_VERSION="3.1.4"
COSIGN_SHA256="424e2c97d0b45fd7a6b608a87f090f35633f4c23ece5f092d48bba11aaf4bbfa"
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
  local dir
  dir="$(_xs_bindir)"
  _xs_fetch "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-amd64" "${COSIGN_SHA256}" "${dir}/cosign"
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

# xs_digest REF: prints the manifest digest of REF.
# Return 0: present. Return 1: absent, which means the registry answered MANIFEST_UNKNOWN or
# NAME_UNKNOWN, or GHCR's documented answer for a package that does not exist yet (the pull token
# request is DENIED). Return 2: any other failure (network, auth, server error).
xs_digest() {
  local out rc
  set +e
  out="$(crane digest "$1" 2>&1)"
  rc=$?
  set -e
  if [ "${rc}" -eq 0 ]; then
    printf '%s\n' "${out}"
    return 0
  fi
  if printf '%s' "${out}" | grep -Eq 'MANIFEST_UNKNOWN|NAME_UNKNOWN|ghcr\.io/token\?scope=[^ ]*: DENIED'; then
    return 1
  fi
  printf '%s\n' "${out}" >&2
  return 2
}

# xs_ensure_signed REF IDENTITY [sign flags...]: REF is repo@digest, IDENTITY the exact certificate
# identity this run signs with. Verify first. Only "no signatures found" means unsigned: sign, then
# verify again. Every other failure, including a signature from a different identity, fails.
xs_ensure_signed() {
  local ref="$1" identity="$2" out rc
  shift 2
  set +e
  out="$(cosign verify --certificate-identity "${identity}" \
    --certificate-oidc-issuer "${XS_OIDC_ISSUER}" "${ref}" 2>&1)"
  rc=$?
  set -e
  if [ "${rc}" -eq 0 ]; then
    echo "already signed: ${ref}"
    return 0
  fi
  if ! printf '%s' "${out}" | grep -q 'no signatures found'; then
    printf '%s\n' "${out}" >&2
    echo "::error::cosign verify failed for ${ref}"
    return 1
  fi
  echo "no signature on ${ref}, signing"
  cosign sign --yes "$@" "${ref}"
  cosign verify --certificate-identity "${identity}" \
    --certificate-oidc-issuer "${XS_OIDC_ISSUER}" "${ref}" > /dev/null
  echo "signed and verified: ${ref}"
}
