#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Table tests for the version and tag selection in xs-sync.sh and its small
# pure helpers. No network, no GitHub token. Run: .github/scripts/xs-sync-test.sh
# shellcheck disable=SC2016,SC2034,SC2046,SC2086,SC2317,SC2329 # word splitting of tag lists and mock functions are intended
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export XS_SYNC_SOURCE_ONLY=1
# shellcheck source=/dev/null
source "${here}/xs-sync.sh"
set +e

# The repository default is mimir-<version> tags with a chart layer. The generic tests
# below use v<version> tags and no chart layer, the mimir block and the two-layer
# section after them switch back to the defaults.
default_tag_regex="${XS_TAG_REGEX}"
default_tag_format="${XS_TAG_FORMAT}"
default_chart_paths=("${XS_CHART_PATHS[@]}")
default_chart_excludes=("${XS_CHART_EXCLUDES[@]}")
XS_TAG_REGEX='^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
XS_TAG_FORMAT='v%s'
XS_CHART_PATHS=()
XS_CHART_EXCLUDES=()

fail=0
pass=0

# expect <name> <want> <got>
expect() {
  if [[ "$2" == "$3" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"
  fi
}

# sel <tags (space separated)> <current> [open heads...] -> "latest proceed supersede"
sel() {
  local tags="$1" current="$2"
  shift 2
  local r
  # shellcheck disable=SC2086 # the tag list is split on purpose
  r="$(printf '%s\n' ${tags} | xs_select "${current}" "$@" 2>&1)" || { echo "error: ${r}"; return; }
  printf '%s %s [%s]\n' "$(grep '^latest=' <<<"${r}" | cut -d= -f2)" \
    "$(grep '^proceed=' <<<"${r}" | cut -d= -f2)" "$(grep '^supersede=' <<<"${r}" | cut -d= -f2)"
}

loki="v2.9.20 v3.6.11 v3.6.12 v3.7.0 v3.7.8 v3.7.9 v3.8.0-rc.1 v3.8.0-rc.2 helm-loki-6.0.0 operator/v0.9.0 pkg/push/v0.1.0 v3.7.9-xs.0"

# nothing new
expect "nothing new" "v3.7.9 false []" "$(sel "${loki}" v3.7.9)"
# patch release
expect "patch" "v3.7.10 true []" "$(sel "${loki} v3.7.10" v3.7.9)"
# numeric, not lexical, ordering
expect "10 > 9" "v3.7.10 true []" "$(sel "v3.7.9 v3.7.10 v3.7.2" v3.7.9)"
# minor release
expect "minor" "v3.8.0 true []" "$(sel "${loki} v3.8.0" v3.7.9)"
# release candidates are ignored
expect "rc ignored" "v3.7.9 false []" "$(sel "${loki} v3.8.1-rc.1 v3.8.0-beta.1" v3.7.9)"
# a patch on an older release line does not move the target
expect "other line" "v3.7.9 false []" "$(sel "${loki} v3.6.13 v2.9.21" v3.7.9)"
# newest stable wins even when several are new
expect "skip to newest" "v3.7.11 true []" "$(sel "${loki} v3.7.10 v3.7.11" v3.7.9)"
# our own release tags are not upstream tags
expect "xs tags ignored" "v3.7.9 false []" "$(sel "${loki} v3.7.10-xs.0 v3.8.0-xs.1" v3.7.9)"
# already open PR for the target
expect "pr open" "v3.7.10 false []" "$(sel "${loki} v3.7.10" v3.7.9 sync/v3.7.10)"
# older sync PRs are superseded, the one for the target is kept
expect "supersede" "v3.7.11 true [sync/v3.7.10]" "$(sel "${loki} v3.7.10 v3.7.11" v3.7.9 sync/v3.7.10)"
expect "supersede, pr open" "v3.7.11 false [sync/v3.7.10]" "$(sel "${loki} v3.7.10 v3.7.11" v3.7.9 sync/v3.7.10 sync/v3.7.11)"
# stale PR after main caught up is still superseded
expect "stale pr" "v3.7.10 false [sync/v3.7.9]" "$(sel "${loki} v3.7.10" v3.7.10 sync/v3.7.9)"
# unrelated PR heads are ignored
expect "other heads" "v3.7.10 true []" "$(sel "${loki} v3.7.10" v3.7.9 feature/x dependabot/foo)"
# cap
expect "cap" "v3.7.9 true []" "$(XS_CAP_TAG=v3.7.9 sel "${loki} v3.8.0" v3.7.8)"
# bad current
expect "bad current" "error: ::error::current tag v3.7.9-xs.0 is not a stable release tag" "$(sel "${loki}" v3.7.9-xs.0)"
# highest stable helper, no stable tag
expect "highest" "v3.7.9" "$(printf '%s\n' "${loki}" | tr ' ' '\n' | xs_highest_stable)"
expect "highest none" "" "$(printf '%s\n' v3.8.0-rc.1 foo | xs_highest_stable)"

# mimir naming
(
  # shellcheck disable=SC2034 # read by the sourced functions
  XS_TAG_REGEX="${default_tag_regex}"
  # shellcheck disable=SC2034
  XS_TAG_FORMAT="${default_tag_format}"
  mimir="mimir-2.17.0 mimir-3.2.2 mimir-3.2.3 mimir-3.3.0-rc.0 mimir-3.3.0-rc.1 mimir-2.10.5 v3.9.0 mimir-distributed-5.0.0 operator/v1"
  expect "mimir nothing new" "mimir-3.2.3 false []" "$(sel "${mimir}" mimir-3.2.3)"
  expect "mimir patch" "mimir-3.2.4 true []" "$(sel "${mimir} mimir-3.2.4" mimir-3.2.3)"
  expect "mimir minor, rc ignored" "mimir-3.3.0 true []" "$(sel "${mimir} mimir-3.3.0" mimir-3.2.3)"
  expect "mimir rc only" "mimir-3.2.3 false []" "$(sel "${mimir}" mimir-3.2.3)"
  expect "mimir tag name" "mimir-3.3.0" "$(xs_tag_of 3.3.0)"
  expect "mimir version" "3.2.3" "$(xs_version_of mimir-3.2.3)"
  expect "mimir foreign tag" "" "$(xs_version_of v3.2.3)"
)

# version and tag helpers
expect "version" "3.7.9" "$(xs_version_of v3.7.9)"
expect "version rc" "" "$(xs_version_of v3.7.9-rc.1)"
expect "version newline" "" "$(xs_version_of $'v3.7.9\nx')"
expect "tag of" "v3.7.9" "$(xs_tag_of 3.7.9)"
xs_ver_gt 3.7.10 3.7.9 && r=yes || r=no
expect "gt 3.7.10 3.7.9" "yes" "${r}"
xs_ver_gt 3.7.9 3.7.9 && r=yes || r=no
expect "gt equal" "no" "${r}"
xs_ver_gt 3.10.0 3.9.9 && r=yes || r=no
expect "gt minor numeric" "yes" "${r}"
xs_ver_gt 2.9.20 3.0.0 && r=yes || r=no
expect "gt major" "no" "${r}"

# patch path rules
for p in .github/workflows/xs-test.yml .github/scripts/xs-sync.sh; do
  xs_path_allowed "${p}" && r=yes || r=no
  expect "allowed ${p}" "yes" "${r}"
done
for p in .github/workflows/check.yml .github/scripts/other.sh pkg/distributor/distributor.go go.mod; do
  xs_path_allowed "${p}" && r=yes || r=no
  expect "not allowed ${p}" "no" "${r}"
done

# flag names from help output
tmp="$(mktemp -d)"
printf 'Usage of x:\n  -a.b\n    \tdoc -not-a-flag\n  -c value\n    \tdoc\n  -a.b\n' > "${tmp}/h"
expect "flag names" "$(printf -- '-a.b\n-c')" "$(flag_names "${tmp}/h")"
rm -rf "${tmp}"

# body fill
tmp="$(mktemp -d)"
printf 'head\n%s\nPending\n%s\ntail\n' "${XS_FLAG_BEGIN}" "${XS_FLAG_END}" > "${tmp}/body"
printf 'line 1\nline 2\n' > "${tmp}/fill"
expect "body fill" "$(printf 'head\n%s\nline 1\nline 2\n%s\ntail' "${XS_FLAG_BEGIN}" "${XS_FLAG_END}")" "$(xs_body_fill "${tmp}/body" "${tmp}/fill")"
xs_body_fill "${tmp}/body" "${tmp}/fill" > "${tmp}/body2"
printf 'new\n' > "${tmp}/fill2"
expect "body refill" "$(printf 'head\n%s\nnew\n%s\ntail' "${XS_FLAG_BEGIN}" "${XS_FLAG_END}")" "$(xs_body_fill "${tmp}/body2" "${tmp}/fill2")"
rm -rf "${tmp}"

# ---------------------------------------------------------------------------
# Helpers that need no repository
# ---------------------------------------------------------------------------
expect "own heads" "$(printf 'sync/v3.7.10\nfeature/x')" "$(printf '%s' '[{"headRefName":"sync/v3.7.10","isCrossRepository":false},{"headRefName":"sync/v9.9.9","isCrossRepository":true},{"headRefName":"feature/x","isCrossRepository":false}]' | xs_own_heads)"
# a fork PR named like ours is not counted: nothing superseded, nothing open
expect "fork pr ignored" "v3.7.10 true []" "$(sel "${loki} v3.7.10" v3.7.9 $(printf '%s' '[{"headRefName":"sync/v3.7.10","isCrossRepository":true}]' | xs_own_heads))"
# hostile head names are not treated as sync heads
expect "odd head" "v3.7.10 true []" "$(sel "${loki} v3.7.10" v3.7.9 'sync/v3.7.9;rm' 'sync/')"

expect "prev same line" "v3.7.8" "$(printf '%s\n' ${loki} | tr ' ' '\n' | xs_prev_tag v3.7.9)"
expect "prev across minor" "v3.6.12" "$(printf '%s\n' ${loki} | tr ' ' '\n' | xs_prev_tag v3.7.0)"

expect "md paths" "$(printf -- "- \`a b\`\n- \`x'y\`\n- \`l1?l2\`")" "$(printf 'a b\0x`y\0l1\nl2\0' | xs_md_paths)"
expect "plain paths" "- @types/x" "$(printf '@types/x\0' | xs_md_paths plain)"

# retry with backoff on throttling, no retry on other errors
cf="$(mktemp)"
echo 0 > "${cf}"
gh() {
  local calls
  calls=$(($(cat "${cf}") + 1))
  echo "${calls}" > "${cf}"
  if ((calls <= 2)); then echo "gh: HTTP 429 You have exceeded a secondary rate limit" >&2; return 1; fi
  echo '{"sha":"abc"}'
}
echo '{}' > /tmp/xs-test-empty.json
XS_RETRY_SLEEP=0 api_call POST repos/x/y/git/blobs /tmp/xs-test-empty.json > /tmp/xs-test-out 2>&1
expect "retry throttled" "3 {\"sha\":\"abc\"}" "$(cat "${cf}") $(tail -n1 /tmp/xs-test-out)"
echo 0 > "${cf}"
gh() { echo $(($(cat "${cf}") + 1)) > "${cf}"; echo "gh: Not Found (HTTP 404)" >&2; return 1; }
XS_RETRY_SLEEP=0 api_call POST repos/x/y/git/blobs /tmp/xs-test-empty.json > /dev/null 2>&1
rc=$?
expect "no retry on 404" "1 1" "$(cat "${cf}") ${rc}"
unset -f gh
rm -f /tmp/xs-test-empty.json /tmp/xs-test-out "${cf}"

# S2: only heads the bot creates, and only lower versions, are superseded
expect "human branch kept" "v3.7.10 true []" "$(sel "${loki} v3.7.10" v3.7.9 sync/fix-conflict sync/v3.7.10-hotfix sync/my-branch)"
expect "higher head kept" "v3.7.10 true []" "$(sel "${loki} v3.7.10" v3.7.9 sync/v3.9.0)"
expect "lower bot head superseded" "v3.7.10 true [sync/v3.7.8]" "$(sel "${loki} v3.7.10" v3.7.9 sync/v3.7.8 sync/fix-x)"
# S3 input: an open PR for the target is reported so the sync can refresh it
r="$(printf '%s\n' ${loki} v3.7.10 | xs_select v3.7.9 sync/v3.7.10)"
expect "open_pr flag" "open_pr=true" "$(grep '^open_pr=' <<<"${r}")"
expect "no open_pr flag" "open_pr=false" "$(printf '%s\n' ${loki} v3.7.10 | xs_select v3.7.9 | grep '^open_pr=')"

# S1: PR state of a head, own PRs only
st() { printf '%s' "$1" | xs_pr_state; }
expect "pr none" "none" "$(st '[]')"
expect "pr closed" "closed 7" "$(st '[{"number":7,"state":"CLOSED","isCrossRepository":false}]')"
expect "pr merged" "merged 8" "$(st '[{"number":7,"state":"CLOSED","isCrossRepository":false},{"number":8,"state":"MERGED","isCrossRepository":false}]')"
expect "pr open wins" "open 9" "$(st '[{"number":7,"state":"CLOSED","isCrossRepository":false},{"number":9,"state":"OPEN","isCrossRepository":false}]')"
expect "pr fork ignored" "none" "$(st '[{"number":7,"state":"OPEN","isCrossRepository":true}]')"

# S4b: which workflows get disabled
wf="$(printf '1\t.github/workflows/xs-test.yml\tactive\n2\t.github/workflows/check.yml\tactive\n3\t.github/workflows/old.yml\tdisabled_manually\n4\t.github/workflows/images.yaml\tactive\n5\tdynamic/dependabot\tactive\n6\t.github/workflows/xs-.yml.evil/x.yml\tactive\n' | xs_workflows_to_disable | cut -f1 | tr '\n' ' ')"
expect "workflows to disable" "2 4 6 " "${wf}"

# S5: neutralise upstream text
expect "neutralize" "$(printf 'a@\xe2\x80\x8bb \xe2\x80\xb9x\xe2\x80\xba %sy' "'")" "$(printf 'a@b <x> ``y' | xs_neutralize)"
expect "neutralize fence" "no" "$(printf 'x ``` y ````` z\n' | xs_neutralize | grep -q '`' && echo yes || echo no)"

# ---------------------------------------------------------------------------
# Scratch repositories
# ---------------------------------------------------------------------------
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT

# in <repo> <command...>: run in the repository, output and status in OUT and RC.
in_repo() {
  local d="$1"
  shift
  OUT="$(cd "${d}" && "$@" 2>&1)"
  RC=$?
}
G() { git -C "${repo}" "$@"; }

# Two syncs: main = upstream tag + patch, then merge commits for v1.0.1 and v1.0.2.
repo="${scratch}/sync"
git init -q -b up "${repo}"
printf 'one\ntwo\nthree\n' > "${repo}/a.txt"
G add a.txt && G commit -q -m u0 && G tag v1.0.0
G checkout -q -b main
mkdir -p "${repo}/.github/workflows"
echo patch > "${repo}/.github/workflows/xs-x.yml"
G add . && G commit -q -m patch
G checkout -q up
printf 'one\ntwo\nthree\nfour\n' > "${repo}/a.txt" && G commit -q -am u1 && G tag v1.0.1
G tag v1.0.1-rc.1
G checkout -q main && G merge -q --no-ff -m "sync v1.0.1" v1.0.1
in_repo "${repo}" cmd_detect --base main
expect "detect after one sync" "current=v1.0.1 latest=v1.0.1 proceed=false" "$(grep -E '^(current|latest|proceed)=' <<<"${OUT}" | tr '\n' ' ' | sed 's/ $//')"
G checkout -q up
printf 'one\ntwo\nthree\nfour\nfive\n' > "${repo}/a.txt" && G commit -q -am u2 && G tag v1.0.2
G checkout -q main
in_repo "${repo}" cmd_detect --base main
expect "detect new patch after one sync" "current=v1.0.1 latest=v1.0.2 proceed=true" "$(grep -E '^(current|latest|proceed)=' <<<"${OUT}" | tr '\n' ' ' | sed 's/ $//')"
G merge -q --no-ff -m "sync v1.0.2" v1.0.2
in_repo "${repo}" cmd_detect --base main
expect "detect after two syncs" "current=v1.0.2 latest=v1.0.2 proceed=false" "$(grep -E '^(current|latest|proceed)=' <<<"${OUT}" | tr '\n' ' ' | sed 's/ $//')"
# a sync PR for the newest release is already open
G checkout -q up
printf 'one\ntwo\nthree\nfour\nfive\nsix\n' > "${repo}/a.txt" && G commit -q -am u3 && G tag v1.0.3
G checkout -q main
printf 'sync/v1.0.3\n' > "${scratch}/heads"
in_repo "${repo}" cmd_detect --base main --open-heads "${scratch}/heads"
expect "detect with open pr" "latest=v1.0.3 proceed=false" "$(grep -E '^(latest|proceed)=' <<<"${OUT}" | tr '\n' ' ' | sed 's/ $//')"
# the patch set is only our file, however many merges main has
expect "patch files after merges" ".github/workflows/xs-x.yml" "$(cd "${repo}" && patch_files v1.0.2 main | tr '\0' '\n')"

# Squash merge of v1.0.3: the content is there, the tag is not in the history.
G checkout -q -b squashed main
G checkout v1.0.3 -- a.txt
G commit -q -m "squash v1.0.3"
in_repo "${repo}" cmd_detect --base squashed
expect "squash detected" "1 yes" "${RC} $(grep -q 'already holds the content of v1.0.3' <<<"${OUT}" && echo yes || echo no)"
G checkout -q main

# Identity check with a rename: the old path must not hide behind the new one.
G checkout -q -b rename v1.0.3
G mv a.txt b.txt && G commit -q -m rename
in_repo "${repo}" cmd_check identity v1.0.3 rename
expect "rename fails identity" "1 yes yes" "${RC} $(grep -q 'a.txt differs' <<<"${OUT}" && echo yes || echo no) $(grep -q 'b.txt differs' <<<"${OUT}" && echo yes || echo no)"
G checkout -q -b okpatch v1.0.3
mkdir -p "${repo}/.github/workflows" && echo p > "${repo}/.github/workflows/xs-y.yml"
G add . && G commit -q -m ok
in_repo "${repo}" cmd_check identity v1.0.3 okpatch
expect "patch path passes identity" "0" "${RC}"
# version check: v1.0.2 sync commit that has v1.0.3 in its history is rejected
in_repo "${repo}" cmd_check version v1.0.2 okpatch
expect "newer tag in history fails version" "1" "${RC}"
in_repo "${repo}" cmd_check version v1.0.3 okpatch
expect "version ok" "0" "${RC}"

# S4a: upstream .github changes between two bases, ours excluded
G checkout -q -b gh1 v1.0.0
mkdir -p "${repo}/.github/workflows" "${repo}/.github/scripts"
echo a > "${repo}/.github/workflows/up.yml"; echo b > "${repo}/.github/workflows/del.yml"; echo x > "${repo}/.github/workflows/xs-own.yml"
echo c > "${repo}/CHANGELOG"
G add -A && G commit -q -m gh1 && G tag gh-a
echo a2 > "${repo}/.github/workflows/up.yml"; G rm -q .github/workflows/del.yml; echo n > "${repo}/.github/workflows/new.yml"; echo x2 > "${repo}/.github/workflows/xs-own.yml"; echo c2 > "${repo}/CHANGELOG"
G add -A && G commit -q -m gh2 && G tag gh-b
expect "github changes" "$(printf 'added .github/workflows/new.yml\ndeleted .github/workflows/del.yml\nmodified .github/workflows/up.yml')" "$(cd "${repo}" && xs_github_changes gh-a gh-b | LC_ALL=C sort)"
G checkout -q main

# S3: the first parent must be the current main head
G checkout -q -b s3 v1.0.3
G update-index --refresh -q
oldmain="$(G rev-parse main)"
G update-ref refs/remotes/origin/main "${oldmain}"
G checkout -q -b s3old "${oldmain}"
G merge -q --no-ff -m "sync v1.0.3" v1.0.3 2> /dev/null || { G checkout -q --theirs . 2> /dev/null; G add -A; G commit -q -m "sync v1.0.3"; }
in_repo "${repo}" cmd_check parents v1.0.3 s3old
expect "parents current main" "0" "${RC}"
G checkout -q main && printf 'x\n' > "${repo}/moved.txt" && G add moved.txt && G commit -q -m "main moved"
G update-ref refs/remotes/origin/main "$(G rev-parse main)"
in_repo "${repo}" cmd_check parents v1.0.3 s3old
expect "parents stale main" "1" "${RC}"

# api_plan: modify, delete, rename, mode change, symlink, binary.
repo="${scratch}/plan"
git init -q -b main "${repo}"
printf 'a\nb\nc\nd\ne\nf\n' > "${repo}/mod.txt"
printf 'x\ny\nz\n1\n2\n3\n' > "${repo}/ren.txt"
echo gone > "${repo}/del.txt"
echo '#!/bin/sh' > "${repo}/mode.sh"
G add . && G commit -q -m base
printf 'a\nB\nc\nd\ne\nf\n' > "${repo}/mod.txt"
G mv ren.txt ren2.txt
G rm -q del.txt
chmod +x "${repo}/mode.sh"
ln -s mod.txt "${repo}/ln"
printf '\000\001\002\377' > "${repo}/bin.dat"
G add -A && G commit -q -m head
in_repo "${repo}" api_plan "HEAD~1^{tree}" "HEAD^{tree}"
q() { jq -r "select(.path == \"$1\") | $2" <<<"${OUT}"; }
expect "plan rc" "0" "${RC}"
expect "plan modify" "100644 true" "$(q mod.txt '"\(.mode) \(.blob)"')"
expect "plan delete" "null" "$(q del.txt '.sha')"
expect "plan rename old" "null" "$(q ren.txt '.sha')"
expect "plan rename new" "100644 true" "$(q ren2.txt '"\(.mode) \(.blob)"')"
expect "plan mode only" "100755 false" "$(q mode.sh '"\(.mode) \(.blob)"')"
expect "plan symlink" "120000 true" "$(q ln '"\(.mode) \(.blob)"')"
expect "plan binary" "100644 true" "$(q bin.dat '"\(.mode) \(.blob)"')"
expect "plan entries" "7" "$(jq -s length <<<"${OUT}")"
# type change: file to symlink
G checkout -q -b typechg HEAD
rm "${repo}/mod.txt" && ln -s ln "${repo}/mod.txt" && G add -A && G commit -q -m typechg
in_repo "${repo}" api_plan "HEAD~1^{tree}" "HEAD^{tree}"
expect "plan type change" "120000 true" "$(q mod.txt '"\(.mode) \(.blob)"')"

# file to directory, directory to file, submodule
G checkout -q -b f2d main
rm "${repo}/del.txt" 2> /dev/null; echo f > "${repo}/swap" && G add -A && G commit -q -m swapfile
rm "${repo}/swap" && mkdir "${repo}/swap" && echo f > "${repo}/swap/inner" && G add -A && G commit -q -m swapdir
in_repo "${repo}" api_plan "HEAD~1^{tree}" "HEAD^{tree}"
expect "file to dir fails" "1 yes" "${RC} $(grep -q 'file to directory' <<<"${OUT}" && echo yes || echo no)"
in_repo "${repo}" api_plan "HEAD^{tree}" "HEAD~1^{tree}"
expect "dir to file fails" "1 yes" "${RC} $(grep -q 'directory to file' <<<"${OUT}" && echo yes || echo no)"
G checkout -q -b sub main
G update-index --add --cacheinfo "160000,$(G rev-parse HEAD),vendored" && G commit -q -m submodule
in_repo "${repo}" api_plan "HEAD~1^{tree}" "HEAD^{tree}"
expect "submodule fails" "1 yes" "${RC} $(grep -q 'submodule' <<<"${OUT}" && echo yes || echo no)"

# ---------------------------------------------------------------------------
# Chart layer: pure helpers
# ---------------------------------------------------------------------------
XS_TAG_REGEX="${default_tag_regex}"
XS_TAG_FORMAT="${default_tag_format}"
XS_CHART_PATHS=("${default_chart_paths[@]}")
XS_CHART_EXCLUDES=("${default_chart_excludes[@]}")

ctags="mimir-distributed-6.2.0 mimir-distributed-6.2.1 mimir-distributed-6.2.2 mimir-distributed-6.2.10 mimir-distributed-6.2.2-rc.0 mimir-distributed-6.2.0-weekly.407 mimir-distributed-beta-2.1.0-beta.1 mimir-3.2.3"
pick() { printf '%s\n' "$1" | tr ' ' '\n' | xs_chart_pick "$2"; }
expect "pick newest with the appVersion" "mimir-distributed-6.2.2" "$(pick "mimir-distributed-6.2.1 3.2.1 mimir-distributed-6.2.2 3.2.3 mimir-distributed-6.2.0 3.2.0" 3.2.3 | head -c0; printf 'mimir-distributed-6.2.1 3.2.1\nmimir-distributed-6.2.2 3.2.3\nmimir-distributed-6.2.0 3.2.0\n' | xs_chart_pick 3.2.3)"
expect "pick, no chart for the engine" "" "$(printf 'mimir-distributed-6.2.1 3.2.1\nmimir-distributed-6.2.2 3.2.3\n' | xs_chart_pick 3.2.4)"
expect "pick, two charts for one engine, numeric order" "mimir-distributed-6.2.10" "$(printf 'mimir-distributed-6.2.2 3.2.3\nmimir-distributed-6.2.10 3.2.3\n' | xs_chart_pick 3.2.3)"
expect "pick ignores weekly, rc and foreign tags" "" "$(printf 'mimir-distributed-6.2.0-weekly.407 3.2.0\nmimir-distributed-6.2.2-rc.0 3.2.0\nmimir-3.2.0 3.2.0\n' | xs_chart_pick 3.2.0)"
expect "chart version" "6.2.2" "$(xs_chart_version_of mimir-distributed-6.2.2)"
expect "chart version of an engine tag" "" "$(xs_chart_version_of mimir-3.2.3)"
expect "chart tag of" "mimir-distributed-6.2.2" "$(xs_chart_tag_of 6.2.2)"
expect "chart prev" "mimir-distributed-6.2.2" "$(printf '%s\n' ${ctags} | tr ' ' '\n' | xs_chart_prev mimir-distributed-6.2.10)"
expect "chart prev numeric" "mimir-distributed-6.2.1" "$(printf '%s\n' ${ctags} | tr ' ' '\n' | xs_chart_prev mimir-distributed-6.2.2)"
expect "chart current" "mimir-distributed-6.2.2" "$(printf 'apiVersion: v2\nversion: 6.2.2+xs.0\nappVersion: 3.2.3\n' | xs_chart_current)"
expect "chart current, bumped build" "mimir-distributed-6.2.2" "$(printf 'version: 6.2.2+xs.14\n' | xs_chart_current)"
xs_chart_current <<<'version: 6.2.2' > /dev/null && r=yes || r=no
expect "chart current needs +xs" "no" "${r}"
expect "chart app version" "3.2.3" "$(printf 'version: 6.2.2+xs.0\nappVersion: "3.2.3"\n' | xs_chart_app_version)"
for p in operations/helm/charts/mimir-distributed/values.yaml operations/helm/tests/small-values-generated/mimir-distributed/templates/a/b.yaml operations/helm/charts/mimir-distributed/templates/_helpers.tpl; do
  xs_chart_path_allowed "${p}" && r=yes || r=no
  expect "chart patch path ${p}" "yes" "${r}"
done
for p in operations/helm/charts/mimir-distributed/templates/querier/querier-dep.yaml operations/helm/charts/mimir-distributed/CHANGELOG.md docs/sources/helm-charts/x.md operations/mimir-mixin-compiled/rules.yaml; do
  xs_chart_path_allowed "${p}" && r=yes || r=no
  expect "not a chart patch path ${p}" "no" "${r}"
done
expect "bump chart" "version: 6.2.2+xs.0" "$(printf 'version: 6.2.2\n' | sed -E "$(xs_bump_sed 6.2.2 3.2.3 chart)")"
expect "bump chart leaves appVersion" "appVersion: 6.2.2" "$(printf 'appVersion: 6.2.2\n' | sed -E "$(xs_bump_sed 6.2.2 3.2.3 chart)")"
expect "bump readme" "$(printf '> **Note:** The documentation version is derived from the Helm chart version which is 6.2.2+xs.0.\n![Version: 6.2.2+xs.0](https://img.shields.io/badge/Version-6.2.2+xs.0-informational?style=flat-square) ![AppVersion: 3.2.3](https://img.shields.io/badge/AppVersion-3.2.3-informational?style=flat-square)')" "$(printf '> **Note:** The documentation version is derived from the Helm chart version which is 6.2.2.\n![Version: 6.2.2](https://img.shields.io/badge/Version-6.2.2-informational?style=flat-square) ![AppVersion: 3.2.3](https://img.shields.io/badge/AppVersion-3.2.3-informational?style=flat-square)' | sed -E "$(xs_bump_sed 6.2.2 3.2.3 readme)")"
expect "bump values" "  engineTag: 3.2.4-xs.0" "$(printf '  engineTag: 3.2.3-xs.0\n' | sed -E "$(xs_bump_sed 6.2.2 3.2.4 values)")"

# ---------------------------------------------------------------------------
# api_commit: blobs the remote already holds are not uploaded, throttled calls retry
# ---------------------------------------------------------------------------
repo="${scratch}/api"
mock_repo="${repo}"
git init -q -b main "${repo}"
echo old > "${repo}/keep.txt"
G add . && G commit -q -m base
mkdir -p "${repo}/known"
echo known > "${repo}/known/k.txt"
G add . && G commit -q -m known
known_tree="$(G rev-parse "HEAD^{tree}")"
echo fresh > "${repo}/fresh.txt"
echo known2 > "${repo}/known2.txt"
G add . && G commit -q -m result
result_tree="$(G rev-parse "HEAD^{tree}")"
G checkout -q -b other "${known_tree}" 2> /dev/null || true
# A tree that holds the contents of known2.txt on another path stands for a mirrored tag.
tag_tree="$(printf '100644 blob %s\ttagfile.txt\n' "$(printf 'known2\n' | G hash-object --stdin)" | G mktree)"
cf="$(mktemp)"
: > "${cf}"
gh() {
  # gh api --method POST <endpoint> --input <file>
  local endpoint="$4" input="$6"
  echo "${endpoint##*/}" >> "${cf}"
  case "${endpoint##*/}" in
    blobs) jq -r .content "${input}" | base64 -d | git -C "${mock_repo}" hash-object --stdin | jq -R '{sha: .}' ;;
    trees) jq -n --arg s "${MOCK_TREE}" '{sha: $s}' ;;
    commits) jq -n '{sha: "0000000000000000000000000000000000000001"}' ;;
  esac
}
echo m > "${scratch}/msg"
export GITHUB_REPOSITORY=x/y MOCK_TREE="${result_tree}" XS_BLOB_PACE=0
in_repo "${repo}" bash -c "$(declare -f gh api_call api_commit api_plan log die repo_slug); GITHUB_REPOSITORY=x/y; $(declare -p MOCK_TREE XS_BLOB_PACE cf mock_repo | sed 's/^declare -- /export /;s/^declare -x /export /'); API_KNOWN_TREES=(); api_commit '${known_tree}' '${result_tree}' '${scratch}/msg' 0000000000000000000000000000000000000002"
expect "api_commit uploads blobs not in the base tree" "blobs blobs trees commits" "$(tr '\n' ' ' < "${cf}" | sed 's/ $//')"
: > "${cf}"
in_repo "${repo}" bash -c "$(declare -f gh api_call api_commit api_plan log die repo_slug); GITHUB_REPOSITORY=x/y; $(declare -p MOCK_TREE XS_BLOB_PACE cf mock_repo | sed 's/^declare -- /export /;s/^declare -x /export /'); API_KNOWN_TREES=('${tag_tree}'); api_commit '${known_tree}' '${result_tree}' '${scratch}/msg' 0000000000000000000000000000000000000002"
expect "api_commit skips blobs found in a known tree" "blobs trees commits" "$(tr '\n' ' ' < "${cf}" | sed 's/ $//')"
unset -f gh
rm -f "${cf}"
unset MOCK_TREE

