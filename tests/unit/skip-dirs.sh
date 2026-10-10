#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/skip-dirs.sh
# Unit test for the shared directory-skip selector (skip-dirs.lib.sh): the category defaults, the per-consumer skip sets
# the lib owns, the optional skip_git override, the operator.conf category overrides (parsed, not sourced),
# and the `-type d` matcher that skips DIRECTORIES only -- so a file sharing a skipped name is still walked. Sources
# the deployed library and exercises a /tmp testdir; does not require privilege of its own. Run as root via sudo (suite
# contract).

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

readonly SKIP_DIRS_LIB="/usr/local/lib/ai-tools/skip-dirs.lib.sh"
section "skip-dirs: categories, per-consumer defaults, -type d matcher (unit)"

if [[ ! -r "${SKIP_DIRS_LIB}" ]]; then
    skip "skip-dirs" "library not readable at ${SKIP_DIRS_LIB}"; finish; exit
fi

# names_for <consumer> [skip_git]: echo the flat skip-name list the lib produces.
names_for() { ai_tools_skip_dirs__build_find_expression "$@"; printf '%s' "${AI_TOOLS_SKIP_DIRS__NAMES[*]}"; }

# (1) Defaults with no operator.conf overrides.
export AI_TOOLS_OPERATOR_CONF=/nonexistent
# shellcheck source=/dev/null
source "${SKIP_DIRS_LIB}"

if [[ "${AI_TOOLS_SKIP_VCS_DIRS[*]}" == ".git" \
      && "${AI_TOOLS_SKIP_ARTIFACT_DIRS[*]:-}" == "" ]]; then
    pass "category defaults are set (VCS=.git, ARTIFACT empty -- build-output skip is opt-in)"
else
    fail "category defaults: VCS='${AI_TOOLS_SKIP_VCS_DIRS[*]}' ARTIFACT='${AI_TOOLS_SKIP_ARTIFACT_DIRS[*]:-}'"
fi

# (2) Per-consumer defaults (lib-owned): handback/normalization consumers skip .git + heavy.
handback_ok=true
for consumer in sweep setgid setfacl unclaim; do
    [[ " $(names_for "${consumer}") " == *" .git "* ]] \
        || { fail "${consumer} should skip .git by default"; handback_ok=false; }
done
${handback_ok} && pass "sweep/setgid/setfacl/unclaim skip .git + heavy trees"

# reclaim WALKS .git but skips the heavy trees; reclaim-full descends everywhere.
if [[ " $(names_for reclaim) " != *" .git "* && " $(names_for reclaim) " == *" node_modules "* ]]; then
    pass "reclaim walks .git but skips the heavy trees"
else
    fail "reclaim names: $(names_for reclaim)"
fi
if [[ -z "$(names_for reclaim-full)" ]]; then
    pass "reclaim-full skips nothing"
else
    fail "reclaim-full names: $(names_for reclaim-full)"
fi
# The secret sweep is not a consumer: ai-tools-lockdown fixes its own `.git` prune, since a name an operator adds
# to a category here must not reopen a tree the claim exposes (tests/unit/lockdown.sh drives that walk).
if ai_tools_skip_dirs__build_find_expression lockdown 2>/dev/null; then
    fail "lockdown is accepted as a consumer: ${AI_TOOLS_SKIP_DIRS__NAMES[*]}"
else
    pass "lockdown is not a consumer of the skip list"
fi

# (3) Optional skip_git override: reclaim true adds .git; sweep false drops it.
[[ " $(names_for reclaim true) " == *" .git "* ]] \
    && pass "skip_git=true override adds .git to reclaim" \
    || fail "override reclaim true: $(names_for reclaim true)"
[[ " $(names_for sweep false) " != *" .git "* ]] \
    && pass "skip_git=false override drops .git from sweep" \
    || fail "override sweep false: $(names_for sweep false)"

# (4) Unknown consumer is rejected.
if ai_tools_skip_dirs__build_find_expression bogus 2>/dev/null; then
    fail "unknown consumer was accepted"
else
    pass "unknown consumer is rejected"
fi

