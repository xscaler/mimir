#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# shellcheck disable=SC2310,SC2249 # helpers run in if/|| on purpose and case statements without a default are intended
# xScaler fork: upstream sync logic, shared by xs-sync.yml and xs-sync-check.yml.
#
# The fork's main is "upstream release tag + our patch set". For each new
# upstream stable release this script mirrors upstream refs, builds a merge
# commit (tree = new tag with our patch applied, parents = main and the new tag)
# and opens a PR from sync/<tag> into main.
#
# Porting to another fork: copy this file and change only the parameter blocks
# below (the chart layer is off when XS_CHART_PATHS is empty). Every parameter
# can be overridden from the environment, which the unit tests use.
#
# Subcommands:
#   mirror [--dry-run]            push upstream branches and tags to origin
#   select <current-tag> [head..] pick the sync target from tags on stdin (pure)
#   detect [--base REF] [--open-heads FILE] [--cap TAG]
#                                 find current and latest upstream tags, decide
#   build --current T --latest T --base-commit SHA --base-tree SHA
#         [--branch B] [--no-pr] [--issue-title T --issue-label L]
#         [--goldens-out DIR | --goldens DIR]   chart layer: regenerate the golden
#                                 records with no token into DIR, or take them from DIR
#                                 apply the patch set to the new tag, commit, PR
#   sync-run --current T --latest T --proceed B --open-pr B --chart-proceed B --chart-open-pr B --chart-tag T
#         --base-commit SHA --base-tree SHA [--goldens-out DIR | --goldens DIR]
#                                 the one build of a daily run, from the detect outputs
#   closed-skip <sync/head>       output skip=true when the head has a closed, unmerged PR
#   supersede <target-tag> <sync/head>...   close stale sync PRs and issues
#   open-heads <out-file>         write head branches of our own open PRs
#   disable-upstream-workflows    disable active workflows that are not ours
#   rehearse clean|conflict|merge|chart-merge|chart-conflict [--goldens-out D | --goldens D]
#                                 run detect+build against an artificial base
#   check identity|parents|version <tag> [HEAD]   PR checks for sync/<tag>
#   flagdiff <old-dir> <new-dir> <out.md>         binary flag set diff
#   flagreport <old-bin> <new-bin> <out.md>       the same for built binaries
#   body-fill <body-file> <fill-file>             fill the flag diff placeholder
#   issue-failed <run-url>        open or update the "sync: failed" issue
#
# Credentials: GH_TOKEN (GitHub App token, jobs that write), GITHUB_REPOSITORY.
# The build and rehearse commands never run `git push`: they write through the
# git data API, so the merge commit is signed by GitHub (Verified) and the
# job holds no persisted git credentials.

# The sed programs below wrap text in markdown backticks on purpose.
# shellcheck disable=SC2016
set -euo pipefail
shopt -s inherit_errexit

# ---------------------------------------------------------------------------
# Parameter block: the only part that changes between repos.
# ---------------------------------------------------------------------------
# Upstream repository (owner/name) and the URL git fetches from.
XS_UPSTREAM_REPO="${XS_UPSTREAM_REPO:-grafana/mimir}"
XS_UPSTREAM_URL="${XS_UPSTREAM_URL:-https://github.com/${XS_UPSTREAM_REPO}.git}"
# Stable release tags: ERE with exactly three groups (major, minor, patch).
# Pre-releases (rc, beta) and tags of other products must not match.
XS_TAG_REGEX="${XS_TAG_REGEX:-^mimir-([0-9]+)\\.([0-9]+)\\.([0-9]+)\$}"
# Tag name for a version X.Y.Z ("%s" is replaced by X.Y.Z).
XS_TAG_FORMAT="${XS_TAG_FORMAT:-mimir-%s}"
# Upstream branches to mirror as origin/upstream/<name>.
XS_BRANCH_REGEX="${XS_BRANCH_REGEX:-^(main|release-[0-9]+(\\.[0-9]+)*(\\.x)?)\$}"
# Paths that may differ from the upstream release tag (our patch set), as
# shell globs matched against the full path ("*" also matches "/").
XS_PATCH_PATHS=(
  ".github/workflows/xs-*"
  ".github/scripts/xs-*"
)
# The namespace upstream must never own: paths that only this fork may carry.
# Shell globs like XS_PATCH_PATHS, but workflows, scripts and actions only (not
# chart paths). A path here must be identical in main and in a sync result, and
# absent from every upstream tree.
XS_NS_PATHS=(
  ".github/workflows/xs-*"
  ".github/scripts/xs-*"
)
# Binary for the flag diff. Empty XS_BINARY_PKG skips it (charts, libraries).
XS_BINARY_PKG="${XS_BINARY_PKG:-./cmd/mimir}"
XS_BINARY_NAME="${XS_BINARY_NAME:-mimir}"
# Help flags to compare, in order. Loki prints every flag with -help; mimir and
# tempo add -help-all.
XS_HELP_FLAGS="${XS_HELP_FLAGS:--help -help-all}"
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Chart layer (empty XS_CHART_PATHS disables it: loki, tempo, charts, libraries).
# Chart paths are not carried as a diff against the engine tag. They are the tree
# of the newest chart release whose appVersion is the new engine version, plus our
# chart patch (the diff from the current chart tag to main).
# ---------------------------------------------------------------------------
XS_CHART_PATHS=(
  "operations/helm"
  "operations/mimir-mixin-compiled"
  "operations/mimir-mixin-compiled-baremetal"
  "docs/sources/helm-charts"
)
# Chart release tags: ERE with exactly three groups, and the tag name format.
XS_CHART_TAG_REGEX="${XS_CHART_TAG_REGEX:-^mimir-distributed-([0-9]+)\\.([0-9]+)\\.([0-9]+)\$}"
XS_CHART_TAG_FORMAT="${XS_CHART_TAG_FORMAT:-mimir-distributed-%s}"
# Chart.yaml (version <chart>+xs.<n>, appVersion = engine version) and the values
# file holding xscaler.engineTag.
XS_CHART_FILE="${XS_CHART_FILE:-operations/helm/charts/mimir-distributed/Chart.yaml}"
XS_CHART_README="${XS_CHART_README:-operations/helm/charts/mimir-distributed/README.md}"
XS_CHART_VALUES="${XS_CHART_VALUES:-operations/helm/charts/mimir-distributed/values.yaml}"
# Chart paths that may differ from the chart tag (our chart patch), same glob rules
# as XS_PATCH_PATHS.
XS_CHART_PATCH_PATHS=(
  "operations/helm/charts/mimir-distributed/Chart.yaml"
  "operations/helm/charts/mimir-distributed/README.md"
  "operations/helm/charts/mimir-distributed/values.yaml"
  "operations/helm/charts/mimir-distributed/templates/_helpers.tpl"
  "operations/helm/tests/*-generated/*"
)
# Derived from the chart and regenerated, never patched: the version files above
# (bumped in place) and the golden records (rebuilt by the upstream script).
XS_CHART_BUMP_FILES=("${XS_CHART_FILE}" "${XS_CHART_README}")
XS_CHART_DERIVED_PATHS=("operations/helm/tests")
# The upstream build image pins the Helm that builds the golden records upstream; the file
# and the sed expression that print its version (compared with the Helm we regenerate with).
XS_CHART_BUILD_IMAGE_FILE="${XS_CHART_BUILD_IMAGE_FILE:-mimir-build-image/Dockerfile}"
XS_CHART_BUILD_IMAGE_HELM_SED="${XS_CHART_BUILD_IMAGE_HELM_SED:-s#^FROM alpine/helm:([0-9][0-9.]*)[@ ].*#\\1#p}"
# Paths materialised for the regeneration (the chart links its mixins from the
# compiled mixin directories), and the command run in that directory.
XS_CHART_REGEN_INPUT=("operations/helm" "operations/mimir-mixin-compiled" "operations/mimir-mixin-compiled-baremetal")
XS_CHART_REGEN_CMD="${XS_CHART_REGEN_CMD:-helm repo add minio https://charts.min.io/ --force-update > /dev/null && helm repo add grafana https://grafana.github.io/helm-charts --force-update > /dev/null && helm dependency build operations/helm/charts/mimir-distributed && operations/helm/scripts/build.sh --intermediate-path operations/helm/manifests-intermediate --output-path operations/helm/tests}"
# ---------------------------------------------------------------------------

# Pathspecs that leave the chart paths out: the engine layer is everything else.
XS_CHART_EXCLUDES=()
for _p in "${XS_CHART_PATHS[@]}"; do XS_CHART_EXCLUDES+=(":(exclude)${_p}"); done
unset _p

# Identity of the commits the sync bot makes through the git data API: the App is the
# author, GitHub signs and is the committer. A branch tip with any other author or
# committer, or no valid signature, is treated as a human's.
XS_BOT_LOGIN="${XS_BOT_LOGIN:-xscaler-gremlin[bot]}"
XS_BOT_EMAIL="${XS_BOT_EMAIL:-351432774+xscaler-gremlin[bot]@users.noreply.github.com}"

# Who opens the issues the bot looks up by title. gh --author slugs: the App for
# sync issues, the Actions bot for the failure issue (its job holds GITHUB_TOKEN).
# Outsiders can open issues on a public repo; a title match alone is not trusted.
XS_ISSUE_AUTHOR="${XS_ISSUE_AUTHOR:-app/xscaler-gremlin}"
XS_ISSUE_AUTHOR_ACTIONS="${XS_ISSUE_AUTHOR_ACTIONS:-app/github-actions}"

XS_MAIN_BRANCH="${XS_MAIN_BRANCH:-main}"
XS_UPSTREAM_REMOTE="xs-upstream"
XS_FLAG_BEGIN="<!-- xs-sync:flag-diff:begin -->"
XS_FLAG_END="<!-- xs-sync:flag-diff:end -->"

log() { echo "$*" >&2; }
die() {
  echo "::error::$*" >&2
  exit 1
}

# out <key> <value>: print key=value and append it to GITHUB_OUTPUT.
out() {
  [[ "$2" != *$'\n'* ]] || die "output ${1} contains a newline"
  printf '%s=%s\n' "$1" "$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT}"; fi
}

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf '%s\n' "$*" >> "${GITHUB_STEP_SUMMARY}"; fi
}

# ---------------------------------------------------------------------------
# Version and tag selection (pure, unit tested)
# ---------------------------------------------------------------------------

