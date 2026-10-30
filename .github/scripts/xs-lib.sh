#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Shared helpers for the xs-* publish jobs. Source this file, do not execute it.
# Needs crane and cosign on PATH for the functions that use them.

CRANE_VERSION="0.22.1"
CRANE_SHA256="0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0"
XS_OIDC_ISSUER="https://token.actions.githubusercontent.com"
# Signatures made by our own workflows, from main or from a release tag.
XS_IDENTITY_REGEXP='^https://github\.com/xscaler/mimir/\.github/workflows/xs-(release|charts)\.yml@refs/(heads/main|tags/v[0-9]+\.[0-9]+\.[0-9]+-xs\.[0-9]+)$'

xs_install_crane() {
  local dir="${RUNNER_TEMP:?}/crane"
  mkdir -p "${dir}"
  curl -fsSL -o "${dir}/crane.tgz" \
    "https://github.com/google/go-containerregistry/releases/download/v${CRANE_VERSION}/go-containerregistry_Linux_x86_64.tar.gz"
  echo "${CRANE_SHA256}  ${dir}/crane.tgz" | sha256sum -c -
  tar -xzf "${dir}/crane.tgz" -C "${dir}" crane
  echo "${dir}" >> "${GITHUB_PATH:?}"
  export PATH="${dir}:${PATH}"
}

# xs_digest REF: prints the manifest digest of REF.
# Return 0: present. Return 1: not there yet (404, manifest/name unknown, or
# denied for a package that does not exist yet; call only after a successful
# login). Return 2: any other failure (network, auth, server error).
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
  if printf '%s' "${out}" | grep -Eqi 'MANIFEST_UNKNOWN|NAME_UNKNOWN|manifest unknown|name unknown|not found|404|DENIED|denied|RepositoryNotFound'; then
    return 1
  fi
  printf '%s\n' "${out}" >&2
  return 2
}

# xs_ensure_signed REPO DIGEST: verify the signature on REPO@DIGEST, sign it
# when it has none, then verify again. Auth or network errors fail the step
# instead of being treated as "unsigned".
xs_ensure_signed() {
  local ref="$1@$2" out rc
  set +e
  out="$(cosign verify --certificate-identity-regexp "${XS_IDENTITY_REGEXP}" \
    --certificate-oidc-issuer "${XS_OIDC_ISSUER}" "${ref}" 2>&1)"
  rc=$?
  set -e
  if [ "${rc}" -eq 0 ]; then
    echo "already signed: ${ref}"
    return 0
  fi
  if ! printf '%s' "${out}" | grep -Eq 'no signatures found|no matching signatures'; then
    printf '%s\n' "${out}" >&2
    echo "::error::cosign verify failed for ${ref} for a reason other than a missing signature"
    return 1
  fi
  echo "no signature on ${ref}, signing"
  cosign sign --yes "${ref}"
  cosign verify --certificate-identity-regexp "${XS_IDENTITY_REGEXP}" \
    --certificate-oidc-issuer "${XS_OIDC_ISSUER}" "${ref}" > /dev/null
  echo "signed and verified: ${ref}"
}
