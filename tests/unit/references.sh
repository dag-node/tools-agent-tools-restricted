#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/references.sh
# Unit test for this repository's use of ref-index.py, the cross-reference tool of the ai-tools-reftags skill
# in the pinned core release, through tools/generators/ref-index.sh. The tool's own findings -- each driven
# with a fixture it must report and the corrected form it must stay silent on -- are the skill's suite, in the release
# the pin names; what stays here is what this repository adds around it.
#
# The first section holds the tree to its committed index: the index is regenerated and diffed
# against .claude/references.md, and `check` runs over every tracked file. The second drives the one finding the wrapper
# holds rather than the tool: a runtime message carrying a link. Both read the checkout through the wrapper, which names
# the file list once and resolves the tool from the pin, so they skip outside a git checkout and, naming the fetch
# command, where the pin is not in the cache. An empty tree is a valid index, so the first section is green
# before the first reftag.
#
# Hermetic: fixtures are written in the test's own /tmp testdir. Pure text analysis, so it does not need privilege
# of its own.
#
# This file holds reftags as fixture text, so the tree-wide check does not read it (the marker on the next line).
# The fixture text carries `$1` and backticks that are content, not expansions.
# ref-index: ignore-file
# shellcheck disable=SC2016
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAPPER="${ROOT}/tools/generators/ref-index.sh"
section "references: the tree's index and the wrapper's message check (unit)"

if ! command -v python3 >/dev/null 2>&1; then
    skip "references" "python3 not available"; finish; exit
fi
if [[ ! -r "${WRAPPER}" ]] || ! git -C "${ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    skip "references" "not a git checkout with tools/generators/ref-index.sh"; finish; exit
fi
# shellcheck source=SCRIPTDIR/../../tools/lib/assets.sh
source "${ROOT}/tools/lib/assets.sh"
if ! RI="$(ai_tools_dev_assets__resolve_tool ref-index)"; then
    skip "references" "the pinned core release is not in the cache; run: ${AI_TOOLS_DEV_ASSETS__FETCH_COMMAND}"; finish; exit
fi
note "tool" "${RI}"

mktestdir

# fixture <relative path> <line...>: write a fixture under TESTDIR, creating its directory.
fixture() {
    local path="$1"; shift
    mkdir -p "${TESTDIR}/$(dirname "${path}")"
    printf '%s\n' "$@" > "${TESTDIR}/${path}"
}
assert_grep() {  # assert_grep <pattern> <text> <description>
    if grep -q -- "$1" <<<"$2"; then pass "$3"; else fail "$3 -- pattern '$1' absent from: $2"; fi
}

# ── The tree is held to its committed index, through the repository wrapper ───────────────────
if out="$(bash "${WRAPPER}" stale 2>&1)"; then
    pass "TEST-RI-01-index-current: .claude/references.md matches a fresh generation"
else
    fail "TEST-RI-01-index-current: ${out}"
fi
if out="$(bash "${WRAPPER}" check 2>&1)"; then
    pass "TEST-RI-02-tree-clean: check reports nothing over the tracked tree"
else
    fail "TEST-RI-02-tree-clean: ${out}"
fi

# ── messages: the link shapes a runtime message may not carry ─────────────────────────────────
# This one finding belongs to the repository wrapper. A message string is not prose, so the checker that skips a quoted
# span never reads it, and knowing that a code in the first argument makes an emit call is repository knowledge. Each
# link shape is driven with the resolvable form beside it, and the pair that must stay silent is what keeps the pattern
# off an ordinary message: a page name in parentheses reads as a Markdown link to a looser pattern, and an option set
# carries the pipe a row escapes. The non-ASCII case is the one a character-set rule would miss, every scheme being
# spelled in ASCII whatever follows it.
fixture src/links.sh '#!/usr/bin/env bash' \
    'die MSG-B4T6 "read https://example.com/rule first"' \
    'warn MSG-C5V7 "read [the manual](docs/x.md) first"' \
    'note MSG-D6W8 '"'"'<a href="x">open</a>'"'"'' \
    'die MSG-F7X9 "read https://exämple.test/ünicode"' \
    'die MSG-G8Y2 "read ai-tools-messages(7) for every code"' \
    'warn MSG-H9Z3 "the option set is --scope minimal|full"'
LINKS_RC=0
LINKS_OUT="$(bash "${WRAPPER}" messages "${TESTDIR}/src/links.sh" 2>&1)" || LINKS_RC=$?
reports_link() {  # reports_link <code> <case>: PASS when the code is reported as a link
    assert_grep "message-link \[$1\]" "${LINKS_OUT}" "$2: reports message-link [$1]"
}
reports_link MSG-B4T6 TEST-RI-18-message-url
reports_link MSG-C5V7 TEST-RI-18-message-markdown
reports_link MSG-D6W8 TEST-RI-18-message-anchor
reports_link MSG-F7X9 TEST-RI-18-message-non-ascii-url
if [[ "${LINKS_RC}" -eq 1 ]]; then
    pass "TEST-RI-18-message-status: a message-link finding exits 1"
else
    fail "TEST-RI-18-message-status: rc ${LINKS_RC}; ${LINKS_OUT}"
fi
if ! grep -q -e 'MSG-G8Y2' -e 'MSG-H9Z3' <<<"${LINKS_OUT}"; then
    pass "TEST-RI-18-message-clean: a page name in parentheses and an option set are not links"
else
    fail "TEST-RI-18-message-clean: reported a message carrying no link; ${LINKS_OUT}"
fi
# The line is resolved from the emit call, so a report is clickable from the transcript.
assert_grep "src/links.sh:2: message-link" "${LINKS_OUT}" \
    "TEST-RI-18-message-line: the finding names the line the code is emitted on"

finish