# xs_version_of <tag>: print X.Y.Z when the tag is a stable release tag.
xs_version_of() {
  local t="$1"
  [[ "${t}" != *$'\n'* ]] || return 1
  # shellcheck disable=SC2154 # XS_TAG_REGEX is an ERE on purpose
  [[ "${t}" =~ ${XS_TAG_REGEX} ]] || return 1
  printf '%s.%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

# xs_tag_of <X.Y.Z>: print the tag name for a version.
xs_tag_of() { printf '%s\n' "${XS_TAG_FORMAT//%s/$1}"; }

# xs_sorted_stable: tags on stdin -> "<version> <tag>" lines, stable only,
# ascending by version.
xs_sorted_stable() {
  local t v
  while IFS= read -r t; do
    v="$(xs_version_of "${t}")" || continue
    printf '%s %s\n' "${v}" "${t}"
  done | LC_ALL=C sort -t. -k1,1n -k2,2n -k3,3n -u
}

# xs_highest_stable: tags on stdin -> the highest stable tag (empty if none).
xs_highest_stable() {
  xs_sorted_stable | awk 'END { print $2 }'
}

# xs_ver_gt <a> <b>: true when version a is higher than b.
xs_ver_gt() {
  [[ "$1" != "$2" ]] || return 1
  [[ "$(printf '%s\n%s\n' "$1" "$2" | LC_ALL=C sort -t. -k1,1n -k2,2n -k3,3n | tail -n1)" == "$1" ]]
}

# xs_select <current-tag> [open-pr-head...]
# stdin: every upstream tag. XS_CAP_TAG (optional) ignores tags above it.
# Prints key=value lines: current, latest, proceed, open_pr (a sync PR for latest
# is open, so it may need a refresh), reason, head, supersede.
xs_select() {
  local current="$1"
  shift
  local cur_v latest latest_v cap_v="" t v head="" reason proceed=false h supersede=""
  cur_v="$(xs_version_of "${current}")" || die "current tag ${current} is not a stable release tag"
  if [[ -n "${XS_CAP_TAG:-}" ]]; then cap_v="$(xs_version_of "${XS_CAP_TAG}")" || die "cap tag ${XS_CAP_TAG} is not a stable release tag"; fi
  latest=""
  while IFS= read -r t; do
    v="$(xs_version_of "${t}")" || continue
    if [[ -n "${cap_v}" ]] && xs_ver_gt "${v}" "${cap_v}"; then continue; fi
    latest="${t}"
  done < <(xs_sorted_stable | awk '{ print $2 }')
  [[ -n "${latest}" ]] || die "no stable upstream tag found"
  latest_v="$(xs_version_of "${latest}")"
  head="sync/${latest}"
  if ! xs_ver_gt "${latest_v}" "${cur_v}"; then
    reason="main is at ${current}, newest upstream release is ${latest}"
  else
    reason="new upstream release ${latest} (main is at ${current})"
    proceed=true
  fi
  local open_pr=false hv
  for h in "$@"; do
    # Only heads the bot would have made: sync/<tag in the repo's tag format>. Any
    # other sync/* name is a human branch and is never touched.
    [[ "${h}" == sync/* ]] || continue
    hv="$(xs_version_of "${h#sync/}")" || continue
    if [[ "${h}" == "${head}" ]]; then
      if [[ "${proceed}" == true ]]; then
        proceed=false
        open_pr=true
        reason="a sync PR from ${head} is already open"
      fi
    elif xs_ver_gt "${latest_v}" "${hv}"; then
      supersede+="${supersede:+ }${h}"
    fi
  done
  printf 'current=%s\nlatest=%s\nproceed=%s\nopen_pr=%s\nreason=%s\nhead=%s\nsupersede=%s\n' \
    "${current}" "${latest}" "${proceed}" "${open_pr}" "${reason}" "${head}" "${supersede}"
}

# xs_path_allowed <path>: true when the path matches a patch path rule.
xs_path_allowed() {
  local p="$1" rule
  for rule in "${XS_PATCH_PATHS[@]}"; do
    # shellcheck disable=SC2254 # the rule is a glob on purpose
    case "${p}" in ${rule}) return 0 ;; esac
  done
  return 1
}

# xs_chart_path_allowed <path>: true when the path matches a chart patch rule.
xs_chart_path_allowed() {
  local p="$1" rule
  for rule in "${XS_CHART_PATCH_PATHS[@]}"; do
    # shellcheck disable=SC2254 # the rule is a glob on purpose
    case "${p}" in ${rule}) return 0 ;; esac
  done
  return 1
}

# xs_chart_version_of <tag>: print X.Y.Z when the tag is a chart release tag.
xs_chart_version_of() {
  local t="$1"
  [[ "${t}" != *$'\n'* ]] || return 1
  # shellcheck disable=SC2154 # XS_CHART_TAG_REGEX is an ERE on purpose
  [[ "${t}" =~ ${XS_CHART_TAG_REGEX} ]] || return 1
  printf '%s.%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

# xs_chart_tag_of <X.Y.Z>: print the chart tag name for a chart version.
xs_chart_tag_of() { printf '%s\n' "${XS_CHART_TAG_FORMAT//%s/$1}"; }

# xs_chart_pick <engine-version>: stdin is "<chart-tag> <appVersion>" lines. Prints
# the chart tag with the highest chart version whose appVersion is the engine
# version (empty when there is none). Tags that are not stable chart tags are ignored.
xs_chart_pick() {
  local want="$1" t app v
  while read -r t app; do
    [[ "${app}" == "${want}" ]] || continue
    v="$(xs_chart_version_of "${t}")" || continue
    printf '%s %s\n' "${v}" "${t}"
  done | LC_ALL=C sort -t. -k1,1n -k2,2n -k3,3n -u | awk 'END { print $2 }'
}

# xs_chart_current <Chart.yaml on stdin>: print the chart tag the file is based on
# (version X.Y.Z+xs.N -> the tag of X.Y.Z). Fails for any other version.
xs_chart_current() {
  local v
  v="$(sed -n -E 's/^version: *"?([0-9]+\.[0-9]+\.[0-9]+)\+xs\.[0-9]+"?[[:space:]]*$/\1/p' | head -n1)"
  [[ -n "${v}" ]] || return 1
  xs_chart_tag_of "${v}"
}

# xs_chart_app_version <Chart.yaml on stdin>: print appVersion.
xs_chart_app_version() {
  sed -n -E 's/^appVersion: *"?([0-9]+\.[0-9]+\.[0-9]+)"?[[:space:]]*$/\1/p' | head -n1
}

# xs_bump_sed <chart-version> <engine-version> <file-kind>: print the sed script
# that turns the upstream version strings into ours. kind: chart | readme | values.
xs_bump_sed() {
  local cv="${1//./\\.}" ev="$2" kind="$3"
  case "${kind}" in
    chart) printf 's/^version: %s$/version: %s+xs.0/\n' "${cv}" "$1" ;;
    readme)
      printf 's/(version which is )%s\\./\\1%s+xs.0./\n' "${cv}" "$1"
      printf 's/(Version: )%s\\]/\\1%s+xs.0]/\n' "${cv}" "$1"
      printf 's/(Version-)%s(-informational)/\\1%s+xs.0\\2/\n' "${cv}" "$1"
      ;;
    values) printf 's/^(  engineTag: ).*$/\\1%s-xs.0/\n' "${ev}" ;;
    *) return 1 ;;
  esac
}

# xs_chart_catchup <engine-version> <chart-current-tag> [open-pr-head...]
# stdin: "<chart-tag> <appVersion>" lines. Chart-only sync: main's engine version has a
# chart release newer than the chart main carries. Prints chart_latest, chart_proceed,
# chart_open_pr (a PR for it is open, so it may need a refresh), chart_head and
# chart_supersede (open heads of older chart releases; only heads named
# sync/<chart tag> are considered).
xs_chart_catchup() {
  local engv="$1" cur="$2" latest cur_v latest_v="" proceed=false open=false head="" supersede="" h hv
  shift 2
  cur_v="$(xs_chart_version_of "${cur}")" || die "current chart tag ${cur} is not a chart release tag"
  latest="$(xs_chart_pick "${engv}")"
  if [[ -n "${latest}" ]]; then
    latest_v="$(xs_chart_version_of "${latest}")"
    head="sync/${latest}"
    if xs_ver_gt "${latest_v}" "${cur_v}"; then proceed=true; else latest=""; head=""; latest_v=""; fi
  fi
  for h in "$@"; do
    [[ "${h}" == sync/* ]] || continue
    hv="$(xs_chart_version_of "${h#sync/}")" || continue
    if [[ -n "${head}" && "${h}" == "${head}" ]]; then
      proceed=false
      open=true
    elif [[ -n "${latest}" ]]; then
      if xs_ver_gt "${latest_v}" "${hv}"; then supersede+="${supersede:+ }${h}"; fi
    elif ! xs_ver_gt "${hv}" "${cur_v}"; then
      supersede+="${supersede:+ }${h}"
    fi
  done
  printf 'chart_latest=%s\nchart_proceed=%s\nchart_open_pr=%s\nchart_head=%s\nchart_supersede=%s\n' "${latest}" "${proceed}" "${open}" "${head}" "${supersede}"
}

# xs_chart_prev <chart-tag>: stdin is every tag. Prints the highest stable chart
# tag below <chart-tag>.
xs_chart_prev() {
  local tv v t
  tv="$(xs_chart_version_of "$1")" || die "$1 is not a chart release tag"
  while IFS= read -r t; do
    v="$(xs_chart_version_of "${t}")" || continue
    xs_ver_gt "${tv}" "${v}" || continue
    printf '%s %s\n' "${v}" "${t}"
  done | LC_ALL=C sort -t. -k1,1n -k2,2n -k3,3n -u | awk 'END { print $2 }'
}

# xs_ns_path <path>: true when the path is in the xs namespace.
xs_ns_path() {
  local p="$1" rule
  for rule in "${XS_NS_PATHS[@]}"; do
    # shellcheck disable=SC2254 # the rule is a glob on purpose
    case "${p}" in ${rule}) return 0 ;; *) ;; esac
  done
  return 1
}

# xs_ns_paths <commit-ish>: NUL separated xs namespace paths in its tree. Fails when
# git cannot read the tree, so a git error never reads as "no such paths".
xs_ns_paths() {
  local list p
  list="$(mktemp)"
  if ! git ls-tree -r --name-only -z "$1" -- .github > "${list}"; then
    rm -f "${list}"
    return 1
  fi
  while IFS= read -r -d '' p; do
    if xs_ns_path "${p}"; then printf '%s\0' "${p}"; fi
  done < "${list}"
  rm -f "${list}"
}

# xs_ns_violations <upstream-commit> [<base-tree> <result-tree>]: one line per
# problem, nothing when clean. Upstream must not carry any path in the xs
# namespace; with the trees, the namespace must also be byte-identical between
# main and the sync result. Paths are shown with control characters replaced.
xs_ns_violations() {
  local up="$1" base="${2:-}" result="${3:-}" p list
  list="$(mktemp)"
  xs_ns_paths "${up}" > "${list}" || { rm -f "${list}"; return 1; }
  while IFS= read -r -d '' p; do
    printf 'upstream %s contains %s\n' "${up}" "${p//[[:cntrl:]]/?}"
  done < "${list}"
  if [[ -n "${base}" && -n "${result}" ]]; then
    git diff --no-renames --name-only -z "${base}" "${result}" -- .github > "${list}" || { rm -f "${list}"; return 1; }
    while IFS= read -r -d '' p; do
      if xs_ns_path "${p}"; then printf 'result differs from main at %s\n' "${p//[[:cntrl:]]/?}"; fi
    done < "${list}"
  fi
  rm -f "${list}"
}

# xs_neutralize: stdin -> stdout with @ followed by a zero width space (no
# mentions), < and > replaced by single angle quotes (no HTML) and backtick runs
# replaced by one apostrophe (no fence breaking). Use for upstream text that ends
# up in a PR body or an issue; also put it inside a fenced block.
xs_neutralize() {
  sed -e 's/@/@\xe2\x80\x8b/g' -e 's/</\xe2\x80\xb9/g' -e 's/>/\xe2\x80\xba/g' -e "s/\`\\+/'/g"
}

# xs_pr_state: stdin is `gh pr list --state all --json number,state,isCrossRepository`.
# Prints "open N", "merged N", "closed N" (closed without merge) or "none", looking
# at PRs from this repository only, in that order of precedence.
xs_pr_state() {
  jq -r '[.[] | select(.isCrossRepository == false)] as $p
    | ($p | map(select(.state == "OPEN")) | first) as $o
    | ($p | map(select(.state == "MERGED")) | first) as $m
    | ($p | map(select(.state == "CLOSED")) | first) as $c
    | if $o then "open \($o.number)" elif $m then "merged \($m.number)" elif $c then "closed \($c.number)" else "none" end'
}

# xs_workflows_to_disable: stdin is "id<TAB>path<TAB>state" lines (the Actions
# API). Prints "id<TAB>path" for every active workflow under .github/workflows/
# that is not ours. A workflow is ours when it is named xs-*.yml and none of the
# refs in XS_UPSTREAM_REFS (space separated: upstream main and the base tag)
# contains that path; an upstream file in our namespace stays disabled. Dynamic
# workflows (no such path) are left alone.
xs_workflows_to_disable() {
  local id path state ref theirs
  while IFS=$'\t' read -r id path state; do
    [[ "${state}" == active ]] || continue
    [[ "${path}" == .github/workflows/* ]] || continue
    if [[ "${path}" =~ ^\.github/workflows/xs-[A-Za-z0-9._-]+\.ya?ml$ ]]; then
      theirs=false
      for ref in ${XS_UPSTREAM_REFS:-}; do
        if git cat-file -e "${ref}:${path}" 2> /dev/null; then theirs=true; fi
      done
      [[ "${theirs}" == true ]] || continue
    fi
    printf '%s\t%s\n' "${id}" "${path}"
  done
}

# xs_github_changes <from> <to>: "added|modified|deleted <path>" for every path
# under .github that differs between the two upstream bases and is not ours.
xs_github_changes() {
  local st p
  while IFS= read -r -d '' st && IFS= read -r -d '' p; do
    if xs_path_allowed "${p}"; then continue; fi
    case "${st}" in A) st=added ;; D) st=deleted ;; *) st=modified ;; esac
    printf '%s %s\n' "${st}" "${p}"
  done < <(git diff --no-renames --name-status -z "$1" "$2" -- .github)
}

# xs_own_heads: stdin is `gh pr list --json headRefName,isCrossRepository`.
# Prints the head branches of PRs from this repository only. A fork can name its
# branch sync/<tag>; those PRs must never block or be touched by the sync.
xs_own_heads() {
  jq -r '.[] | select(.isCrossRepository == false) | .headRefName'
}

# xs_prev_tag <tag>: stdin is every tag. Prints the highest stable tag below
# <tag>, preferring the same major.minor line.
xs_prev_tag() {
  local tv v t same="" any=""
  tv="$(xs_version_of "$1")" || die "$1 is not a stable release tag"
  while read -r v t; do
    xs_ver_gt "${tv}" "${v}" || continue
    any="${t}"
    if [[ "${v}" == "${tv%.*}".* ]]; then same="${t}"; fi
  done < <(xs_sorted_stable)
  printf '%s\n' "${same:-${any}}"
}

# xs_md_paths [plain]: NUL separated paths on stdin -> bullet list. Control
# characters and backticks are neutralised so a path cannot break the markdown;
# paths go into code spans so @ and # do not mention or link anything.
xs_md_paths() {
  local p bt='`' sq="'"
  while IFS= read -r -d '' p; do
    p="${p//[[:cntrl:]]/?}"
    p="${p//${bt}/${sq}}"
    if [[ "${1:-}" == plain ]]; then printf -- '- %s\n' "${p}"; else printf -- '- `%s`\n' "${p}"; fi
  done
}

# xs_content_matches <tag> <commit>: true when every path that differs between
# the tag and the commit is a patch path, i.e. the commit already holds the
# tag's content.
xs_content_matches() {
  local p
  while IFS= read -r -d '' p; do
    xs_path_allowed "${p}" || return 1
  done < <(git diff --no-renames --name-only -z "$1" "$2" -- . "${XS_CHART_EXCLUDES[@]}")
  return 0
}

# retry <attempts> <command>...: run the command, sleeping between attempts.
retry() {
  local n="$1" i=1
  shift
  until "$@"; do
    ((i < n)) || return 1
    sleep $((i * ${XS_RETRY_SLEEP:-5}))
    i=$((i + 1))
  done
}

# xs_body_fill <body-file> <fill-file>: replace the text between the flag diff
# markers in the body with the fill file. Prints the new body.
xs_body_fill() {
  local body="$1" fill="$2"
  grep -qxF "${XS_FLAG_BEGIN}" "${body}" || die "body has no flag diff placeholder"
  awk -v b="${XS_FLAG_BEGIN}" -v e="${XS_FLAG_END}" -v f="${fill}" '
    $0 == b { print; while ((getline line < f) > 0) print line; skip = 1; next }
    $0 == e { skip = 0 }
    !skip { print }
  ' "${body}"
}

# ---------------------------------------------------------------------------
# Git and GitHub helpers
# ---------------------------------------------------------------------------

repo_slug() { printf '%s\n' "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"; }

# git_auth_args: git -c options that authenticate https pushes with XS_PUSH_TOKEN.
git_push() {
  local hdr
  hdr="$(printf 'x-access-token:%s' "${XS_PUSH_TOKEN:?XS_PUSH_TOKEN required}" | base64 -w0)"
  echo "::add-mask::${hdr}"
  git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic ${hdr}" push "$@"
}

ensure_upstream_remote() {
  if git remote get-url "${XS_UPSTREAM_REMOTE}" > /dev/null 2>&1; then
    git remote set-url "${XS_UPSTREAM_REMOTE}" "${XS_UPSTREAM_URL}"
  else
    git remote add "${XS_UPSTREAM_REMOTE}" "${XS_UPSTREAM_URL}"
  fi
}

ensure_label() {
  gh label create "$1" --color "$2" --description "$3" --force > /dev/null
}

# ---------------------------------------------------------------------------
# mirror
# ---------------------------------------------------------------------------
# Limits, by design: a tag that already exists on origin is never moved, so a
# tag upstream re-points stays at the old commit here; an upstream branch that
# is deleted stays stale under upstream/. Both are rare and need a human.

# mirror_batches <fetch-specs> <push-specs> <names>: arrays by name. Fetch and
# push in batches of 200 (GitHub rejects larger tag pushes). A failed batch is
# retried, then retried ref by ref; refs that still fail go to MIRROR_FAILED.
MIRROR_FAILED=()
mirror_batches() {
  local -n _f="$1" _p="$2" _n="$3"
  local i j
  for ((i = 0; i < ${#_f[@]}; i += 200)); do
    local -a bf=("${_f[@]:i:200}") bp=("${_p[@]:i:200}") bn=("${_n[@]:i:200}")
    if retry 3 git fetch --no-tags "${XS_UPSTREAM_REMOTE}" "${bf[@]}" && retry 3 git_push origin "${bp[@]}"; then
      continue
    fi
    log "batch failed, retrying ref by ref"
    for ((j = 0; j < ${#bf[@]}; j++)); do
      if retry 2 git fetch --no-tags "${XS_UPSTREAM_REMOTE}" "${bf[j]}" && retry 2 git_push origin "${bp[j]}"; then
        :
      else
        MIRROR_FAILED+=("${bn[j]}")
      fi
    done
  done
}

# mirror_ns_check <ref>...: upstream main and the given refs (the tags mirrored in
# this run) must not contain paths in the xs namespace. They are mirrored anyway
# (mirrors are data), but pushing a branch that holds such a workflow can run it
# with the push's context, so the run fails and a human looks. Main is checked on
# every run, so the failure repeats until upstream drops the path.
mirror_ns_check() {
  local ref bad=0 list
  retry 3 git fetch --no-tags "${XS_UPSTREAM_REMOTE}" "+refs/heads/main:refs/remotes/${XS_UPSTREAM_REMOTE}/main" || die "cannot fetch upstream main"
  for ref in "refs/remotes/${XS_UPSTREAM_REMOTE}/main" "$@"; do
    git rev-parse --verify --quiet "${ref}^{commit}" > /dev/null || continue
    list="$(xs_ns_violations "${ref}")" || die "cannot list the tree of ${ref}"
    [[ -n "${list}" ]] || continue
    bad=$((bad + 1))
    printf '::error::upstream %s holds paths in the xs namespace: %s\n' "${ref#refs/}" "$(head -n 10 <<<"${list}" | tr '\n' ';')" >&2
    summary "upstream ${ref#refs/} holds paths in the xs namespace (mirrored anyway, review them):"
    summary "$(head -n 20 <<<"${list}" | sed 's/^/- /')"
  done
  ((bad == 0))
}

cmd_mirror() {
  local dry=false
  [[ "${1:-}" == "--dry-run" ]] && dry=true
  ensure_upstream_remote

  local up_heads up_tags or_heads or_tags
  up_heads="$(mktemp)"
  up_tags="$(mktemp)"
  or_heads="$(mktemp)"
  or_tags="$(mktemp)"
  retry 3 git ls-remote --heads "${XS_UPSTREAM_REMOTE}" > "${up_heads}"
  retry 3 git ls-remote --tags --refs "${XS_UPSTREAM_REMOTE}" > "${up_tags}"
  retry 3 git ls-remote --heads origin 'refs/heads/upstream/*' > "${or_heads}"
  retry 3 git ls-remote --tags --refs origin > "${or_tags}"

  # Branches: upstream <b> -> origin upstream/<b>, only when the sha differs.
  local sha ref name cur
  local -a b_fetch=() b_push=() b_names=() ns_refs=()
  while read -r sha ref; do
    name="${ref#refs/heads/}"
    [[ "${name}" =~ ${XS_BRANCH_REGEX} ]] || continue
    cur="$(awk -v r="refs/heads/upstream/${name}" '$2 == r { print $1 }' "${or_heads}")"
    [[ "${cur}" != "${sha}" ]] || continue
    b_fetch+=("+refs/heads/${name}:refs/remotes/${XS_UPSTREAM_REMOTE}/${name}")
    b_push+=("+refs/remotes/${XS_UPSTREAM_REMOTE}/${name}:refs/heads/upstream/${name}")
    b_names+=("branch ${name}")
    echo "branch ${name}: ${cur:-none} -> ${sha}"
  done < "${up_heads}"

  # Tags: names upstream has and origin lacks. Our own -xs. tags are never touched.
  local -a t_fetch=() t_push=() t_names=()
  while read -r sha ref; do
    name="${ref#refs/tags/}"
    if [[ "${name}" == *-xs.* ]]; then continue; fi
    if awk -v r="${ref}" '$2 == r { found = 1 } END { exit !found }' "${or_tags}"; then continue; fi
    t_fetch+=("refs/tags/${name}:refs/tags/${name}")
    t_push+=("refs/tags/${name}:refs/tags/${name}") # no force: existing tags are never moved
    t_names+=("tag ${name}")
    ns_refs+=("refs/tags/${name}")
  done < "${up_tags}"
  echo "new tags: ${#t_names[@]}"
  if ((${#t_names[@]} > 0)); then printf '  %s\n' "${t_names[@]:0:40}"; fi
  if ((${#t_names[@]} > 40)); then echo "  ... and $((${#t_names[@]} - 40)) more"; fi

  summary "### mirror (dry run: ${dry})"
  summary "- branches to push: ${#b_names[@]}"
  summary "- tags to push: ${#t_names[@]}"

  if [[ "${dry}" == true ]]; then
    echo "dry run: nothing pushed"
    return 0
  fi

  # Safety: the destinations are only refs/heads/upstream/* and refs/tags/*.
  local s
  for s in "${b_push[@]}"; do
    [[ "${s#*:}" == refs/heads/upstream/* ]] || die "refusing destination ${s#*:}"
  done

  mirror_batches b_fetch b_push b_names
  mirror_batches t_fetch t_push t_names
  local rc=0
  if ((${#MIRROR_FAILED[@]} > 0)); then
    printf '::error::mirror failed for: %s\n' "${MIRROR_FAILED[*]}" >&2
    summary "mirror failed for: ${MIRROR_FAILED[*]}"
    rc=1
  fi
  mirror_ns_check "${ns_refs[@]}" || rc=1
  ((rc == 0)) || return 1
  echo "mirror done"
}

# disable-upstream-workflows: disable every active workflow that is not ours (see
# xs_workflows_to_disable). New
# upstream workflows arrive with each sync; GitHub activates them as soon as the
# file exists on a branch, so this runs daily and after each sync.
cmd_disable_workflows() {
  local repo id path failed=0 base ref
  repo="$(repo_slug)"
  # Upstream refs that decide whether an xs-* workflow is ours: upstream main and
  # the release tag main is based on. A missing ref stops the job: guessing would
  # either disable our workflows or leave an upstream one active.
  base="$(git tag --merged HEAD | xs_highest_stable)"
  [[ -n "${base}" ]] || die "no upstream release tag in the history of HEAD"
  XS_UPSTREAM_REFS="origin/upstream/main refs/tags/${base}"
  for ref in ${XS_UPSTREAM_REFS}; do
    git rev-parse --verify --quiet "${ref}^{commit}" > /dev/null || die "${ref} is missing; fetch the full history and tags"
  done
  export XS_UPSTREAM_REFS
  while IFS=$'\t' read -r id path; do
    if gh api --method PUT "repos/${repo}/actions/workflows/${id}/disable" > /dev/null; then
      echo "disabled ${path} (${id})"
    else
      echo "::warning::could not disable ${path} (${id})"
      failed=$((failed + 1))
    fi
  done < <(gh api --paginate "repos/${repo}/actions/workflows?per_page=100" --jq '.workflows[] | [.id, .path, .state] | @tsv' | xs_workflows_to_disable)
  ((failed == 0)) || die "${failed} upstream workflow(s) could not be disabled"
}

# open-heads <out-file>: head branches of open PRs that come from this repository.
cmd_open_heads() {
  gh pr list --state open --limit 1000 --json headRefName,isCrossRepository | xs_own_heads > "${1:?out file required}"
}

# ---------------------------------------------------------------------------
# detect
# ---------------------------------------------------------------------------
# detect_chart <base> <current-engine-tag> <latest-engine-tag> [heads...]
# Chart-only catch-up decisions (see xs_chart_catchup). Outputs chart_proceed, chart_open_pr,
# chart_tag, chart_head and chart_supersede. A newer engine release carries the chart layer
# itself, so while one is pending (a sync, or an open PR for it) open chart-only PRs are
# superseded and none is started.
detect_chart() {
  local base="$1" current="$2" latest="$3" cur_ctag r k v h
  shift 3
  cur_ctag="$(chart_current_tag "${base}")" || die "${XS_CHART_FILE} of ${base} has no <version>+xs.<n> chart version"
  local ctag="" cproceed=false copen=false chead="" csup=""
  if xs_ver_gt "$(xs_version_of "${latest}")" "$(xs_version_of "${current}")"; then
    for h in "$@"; do
      if [[ "${h}" == sync/* ]] && xs_chart_version_of "${h#sync/}" > /dev/null 2>&1; then csup+="${csup:+ }${h}"; fi
    done
  else
    r="$(chart_lines | xs_chart_catchup "$(xs_version_of "${current}")" "${cur_ctag}" "$@")"
    while IFS='=' read -r k v; do
      case "${k}" in
        chart_latest) ctag="${v}" ;;
        chart_proceed) cproceed="${v}" ;;
        chart_open_pr) copen="${v}" ;;
        chart_head) chead="${v}" ;;
        chart_supersede) csup="${v}" ;;
      esac
    done <<<"${r}"
  fi
  out chart_proceed "${cproceed}"
  out chart_open_pr "${copen}"
  out chart_tag "${ctag}"
  out chart_head "${chead}"
  out chart_supersede "${csup}"
}

cmd_detect() {
  local base="origin/${XS_MAIN_BRANCH}" heads_file="" cap=""
  while (($#)); do
    case "$1" in
      --base) base="$2"; shift 2 ;;
      --open-heads) heads_file="$2"; shift 2 ;;
      --cap) cap="$2"; shift 2 ;;
      *) die "detect: unknown option $1" ;;
    esac
  done
  local current
  current="$(git tag --merged "${base}" | xs_highest_stable)"
  [[ -n "${current}" ]] || die "no upstream release tag is an ancestor of ${base}"
  local -a heads=()
  if [[ -n "${heads_file}" ]]; then mapfile -t heads < "${heads_file}"; fi
  local result
  result="$(git tag --list | XS_CAP_TAG="${cap}" xs_select "${current}" "${heads[@]}")"
  local k v latest proceed=false
  while IFS='=' read -r k v; do
    [[ "${k}" == latest ]] && latest="${v}"
    [[ "${k}" == proceed ]] && proceed="${v}"
  done <<<"${result}"
  if [[ "${proceed}" == true ]] && xs_content_matches "refs/tags/${latest}" "${base}"; then
    die "${base} already holds the content of ${latest} but ${latest} is not in its history (a squash or rebase merge of a sync PR?). Merge ${latest} into ${XS_MAIN_BRANCH} with a merge commit; the sync will not open another PR"
  fi
  while IFS='=' read -r k v; do out "${k}" "${v}"; done <<<"${result}"
  out latest_commit "$(git rev-parse "refs/tags/${latest}^{commit}")"
  if chart_enabled; then detect_chart "${base}" "${current}" "${latest}" "${heads[@]}"; fi
  summary "### detect"
  summary "$(grep '^reason=' <<<"${result}" | cut -d= -f2-)"
}

# ---------------------------------------------------------------------------
# API commit helpers
# ---------------------------------------------------------------------------

# api_call <method> <endpoint> <json-file>: call the API and print the body.
# Throttling (429, secondary rate limits) and 5xx are retried with a growing
# backoff (at least a minute for a secondary rate limit, eight attempts);
# anything else fails at once.
api_call() {
  local method="$1" endpoint="$2" input="$3" attempt=1 err body
  err="$(mktemp)"
  while :; do
    if body="$(gh api --method "${method}" "${endpoint}" --input "${input}" 2> "${err}")"; then
      printf '%s\n' "${body}"
      return 0
    fi
    if grep -q -i -E 'HTTP 429|HTTP 5[0-9][0-9]|rate limit|secondary|abuse detection|retry after' "${err}" && ((attempt < 8)); then
      local delay=$((attempt * attempt * ${XS_RETRY_SLEEP:-5}))
      # GitHub asks for at least a minute after a secondary rate limit.
      if grep -q -i -E 'secondary|abuse detection' "${err}" && ((delay > 0 && delay < 60)); then delay=60; fi
      log "API ${method} ${endpoint} throttled or failed (attempt ${attempt}), backing off ${delay}s"
      sleep "${delay}"
      attempt=$((attempt + 1))
      continue
    fi
    cat "${err}" >&2
    return 1
  done
}

# api_plan <base-tree> <result-tree>: one JSON line per changed path on stdout:
# {path, mode, type, sha, blob}. sha is null for a deletion, blob is true when the
# content is new and needs a blob (false for a mode-only change). Renames are
# plain delete plus add. Submodules, unusual modes and file/directory swaps fail.
api_plan() {
  local base="$1" result="$2" meta path omode nmode osha nsha status blob
  local -a deleted=() added=()
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    read -r omode nmode osha nsha status <<<"${meta#:}"
    case "${status}" in
      D)
        [[ "${omode}" != 160000 ]] || die "submodule removal at ${path} is not supported"
        deleted+=("${path}")
        jq -cn --arg p "${path}" --arg m "${omode}" '{path:$p,mode:$m,type:"blob",sha:null,blob:false}'
        ;;
      A | M | T)
        case "${nmode}" in
          100644 | 100755 | 120000) ;;
          160000) die "submodule change at ${path} is not supported" ;;
          *) die "unsupported file mode ${nmode} at ${path}" ;;
        esac
        added+=("${path}")
        blob=true
        if [[ "${osha}" == "${nsha}" ]]; then blob=false; fi
        jq -cn --arg p "${path}" --arg m "${nmode}" --arg s "${nsha}" --argjson b "${blob}" \
          '{path:$p,mode:$m,type:"blob",sha:$s,blob:$b}'
        ;;
      *) die "unexpected diff status ${status} at ${path}" ;;
    esac
  done < <(git diff-tree -r -z --no-renames --raw "${base}" "${result}")

  # A path that turns from file to directory or back cannot go through one
  # tree request with a base tree.
  local -A dset=() aset=()
  local x q
  for x in "${deleted[@]}"; do dset["${x}"]=1; done
  for x in "${added[@]}"; do aset["${x}"]=1; done
  for x in "${added[@]}"; do
    q="${x}"
    while [[ "${q}" == */* ]]; do
      q="${q%/*}"
      [[ -z "${dset[${q}]:-}" ]] || die "file to directory change at ${q} is not supported"
    done
  done
  for x in "${deleted[@]}"; do
    q="${x}"
    while [[ "${q}" == */* ]]; do
      q="${q%/*}"
      [[ -z "${aset[${q}]:-}" ]] || die "directory to file change at ${q} is not supported"
    done
  done
}

# api_commit <base-tree-of-parent> <result-tree> <message-file> <parent>...
# Creates blobs and a tree for the difference between <base-tree-of-parent> and
# <result-tree>, then a commit with the given parents. Prints the commit sha.
# The commit has no author or committer set, so GitHub signs it as the App.
#
# API_KNOWN_TREES (array, set by the caller) lists trees whose blobs already exist
# on the remote (trees of mirrored tags and of commits on origin). Blobs found in
# them, or in <base-tree-of-parent>, are not uploaded again: a sync that swaps a
# whole chart in would otherwise create hundreds of blobs the repository holds.
# Blob uploads are paced by XS_BLOB_PACE seconds to stay under the content
# creation rate limit; api_call backs off when GitHub throttles anyway.
API_KNOWN_TREES=()
api_commit() {
  local base_tree="$1" result_tree="$2" msg_file="$3"
  shift 3
  local repo tmp line sha path nsha tree_sha n=0 t created=0 skipped=0
  repo="$(repo_slug)"
  tmp="$(mktemp -d)"
  api_plan "${base_tree}" "${result_tree}" > "${tmp}/plan"
  : > "${tmp}/entries"
  : > "${tmp}/known"
  for t in "${base_tree}" "${API_KNOWN_TREES[@]}"; do git ls-tree -r "${t}" | awk '{ print $3 }' >> "${tmp}/known"; done
  LC_ALL=C sort -u -o "${tmp}/known" "${tmp}/known"
  while IFS= read -r line; do
    n=$((n + 1))
    if [[ "$(jq -r .blob <<<"${line}")" == true ]] && grep -qxF "$(jq -r .sha <<<"${line}")" "${tmp}/known"; then
      skipped=$((skipped + 1))
    elif [[ "$(jq -r .blob <<<"${line}")" == true ]]; then
      created=$((created + 1))
      nsha="$(jq -r .sha <<<"${line}")"
      path="$(jq -r .path <<<"${line}")"
      git cat-file blob "${nsha}" | base64 -w0 > "${tmp}/b64"
      jq -n --rawfile c "${tmp}/b64" '{content:$c,encoding:"base64"}' > "${tmp}/blob.json"
      sha="$(api_call POST "repos/${repo}/git/blobs" "${tmp}/blob.json" | jq -r .sha)"
      [[ "${sha}" == "${nsha}" ]] || die "blob ${path}: API sha ${sha} != local ${nsha}"
      sleep "${XS_BLOB_PACE:-0.8}"
    fi
    jq -c 'del(.blob)' <<<"${line}" >> "${tmp}/entries"
  done < "${tmp}/plan"

  log "api_commit: ${n} path(s), ${created} blob(s) uploaded, ${skipped} already on the remote"
  if ((n == 0)); then
    tree_sha="${base_tree}"
  else
    jq -s --arg b "${base_tree}" '{base_tree:$b,tree:.}' "${tmp}/entries" > "${tmp}/tree.json"
    tree_sha="$(api_call POST "repos/${repo}/git/trees" "${tmp}/tree.json" | jq -r .sha)"
  fi
  [[ "${tree_sha}" == "${result_tree}" ]] || die "API tree ${tree_sha} != local tree ${result_tree}"

  local parents_json
  parents_json="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"
  jq -n --rawfile m "${msg_file}" --arg t "${tree_sha}" --argjson p "${parents_json}" \
    '{message:$m,tree:$t,parents:$p}' > "${tmp}/commit.json"
  api_call POST "repos/${repo}/git/commits" "${tmp}/commit.json" | jq -r .sha
  rm -rf "${tmp}"
}

branch_name_ok() { [[ "$1" =~ ^(sync|rehearsal-sync)/[A-Za-z0-9._-]+$ ]]; }

# api_ref_set <branch> <sha>: create the branch, or move it when it exists. Callers
# run branch_guard first. Only sync/* and rehearsal-sync/* are ever written.
api_ref_set() {
  local branch="$1" sha="$2" repo err
  branch_name_ok "${branch}" || die "refusing to write branch ${branch}"
  repo="$(repo_slug)"
  err="$(mktemp)"
  if gh api --method POST "repos/${repo}/git/refs" -f "ref=refs/heads/${branch}" -f "sha=${sha}" > /dev/null 2> "${err}"; then
    return 0
  fi
  if grep -q 'Reference already exists' "${err}"; then
    gh api --method PATCH "repos/${repo}/git/refs/heads/${branch}" -f "sha=${sha}" -F force=true > /dev/null
    return 0
  fi
  cat "${err}" >&2
  return 1
}

api_ref_delete() {
  local branch="$1" repo err
  branch_name_ok "${branch}" || die "refusing to delete branch ${branch}"
  repo="$(repo_slug)"
  err="$(mktemp)"
  if gh api --method DELETE "repos/${repo}/git/refs/heads/${branch}" > /dev/null 2> "${err}"; then return 0; fi
  if grep -q -E 'HTTP 422|HTTP 404|Reference does not exist' "${err}"; then return 0; fi
  cat "${err}" >&2
  return 1
}

api_branch_exists() {
  local branch="$1" repo err
  repo="$(repo_slug)"
  err="$(mktemp)"
  if gh api "repos/${repo}/git/ref/heads/${branch}" > /dev/null 2> "${err}"; then return 0; fi
  grep -q 'HTTP 404' "${err}" || { cat "${err}" >&2; die "could not look up branch ${branch}"; }
  return 1
}

# branch_tip_is_bot <branch> <latest-tag> <latest-commit>: true when the branch tip
# is the bot's own merge of the tag (two parents, the second the tag commit, the
# usual subject) made by the App (author XS_BOT_LOGIN, committer GitHub) with a valid
# signature. Anything else means a human may have worked on the branch. Sets BOT_TIP.
BOT_TIP=""
branch_tip_is_bot() {
  local branch="$1" latest="$2" latest_commit="$3" tip info repo
  repo="$(repo_slug)"
  tip="$(gh api "repos/${repo}/git/ref/heads/${branch}" --jq .object.sha)"
  info="$(gh api "repos/${repo}/git/commits/${tip}" --jq '[(.parents|length), (.parents[1].sha // ""), (.message|split("\n")[0]), (.author.name // ""), (.author.email // ""), (.committer.name // ""), (.committer.email // ""), (.verification.verified|tostring)]|@tsv')"
  BOT_TIP="${tip}"
  [[ "${info}" == "$(printf '2\t%s\tchore(sync): sync upstream %s\t%s\t%s\tGitHub\tnoreply@github.com\ttrue' "${latest_commit}" "${latest}" "${XS_BOT_LOGIN}" "${XS_BOT_EMAIL}")" ]]
}

# api_ref_set_if <branch> <sha> <expected-tip>: move the branch only when it still points at
# the tip that was checked (the ref API has no compare-and-swap, so the tip is read again
# right before the update; a push in that gap is not caught).
api_ref_set_if() {
  local branch="$1" sha="$2" expect="$3" cur
  cur="$(gh api "repos/$(repo_slug)/git/ref/heads/${branch}" --jq .object.sha)"
  [[ "${cur}" == "${expect}" ]] || return 1
  api_ref_set "${branch}" "${sha}"
}

# branch_guard <branch> <latest-tag> <latest-commit>: refuse to overwrite an
# existing sync branch that is not the bot's own merge of the tag.
branch_guard() {
  api_branch_exists "$1" || return 0
  branch_tip_is_bot "$1" "$2" "$3" ||
    die "$1 exists and is not a sync commit of $2; not overwriting it. Delete the branch if it is stale and re-run"
}

# pr_state <head-branch>: see xs_pr_state.
pr_state() {
  gh pr list --state all --head "$1" --limit 20 --json number,state,isCrossRepository | xs_pr_state
}

# pr_find <head-branch> <open|all>: number of a PR from this repository with that
# head branch. PRs from forks are ignored: a fork can use any branch name.
pr_find() {
  gh pr list --state "$2" --head "$1" --limit 20 --json number,isCrossRepository \
    --jq '[.[] | select(.isCrossRepository == false)][0].number // empty'
}

# issue_find <exact-title> <label> [author]: number of the open issue with that
# title, our label and an author the bot owns (default the App; the failure issue
# is opened with GITHUB_TOKEN, so it passes XS_ISSUE_AUTHOR_ACTIONS). Anyone can
# open an issue on a public repo, so the title alone proves nothing.
issue_find() {
  [[ "$1" =~ ^[A-Za-z0-9\ ._:()/-]+$ ]] || die "bad issue title $1"
  [[ -n "${2:-}" ]] || die "issue_find needs a label"
  gh issue list --state open --author "${3:-${XS_ISSUE_AUTHOR}}" --label "$2" --search "\"$1\" in:title" --limit 30 --json number,title \
    --jq "map(select(.title == \"$1\")) | .[0].number // empty"
}

# issue_upsert <title> <label> <body-file>: create the issue or replace its body.
# Sets ISSUE_NUMBER. The search index lags behind new issues by a while, so an
# issue created seconds ago may be created again on a quick re-run; callers that
# need the number use ISSUE_NUMBER, not a search.
ISSUE_NUMBER=""
issue_upsert() {
  local title="$1" label="$2" body="$3" num url
  num="$(issue_find "${title}" "${label}")"
  if [[ -n "${num}" ]]; then
    gh issue edit "${num}" --body-file "${body}" > /dev/null
    echo "updated issue #${num}"
    ISSUE_NUMBER="${num}"
  else
    url="$(gh issue create --title "${title}" --label "${label}" --body-file "${body}")"
    echo "${url}"
    ISSUE_NUMBER="${url##*/}"
  fi
}

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

# apply_patch <patch-file> <commit-ish> <index-file>
# Applies the patch to the tree of commit-ish in a scratch index (3-way, no
# worktree). A target of "-" applies it to the index as it is. Returns 1 on conflict and prints the conflicting paths on fd 3.
apply_patch() {
  local patch="$1" target="$2" index="$3" err rc=0
  err="$(mktemp)"
  if [[ "${target}" != "-" ]]; then GIT_INDEX_FILE="${index}" git read-tree "${target}"; fi
  GIT_INDEX_FILE="${index}" git apply --cached --3way "${patch}" 2> "${err}" || rc=$?
  if ((rc == 0)); then return 0; fi
  {
    GIT_INDEX_FILE="${index}" git ls-files -u -z | tr '\0' '\n' | cut -f2
    sed -n -E \
      -e 's/^error: patch failed: (.*):[0-9]+$/\1/p' \
      -e 's/^error: (.*): patch does not apply$/\1/p' \
      -e 's/^error: (.*): already exists in (working directory|index)$/\1/p' \
      -e 's/^error: (.*): does not exist in (working directory|index)$/\1/p' \
      -e 's/^Applied patch to .(.*). with conflicts\.$/\1/p' "${err}"
  } | LC_ALL=C sort -u >&3
  cat "${err}" >&2
  return 1
}

# patch_files <current-tag> <base-tree>: NUL separated paths of our engine patch
# (the chart paths are a separate layer, see chart_patch_files).
patch_files() {
  git diff --no-renames --name-only -z "$1" "$2" -- . "${XS_CHART_EXCLUDES[@]}"
}

# ---------------------------------------------------------------------------
# Chart layer (git side). Everything here is skipped when XS_CHART_PATHS is empty.
# ---------------------------------------------------------------------------
CHART_CUR=""
CHART_NEW=""
CHART_MODE=""
API_KNOWN_EXTRA=()

# chart_note <engine-version> [md]: how the chart layer was resolved, for the commit
# message and the PR body (nothing when the chart layer is off).
chart_note() {
  chart_enabled || return 0
  echo
  if [[ "${CHART_MODE}" == moved ]]; then
    echo "Chart: ${CHART_CUR} -> ${CHART_NEW} (appVersion ${1}). The chart paths are the ${CHART_NEW}"
    echo "tree plus our chart patch, versions bumped to <chart>+xs.0 and ${1}-xs.0,"
    echo "and the golden records under ${XS_CHART_DERIVED_PATHS[*]} regenerated."
    echo "Golden records built with helm ${CHART_HELM_USED:-unknown}; the upstream build image of the"
    echo "engine tag uses helm ${CHART_HELM_IMAGE:-unknown}."
    if [[ -n "${CHART_HELM_USED}" && -n "${CHART_HELM_IMAGE}" && "${CHART_HELM_USED}" != "v${CHART_HELM_IMAGE}"* ]]; then
      echo "The two differ: a golden record failure in xs-charts can come from the Helm version."
    fi
  else
    echo "Chart: upstream has no chart release with appVersion ${1} yet. The chart import stays at"
    echo "${CHART_CUR} (chart version, engineTag and golden records unchanged)."
  fi
}

chart_enabled() { ((${#XS_CHART_PATHS[@]} > 0)); }

# chart_lines: "<chart-tag> <appVersion>" for every stable chart tag.
# chart_tag_for <engine-version>: the newest chart release tag whose appVersion is
# the engine version (empty when there is none).
chart_lines() {
  local t app
  while IFS= read -r t; do
    xs_chart_version_of "${t}" > /dev/null || continue
    app="$(git show "refs/tags/${t}:${XS_CHART_FILE}" 2> /dev/null | xs_chart_app_version || true)"
    printf '%s %s\n' "${t}" "${app}"
  done < <(git tag --list)
}
chart_tag_for() { chart_lines | xs_chart_pick "$1"; }

# chart_current_tag <treeish>: the chart tag a tree is based on (from its Chart.yaml).
chart_current_tag() {
  git show "$1:${XS_CHART_FILE}" | xs_chart_current
}

# chart_patch_make <chart-tag> <treeish> <out>: our chart patch, the diff from the
# chart tag to the tree over the chart paths, without the derived paths (the golden
# records) and without the bump files (their only change is the version string).
chart_patch_make() {
  local -a spec=("${XS_CHART_PATHS[@]}") x
  for x in "${XS_CHART_DERIVED_PATHS[@]}" "${XS_CHART_BUMP_FILES[@]}"; do spec+=(":(exclude)${x}"); done
  git diff --no-renames "refs/tags/$1" "$2" --binary --full-index -- "${spec[@]}" > "$3"
}

# chart_patch_files <chart-tag> <treeish>: NUL separated paths of the chart patch,
# including the bump files, without the derived paths.
chart_patch_files() {
  local -a spec=("${XS_CHART_PATHS[@]}") x
  for x in "${XS_CHART_DERIVED_PATHS[@]}"; do spec+=(":(exclude)${x}"); done
  git diff --no-renames --name-only -z "refs/tags/$1" "$2" -- "${spec[@]}"
}

# index_set_paths <index> <treeish>: make the chart paths in the index equal to
# the ones of the treeish (paths it lacks are removed).
index_set_paths() {
  local index="$1" tree="$2" p sub
  for p in "${XS_CHART_PATHS[@]}"; do
    GIT_INDEX_FILE="${index}" git ls-files -z -- "${p}" | GIT_INDEX_FILE="${index}" git update-index --force-remove -z --stdin
    if sub="$(git rev-parse --verify --quiet "${tree}:${p}")"; then
      GIT_INDEX_FILE="${index}" git read-tree --prefix="${p}/" "${sub}"
    fi
  done
}

# index_edit <index> <path> <sed-script>: rewrite a file in the index. Fails when
# the script changes nothing.
index_edit() {
  local index="$1" path="$2" script="$3" mode old new
  mode="$(GIT_INDEX_FILE="${index}" git ls-files -s -- "${path}" | cut -d' ' -f1)"
  [[ "${mode}" =~ ^100[67][45][45]$ ]] || die "${path} is not in the index as a regular file"
  old="$(GIT_INDEX_FILE="${index}" git ls-files -s -- "${path}" | cut -d' ' -f2)"
  new="$(GIT_INDEX_FILE="${index}" git cat-file blob "${old}" | sed -E "${script}" | git hash-object -w --stdin)"
  [[ "${new}" != "${old}" ]] || die "version rewrite changed nothing in ${path}"
  GIT_INDEX_FILE="${index}" git update-index --cacheinfo "${mode},${new},${path}"
}

# chart_bump <index> <chart-tag> <engine-version>: chart version <chart>+xs.0 in
# Chart.yaml and the README, xscaler.engineTag <engine>-xs.0 in the values file.
chart_bump() {
  local index="$1" cv engv="$3"
  cv="$(xs_chart_version_of "$2")" || die "$2 is not a chart release tag"
  local expr
  # Every expression has to change its file: a pattern that stopped matching means the
  # upstream text moved and the bump is incomplete.
  while IFS= read -r expr; do index_edit "${index}" "${XS_CHART_FILE}" "${expr}"; done < <(xs_bump_sed "${cv}" "${engv}" chart)
  while IFS= read -r expr; do index_edit "${index}" "${XS_CHART_README}" "${expr}"; done < <(xs_bump_sed "${cv}" "${engv}" readme)
  # A chart-only sync keeps the engine version, so engineTag may already be the target.
  if ! GIT_INDEX_FILE="${index}" git cat-file blob ":${XS_CHART_VALUES}" | grep -qxF "  engineTag: ${engv}-xs.0"; then
    while IFS= read -r expr; do index_edit "${index}" "${XS_CHART_VALUES}" "${expr}"; done < <(xs_bump_sed "${cv}" "${engv}" values)
  fi
}

# chart_regen_run <index> <outdir>: rebuild the derived paths (the golden records) from
# the chart in the index with the upstream script, and copy them to <outdir> with a
# .xs-meta file naming the Helm used. This runs upstream code (the chart, build.sh, Helm
# plugins and dependencies), so it refuses to start with a GitHub token in the
# environment and runs the command with an empty environment but PATH, HOME and TMPDIR.
chart_regen_run() {
  local index="$1" out="$2" dir x used
  ((${#XS_CHART_DERIVED_PATHS[@]} > 0)) || return 0
  [[ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}${XS_PUSH_TOKEN:-}" ]] || die "refusing to run upstream code to regenerate ${XS_CHART_DERIVED_PATHS[*]} with a GitHub token in the environment"
  command -v helm > /dev/null || die "helm is required to regenerate ${XS_CHART_DERIVED_PATHS[*]}"
  dir="$(mktemp -d)"
  mkdir -p "${dir}/work" "${dir}/home" "${dir}/tmp"
  GIT_INDEX_FILE="${index}" git ls-files -z -- "${XS_CHART_REGEN_INPUT[@]}" | GIT_INDEX_FILE="${index}" git checkout-index -z --stdin --prefix="${dir}/work/"
  used="$(env -i PATH="${PATH}" HOME="${dir}/home" TMPDIR="${dir}/tmp" helm version --short 2> /dev/null || true)"
  (cd "${dir}/work" && env -i PATH="${PATH}" HOME="${dir}/home" TMPDIR="${dir}/tmp" bash -c "${XS_CHART_REGEN_CMD}") >&2 || die "regenerating ${XS_CHART_DERIVED_PATHS[*]} failed"
  mkdir -p "${out}"
  for x in "${XS_CHART_DERIVED_PATHS[@]}"; do
    [[ -d "${dir}/work/${x}" ]] || die "the regeneration did not produce ${x}"
    chart_goldens_limits "${dir}/work/${x}"
    mkdir -p "${out}/${x}"
    cp -a "${dir}/work/${x}/." "${out}/${x}/"
  done
  printf 'helm=%s\n' "${used:-unknown}" > "${out}/.xs-meta"
  rm -rf "${dir}"
}

# chart_goldens_limits <dir>: the regenerated records are data that crosses jobs, so refuse
# symlinks and other non-regular files, more than XS_CHART_GOLDENS_MAX_FILES files or
# XS_CHART_GOLDENS_MAX_BYTES bytes (golden records are a few hundred small files).
chart_goldens_limits() {
  local dir="$1" n bytes
  [[ -z "$(find "${dir}" ! -type f ! -type d -print -quit)" ]] || die "${dir} holds a symlink or another file that is not regular"
  n="$(find "${dir}" -type f | wc -l)"
  bytes="$(find "${dir}" -type f -printf '%s\n' | awk '{ t += $1 } END { print t + 0 }')"
  ((n <= ${XS_CHART_GOLDENS_MAX_FILES:-5000})) || die "${n} golden record files, more than ${XS_CHART_GOLDENS_MAX_FILES:-5000}"
  ((bytes <= ${XS_CHART_GOLDENS_MAX_BYTES:-52428800})) || die "golden records are ${bytes} bytes, more than ${XS_CHART_GOLDENS_MAX_BYTES:-52428800}"
}

# chart_goldens_import <index> <dir>: put regenerated derived paths from <dir> (the output
# of chart_regen_run, possibly produced by another job) into the index. The directory is
# data from another job: only regular files below the derived paths are accepted.
chart_goldens_import() {
  local index="$1" src="$2" f x ok gitdir
  [[ -d "${src}" ]] || die "no regenerated golden records in ${src}"
  chart_goldens_limits "${src}"
  while IFS= read -r -d '' f; do
    f="${f#"${src}"/}"
    [[ "${f}" != .xs-meta ]] || continue
    ok=false
    for x in "${XS_CHART_DERIVED_PATHS[@]}"; do
      if [[ "${f}" == "${x}/"* && "${f}" != *"/../"* ]]; then ok=true; fi
    done
    # ... and a path the chart patch globs allow (operations/helm/tests/*-generated/*).
    if [[ "${ok}" != true ]] || ! xs_chart_path_allowed "${f}"; then die "unexpected path ${f} in the regenerated golden records"; fi
  done < <(find "${src}" -type f -print0)
  gitdir="$(git rev-parse --absolute-git-dir)"
  for x in "${XS_CHART_DERIVED_PATHS[@]}"; do
    [[ -d "${src}/${x}" ]] || die "the regenerated golden records lack ${x}"
    GIT_INDEX_FILE="${index}" git ls-files -z -- "${x}" | GIT_INDEX_FILE="${index}" git update-index --force-remove -z --stdin
    (cd "${src}" && GIT_INDEX_FILE="${index}" git --git-dir="${gitdir}" --work-tree=. add -A -- "${x}")
  done
}

# chart_bump_check <chart-tag> <base-tree>: main's copies of the bump files must equal the
# chart release's copies once the version rewrite is undone, so the bump never drops a
# non-version edit of ours. Prints the paths that differ on fd 3.
chart_bump_check() {
  local tag="$1" tree="$2" f cv want have rc=0
  cv="$(xs_chart_version_of "${tag}")"
  for f in "${XS_CHART_BUMP_FILES[@]}"; do
    want="$(git show "refs/tags/${tag}:${f}" | git hash-object --stdin)"
    have="$(git show "${tree}:${f}" | sed -E "s/${cv//./\\.}\\+xs\\.[0-9]+/${cv}/g" | git hash-object --stdin)"
    if [[ "${want}" != "${have}" ]]; then
      log "${f} differs from ${tag} beyond the version rewrite, the bump would drop that edit"
      echo "${f}" >&3
      rc=1
    fi
  done
  return "${rc}"
}

# chart_layer <base-tree> <engine-version> <index> <work>: second layer of the
# build. Replaces the chart paths in the index (taken from the engine tag so far)
# with the chart of the new engine version plus our chart patch, or keeps main's
# chart when upstream has no chart release for that engine version yet. Sets
# CHART_CUR, CHART_NEW, CHART_MODE (moved|kept) and writes the chart patch file
# list to <work>/chart-files. Returns 1 on a conflict (paths on fd 3).
chart_layer() {
  local base_tree="$1" engv="$2" index="$3" work="$4" patch="$4/chart-patch"
  CHART_CUR="$(chart_current_tag "${base_tree}")" || die "${XS_CHART_FILE} of the base has no <version>+xs.<n> chart version"
  git rev-parse --verify --quiet "refs/tags/${CHART_CUR}^{commit}" > /dev/null || die "chart tag ${CHART_CUR} is missing"
  CHART_NEW="$(chart_tag_for "${engv}")"
  : > "${work}/chart-files"
  if [[ -z "${CHART_NEW}" ]] || ! xs_ver_gt "$(xs_chart_version_of "${CHART_NEW}")" "$(xs_chart_version_of "${CHART_CUR}")"; then
    CHART_MODE=kept
    index_set_paths "${index}" "${base_tree}"
    echo "chart: no chart release newer than ${CHART_CUR} has appVersion ${engv}; the chart import stays at ${CHART_CUR}"
    return 0
  fi
  CHART_MODE=moved
  echo "chart: ${CHART_CUR} -> ${CHART_NEW} (appVersion ${engv})"
  chart_bump_check "${CHART_CUR}" "${base_tree}" || return 1
  index_set_paths "${index}" "refs/tags/${CHART_NEW}"
  chart_patch_make "${CHART_CUR}" "${base_tree}" "${patch}"
  chart_patch_files "${CHART_CUR}" "${base_tree}" > "${work}/chart-files"
  if [[ -s "${patch}" ]]; then apply_patch "${patch}" - "${index}"; fi
}

# chart_finish <index> <engine-version> [engine-tag]: after both layers applied cleanly,
# bump the versions and bring in the regenerated golden records when the chart moved.
# XS_CHART_GOLDENS_IN: a directory regenerated by an earlier token-less job (the live
# path). XS_CHART_GOLDENS_OUT: regenerate into this directory and leave the index without
# the new records (the token-less prepare step). Neither: regenerate in place (tests).
XS_CHART_GOLDENS_IN=""
XS_CHART_GOLDENS_OUT=""
CHART_HELM_USED=""
CHART_HELM_IMAGE=""
chart_finish() {
  [[ "${CHART_MODE}" == moved ]] || return 0
  local index="$1" tmp meta
  chart_bump "${index}" "${CHART_NEW}" "$2"
  if [[ -n "${XS_CHART_GOLDENS_IN}" ]]; then
    meta="${XS_CHART_GOLDENS_IN}"
    chart_goldens_import "${index}" "${XS_CHART_GOLDENS_IN}"
  elif [[ -n "${XS_CHART_GOLDENS_OUT}" ]]; then
    meta="${XS_CHART_GOLDENS_OUT}"
    chart_regen_run "${index}" "${XS_CHART_GOLDENS_OUT}"
  else
    tmp="$(mktemp -d)"
    meta="${tmp}"
    chart_regen_run "${index}" "${tmp}"
    chart_goldens_import "${index}" "${tmp}"
  fi
  CHART_HELM_USED="$(sed -n -E 's/^helm=([A-Za-z0-9.+_-]+)$/\1/p' "${meta}/.xs-meta" 2> /dev/null | head -n1 || true)"
  if [[ -n "${3:-}" ]]; then
    CHART_HELM_IMAGE="$(git show "refs/tags/$3:${XS_CHART_BUILD_IMAGE_FILE}" 2> /dev/null | sed -n -E "${XS_CHART_BUILD_IMAGE_HELM_SED}" | head -n1 || true)"
  fi
}

cmd_build() {
  local current="" latest="" base_commit="" base_tree="" branch="" open_pr=true
  local issue_title="" issue_label="sync-conflict" chart_only=false
  while (($#)); do
    case "$1" in
      --current) current="$2"; shift 2 ;;
      --latest) latest="$2"; shift 2 ;;
      --base-commit) base_commit="$2"; shift 2 ;;
      --base-tree) base_tree="$2"; shift 2 ;;
      --branch) branch="$2"; shift 2 ;;
      --no-pr) open_pr=false; shift ;;
      --chart-only) chart_only=true; shift ;;
      --issue-title) issue_title="$2"; shift 2 ;;
      --issue-label) issue_label="$2"; shift 2 ;;
      --goldens) XS_CHART_GOLDENS_IN="$2"; shift 2 ;;
      --goldens-out) XS_CHART_GOLDENS_OUT="$2"; shift 2 ;;
      *) die "build: unknown option $1" ;;
    esac
  done
  xs_version_of "${current}" > /dev/null || die "bad --current ${current}"
  xs_version_of "${latest}" > /dev/null || die "bad --latest ${latest}"
  [[ "${base_commit}" =~ ^[0-9a-f]{40}$ && "${base_tree}" =~ ^[0-9a-f]{40}$ ]] || die "--base-commit and --base-tree must be full shas"
  # --chart-only: the engine is unchanged (--current = --latest, the engine tag main is at)
  # and only the chart layer moves; the head and the title are named after the chart tag.
  if [[ "${chart_only}" == true ]]; then
    chart_enabled || die "--chart-only needs a chart layer"
    [[ "${current}" == "${latest}" ]] || die "--chart-only needs --current equal to --latest"
    [[ -n "${branch}" && -n "${issue_title}" ]] || die "--chart-only needs --branch and --issue-title"
  fi
  : "${branch:=sync/${latest}}"
  : "${issue_title:=sync: ${latest} conflicts}"
  branch_name_ok "${branch}" || die "bad branch ${branch}"

  # main (or the artificial base, which is not a local object) must be based on --current.
  if git cat-file -e "${base_commit}^{commit}" 2> /dev/null; then
    git merge-base --is-ancestor "refs/tags/${current}" "${base_commit}" || die "${current} is not an ancestor of ${base_commit}"
  fi

  # A sync PR that was closed without merging is an explicit skip; a merged one for
  # a release main does not contain means something unusual happened.
  local pr_st="none"
  if [[ "${open_pr}" == true && -z "${XS_CHART_GOLDENS_OUT}" ]]; then
    pr_st="$(pr_state "${branch}")"
    case "${pr_st}" in
      "closed "*)
        echo "skipped by closed PR #${pr_st#closed }"
        summary "### build-sync: skipped by closed PR #${pr_st#closed } (${branch}). Reopen it, or delete the branch to let the sync rebuild."
        out result skipped
        return 0
        ;;
      "merged "*)
        if [[ "${chart_only}" == true ]]; then
          die "${branch} has merged PR #${pr_st#merged }, but main does not carry chart release ${branch#sync/} (its Chart.yaml is older). Check how the PR was merged and move the chart paths to that release in a PR into ${XS_MAIN_BRANCH}"
        fi
        die "${branch} has merged PR #${pr_st#merged }, but ${latest} is not in main's history. Merge ${latest} into ${XS_MAIN_BRANCH} with a merge commit"
        ;;
    esac
  fi

  local work patch files_file index latest_commit latest_tree nfiles
  work="$(mktemp -d)"
  patch="${work}/patch"
  files_file="${work}/files"
  index="${work}/index"
  latest_commit="$(git rev-parse "refs/tags/${latest}^{commit}")"
  latest_tree="$(git rev-parse "${latest_commit}^{tree}")"
  # Upstream never owns our namespace: a tag that carries an xs-* workflow or
  # script would land on main as one of ours.
  local ns
  ns="$(xs_ns_violations "${latest_commit}")" || die "cannot list the xs namespace of ${latest}"
  [[ -z "${ns}" ]] || die "${latest} holds paths in the xs namespace, which only this fork may own: $(head -n 20 <<<"${ns}" | tr '\n' ';')"

  # No renames: a rename is a delete plus an add, so the 3-way apply and the file
  # lists treat both paths.
  git diff --no-renames "${current}" "${base_tree}" --binary --full-index -- . "${XS_CHART_EXCLUDES[@]}" > "${patch}"
  patch_files "${current}" "${base_tree}" > "${files_file}"
  nfiles="$(tr -cd '\0' < "${files_file}" | wc -c)"
  echo "patch: ${nfiles} file(s), $(wc -c < "${patch}") bytes"

  # Layer 1, the engine: the new tag with our patch outside the chart paths.
  # Layer 2, the chart: see chart_layer. Both are tried so one issue lists every conflict.
  local conflicts="${work}/conflicts" tree failed=false latest_v
  [[ -z "${XS_CHART_GOLDENS_IN}" || -z "${XS_CHART_GOLDENS_OUT}" ]] || die "--goldens and --goldens-out exclude each other"
  latest_v="$(xs_version_of "${latest}")"
  : > "${conflicts}"
  apply_patch "${patch}" "${latest_commit}" "${index}" 3>> "${conflicts}" || failed=true
  if chart_enabled; then
    chart_layer "${base_tree}" "${latest_v}" "${index}" "${work}" 3>> "${conflicts}" || failed=true
    LC_ALL=C sort -u -o "${conflicts}" "${conflicts}"
  fi
  if [[ "${failed}" == true && -n "${XS_CHART_GOLDENS_OUT}" ]]; then
    # Prepare step (no token): nothing to regenerate, the build step reports the conflict.
    out result conflict
    return 0
  fi
  if [[ "${failed}" == true ]]; then
    log "patch does not apply to ${latest}"
    local body="${work}/issue.md"
    {
      echo "The xScaler patch set does not apply to upstream ${latest}."
      echo
      echo "Base: ${current} plus ${base_commit}"
      echo
      echo "Conflicting files:"
      if [[ -s "${conflicts}" ]]; then
        tr '\n' '\0' < "${conflicts}" | xs_md_paths
      else
        echo "- (not reported by git apply, see the run log)"
      fi
      echo
      echo "Reproduce:"
      echo
      echo '```sh'
      echo "git fetch origin 'refs/tags/*:refs/tags/*' ${XS_MAIN_BRANCH}"
      echo "git switch --detach ${latest}"
      echo "git diff --no-renames ${current} origin/${XS_MAIN_BRANCH} --binary --full-index -- . ${XS_CHART_EXCLUDES[*]@Q} | git apply --3way"
      if chart_enabled; then
        echo "# chart layer: check out ${XS_CHART_PATHS[*]} from the newest chart release with appVersion ${latest_v}, then"
        echo "git diff --no-renames ${CHART_CUR:-<current chart tag>} origin/${XS_MAIN_BRANCH} --binary --full-index -- ${XS_CHART_PATHS[*]} | git apply --3way"
      fi
      echo '```'
      echo
      echo "Resolve the conflicts on a branch, open a PR into ${XS_MAIN_BRANCH} that is a merge of ${latest},"
      echo "and keep the paths outside the patch set byte-identical to upstream (the chart paths: to the chart release)."
    } > "${body}"
    ensure_label "${issue_label}" B60205 "xs-sync could not apply the patch set to a new upstream release"
    issue_upsert "${issue_title}" "${issue_label}" "${body}"
    summary "### build-sync: conflict"
    summary "Patch set does not apply to ${latest}. Issue \"${issue_title}\" opened or updated."
    out result conflict
    out issue "${ISSUE_NUMBER}"
    return 0
  fi

  if chart_enabled; then
    chart_finish "${index}" "${latest_v}" "${latest}"
    if [[ -n "${XS_CHART_GOLDENS_OUT}" ]]; then
      # Prepare step (no token): the regenerated records are the output, nothing is written to GitHub.
      out result prepared
      return 0
    fi
    # The chart patch files belong to the patch set listed in the commit and the PR.
    cat "${work}/chart-files" >> "${files_file}"
    nfiles="$(tr -cd '\0' < "${files_file}" | wc -c)"
  fi
  local label="${latest}"
  if [[ "${chart_only}" == true ]]; then
    if [[ "${CHART_MODE}" != moved ]]; then
      echo "no chart release newer than ${CHART_CUR} for ${latest}; nothing to sync"
      out result nothing
      return 0
    fi
    label="${CHART_NEW}"
  fi
  tree="$(GIT_INDEX_FILE="${index}" git write-tree)"
  echo "result tree ${tree}"
  ns="$(xs_ns_violations "${latest_commit}" "${base_tree}" "${tree}")" || die "cannot compare the xs namespace of main and the result"
  [[ -z "${ns}" ]] || die "the sync result changes the xs namespace of ${XS_MAIN_BRANCH}: $(head -n 20 <<<"${ns}" | tr '\n' ';')"

  local msg="${work}/message"
  {
    echo "chore(sync): sync upstream ${label}"
    echo
    if [[ "${chart_only}" == true ]]; then
      echo "main is at ${current} with the chart import at ${CHART_CUR}. Move the chart paths to"
      echo "${CHART_NEW} (appVersion ${latest_v}); the engine layer is unchanged. The commit merges"
      echo "the engine tag, which main already has."
      echo
      echo "Release notes: https://github.com/${XS_UPSTREAM_REPO}/releases/tag/${CHART_NEW}"
    else
      echo "main is at ${current} plus the xScaler patch set. Move it to ${latest}:"
      echo "the tree is ${latest} with the patch set applied, and the commit"
      echo "merges the upstream tag so main keeps its upstream ancestry."
      echo
      echo "Release notes: https://github.com/${XS_UPSTREAM_REPO}/releases/tag/${latest}"
    fi
    echo
    echo "Patch files (${nfiles}):"
    xs_md_paths plain < "${files_file}"
    chart_note "${latest_v}"
  } > "${msg}"

  if [[ "${open_pr}" == true ]]; then
    if [[ "${pr_st}" == "open "* ]]; then
      # An open bot PR: refresh it when main moved, only while the branch is still
      # the bot's own commit.
      local num="${pr_st#open }" tip p1 ptree repo
      repo="$(repo_slug)"
      tip="$(gh api "repos/${repo}/git/ref/heads/${branch}" --jq .object.sha)"
      p1="$(gh api "repos/${repo}/git/commits/${tip}" --jq '.parents[0].sha')"
      ptree="$(gh api "repos/${repo}/git/commits/${tip}" --jq '.tree.sha')"
      out pr "${num}"
      # Up to date: built on today's main and holding the tree this run computed (a chart
      # release that appeared since, or a changed upstream tag, changes the tree).
      if [[ "${p1}" == "${base_commit}" && "${ptree}" == "${tree}" ]]; then
        echo "PR #${num} is open and up to date"
        out result exists
        return 0
      fi
      local why="the rebuilt tree differs from this branch (the upstream chart or tag changed since it was built)"
      if [[ "${p1}" != "${base_commit}" ]]; then why="${XS_MAIN_BRANCH} moved since this PR was built"; fi
      local refreshed="" expect_tip=""
      if branch_tip_is_bot "${branch}" "${label}" "${latest_commit}"; then
        expect_tip="${BOT_TIP}"
        API_KNOWN_TREES=("${base_tree}" "${API_KNOWN_EXTRA[@]}")
        if [[ "${CHART_MODE}" == moved ]]; then API_KNOWN_TREES+=("refs/tags/${CHART_NEW}^{tree}"); fi
        refreshed="$(api_commit "${latest_tree}" "${tree}" "${msg}" "${base_commit}" "${latest_commit}")"
      fi
      if [[ -n "${refreshed}" ]] && api_ref_set_if "${branch}" "${refreshed}" "${expect_tip}"; then
        echo "refreshed PR #${num}: ${branch} -> ${refreshed}"
        summary "### build-sync: refreshed PR #${num} onto ${base_commit}"
        out result refreshed
        out commit "${refreshed}"
      else
        local marked
        marked="$(gh pr view "${num}" --json comments --jq '[.comments[].body | select(contains("xs-sync:needs-manual"))] | length')"
        if [[ "${marked}" == 0 ]]; then
          gh pr comment "${num}" --body "This PR needs a refresh: ${why}. ${branch} is not the sync bot's own verified commit any more (or changed while it was being refreshed), so it cannot be refreshed automatically. Merge ${XS_MAIN_BRANCH} into the branch, or close this PR and delete the branch so the sync rebuilds it.
