#!/usr/bin/env bash
# tests/unit/skip-dirs.sh
# Unit test for the shared directory-skip selector (skip-dirs.lib.sh): the category defaults,
# the per-consumer skip sets the lib owns, the optional skip_git override, the operator.conf
# category overrides (parsed, not sourced), and the -type d matcher that skips DIRECTORIES
# only -- so a file sharing a skipped name is still walked. Sources the deployed library and
# exercises a /tmp testdir; needs no privilege of its own. Run as root via sudo (suite contract).

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

readonly SKIP_DIRS_LIB="/usr/local/lib/ai-tools/skip-dirs.lib.sh"
section "skip-dirs: categories, per-consumer defaults, -type d matcher (unit)"

if [[ ! -r "${SKIP_DIRS_LIB}" ]]; then
    skip "skip-dirs" "library not readable at ${SKIP_DIRS_LIB}"; finish; exit
fi

# names_for <consumer> [skip_git]: echo the flat skip-name list the lib produces.
names_for() { ai_tools_skip_find_expr "$@"; printf '%s' "${AI_TOOLS_SKIP_NAMES[*]}"; }

# (1) Defaults with no operator.conf overrides.
export AI_TOOLS_OPERATOR_CONF=/nonexistent
# shellcheck source=/dev/null
source "${SKIP_DIRS_LIB}"

if [[ "${AI_TOOLS_SKIP_VCS_DIRS[*]}" == ".git" \
      && "${AI_TOOLS_SKIP_ARTIFACT_DIRS[*]}" == "bin obj" ]]; then
    pass "category defaults are set (VCS=.git, ARTIFACT='bin obj')"
else
    fail "category defaults: VCS='${AI_TOOLS_SKIP_VCS_DIRS[*]}' ARTIFACT='${AI_TOOLS_SKIP_ARTIFACT_DIRS[*]}'"
fi

# (2) Per-consumer defaults (lib-owned): handback/normalization consumers skip .git + heavy.
handback_ok=true
for consumer in sweep setgid setfacl unclaim lockdown; do
    [[ " $(names_for "${consumer}") " == *" .git "* ]] \
        || { fail "${consumer} should skip .git by default"; handback_ok=false; }
done
${handback_ok} && pass "sweep/setgid/setfacl/unclaim/lockdown skip .git + heavy trees"

# reclaim WALKS .git but skips the heavy trees; reclaim-full skips nothing.
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

# (3) Optional skip_git override: reclaim true adds .git; sweep false drops it.
[[ " $(names_for reclaim true) " == *" .git "* ]] \
    && pass "skip_git=true override adds .git to reclaim" \
    || fail "override reclaim true: $(names_for reclaim true)"
[[ " $(names_for sweep false) " != *" .git "* ]] \
    && pass "skip_git=false override drops .git from sweep" \
    || fail "override sweep false: $(names_for sweep false)"

# (4) Unknown consumer is rejected.
if ai_tools_skip_find_expr bogus 2>/dev/null; then
    fail "unknown consumer was accepted"
else
    pass "unknown consumer is rejected"
fi

# (5) -type d matcher: a DIRECTORY named obj is skipped, a FILE named obj is walked.
mktestdir
mkdir -p "${TESTDIR}/proj/obj/nested" "${TESTDIR}/proj/.git/objects/ab" "${TESTDIR}/proj/src"
: > "${TESTDIR}/proj/obj/nested/built"      # inside a build DIRECTORY -> skipped
: > "${TESTDIR}/proj/.git/objects/ab/obj"   # a FILE named obj inside walked .git -> walked
ai_tools_skip_find_expr reclaim             # walks .git, skips the heavy trees (incl. obj dir)
declare -a found=()
mapfile -d '' -t found < <(find "${TESTDIR}/proj" "${AI_TOOLS_SKIP_FIND_EXPR[@]}" -type f -print0)
walked() { local f; for f in "${found[@]}"; do [[ "${f}" == "$1" ]] && return 0; done; return 1; }
if walked "${TESTDIR}/proj/.git/objects/ab/obj" && ! walked "${TESTDIR}/proj/obj/nested/built"; then
    pass "-type d skips the obj DIRECTORY but walks a FILE named obj"
else
    fail "-type d matcher off: file-obj walked=$(walked "${TESTDIR}/proj/.git/objects/ab/obj" && echo y || echo n), dir-obj-content walked=$(walked "${TESTDIR}/proj/obj/nested/built" && echo y || echo n)"
fi

# (6) operator.conf category override REPLACES the default (parsed, not sourced); other
#     categories keep their defaults.
printf 'OPERATORS="%s"\nSKIP_PACKAGE_DIRS="node_modules vendor"\n' "${PROJECTS_USER}" \
    > "${TESTDIR}/operator.conf"
AI_TOOLS_OPERATOR_CONF="${TESTDIR}/operator.conf"
# shellcheck source=/dev/null
source "${SKIP_DIRS_LIB}"
if [[ "${AI_TOOLS_SKIP_PACKAGE_DIRS[*]}" == "node_modules vendor" \
      && "${AI_TOOLS_SKIP_ARTIFACT_DIRS[*]}" == "bin obj" ]]; then
    pass "operator.conf overrides a category, leaving the others at default"
else
    fail "override: PACKAGE='${AI_TOOLS_SKIP_PACKAGE_DIRS[*]}' ARTIFACT='${AI_TOOLS_SKIP_ARTIFACT_DIRS[*]}'"
fi

finish