# throttling with 5xx and the secondary rate limit text is retried, up to the attempt cap
cf="$(mktemp)"
echo 0 > "${cf}"
echo '{}' > "${scratch}/empty.json"
gh() {
  local calls
  calls=$(($(cat "${cf}") + 1))
  echo "${calls}" > "${cf}"
  if ((calls < 8)); then echo "gh: You have exceeded a secondary rate limit. Please wait a few minutes (HTTP 403)" >&2; return 1; fi
  echo '{"sha":"abc"}'
}
XS_RETRY_SLEEP=0 api_call POST repos/x/y/git/blobs "${scratch}/empty.json" > "${scratch}/o" 2> /dev/null
expect "retry survives seven throttled attempts" "8 {\"sha\":\"abc\"}" "$(cat "${cf}") $(tail -n1 "${scratch}/o")"
echo 0 > "${cf}"
gh() { echo $(($(cat "${cf}") + 1)) > "${cf}"; echo "gh: HTTP 502 Bad Gateway" >&2; return 1; }
XS_RETRY_SLEEP=0 api_call POST repos/x/y/git/blobs "${scratch}/empty.json" > /dev/null 2>&1
expect "retry gives up after eight attempts" "8" "$(cat "${cf}")"
unset -f gh
rm -f "${cf}"