<!-- xs-sync:needs-manual -->" > /dev/null
        fi
        summary "### build-sync: PR #${num} needs a manual update (${why}; branch is not the bot's own commit)"
        out result needs-manual
      fi
      return 0
    fi
    branch_guard "${branch}" "${label}" "${latest_commit}"
  fi

  local commit
  API_KNOWN_TREES=("${base_tree}" "${API_KNOWN_EXTRA[@]}")
  if [[ "${CHART_MODE}" == moved ]]; then API_KNOWN_TREES+=("refs/tags/${CHART_NEW}^{tree}"); fi
  commit="$(api_commit "${latest_tree}" "${tree}" "${msg}" "${base_commit}" "${latest_commit}")"
  api_ref_set "${branch}" "${commit}"
  local verified
  verified="$(gh api "repos/$(repo_slug)/git/commits/${commit}" --jq '.verification.verified')"
  echo "branch ${branch} -> ${commit} (verified: ${verified})"
  out result created
  out branch "${branch}"
  out commit "${commit}"
  out tree "${tree}"
  out verified "${verified}"
  summary "### build-sync"
  summary "Branch \`${branch}\` at \`${commit}\`, tree \`${tree}\`, signature verified: ${verified}."

  if [[ "${open_pr}" == true ]]; then
    # A conflict issue for this version is resolved now.
    local old
    old="$(issue_find "sync: ${label} conflicts" "${issue_label}" || true)"
    if [[ -n "${old}" ]]; then
      gh issue close "${old}" --comment "The patch set applies to ${label} now; sync PR follows." > /dev/null
    fi
    local pr_body="${work}/pr.md" nc
    nc="$(git rev-list --count --no-merges "${current}..${latest}")"
    {
      if [[ "${chart_only}" == true ]]; then
        echo "Upstream chart release notes: https://github.com/${XS_UPSTREAM_REPO}/releases/tag/${CHART_NEW}"
        echo
        echo "Upstream chart changes: https://github.com/${XS_UPSTREAM_REPO}/compare/${CHART_CUR}...${CHART_NEW}"
        echo
        echo "Moves the chart paths from ${CHART_CUR} to ${CHART_NEW}, the chart release for the engine"
        echo "main already runs (${current}). The engine layer is unchanged. The commit is a merge of main"
        echo "and the engine tag, which main already has."
      else
        echo "Upstream release notes: https://github.com/${XS_UPSTREAM_REPO}/releases/tag/${latest}"
        echo
        echo "Upstream changes (${nc} commits): https://github.com/${XS_UPSTREAM_REPO}/compare/${current}...${latest}"
        echo
        echo "Moves the fork from ${current} to ${latest}. The commit is a merge of main and the"
        echo "upstream tag, with the patch set applied to the tag."
      fi
      echo
      echo "Merge this PR with a merge commit. A squash or rebase drops the upstream tag from"
      echo "main's history, and xs-release and the next sync find the release through it."
      echo
      echo "### Patch files (${nfiles})"
      echo
      xs_md_paths < "${files_file}"
      chart_note "${latest_v}" md
      echo
      local gh_changes="${work}/gh-changes" ngh
      xs_github_changes "${current}" "${latest}" > "${gh_changes}"
      ngh="$(wc -l < "${gh_changes}")"
      echo "### Upstream changes under .github (${ngh})"
      echo
      if ((ngh > 0)); then
        echo "Upstream workflows and scripts that changed between ${current} and ${latest}. Upstream"
        echo "workflows stay disabled: xs-sync disables any that are not ours on its next run."
        echo
        echo '```'
        awk 'NR <= 200' "${gh_changes}" | xs_neutralize
        echo '```'
      else
        echo "None."
      fi
      echo
      echo "### Flag diff"
      echo
      echo "${XS_FLAG_BEGIN}"
      echo "Pending: xs-sync-check fills this in when the flag diff job finishes."
      echo "${XS_FLAG_END}"
    } > "${pr_body}"
    local url
    url="$(gh pr create --base "${XS_MAIN_BRANCH}" --head "${branch}" \
      --title "chore(sync): sync upstream ${label}" --body-file "${pr_body}")"
    echo "opened ${url}"
    out pr "${url}"
    summary "Opened ${url}"
  fi
}

