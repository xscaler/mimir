#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# xs- helm render test: compare the chart in the working tree with the upstream release chart it was
# imported from and prove that only the engine image of the default configuration differs.
#
# Usage: xs-chart-image-test.sh <upstream-tag> [chart-dir]
# Needs helm on PATH. Run from the repository root.
set -euo pipefail

BASE_TAG="${1:?upstream chart tag, for example mimir-distributed-6.2.2}"
CHART_DIR="${2:-operations/helm/charts/mimir-distributed}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/xs-chart-test.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

# The upstream chart symlinks into the compiled mixin, so export both trees.
mkdir -p "${TMP}/base"
git archive "${BASE_TAG}" operations/helm operations/mimir-mixin-compiled operations/mimir-mixin-compiled-baremetal | tar -x -C "${TMP}/base"
BASE="${TMP}/base/${CHART_DIR}"

helm dependency build "${BASE}" > /dev/null 2>&1
helm dependency build "${CHART_DIR}" > /dev/null 2>&1

OUR_VERSION="$(sed -n 's/^version: *//p' "${CHART_DIR}/Chart.yaml" | head -n 1)"
BASE_VERSION="$(sed -n 's/^version: *//p' "${BASE}/Chart.yaml" | head -n 1)"
OUR_LABEL="mimir-distributed-${OUR_VERSION//+/_}"
BASE_LABEL="mimir-distributed-${BASE_VERSION//+/_}"
APP_VERSION="$(sed -n 's/^appVersion: *//p' "${CHART_DIR}/Chart.yaml" | head -n 1)"
[ "${APP_VERSION}" = "$(sed -n 's/^appVersion: *//p' "${BASE}/Chart.yaml" | head -n 1)" ] || { echo "appVersion differs from upstream"; exit 1; }

ENGINE_TAG="$(sed -n 's/^  engineTag: *//p' "${CHART_DIR}/values.yaml" | head -n 1)"
fail=0

# render DIR LABEL ARGS...: render with the chart version label normalised.
render() {
  local dir="$1" label="$2"
  shift 2
  # checksum/* annotations hash rendered objects that carry the chart version label, so they
  # change with the +xs.<n> chart version alone.
  helm template rel "${dir}" "$@" 2> /dev/null | sed "s/${label}/CHART_LABEL/g; s#\(checksum/[a-z-]*:\) .*#\1 X#"
}

# check NAME OUR_ARGS BASE_ARGS SED_EXPR: render both and require identical output after
# applying SED_EXPR to ours (empty means none).
check() {
  local name="$1" ours_args="$2" base_args="$3" norm="$4"
  # shellcheck disable=SC2086
  render "${CHART_DIR}" "${OUR_LABEL}" ${ours_args} > "${TMP}/ours.yaml"
  # shellcheck disable=SC2086
  render "${BASE}" "${BASE_LABEL}" ${base_args} > "${TMP}/base.yaml"
  if [ -n "${norm}" ]; then
    sed -i "${norm}" "${TMP}/ours.yaml"
  fi
  if diff -q "${TMP}/base.yaml" "${TMP}/ours.yaml" > /dev/null; then
    echo "ok   ${name}"
  else
    echo "FAIL ${name}"
    diff "${TMP}/base.yaml" "${TMP}/ours.yaml" | head -20
    fail=1
  fi
}

# 1. No overrides: only the engine image differs, and only by repository and tag.
check "default: only the engine image differs" "" "" \
  "s#ghcr.io/xscaler/mimir:${ENGINE_TAG}#docker.io/grafana/mimir:${APP_VERSION}#g"
# 2. Mirror of the xScaler engine repository keeps the mirror and gets the engine tag.
check "mirror of xscaler/mimir keeps the mirror and the engine tag" \
  "--set image.repository=mirror.example.com/xscaler/mimir" "--set image.repository=mirror.example.com/xscaler/mimir" \
  "s#mirror.example.com/xscaler/mimir:${ENGINE_TAG}#mirror.example.com/xscaler/mimir:${APP_VERSION}#g"
# 3. A repository-only override of another image keeps the upstream behaviour.
check "mirror of grafana/mimir is unchanged" \
  "--set image.repository=mirror.example.com/grafana/mimir" "--set image.repository=mirror.example.com/grafana/mimir" ""
check "enterprise repository only is unchanged" \
  "--set image.repository=grafana/enterprise-metrics" "--set image.repository=grafana/enterprise-metrics" ""
check "enterprise repository and tag is unchanged" \
  "--set image.repository=grafana/enterprise-metrics --set image.tag=v3.2.0" "--set image.repository=grafana/enterprise-metrics --set image.tag=v3.2.0" ""
# 4. An explicit tag always wins.
check "explicit global tag wins" "--set image.tag=custom" "--set image.tag=custom" \
  "s#ghcr.io/xscaler/mimir:custom#docker.io/grafana/mimir:custom#g"
# 5. Component level overrides win and the other components keep the engine image.
check "component repository and tag overrides" \
  "--set distributor.image.repository=reg.example.com/d --set distributor.image.tag=t1 --set ingester.image.tag=t2" \
  "--set distributor.image.repository=reg.example.com/d --set distributor.image.tag=t1 --set ingester.image.tag=t2" \
  "s#ghcr.io/xscaler/mimir:\(${ENGINE_TAG}\|t2\)#docker.io/grafana/mimir:\1#g; s#docker.io/grafana/mimir:${ENGINE_TAG}#docker.io/grafana/mimir:${APP_VERSION}#g"
# 6. Every other image and the app version label are untouched in the optional components.
check "optional components render the same" \
  "--set kafka.enabled=true --set gateway.enabledNonEnterprise=true --set metaMonitoring.grafanaAgent.enabled=true" \
  "--set kafka.enabled=true --set gateway.enabledNonEnterprise=true --set metaMonitoring.grafanaAgent.enabled=true" \
  "s#ghcr.io/xscaler/mimir:${ENGINE_TAG}#docker.io/grafana/mimir:${APP_VERSION}#g"

# The checks above compare the whole rendered output, so app.kubernetes.io/version and every other
# label are covered. Only the chart version label may differ, and it is normalised.
exit "${fail}"