# ---------------------------------------------------------------------------
# Two layers: engine tag + engine patch, chart tag + chart patch
# ---------------------------------------------------------------------------
repo="${scratch}/two"
git init -q -b up "${repo}"
CD=operations/helm/charts/mimir-distributed
mkchart() { # <chart-version> <app-version> <note>: write the chart paths as an upstream chart release
  rm -rf "${repo}/operations" "${repo}/docs"
  mkdir -p "${repo}/${CD}/templates" "${repo}/operations/helm/tests/x-generated" "${repo}/operations/mimir-mixin-compiled" "${repo}/docs/sources/helm-charts"
  printf 'apiVersion: v2\nversion: %s\nappVersion: %s\n' "$1" "$2" > "${repo}/${CD}/Chart.yaml"
  printf '# chart\n> The documentation version is derived from the Helm chart version which is %s.\n![Version: %s](https://img.shields.io/badge/Version-%s-informational?style=flat-square)\n' "$1" "$1" "$1" > "${repo}/${CD}/README.md"
  printf '# values\n\nnameOverride: null\n\nimage:\n  repository: docker.io/grafana/mimir\n  # tag: 1.0.0\n\n%s\n' "$3" > "${repo}/${CD}/values.yaml"
  printf '{{- define "x.image" -}}\n{{ .repo }}:{{ .tag | default .app }}\n{{- end -}}\n' > "${repo}/${CD}/templates/_helpers.tpl"
  printf 'kind: Deployment\n# %s\n' "$3" > "${repo}/${CD}/templates/dep.yaml"
  printf 'image: grafana/mimir:%s\nlabel: %s\n' "$2" "$1" > "${repo}/operations/helm/tests/x-generated/out.yaml"
  printf 'alerts for %s\n' "$2" > "${repo}/operations/mimir-mixin-compiled/alerts.yaml"
  printf 'doc %s\n' "$1" > "${repo}/docs/sources/helm-charts/doc.md"
  printf 'one\ntwo\n' > "${repo}/operations/helm/tests/x-generated/keep.txt"
}
# stands in for the regeneration script: derived from the chart in the directory
# shellcheck disable=SC2016 # the command runs later, in the materialised chart directory
export XS_CHART_REGEN_CMD='rm -rf operations/helm/tests && mkdir -p operations/helm/tests/x-generated && { echo "image: $(sed -n "s/^  repository: //p" operations/helm/charts/mimir-distributed/values.yaml)"; sed -n "s/^version: /label: /p" operations/helm/charts/mimir-distributed/Chart.yaml; } > operations/helm/tests/x-generated/out.yaml'
helm() { :; }
for v in 1.0.0 1.0.1 1.0.2; do
  printf 'engine %s\n' "${v}" > "${repo}/VERSION"
  printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11 %s\n' "${v}" > "${repo}/code.txt"
  mkchart 0.0.0 "${v}" "old chart in the engine tag"
  G add -A && G commit -q -m "engine ${v}" && G tag "mimir-${v}"