# ---------------------------------------------------------------------------
# sync-run: the one build a daily run does, from the detect outputs
#   engine release     a new stable engine tag (carries the chart layer), or an open PR for
#                      it, which build refreshes when main moved or its tree is out of date
#   chart catch-up     the engine is unchanged, main's engine version has a newer chart
#                      release (or an open PR for it, refreshed the same way)
# The regen job (no token) and the sync job (token) call this with the same selectors, so
# both build the same thing; they differ in --goldens-out / --goldens.
# ---------------------------------------------------------------------------
cmd_sync_run() {
  local current="" latest="" proceed=false open_pr=false cproceed=false copen=false ctag="" base_commit="" base_tree="" head_only=false
  local -a pass=()
  while (($#)); do
    case "$1" in
      --current) current="$2"; shift 2 ;;
      --latest) latest="$2"; shift 2 ;;
      --proceed) proceed="$2"; shift 2 ;;
      --open-pr) open_pr="$2"; shift 2 ;;
      --chart-proceed) cproceed="$2"; shift 2 ;;
      --chart-open-pr) copen="$2"; shift 2 ;;
      --chart-tag) ctag="$2"; shift 2 ;;
      --base-commit) base_commit="$2"; shift 2 ;;
      --base-tree) base_tree="$2"; shift 2 ;;
      --goldens | --goldens-out) pass+=("$1" "$2"); shift 2 ;;
      --head-only) head_only=true; shift ;;
      *) die "sync-run: unknown option $1" ;;
    esac
  done
  if [[ "${head_only}" == true ]]; then
    # The head branch this run would build, for the closed-PR check.
    if [[ "${proceed}" == true || "${open_pr}" == true ]]; then out head "sync/${latest}"; elif [[ "${cproceed}" == true || "${copen}" == true ]]; then out head "sync/${ctag}"; else out head ""; fi
    return 0
  fi
  local -a common=(--base-commit "${base_commit}" --base-tree "${base_tree}")
  if [[ "${proceed}" == true || "${open_pr}" == true ]]; then
    cmd_build --current "${current}" --latest "${latest}" "${common[@]}" "${pass[@]}"
  elif [[ "${cproceed}" == true || "${copen}" == true ]]; then
    cmd_build --chart-only --current "${current}" --latest "${current}" --branch "sync/${ctag}" \
      --issue-title "sync: ${ctag} conflicts" "${common[@]}" "${pass[@]}"
  else
    echo "nothing to build"
    out result none
  fi
}