# (5) `-type d` matcher: a DIRECTORY named node_modules is skipped, a FILE sharing the name
#     is walked.
mktestdir
mkdir -p "${TESTDIR}/proj/node_modules/nested" "${TESTDIR}/proj/.git/objects/ab" "${TESTDIR}/proj/src"
: > "${TESTDIR}/proj/node_modules/nested/dep.js"     # inside a dependency DIRECTORY -> skipped
: > "${TESTDIR}/proj/.git/objects/ab/node_modules"   # a FILE sharing the name, in walked .git -> walked
ai_tools_skip_dirs__build_find_expression reclaim             # walks .git, skips the heavy trees
declare -a found=()
mapfile -d '' -t found < <(find "${TESTDIR}/proj" "${AI_TOOLS_SKIP_DIRS__FIND_EXPRESSION[@]}" -type f -print0)
walked() { local f; for f in "${found[@]}"; do [[ "${f}" == "$1" ]] && return 0; done; return 1; }
if walked "${TESTDIR}/proj/.git/objects/ab/node_modules" && ! walked "${TESTDIR}/proj/node_modules/nested/dep.js"; then
    pass "-type d skips the node_modules DIRECTORY but walks a FILE sharing the name"
else
    fail "-type d matcher off: file walked=$(walked "${TESTDIR}/proj/.git/objects/ab/node_modules" && echo y || echo n), dir content walked=$(walked "${TESTDIR}/proj/node_modules/nested/dep.js" && echo y || echo n)"
fi

# (6) operator.conf category override REPLACES the default (parsed, not sourced); other
#     categories keep their defaults. The artifact opt-in is the documented use-case.
printf 'OPERATORS="%s"\nSKIP_PACKAGE_DIRS="node_modules vendor"\nSKIP_ARTIFACT_DIRS="bin obj"\n' \
    "${PROJECTS_USER}" > "${TESTDIR}/operator.conf"
AI_TOOLS_OPERATOR_CONF="${TESTDIR}/operator.conf"
# shellcheck source=/dev/null
source "${SKIP_DIRS_LIB}"
if [[ "${AI_TOOLS_SKIP_PACKAGE_DIRS[*]}" == "node_modules vendor" \
      && "${AI_TOOLS_SKIP_ARTIFACT_DIRS[*]:-}" == "bin obj" \
      && "${AI_TOOLS_SKIP_CACHE_DIRS[*]}" == "__pycache__" ]]; then
    pass "operator.conf overrides categories (artifact opt-in), leaving the others at default"
else
    fail "override: PACKAGE='${AI_TOOLS_SKIP_PACKAGE_DIRS[*]}' ARTIFACT='${AI_TOOLS_SKIP_ARTIFACT_DIRS[*]:-}' CACHE='${AI_TOOLS_SKIP_CACHE_DIRS[*]}'"
fi

# (7) Root-anchored artifact exclusions: with the artifact opt-in from (6) plus a relative
#     exclusion, a walk that passes its root walks the exempted bin/ but still skips the
#     other one; without a root the plain name skip applies to both.
printf 'SKIP_ARTIFACT_DIRS="bin obj"\nSKIP_ARTIFACT_DIRS_EXCLUDED_PATHS_RELATIVE="src/bin"\n' \
    > "${TESTDIR}/operator.conf"
# shellcheck source=/dev/null
source "${SKIP_DIRS_LIB}"
mkdir -p "${TESTDIR}/proj2/src/bin" "${TESTDIR}/proj2/out/bin"
: > "${TESTDIR}/proj2/src/bin/tool.sh"   # exempted source dir -> walked
: > "${TESTDIR}/proj2/out/bin/built"     # ordinary artifact dir -> skipped
ai_tools_skip_dirs__build_find_expression sweep '' "${TESTDIR}/proj2"
found=()
mapfile -d '' -t found < <(find "${TESTDIR}/proj2" "${AI_TOOLS_SKIP_DIRS__FIND_EXPRESSION[@]}" -type f -print0)
if walked "${TESTDIR}/proj2/src/bin/tool.sh" && ! walked "${TESTDIR}/proj2/out/bin/built"; then
    pass "relative exclusion exempts src/bin from the artifact skip (out/bin stays skipped)"
else
    fail "exclusion: src/bin walked=$(walked "${TESTDIR}/proj2/src/bin/tool.sh" && echo y || echo n), out/bin walked=$(walked "${TESTDIR}/proj2/out/bin/built" && echo y || echo n)"
fi
ai_tools_skip_dirs__build_find_expression sweep   # no root -> exclusions cannot anchor
found=()
mapfile -d '' -t found < <(find "${TESTDIR}/proj2" "${AI_TOOLS_SKIP_DIRS__FIND_EXPRESSION[@]}" -type f -print0)
if ! walked "${TESTDIR}/proj2/src/bin/tool.sh"; then
    pass "without a walk root the plain name skip applies (exclusions need the root)"
else
    fail "rootless walk unexpectedly honoured a relative exclusion"
fi

finish