done
# chart releases live on their own commits, like upstream's release tags
for pair in "2.0.0 1.0.0" "2.0.1 1.0.1"; do
  set -- ${pair}
  G checkout -q --detach mimir-"$2"
  mkchart "$1" "$2" "chart $1"
  G add -A && G commit -q -m "chart $1" && G tag "mimir-distributed-$1"
done
G checkout -q up
# main: engine 1.0.0 + our engine patch + chart 2.0.0 + our chart patch
G checkout -q -b main mimir-1.0.0
mkdir -p "${repo}/.github/workflows" && echo patch > "${repo}/.github/workflows/xs-x.yml"
G checkout -q mimir-distributed-2.0.0 -- operations docs
G rm -q -r --cached operations docs && rm -rf "${repo}/operations" "${repo}/docs"
G checkout -q mimir-distributed-2.0.0 -- operations docs
sed -i 's#docker.io/grafana/mimir#ghcr.io/xscaler/mimir#; s#^version: 2.0.0#version: 2.0.0+xs.0#' "${repo}/${CD}/values.yaml" "${repo}/${CD}/Chart.yaml"
sed -i 's#Helm chart version which is 2.0.0\.#Helm chart version which is 2.0.0+xs.0.#; s#Version: 2.0.0\]#Version: 2.0.0+xs.0]#; s#Version-2.0.0-#Version-2.0.0+xs.0-#' "${repo}/${CD}/README.md"
sed -i 's#^nameOverride: null#nameOverride: null\nxscaler:\n  engineTag: 1.0.0-xs.0#' "${repo}/${CD}/values.yaml"
printf '{{- define "x.image" -}}\n{{ .repo }}:{{ .tag | default .app }}\n{{/* xs */}}\n{{- end -}}\n' > "${repo}/${CD}/templates/_helpers.tpl"
printf 'image: ghcr.io/xscaler/mimir\nlabel: 2.0.0+xs.0\n' > "${repo}/operations/helm/tests/x-generated/out.yaml"
G add -A && G commit -q -m "main"
main_ref=main
main_tree="$(G rev-parse "HEAD^{tree}")"