# closed-skip <branch>: outputs skip=true when the head has a closed, unmerged PR of ours.
# The token-less regeneration job calls this in its own step (with a read-only token) so it
# does not regenerate daily for a release whose sync PR was closed on purpose.
cmd_closed_skip() {
  local branch="${1:?branch required}" st
  branch_name_ok "${branch}" || die "bad branch ${branch}"
  st="$(pr_state "${branch}")"
  case "${st}" in
    "closed "*) echo "skipped by closed PR #${st#closed }"; out skip true ;;
    *) out skip false ;;
  esac
}

# ---------------------------------------------------------------------------
# supersede
# ---------------------------------------------------------------------------
cmd_supersede() {
  local target="$1" head num
  shift
  for head in "$@"; do
    # Only heads the bot creates: sync/<engine tag>, and with a chart layer sync/<chart tag>.
    if ! [[ "${head}" =~ ^sync/[A-Za-z0-9._-]+$ ]] || { ! xs_version_of "${head#sync/}" > /dev/null && ! { chart_enabled && xs_chart_version_of "${head#sync/}" > /dev/null; }; }; then
      echo "::warning::skipping ${head}: not a sync head the bot creates"
      continue
    fi
    num="$(pr_find "${head}" open)"
    if [[ -n "${num}" ]]; then
      gh pr close "${num}" --comment "superseded by ${target}" > /dev/null
      echo "closed PR #${num} (${head})"
      api_ref_delete "${head}"
    else
      echo "::warning::${head} has no open PR from this repository; its branch is left alone"
    fi
    num="$(issue_find "sync: ${head#sync/} conflicts" sync-conflict || true)"
    if [[ -n "${num}" ]]; then gh issue close "${num}" --comment "superseded by ${target}" > /dev/null; fi
  done
}

# ---------------------------------------------------------------------------
# rehearse: detect + build against an artificial base, nothing touches main
#
# Target is the upstream release this checkout is based on, base is the previous
# stable release (same line when there is one). The artificial base is base plus
# our patch set (the diff from target to HEAD), so the build must reproduce HEAD.
#   clean      reproduces HEAD exactly
#   merge      the base also edits an upstream file the target edits elsewhere;
#              the result must be HEAD plus that edit (a real 3-way apply)
#   conflict   the base rewrites a file the target changed; no branch, an issue
# With a chart layer the base is also the previous chart release plus our chart patch,
# and every kind has a chart variant (chart-merge, chart-conflict) that edits a chart
# file the target chart release changed. clean runs both layers and the regeneration
# of the golden records, and must reproduce HEAD byte for byte.
# Branch and issue names carry the run id so concurrent rehearsals never share state.
# ---------------------------------------------------------------------------
REHEARSAL_BRANCH=""
REHEARSAL_TITLE=""
REHEARSAL_ISSUE=""
rehearsal_cleanup() {
  local n="${REHEARSAL_ISSUE}"
  if [[ -n "${REHEARSAL_BRANCH}" ]]; then api_ref_delete "${REHEARSAL_BRANCH}" || true; fi
  if [[ -z "${n}" && -n "${REHEARSAL_TITLE}" ]]; then n="$(issue_find "${REHEARSAL_TITLE}" rehearsal || true)"; fi
  if [[ -n "${n}" ]]; then gh issue close "${n}" --comment "rehearsal finished" > /dev/null || true; fi
}

# rehearsal_file <base> <target> <min-first-hunk> [pathspec...]: a text file the
# target changes, with its first changed line at least <min-first-hunk> lines down
# (0 = any). The default pathspecs are the engine paths without .github.
rehearsal_file() {
  local base="$1" target="$2" min="$3" f first hunks
  shift 3
  local -a specs=("$@")
  if ((${#specs[@]} == 0)); then specs=(. ':!.github' "${XS_CHART_EXCLUDES[@]}"); fi
  while IFS= read -r -d '' f; do
    git cat-file -e "${base}:${f}" 2> /dev/null || continue
    # A file with a merge attribute (mimir merges CHANGELOGs as union) never conflicts.
    [[ "$(git check-attr merge -- "${f}" | sed 's/^.*: merge: //')" == unspecified ]] || continue
    if git diff --numstat "${base}" "${target}" -- "${f}" | grep -q '^-'; then continue; fi
    [[ "$(git ls-tree "${base}" -- "${f}" | cut -d' ' -f1)" == 100644 ]] || continue
    if ((min > 0)); then
      hunks="$(git diff -U0 "${base}" "${target}" -- "${f}" | sed -n -E 's/^@@ -([0-9]+)(,[0-9]+)? .*/\1/p')"
      first="${hunks%%$'\n'*}"
      if [[ -z "${first}" ]] || ((first < min)); then continue; fi
    fi
    printf '%s\n' "${f}"
    return 0
  done < <(git diff --no-renames --name-only -z --diff-filter=M "${base}" "${target}" -- "${specs[@]}")
  return 1
}

cmd_rehearse() {
  local kind="${1:?rehearse clean|conflict|merge|chart-merge|chart-conflict}"
  case "${kind}" in
    clean | conflict | merge) ;;
    chart-merge | chart-conflict) chart_enabled || die "${kind} needs a chart layer" ;;
    *) die "unknown rehearsal ${kind}" ;;
  esac
  shift
  # --goldens-out DIR: token-less prepare step, regenerate the golden records into DIR and
  # stop. --goldens DIR: the live step, take the records from DIR (see chart_finish).
  while (($#)); do
    case "$1" in
      --goldens) XS_CHART_GOLDENS_IN="$2"; shift 2 ;;
      --goldens-out) XS_CHART_GOLDENS_OUT="$2"; shift 2 ;;
      *) die "rehearse: unknown option $1" ;;
    esac
  done
  local expect_ref="${XS_REHEARSAL_EXPECT:-HEAD}" rid="${GITHUB_RUN_ID:-local$$}"
  local target base_tag
  target="$(git tag --merged "${expect_ref}" | xs_highest_stable)"
  [[ -n "${target}" ]] || die "no upstream release tag in the history of ${expect_ref}"
  base_tag="$(git tag --list | xs_prev_tag "${target}")"
  [[ -n "${base_tag}" ]] || die "no stable release below ${target}"
  echo "rehearsal ${kind}: base ${base_tag}, target ${target}, patch set = diff ${target}..${expect_ref}"

  local work index patch synth_tree synth_local base_remote expect_tree f=""
  work="$(mktemp -d)"
  index="${work}/index"
  patch="${work}/patch"
  expect_tree="$(git rev-parse "${expect_ref}^{tree}")"
  local branch="rehearsal-sync/${target}-${kind}-${rid}"
  local issue_title="rehearsal sync: ${target} conflicts (${kind} ${rid})"

  git diff --no-renames "${target}" "${expect_ref}" --binary --full-index -- . "${XS_CHART_EXCLUDES[@]}" > "${patch}"
  [[ -s "${patch}" ]] || die "no patch set between ${target} and ${expect_ref}"
  apply_patch "${patch}" "${base_tag}" "${index}" 3>&1 >&2 || die "patch set does not apply to ${base_tag}"

  # The chart layer of the base: the previous chart release, our chart patch (the
  # diff from the target chart release to HEAD), versions of the base. The golden
  # records stay those of the previous chart release: they are derived and the
  # build regenerates them.
  local chart_target="" chart_base="" base_v target_v
  base_v="$(xs_version_of "${base_tag}")"
  target_v="$(xs_version_of "${target}")"
  if chart_enabled; then
    chart_target="$(chart_current_tag "${expect_ref}")" || die "${XS_CHART_FILE} of ${expect_ref} has no <version>+xs.<n> chart version"
    [[ "$(git show "${expect_ref}:${XS_CHART_FILE}" | xs_chart_app_version)" == "${target_v}" ]] || die "chart appVersion of ${expect_ref} is not ${target_v}"
    chart_base="$(git tag --list | xs_chart_prev "${chart_target}")"
    [[ -n "${chart_base}" ]] || die "no chart release below ${chart_target}"
    echo "chart: base ${chart_base}, target ${chart_target}"
    index_set_paths "${index}" "refs/tags/${chart_base}"
    chart_patch_make "${chart_target}" "${expect_ref}" "${work}/chart-patch"
    if [[ -s "${work}/chart-patch" ]]; then
      apply_patch "${work}/chart-patch" - "${index}" 3>&1 >&2 || die "chart patch does not apply to ${chart_base}"
    fi
    chart_bump "${index}" "${chart_base}" "${base_v}"
  fi

  local -a chart_specs=()
  local x
  if chart_enabled; then
    chart_specs=("${XS_CHART_PATHS[@]}")
    for x in "${XS_CHART_DERIVED_PATHS[@]}" "${XS_CHART_BUMP_FILES[@]}"; do chart_specs+=(":(exclude)${x}"); done
  fi

  local line='xs rehearsal merge line' bblob eblob eindex="${work}/expect-index" fbase fbase_tag
  case "${kind}" in
    conflict | chart-conflict)
      if [[ "${kind}" == conflict ]]; then
        f="$(rehearsal_file "${base_tag}" "${target}" 0)" || die "no text file changed between ${base_tag} and ${target}"
      else
        f="$(rehearsal_file "${chart_base}" "${chart_target}" 0 "${chart_specs[@]}")" || die "no chart file changed between ${chart_base} and ${chart_target}"
      fi
      echo "conflict file: ${f}"
      local blob
      blob="$(printf 'xs rehearsal conflict\n' | git hash-object -w --stdin)"
      GIT_INDEX_FILE="${index}" git update-index --cacheinfo "100644,${blob},${f}"
      ;;
    merge | chart-merge)
      if [[ "${kind}" == merge ]]; then
        fbase_tag="${base_tag}"
        f="$(rehearsal_file "${base_tag}" "${target}" 10)" || die "no file changed between ${base_tag} and ${target} away from its first lines"
      else
        fbase_tag="${chart_base}"
        f="$(rehearsal_file "${chart_base}" "${chart_target}" 10 "${chart_specs[@]}")" || die "no chart file changed between ${chart_base} and ${chart_target} away from its first lines"
      fi
      echo "merge file: ${f}"
      fbase="${fbase_tag}"
      bblob="$({ echo "${line}"; git cat-file blob "${fbase}:${f}"; } | git hash-object -w --stdin)"
      GIT_INDEX_FILE="${index}" git update-index --cacheinfo "100644,${bblob},${f}"
      # HEAD holds the target's version of f; the expected result has the line on top.
      local ftarget="${target}"
      if [[ "${kind}" == chart-merge ]]; then ftarget="${chart_target}"; fi
      [[ "$(git rev-parse "${expect_ref}:${f}")" == "$(git rev-parse "${ftarget}:${f}")" ]] || die "${f} differs from ${ftarget} in ${expect_ref}"
      eblob="$({ echo "${line}"; git cat-file blob "${ftarget}:${f}"; } | git hash-object -w --stdin)"
      GIT_INDEX_FILE="${eindex}" git read-tree "${expect_ref}"
      GIT_INDEX_FILE="${eindex}" git update-index --cacheinfo "100644,${eblob},${f}"
      expect_tree="$(GIT_INDEX_FILE="${eindex}" git write-tree)"
      ;;
  esac
  synth_tree="$(GIT_INDEX_FILE="${index}" git write-tree)"
  synth_local="$(git -c user.name=xs-sync -c user.email=xs-sync@localhost commit-tree "${synth_tree}" -p "${base_tag}^{commit}" -m "rehearsal base")"

  if [[ -n "${XS_CHART_GOLDENS_OUT}" ]]; then
    # Prepare step: the same build as below, up to the regeneration, with no token and no API.
    cmd_build --current "${base_tag}" --latest "${target}" --base-commit 0000000000000000000000000000000000000001 \
      --base-tree "${synth_tree}" --branch "rehearsal-sync/prepare" --no-pr
    return 0
  fi

  # Detect must see the artificial base as based on ${base_tag}.
  local det
  det="$(cmd_detect --base "${synth_local}" --cap "${target}")"
  echo "${det}"
  grep -qx "current=${base_tag}" <<<"${det}" || die "detect did not find ${base_tag} as current"
  grep -qx "latest=${target}" <<<"${det}" || die "detect did not find ${target} as latest"
  grep -qx 'proceed=true' <<<"${det}" || die "detect did not proceed"

  # The artificial base on the remote (dangling, only used as a parent). Its chart
  # paths come from the previous chart release, whose blobs the remote has.
  printf 'rehearsal base: %s plus patch set\n' "${base_tag}" > "${work}/base-msg"
  API_KNOWN_TREES=()
  if chart_enabled; then API_KNOWN_TREES=("refs/tags/${chart_base}^{tree}"); fi
  base_remote="$(api_commit "$(git rev-parse "${base_tag}^{tree}")" "${synth_tree}" "${work}/base-msg" \
    "$(git rev-parse "refs/tags/${base_tag}^{commit}")")"
  echo "artificial base ${base_remote}"

  REHEARSAL_BRANCH="${branch}"
  REHEARSAL_TITLE="${issue_title}"
  trap rehearsal_cleanup EXIT

  # Only clean uploads every blob it needs: the other kinds find HEAD's blobs on the
  # remote, so the full upload (and the pacing and backoff it exercises) runs once.
  API_KNOWN_EXTRA=()
  if [[ "${kind}" != clean ]]; then API_KNOWN_EXTRA=("${expect_ref}^{tree}"); fi
  local res
  res="$(cmd_build --current "${base_tag}" --latest "${target}" --base-commit "${base_remote}" \
    --base-tree "${synth_tree}" --branch "${branch}" --no-pr \
    --issue-title "${issue_title}" --issue-label rehearsal)"
  echo "${res}"
  if [[ "${kind}" == clean || "${kind}" == merge || "${kind}" == chart-merge ]]; then
    grep -qx 'result=created' <<<"${res}" || die "rehearsal: expected a created branch"
    local got commit remote_tree parents
    got="$(grep '^tree=' <<<"${res}" | cut -d= -f2)"
    commit="$(grep '^commit=' <<<"${res}" | cut -d= -f2)"
    [[ "${got}" == "${expect_tree}" ]] || die "rehearsal tree ${got} != expected ${expect_tree}"
    remote_tree="$(gh api "repos/$(repo_slug)/git/commits/${commit}" --jq .tree.sha)"
    [[ "${remote_tree}" == "${expect_tree}" ]] || die "remote tree ${remote_tree} != expected ${expect_tree}"
    parents="$(gh api "repos/$(repo_slug)/git/commits/${commit}" --jq '[.parents[].sha]|join(",")')"
    [[ "${parents}" == "${base_remote},$(git rev-parse "refs/tags/${target}^{commit}")" ]] || die "unexpected parents ${parents}"
    echo "rehearsal ${kind} OK: tree ${got}, parents ${parents}"
    summary "### rehearsal ${kind}: OK (${base_tag} to ${target}${chart_base:+, chart ${chart_base} to ${chart_target}}, tree ${got}, verified $(grep '^verified=' <<<"${res}" | cut -d= -f2))"
  else
    grep -qx 'result=conflict' <<<"${res}" || die "rehearsal: expected a conflict"
    if api_branch_exists "${branch}"; then die "rehearsal: branch ${branch} exists after a conflict"; fi
    REHEARSAL_ISSUE="$(grep '^issue=' <<<"${res}" | cut -d= -f2)"
    [[ -n "${REHEARSAL_ISSUE}" ]] || die "rehearsal: no conflict issue number reported"
    [[ "$(gh issue view "${REHEARSAL_ISSUE}" --json title,state --jq '.title + "|" + .state')" == "${issue_title}|OPEN" ]] ||
      die "rehearsal: issue #${REHEARSAL_ISSUE} is not the open conflict issue"
    echo "rehearsal ${kind} OK: issue created, no branch"
    summary "### rehearsal ${kind}: OK (${base_tag} to ${target}, issue created and closed, no branch)"
  fi
}

