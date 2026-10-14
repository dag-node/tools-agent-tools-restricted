#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/prose-width.sh
# The width gate: holds every tracked file in this repository's format scope to its column, as references.sh holds
# the tree to its index. The scope is tools/lib/format-scope.sh's, the one tools/format.sh formats, so the gate
# and the formatter read one set of patterns. The checker is the pinned core release's prose-check.py, which is
# read-only: the formatter fills, and a gate does not write. `--wrap` measures a page and a source comment
# and `--config-header` a config header, each at the column the checker resolves for the file. `--wrap` runs the prose
# checks as well, which are the writing pass's, so the gate counts the `comment-width`, `document-width`
# and `header-width` findings alone and prints each with its line.
#
# The first section runs the gate over a fixture repository holding one over-width line of each kind, beside a vendored
# file, a file outside the scope and an untracked page that are over their columns too, and then over the corrected
# form, so the gate shows it reports what it exists to report before its verdict on the tree is read. A checker
# that could not run -- an exit above 1, or anything on stderr, which is where it reports a path it cannot read -- fails
# the case, as does a tree git cannot list, so a file the gate did not measure is reported and not passed. The second
# section measures the tree. Skipped outside a git checkout and, naming the fetch command, where the pin is not
# in the cache.
#
# Hermetic: the fixture repository is written in the test's own /tmp testdir. Pure text analysis, so it does not need
# privilege of its own.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
section "prose-width: every in-scope file at its column (unit)"

if ! command -v python3 >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    skip "prose-width" "python3 or git not available"; finish; exit
fi
if [[ ! -r "${ROOT}/tools/lib/format-scope.sh" ]] || ! git -C "${ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    skip "prose-width" "not a git checkout with tools/lib/format-scope.sh"; finish; exit
fi
# shellcheck source=SCRIPTDIR/../../tools/lib/assets.sh
source "${ROOT}/tools/lib/assets.sh"
# shellcheck source=SCRIPTDIR/../../tools/lib/format-scope.sh
source "${ROOT}/tools/lib/format-scope.sh"
if ! CHECKER="$(ai_tools_dev_assets__resolve_tool prose-check)"; then
    skip "prose-width" "the pinned core release is not in the cache; run: ${AI_TOOLS_DEV_ASSETS__FETCH_COMMAND}"; finish; exit
fi
note "checker" "${CHECKER}"

# in_scope <path>: 0 when the root-relative <path> matches a scope pattern and no vendored one, `*` crossing a `/`,
# as the formatter matches the patterns tools/format.sh hands it.
in_scope() {
    local pattern
    for pattern in "${AI_TOOLS_FORMAT_SCOPE__VENDORED[@]}"; do
        [[ "$1" == ${pattern} ]] && return 1
    done
    for pattern in "${AI_TOOLS_FORMAT_SCOPE__PATTERNS[@]}"; do
        [[ "$1" == ${pattern} ]] && return 0
    done
    return 1
}

# The gate's result: WIDTH_OUT holds each width finding with the line it quotes, and each checker failure; WIDTH_RC is 0
# with neither, 1 with a width finding, 2 where the checker or the file listing could not run. WIDTH_FILES counts
# the files measured.
WIDTH_OUT="" WIDTH_RC=0 WIDTH_FILES=0

# run_checker <repo> <checker-argument>...: run the checker from <repo> and add its width findings to the result.
run_checker() {
    local repo="$1" out rc=0 err="${TESTDIR}/checker.err" findings
    shift
    out="$(cd "${repo}" && python3 "${CHECKER}" "$@" 2>"${err}")" || rc=$?
    if (( rc > 1 )) || [[ -s "${err}" ]]; then
        WIDTH_OUT+="the checker could not run (exit ${rc}): $(head -c 300 "${err}")"$'\n'
        WIDTH_RC=2
        return 0
    fi
    findings="$(grep -E --no-group-separator -A1 -- ': (comment|document|header)-width \[' <<<"${out}" || true)"
    if [[ -n "${findings}" ]]; then
        WIDTH_OUT+="${findings}"$'\n'
        (( WIDTH_RC == 2 )) || WIDTH_RC=1
    fi
}