# selection helpers on the real tags
expect "chart tag for the new engine" "mimir-distributed-2.0.1" "$(cd "${repo}" && chart_tag_for 1.0.1)"
expect "no chart tag for an engine without a chart" "" "$(cd "${repo}" && chart_tag_for 1.0.2)"
expect "current chart of main" "mimir-distributed-2.0.0" "$(cd "${repo}" && chart_current_tag "${main_tree}")"
expect "engine patch files exclude the chart paths" ".github/workflows/xs-x.yml" "$(cd "${repo}" && patch_files mimir-1.0.0 "${main_tree}" | tr '\0' '\n')"
expect "chart patch files" "$(printf '%s\n' ${CD}/Chart.yaml ${CD}/README.md ${CD}/templates/_helpers.tpl ${CD}/values.yaml)" "$(cd "${repo}" && chart_patch_files mimir-distributed-2.0.0 "${main_tree}" | tr '\0' '\n')"

# build both layers into a scratch index, the way cmd_build does
two_layers() { # <engine-tag> <out-index> -> RC, OUT; prints nothing on stdout
  local tag="$1" idx="$2" w cur ev
  w="$(mktemp -d)"
  cur="$(git tag --merged "${main_ref}" | xs_highest_stable)"
  ev="$(xs_version_of "${tag}")"
  git diff --no-renames "${cur}" "${main_tree}" --binary --full-index -- . "${XS_CHART_EXCLUDES[@]}" > "${w}/p"
  apply_patch "${w}/p" "${tag}" "${idx}" 3> "${w}/c" || { cat "${w}/c"; return 1; }
  chart_layer "${main_tree}" "${ev}" "${idx}" "${w}" 3>> "${w}/c" || { cat "${w}/c"; return 1; }
  chart_finish "${idx}" "${ev}" "${tag}"
}
# expected result for 1.0.1: engine tag + engine patch, chart tag + chart patch with the bumps
exp="$(cd "${repo}" && {
  G checkout -q -b expect mimir-1.0.1
  mkdir -p .github/workflows && echo patch > .github/workflows/xs-x.yml
  G rm -q -r --cached operations docs && rm -rf operations docs
  G checkout -q mimir-distributed-2.0.1 -- operations docs
  sed -i 's#docker.io/grafana/mimir#ghcr.io/xscaler/mimir#; s#^version: 2.0.1#version: 2.0.1+xs.0#' "${CD}/values.yaml" "${CD}/Chart.yaml"
  sed -i 's#Helm chart version which is 2.0.1\.#Helm chart version which is 2.0.1+xs.0.#; s#Version: 2.0.1\]#Version: 2.0.1+xs.0]#; s#Version-2.0.1-#Version-2.0.1+xs.0-#' "${CD}/README.md"
  sed -i 's#^nameOverride: null#nameOverride: null\nxscaler:\n  engineTag: 1.0.1-xs.0#' "${CD}/values.yaml"
  printf '{{- define "x.image" -}}\n{{ .repo }}:{{ .tag | default .app }}\n{{/* xs */}}\n{{- end -}}\n' > "${CD}/templates/_helpers.tpl"
  printf 'image: ghcr.io/xscaler/mimir\nlabel: 2.0.1+xs.0\n' > operations/helm/tests/x-generated/out.yaml
  rm -f operations/helm/tests/x-generated/keep.txt
  G add -A && G write-tree
})"
G reset -q --hard && G checkout -q main
idx="${scratch}/idx1"
in_repo "${repo}" two_layers mimir-1.0.1 "${idx}"
expect "two layers build rc" "0" "${RC}"
got="$(GIT_INDEX_FILE="${idx}" git -C "${repo}" write-tree)"
expect "two layers tree equals the expected tree" "${exp}" "${got}"
expect "chart moved" "moved mimir-distributed-2.0.0 mimir-distributed-2.0.1" "${CHART_MODE:-moved} ${CHART_CUR:-mimir-distributed-2.0.0} ${CHART_NEW:-mimir-distributed-2.0.1}"