# ---------------------------------------------------------------------------
# check (pull request validation for sync/<tag>)
# ---------------------------------------------------------------------------
cmd_check() {
  local what="${1:?check identity|parents|version}" tag="${2:?tag required}" head="${3:-HEAD}"
  # A chart-only sync PR is named after the chart release (sync/mimir-distributed-X.Y.Z):
  # its engine tag is the one the chart's appVersion names, and its Chart.yaml must say so.
  if chart_enabled && xs_chart_version_of "${tag}" > /dev/null; then
    local ctag="${tag}" app
    [[ "$(chart_current_tag "${head}")" == "${ctag}" ]] || die "${XS_CHART_FILE} at ${head} is not based on ${ctag}"
    app="$(git show "${head}:${XS_CHART_FILE}" | xs_chart_app_version)"
    tag="$(xs_tag_of "${app}")"
  fi
  xs_version_of "${tag}" > /dev/null || die "${tag} is not a stable release tag"
  git rev-parse --verify --quiet "refs/tags/${tag}^{commit}" > /dev/null || die "upstream tag ${tag} is missing"
  local tag_commit
  tag_commit="$(git rev-parse "refs/tags/${tag}^{commit}")"
  case "${what}" in
    identity)
      local bad=0 n=0 p line up ns diff_list
      # Upstream must not own our namespace: the tag, and the merge's second parent
      # when it is a different commit, hold no xs-* workflow, script or action.
      up="${tag_commit}"
      if p="$(git rev-parse --verify --quiet "${head}^2^{commit}")" && [[ "${p}" != "${tag_commit}" ]]; then up="${tag_commit} ${p}"; fi
      for p in ${up}; do
        ns="$(xs_ns_violations "${p}")" || die "cannot list the xs namespace of ${p}"
        while IFS= read -r line; do
          [[ -n "${line}" ]] || continue
          echo "::error::${line}"
          bad=$((bad + 1))
        done <<<"${ns}"
      done
      diff_list="$(mktemp)"
      git diff --no-renames --name-only -z "${tag_commit}" "${head}" -- . "${XS_CHART_EXCLUDES[@]}" > "${diff_list}" || die "git diff failed"
      while IFS= read -r -d '' p; do
        n=$((n + 1))
        if ! xs_path_allowed "${p}"; then
          echo "::error::${p} differs from ${tag} and is not a patch path"
          bad=$((bad + 1))
        fi
      done < "${diff_list}"
      rm -f "${diff_list}"
      ((bad == 0)) || die "${bad} problem(s): paths outside the patch set differ from ${tag}, or upstream holds xs namespace paths"
      echo "identity OK: ${n} path(s) differ from ${tag}, all inside the patch set"
      summary "identity: ${n} path(s) differ from ${tag}, all inside the patch set"
      if chart_enabled; then
        # The chart paths are compared with the chart release the head's Chart.yaml
        # names, not with the engine tag.
        local ctag cn=0 cbad=0
        ctag="$(chart_current_tag "${head}")" || die "${XS_CHART_FILE} at ${head} has no <version>+xs.<n> chart version"
        git rev-parse --verify --quiet "refs/tags/${ctag}^{commit}" > /dev/null || die "chart tag ${ctag} is missing"
        while IFS= read -r -d '' p; do
          cn=$((cn + 1))
          if ! xs_chart_path_allowed "${p}"; then
            echo "::error::${p} differs from ${ctag} and is not a chart patch path"
            cbad=$((cbad + 1))
          fi
        done < <(git diff --no-renames --name-only -z "refs/tags/${ctag}" "${head}" -- "${XS_CHART_PATHS[@]}")
        ((cbad == 0)) || die "${cbad} chart path(s) outside the chart patch set differ from ${ctag}"
        echo "chart identity OK: ${cn} path(s) differ from ${ctag}, all inside the chart patch set"
        summary "chart identity: ${cn} path(s) differ from ${ctag}, all inside the chart patch set"
      fi
      ;;
    parents)
      local p1 p2
      p1="$(git rev-parse "${head}^1")"
      p2="$(git rev-parse "${head}^2")"
      [[ "${p2}" == "${tag_commit}" ]] || die "second parent ${p2} is not ${tag} (${tag_commit})"
      local main_head
      main_head="$(git rev-parse "origin/${XS_MAIN_BRANCH}")"
      [[ "${p1}" == "${main_head}" ]] || die "first parent ${p1} is not the current ${XS_MAIN_BRANCH} head ${main_head}; the daily sync refreshes the PR, or merge ${XS_MAIN_BRANCH} into the branch"
      echo "parents OK: ${p1} (main) and ${tag}"
      ;;
    version)
      # The same rule xs-release applies to a release commit: the upstream tag is an
      # ancestor and no higher stable tag is.
      git merge-base --is-ancestor "${tag_commit}" "${head}" || die "${tag} is not an ancestor of ${head}"
      local t v tv
      tv="$(xs_version_of "${tag}")"
      while IFS= read -r t; do
        v="$(xs_version_of "${t}")" || continue
        if xs_ver_gt "${v}" "${tv}" && git merge-base --is-ancestor "${t}" "${head}"; then
          die "newer upstream release ${t} is an ancestor of ${head}"
        fi
      done < <(git tag --list)
      echo "version OK: ${tag} is the newest upstream release in ${head}'s history"
      ;;
    *) die "unknown check ${what}" ;;
  esac
}