# measure_widths <repo>: run the gate over the tracked files of <repo> in the scope, a config header
# through `--config-header` and every other file through `--wrap`.
measure_widths() {
    local repo="$1" f
    local -a tracked=() wrapped=() headers=()
    WIDTH_OUT="" WIDTH_RC=0
    if ! git -C "${repo}" ls-files -z > "${TESTDIR}/tracked" 2>&1; then
        WIDTH_OUT="git ls-files could not list ${repo}: $(head -c 300 "${TESTDIR}/tracked")"$'\n'
        WIDTH_RC=2
        return 0
    fi
    mapfile -d '' -t tracked < "${TESTDIR}/tracked"
    for f in "${tracked[@]}"; do
        in_scope "${f}" || continue
        if [[ "${f}" == ${AI_TOOLS_FORMAT_SCOPE__CONFIG_HEADERS} ]]; then headers+=("${f}"); else wrapped+=("${f}"); fi
    done
    WIDTH_FILES=$(( ${#wrapped[@]} + ${#headers[@]} ))
    if (( ${#wrapped[@]} )); then run_checker "${repo}" --wrap -- "${wrapped[@]}"; fi
    if (( ${#headers[@]} )); then run_checker "${repo}" --config-header -- "${headers[@]}"; fi
}

assert_grep() {  # assert_grep <pattern> <text> <description>
    if grep -q -- "$1" <<<"$2"; then pass "$3"; else fail "$3 -- pattern '$1' absent from: $2"; fi
}
refute_grep() {  # refute_grep <pattern> <text> <description>
    if ! grep -q -- "$1" <<<"$2"; then pass "$3"; else fail "$3 -- pattern '$1' present in: $2"; fi
}

# ── The gate over a fixture: one line over each column, then the corrected form ──────────────
mktestdir
repo="${TESTDIR}/repo"
mkdir -p "${repo}/docs" "${repo}/src/etc" "${repo}/src/usr/local/lib/ai-tools/typesafe"
long="$(printf 'word %.0s' $(seq 1 30))"   # 150 columns of prose, over every column
short="a line inside every column"
write_fixture() {  # write_fixture <text>: the in-scope files, each holding <text> where its column is measured
    printf '#!/usr/bin/env bash\n# %s\nx=1\n' "$1" > "${repo}/script.sh"
    printf '# A page\n\n%s\n' "$1" > "${repo}/docs/page.md"
    printf '# %s\nKEY=value\n' "$1" > "${repo}/src/etc/x.conf"
}
write_fixture "${long}"
printf '#!/usr/bin/env bash\n# %s\n' "${long}" > "${repo}/src/usr/local/lib/ai-tools/typesafe/client.sh"
printf '[Unit]\n# %s\nDescription=x\n' "${long}" > "${repo}/unit.service"
git -C "${repo}" init -q
git -C "${repo}" add -A
printf '# Untracked\n\n%s\n' "${long}" > "${repo}/notes.md"

measure_widths "${repo}"
if [[ "${WIDTH_RC}" -eq 1 ]]; then
    pass "TEST-PW-01-over-status: an over-width line fails the gate"
else
    fail "TEST-PW-01-over-status: rc ${WIDTH_RC}; ${WIDTH_OUT}"
fi
assert_grep "script.sh:2: comment-width \[151>120\]" "${WIDTH_OUT}" \
    "TEST-PW-02-comment: a source comment is reported at 120 with its file and line"
assert_grep "docs/page.md:3: document-width \[149>79\]" "${WIDTH_OUT}" \
    "TEST-PW-02-document: a page under docs/ is reported at 79"
assert_grep "src/etc/x.conf:1: header-width \[151>72\]" "${WIDTH_OUT}" \
    "TEST-PW-02-header: a config header is reported at 72"
refute_grep "typesafe/" "${WIDTH_OUT}" "TEST-PW-03-vendored: a vendored file is not measured"
refute_grep "unit.service" "${WIDTH_OUT}" "TEST-PW-03-outside: a file outside the scope is not measured"
refute_grep "notes.md" "${WIDTH_OUT}" "TEST-PW-03-untracked: an untracked file is not measured"

write_fixture "${short}"
measure_widths "${repo}"
if [[ "${WIDTH_RC}" -eq 0 && -z "${WIDTH_OUT}" ]]; then
    pass "TEST-PW-04-clean: the corrected form passes with no output"
else
    fail "TEST-PW-04-clean: rc ${WIDTH_RC}; ${WIDTH_OUT}"
fi

# The checker reports a tracked file missing from the working tree on its stderr and exits 0; the gate fails
# on the stderr line.
rm -f "${repo}/script.sh"
measure_widths "${repo}"
if [[ "${WIDTH_RC}" -eq 2 ]]; then
    pass "TEST-PW-05-unreadable: a path the checker cannot read fails the gate"
else
    fail "TEST-PW-05-unreadable: rc ${WIDTH_RC}; ${WIDTH_OUT}"
fi
assert_grep "script.sh" "${WIDTH_OUT}" "TEST-PW-05-unreadable-named: the failure names the path"

# A directory git cannot list fails the gate rather than reading as a tree without files.
mkdir -p "${TESTDIR}/not-a-repo"
measure_widths "${TESTDIR}/not-a-repo"
if [[ "${WIDTH_RC}" -eq 2 ]]; then
    pass "TEST-PW-06-unlisted: a tree git cannot list fails the gate"
else
    fail "TEST-PW-06-unlisted: rc ${WIDTH_RC}; ${WIDTH_OUT}"
fi

# ── The tree ──────────────────────────────────────────────────────────────────────────────────
# A failure is one line per finding, each naming the file, the line and the column; `bash tools/format.sh <file>` fills
# the file.
measure_widths "${ROOT}"
if [[ "${WIDTH_RC}" -eq 0 && "${WIDTH_FILES}" -gt 0 ]]; then
    pass "TEST-PW-10-tree: each of the ${WIDTH_FILES} in-scope tracked files is at its column"
elif [[ "${WIDTH_RC}" -eq 0 ]]; then
    fail "TEST-PW-10-tree: the listing of ${ROOT} held no file in the scope"
else
    while IFS= read -r line; do
        [[ -z "${line}" || "${line}" == ' '* ]] || fail "TEST-PW-10-tree: ${line}"
    done <<<"${WIDTH_OUT}"
fi

finish