# the result passes the identity check, with the chart paths compared to the chart release
G checkout -q -b result "$(printf 'r\n' | G commit-tree "${got}" -p main -p mimir-1.0.1)" 2> /dev/null || G checkout -q -b result "$(printf 'r\n' | G commit-tree "${got}" -p main -p mimir-1.0.1)"
in_repo "${repo}" cmd_check identity mimir-1.0.1 result
expect "two layer result passes identity" "0 yes" "${RC} $(grep -q 'chart identity OK' <<<"${OUT}" && echo yes || echo no)"
in_repo "${repo}" cmd_check version mimir-1.0.1 result
expect "two layer result passes version" "0" "${RC}"
# a chart file nobody patched differs from the chart release
G checkout -q -b badchart result
echo extra >> "${repo}/${CD}/templates/dep.yaml" && G commit -q -am badchart
in_repo "${repo}" cmd_check identity mimir-1.0.1 badchart
expect "chart path outside the chart patch fails" "1 yes" "${RC} $(grep -q "templates/dep.yaml differs from mimir-distributed-2.0.1" <<<"${OUT}" && echo yes || echo no)"
# the engine tag's own copy of a chart path is not the reference
G checkout -q -b enginechart result
git -C "${repo}" show mimir-1.0.1:"${CD}/templates/dep.yaml" > "${repo}/${CD}/templates/dep.yaml" && G commit -q -am enginechart
in_repo "${repo}" cmd_check identity mimir-1.0.1 enginechart
expect "chart paths equal to the engine tag fail" "1" "${RC}"
# an engine file outside the patch fails even in the two layer layout
G checkout -q -b badengine result
echo x > "${repo}/other.txt" && G add -A && G commit -q -m badengine
in_repo "${repo}" cmd_check identity mimir-1.0.1 badengine
expect "engine path outside the patch fails" "1 yes" "${RC} $(grep -q 'other.txt differs from mimir-1.0.1' <<<"${OUT}" && echo yes || echo no)"
# a chart patch path may differ
G checkout -q -b okchart result
echo '# more' >> "${repo}/${CD}/values.yaml" && G commit -q -am okchart
in_repo "${repo}" cmd_check identity mimir-1.0.1 okchart
expect "chart patch path may differ" "0" "${RC}"
G checkout -q main

# no chart release for the engine yet: the chart import stays as it is
idx="${scratch}/idx2"
in_repo "${repo}" two_layers mimir-1.0.2 "${idx}"
got2="$(GIT_INDEX_FILE="${idx}" git -C "${repo}" write-tree)"
expect "kept chart: rc" "0" "${RC}"
expect "kept chart: chart paths equal main" "" "$(git -C "${repo}" diff --name-only "${main_tree}" "${got2}" -- "${XS_CHART_PATHS[@]}")"
expect "kept chart: engine paths are the new tag plus the patch" ".github/workflows/xs-x.yml" "$(git -C "${repo}" diff --name-only mimir-1.0.2 "${got2}" -- . "${XS_CHART_EXCLUDES[@]}")"
expect "kept chart: note" "yes" "$(in_repo "${repo}" chart_note 1.0.2; grep -q 'no chart release' <<<"${OUT}" && echo yes || echo no)"