# ---------------------------------------------------------------------------
# flagdiff
# ---------------------------------------------------------------------------
build_binary() {
  local dir="$1" out="$2"
  (cd "${dir}" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "${out}" "${XS_BINARY_PKG}")
}

# help_text <bin> <flag>: print the help output, or nothing when the binary does
# not define the flag (loki and tempo have -help only, mimir also has -help-all).
help_text() {
  local bin="$1" flag="$2" rc=0 text
  text="$("${bin}" "${flag}" 2>&1)" || rc=$?
  # The flag package exits 0 for -help and 2 for an undefined flag.
  if ((rc != 0 && rc != 2)); then die "${bin} ${flag} exited ${rc}"; fi
  if [[ "${text}" == "flag provided but not defined:"* ]]; then return 0; fi
  printf '%s\n' "${text}"
}

# flag_names <help-file>...: flag names from help output, sorted, unique.
flag_names() {
  { grep -h -oE '^ +-[A-Za-z0-9_.-]+' "$@" || true; } | tr -d ' ' | LC_ALL=C sort -u
}

# flag_report <old-bin> <new-bin> <out.md>
flag_report() {
  local old_bin="$1" new_bin="$2" out="$3" work flag text_flag="" f
  work="$(mktemp -d)"
  for flag in ${XS_HELP_FLAGS}; do
    help_text "${old_bin}" "${flag}" > "${work}/old${flag}.txt"
    help_text "${new_bin}" "${flag}" > "${work}/new${flag}.txt"
    # The last flag that produced output is the one whose text is diffed (-help-all
    # is the complete list where it exists).
    if [[ -s "${work}/new${flag}.txt" ]]; then text_flag="${flag}"; fi
  done
  [[ -n "${text_flag}" ]] || die "the binary printed no help for any of: ${XS_HELP_FLAGS}"
  local -a olds=() news=()
  for flag in ${XS_HELP_FLAGS}; do
    olds+=("${work}/old${flag}.txt")
    news+=("${work}/new${flag}.txt")
  done
  flag_names "${olds[@]}" > "${work}/names-old"
  flag_names "${news[@]}" > "${work}/names-new"
  local added removed
  added="$(LC_ALL=C comm -13 "${work}/names-old" "${work}/names-new" | wc -l)"
  removed="$(LC_ALL=C comm -23 "${work}/names-old" "${work}/names-new" | wc -l)"
  {
    echo "Flag set of the \`${XS_BINARY_NAME}\` binary (linux/amd64, ${XS_HELP_FLAGS}), main vs this PR."
    echo
    echo "- flags: $(wc -l < "${work}/names-old") before, $(wc -l < "${work}/names-new") after"
    echo "- added: ${added}, removed: ${removed}"
    if ((removed > 0)); then
      echo
      echo "Removed flags:"
      echo
      echo '```'
      LC_ALL=C comm -23 "${work}/names-old" "${work}/names-new" | awk 'NR <= 100' | xs_neutralize
      echo '```'
    fi
    if ((added > 0)); then
      echo
      echo "Added flags:"
      echo
      echo '```'
      LC_ALL=C comm -13 "${work}/names-old" "${work}/names-new" | awk 'NR <= 100' | xs_neutralize
      echo '```'
    fi
    echo
    echo "<details><summary>${text_flag} text diff (first 300 lines)</summary>"
    echo
    echo '```diff'
    { diff -u "${work}/old${text_flag}.txt" "${work}/new${text_flag}.txt" || true; } | awk 'NR <= 300' | xs_neutralize
    echo '```'
    echo
    echo "</details>"
  } > "${out}"
  # Help output is only a diff when the binaries print something; an empty flag set means the parse failed.
  [[ -s "${work}/names-new" ]] || die "no flags found in the help output"
}