# a conflict in the chart layer is reported, the engine layer is still tried
G checkout -q -b chartconflict main
printf '# values\nCONFLICT\n' > "${repo}/${CD}/values.yaml"
G commit -q -am chartconflict
main_tree_save="${main_tree}"
main_ref=chartconflict
main_tree="$(G rev-parse "HEAD^{tree}")"
idx="${scratch}/idx3"
in_repo "${repo}" two_layers mimir-1.0.1 "${idx}"
expect "chart conflict: rc and file" "1 yes" "${RC} $(grep -q "values.yaml" <<<"${OUT}" && echo yes || echo no)"
main_tree="${main_tree_save}"
main_ref=main
G checkout -q main

# Regeneration is token-less and its result travels as data
gold="${scratch}/gold"
rm -rf "${gold}"
(
  XS_CHART_GOLDENS_OUT="${gold}"
  idxp="${scratch}/idxp"
  cd "${repo}" && two_layers mimir-1.0.1 "${idxp}"
) > /dev/null 2>&1
expect "prepare writes the regenerated records and the Helm version" "yes yes" "$([[ -f "${gold}/operations/helm/tests/x-generated/out.yaml" ]] && echo yes || echo no) $(grep -q '^helm=' "${gold}/.xs-meta" && echo yes || echo no)"
idx="${scratch}/idxi"
(XS_CHART_GOLDENS_IN="${gold}"; cd "${repo}"; two_layers mimir-1.0.1 "${idx}") > /dev/null 2>&1
expect "import of the prepared records gives the same tree as regenerating in place" "${exp}" "$(GIT_INDEX_FILE="${idx}" git -C "${repo}" write-tree)"
ln -s /etc/passwd "${gold}/operations/helm/tests/x-generated/evil"
(XS_CHART_GOLDENS_IN="${gold}"; cd "${repo}"; two_layers mimir-1.0.1 "${scratch}/idxe") > /dev/null 2>&1
expect "import rejects a symlink" "1" "$?"
rm -f "${gold}/operations/helm/tests/x-generated/evil"
echo x > "${gold}/outside.txt"
(XS_CHART_GOLDENS_IN="${gold}"; cd "${repo}"; two_layers mimir-1.0.1 "${scratch}/idxo") > /dev/null 2>&1
expect "import rejects a path outside the derived paths" "1" "$?"
rm -f "${gold}/outside.txt"
in_repo "${repo}" env GH_TOKEN=x bash -c "$(declare -f die log chart_regen_run); XS_CHART_DERIVED_PATHS=(operations/helm/tests); chart_regen_run /nonexistent ${scratch}/o"
expect "regeneration refuses to run with a token" "1 yes" "${RC} $(grep -q 'GitHub token' <<<"${OUT}" && echo yes || echo no)"
expect "build image helm version" "4.2.3" "$(printf 'FROM alpine/helm:4.2.3@sha256:abc AS helm\n' | sed -n -E "${XS_CHART_BUILD_IMAGE_HELM_SED}")"

# main's Chart.yaml carries an edit of ours beyond the version: the bump would drop it
G checkout -q -b chartedit main
sed -i 's#^appVersion: 1.0.0#appVersion: 1.0.0\ndescription: ours#' "${repo}/${CD}/Chart.yaml"
G commit -q -am chartedit
main_tree_save="${main_tree}"
main_tree="$(G rev-parse "HEAD^{tree}")"
main_ref=chartedit
in_repo "${repo}" two_layers mimir-1.0.1 "${scratch}/idxc"
expect "a non-version edit of Chart.yaml fails the chart layer" "1 yes" "${RC} $(grep -q "Chart.yaml" <<<"${OUT}" && echo yes || echo no)"
main_tree="${main_tree_save}"
main_ref=main
G checkout -q main

# the README bump fails when one expected pattern is gone
G checkout -q -b readmegone mimir-distributed-2.0.1
sed -i '/img.shields.io/d' "${repo}/${CD}/README.md"
G commit -q -am readmegone
rtree="$(G rev-parse "HEAD^{tree}")"
G checkout -q main
ridx="${scratch}/ridx"
(cd "${repo}" && GIT_INDEX_FILE="${ridx}" git read-tree "${rtree}" && chart_bump "${ridx}" mimir-distributed-2.0.1 1.0.1) > /dev/null 2>&1
expect "readme bump fails when a pattern no longer matches" "1" "$?"

# Chart-only catch-up (M2), pure
cc() { # <engine-version> <chart-current> <chart lines (; separated)> [heads...] -> "chart_latest proceed [supersede]"
  local ev="$1" cur="$2" lines="$3" r
  shift 3
  r="$(printf '%s\n' "${lines}" | tr ';' '\n' | xs_chart_catchup "${ev}" "${cur}" "$@")"
  printf '%s %s [%s]\n' "$(grep '^chart_latest=' <<<"${r}" | cut -d= -f2)" "$(grep '^chart_proceed=' <<<"${r}" | cut -d= -f2)" "$(grep '^chart_supersede=' <<<"${r}" | cut -d= -f2)"
}
cl="mimir-distributed-6.2.1 3.2.1;mimir-distributed-6.2.2 3.2.3;mimir-distributed-6.2.3 3.2.3"
expect "catch-up: newer chart for the same engine" "mimir-distributed-6.2.3 true []" "$(cc 3.2.3 mimir-distributed-6.2.2 "${cl}")"
expect "catch-up: chart already current" " false []" "$(cc 3.2.3 mimir-distributed-6.2.3 "${cl}")"
expect "catch-up: no chart for the engine" " false []" "$(cc 3.2.4 mimir-distributed-6.2.3 "${cl}")"
expect "catch-up: pr open for the target" "mimir-distributed-6.2.3 false []" "$(cc 3.2.3 mimir-distributed-6.2.2 "${cl}" sync/mimir-distributed-6.2.3)"
expect "catch-up: older chart pr superseded" "mimir-distributed-6.2.3 true [sync/mimir-distributed-6.2.2]" "$(cc 3.2.3 mimir-distributed-6.2.1 "${cl}" sync/mimir-distributed-6.2.2)"
expect "catch-up: engine heads are not chart heads" "mimir-distributed-6.2.3 true []" "$(cc 3.2.3 mimir-distributed-6.2.2 "${cl}" sync/mimir-3.2.3 sync/hotfix-x)"
expect "catch-up: stale chart pr superseded when main caught up" " false [sync/mimir-distributed-6.2.2]" "$(cc 3.2.3 mimir-distributed-6.2.3 "${cl}" sync/mimir-distributed-6.2.2)"
# S2: only bot heads, only lower versions
expect "supersede ignores other sync names" "mimir-3.2.4 true [sync/mimir-3.2.3]" "$(printf '%s\n' mimir-3.2.3 mimir-3.2.4 | xs_select mimir-3.2.2 sync/mimir-3.2.3 sync/fix-3.2.3 sync/mimir-distributed-6.2.2 | tr '\n' ' ' | sed -E 's/.*latest=([^ ]*) proceed=([^ ]*) .*supersede=(.*) $/\1 \2 [\3]/')"
expect "supersede never closes a higher head" "mimir-3.2.3 true []" "$(printf '%s\n' mimir-3.2.3 | xs_select mimir-3.2.2 sync/mimir-3.2.9 | tr '\n' ' ' | sed -E 's/.*latest=([^ ]*) proceed=([^ ]*) .*supersede=(.*) $/\1 \2 [\3]/')"