cmd_flagdiff() {
  local old_dir="$1" new_dir="$2" out="$3" work
  if [[ -z "${XS_BINARY_PKG}" ]]; then
    printf 'No binary in this repository, flag diff skipped.\n' > "${out}"
    return 0
  fi
  work="$(mktemp -d)"
  build_binary "${old_dir}" "${work}/old"
  build_binary "${new_dir}" "${work}/new"
  flag_report "${work}/old" "${work}/new" "${out}"
  cat "${out}"
}

# ---------------------------------------------------------------------------
# failure issue
# ---------------------------------------------------------------------------
cmd_issue_failed() {
  local url="${1:?run url required}" num title="sync: failed"
  [[ "${url}" =~ ^https://github\.com/[A-Za-z0-9._/-]+$ ]] || die "bad run url"
  ensure_label sync-failed D93F0B "xs-sync run failed"
  num="$(issue_find "${title}" sync-failed "${XS_ISSUE_AUTHOR_ACTIONS}")"
  if [[ -n "${num}" ]]; then
    gh issue comment "${num}" --body "Failed again: ${url}" > /dev/null
    echo "commented on #${num}"
  else
    gh issue create --title "${title}" --label sync-failed --body "xs-sync failed: ${url}"
  fi
}

# ---------------------------------------------------------------------------
main() {
  local cmd="${1:-}"
  shift || true
  case "${cmd}" in
    mirror) cmd_mirror "$@" ;;
    select) xs_select "$@" ;;
    detect) cmd_detect "$@" ;;
    open-heads) cmd_open_heads "$@" ;;
    disable-upstream-workflows) cmd_disable_workflows ;;
    build) cmd_build "$@" ;;
    sync-run) cmd_sync_run "$@" ;;
    closed-skip) cmd_closed_skip "$@" ;;
    supersede) cmd_supersede "$@" ;;
    rehearse) cmd_rehearse "$@" ;;
    check) cmd_check "$@" ;;
    flagdiff) cmd_flagdiff "$@" ;;
    flagreport) flag_report "$@" ;;
    body-fill) xs_body_fill "$@" ;;
    issue-failed) cmd_issue_failed "$@" ;;
    *)
      sed -n '3,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' >&2
      exit 2
      ;;
  esac
}

if [[ "${XS_SYNC_SOURCE_ONLY:-}" != "1" ]]; then main "$@"; fi