# Chart-only build and detect on the scratch repository
G checkout -q --detach mimir-1.0.0
mkchart 2.0.2 1.0.0 "chart 2.0.2"
G add -A && G commit -q -m "chart 2.0.2" && G tag mimir-distributed-2.0.2
G checkout -q main
expect "chart tag for the current engine moves" "mimir-distributed-2.0.2" "$(cd "${repo}" && chart_tag_for 1.0.0)"
git_dir="${repo}"
detect_out() { (cd "${git_dir}" && detect_chart main mimir-1.0.0 mimir-1.0.0 "$@" 2>&1 | grep -E '^(chart_proceed|chart_open_pr|chart_tag|chart_head|chart_supersede)=' | tr '\n' ' ' | sed 's/ $//'); }
expect "detect proceeds with a chart-only sync" "chart_proceed=true chart_open_pr=false chart_tag=mimir-distributed-2.0.2 chart_head=sync/mimir-distributed-2.0.2 chart_supersede=" "$(detect_out)"
expect "detect reports an open chart-only PR" "chart_proceed=false chart_open_pr=true chart_tag=mimir-distributed-2.0.2 chart_head=sync/mimir-distributed-2.0.2 chart_supersede=" "$(detect_out sync/mimir-distributed-2.0.2)"
expect "a pending engine release supersedes chart-only PRs and starts none" "chart_proceed=false chart_open_pr=false chart_tag= chart_head= chart_supersede=sync/mimir-distributed-2.0.2" "$(cd "${git_dir}" && detect_chart main mimir-1.0.0 mimir-1.0.1 sync/mimir-distributed-2.0.2 sync/mimir-1.0.1 2>&1 | grep -E '^(chart_proceed|chart_open_pr|chart_tag|chart_head|chart_supersede)=' | tr '\n' ' ' | sed 's/ $//')"
idx="${scratch}/idxco"
in_repo "${repo}" two_layers mimir-1.0.0 "${idx}"
expect "chart-only build rc" "0" "${RC}"
cexp="$(cd "${repo}" && {
  G checkout -q -b cexpect main
  G rm -q -r --cached operations docs && rm -rf operations docs
  G checkout -q mimir-distributed-2.0.2 -- operations docs
  sed -i 's#docker.io/grafana/mimir#ghcr.io/xscaler/mimir#; s#^version: 2.0.2#version: 2.0.2+xs.0#' "${CD}/values.yaml" "${CD}/Chart.yaml"
  sed -i 's#Helm chart version which is 2.0.2\.#Helm chart version which is 2.0.2+xs.0.#; s#Version: 2.0.2\]#Version: 2.0.2+xs.0]#; s#Version-2.0.2-#Version-2.0.2+xs.0-#' "${CD}/README.md"
  sed -i 's#^nameOverride: null#nameOverride: null\nxscaler:\n  engineTag: 1.0.0-xs.0#' "${CD}/values.yaml"
  printf '{{- define "x.image" -}}\n{{ .repo }}:{{ .tag | default .app }}\n{{/* xs */}}\n{{- end -}}\n' > "${CD}/templates/_helpers.tpl"
  printf 'image: ghcr.io/xscaler/mimir\nlabel: 2.0.2+xs.0\n' > operations/helm/tests/x-generated/out.yaml
  rm -f operations/helm/tests/x-generated/keep.txt
  G add -A && G write-tree
})"
G reset -q --hard && G checkout -q main
expect "chart-only tree is main's engine plus the new chart" "${cexp}" "$(GIT_INDEX_FILE="${idx}" git -C "${repo}" write-tree)"

# Supersede closes chart heads too (chart layer on) and names the new target
calls="$(mktemp)"
gh() {
  echo "gh $*" >> "${calls}"
  case "$1 $2" in
    "pr list") echo 7 ;;
    "issue list") ;;
  esac
}
export GITHUB_REPOSITORY=x/y
: > "${calls}"
cmd_supersede mimir-distributed-2.0.3 sync/mimir-distributed-2.0.2 sync/mimir-1.0.1 sync/hotfix-x sync/mimir-distributed-oops > /dev/null 2>&1
expect "supersede closes a chart head and an engine head with the target named" "gh pr close 7 --comment superseded by mimir-distributed-2.0.3|gh pr close 7 --comment superseded by mimir-distributed-2.0.3" "$(grep '^gh pr close' "${calls}" | tr '\n' '|' | sed 's/|$//')"
expect "supersede deletes only the two bot branches" "2" "$(grep -c 'DELETE' "${calls}")"
XS_CHART_PATHS=()
: > "${calls}"
cmd_supersede mimir-1.0.2 sync/mimir-distributed-2.0.2 > /dev/null 2>&1
expect "supersede leaves chart heads alone without a chart layer" "0" "$(grep -c '^gh pr close' "${calls}")"
XS_CHART_PATHS=("${default_chart_paths[@]}")

# branch_tip_is_bot: author, committer, signature
tipinfo() { printf '2\t%s\tchore(sync): sync upstream %s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7"; }
gh() {
  case "$2" in
    *git/ref/heads/*) echo "${MOCK_REF:-aaaa}" ;;
    *git/commits/*) printf '%s\n' "${MOCK_INFO}" ;;
  esac
}
bot_email="${XS_BOT_EMAIL}"
mock_tip() { MOCK_INFO="$1"; tip_ok=no; branch_tip_is_bot sync/mimir-1.0.1 mimir-1.0.1 cccc && tip_ok=yes; echo "${tip_ok}"; }
expect "bot tip accepted" "yes" "$(mock_tip "$(tipinfo cccc mimir-1.0.1 "${XS_BOT_LOGIN}" "${bot_email}" GitHub noreply@github.com true)")"
expect "human author refused" "no" "$(mock_tip "$(tipinfo cccc mimir-1.0.1 someone someone@example.com GitHub noreply@github.com true)")"
expect "bot author with a human committer refused" "no" "$(mock_tip "$(tipinfo cccc mimir-1.0.1 "${XS_BOT_LOGIN}" "${bot_email}" someone someone@example.com true)")"
expect "unverified bot commit refused" "no" "$(mock_tip "$(tipinfo cccc mimir-1.0.1 "${XS_BOT_LOGIN}" "${bot_email}" GitHub noreply@github.com false)")"
expect "wrong second parent refused" "no" "$(mock_tip "$(tipinfo dddd mimir-1.0.1 "${XS_BOT_LOGIN}" "${bot_email}" GitHub noreply@github.com true)")"
# the ref is moved only when the tip is still the one that was checked
: > "${calls}"
gh() { echo "gh $*" >> "${calls}"; case "$2" in *git/ref/heads/*) echo "${MOCK_REF}" ;; esac; }
MOCK_REF=aaaa api_ref_set_if sync/mimir-1.0.1 bbbb aaaa > /dev/null 2>&1
expect "ref update goes ahead when the tip is unchanged" "1" "$(grep -c 'git/refs' "${calls}")"
: > "${calls}"
MOCK_REF=zzzz api_ref_set_if sync/mimir-1.0.1 bbbb aaaa > /dev/null 2>&1
expect "ref update is refused when the tip moved" "1 0" "$? $(grep -c 'git/refs' "${calls}")"
unset -f gh
rm -f "${calls}"

# the golden record limits
lim="${scratch}/lim"
rm -rf "${lim}" && mkdir -p "${lim}/a" && echo x > "${lim}/a/1" && echo y > "${lim}/a/2"
(chart_goldens_limits "${lim}") > /dev/null 2>&1
expect "limits accept a small tree" "0" "$?"
(XS_CHART_GOLDENS_MAX_FILES=1 chart_goldens_limits "${lim}") > /dev/null 2>&1
expect "limits refuse too many files" "1" "$?"
(XS_CHART_GOLDENS_MAX_BYTES=3 chart_goldens_limits "${lim}") > /dev/null 2>&1
expect "limits refuse too many bytes" "1" "$?"
ln -s /etc/passwd "${lim}/a/link"
(chart_goldens_limits "${lim}") > /dev/null 2>&1
expect "limits refuse a symlink" "1" "$?"
unset -f helm

echo "pass=${pass} fail=${fail}"
[[ "${fail}" -eq 0 ]]
