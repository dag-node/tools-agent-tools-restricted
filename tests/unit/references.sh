#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/references.sh
# Unit test for ref-index.py, the cross-reference tool shipped beside the ai-tools-technical-docs
# skill, and for the index it keeps. A reference names a reftag, and the reftag resolves
# to the target's current place, so the guarantee under test is that a target which moved, was
# renamed, or was deleted is REPORTED; a reference left pointing at the old place is the defect.
# Each finding `check` can make is driven with a fixture it MUST report and with the corrected
# form it MUST stay silent on, so neither a check that stopped firing nor one widened
# into reporting good prose survives.
#
# The first section holds the tree to its committed index: the index is regenerated and diffed
# against .claude/references.md, and `check` runs over every tracked file. Both read the checkout
# through tools/ref-index.sh, which names the file list once, so they skip outside a git
# checkout. An empty tree is a valid index, so the section is green before the first reftag.
#
# Hermetic: fixtures are written in the test's own /tmp testdir and the tool is run on those
# paths only, from inside the testdir so its `file:line` reports carry the fixture's relative
# path. Pure text analysis, so it does not need privilege of its own; run as root via sudo like
# the rest of the suite. Validates the repo source, falling back to the installed copies.
#
# This file holds reftags as fixture text, so the tree-wide check does not read it (the marker
# on the next line). The fixture text carries `$1` and backticks that are content, not expansions.
# ref-index: ignore-file
# shellcheck disable=SC2016
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
section "references: cross-reference reftags and the index (unit)"

RI=""
for candidate in \
    "${ROOT}/src/usr/share/ai-tools/skills/ai-tools-technical-docs/ref-index.py" \
    "/usr/share/ai-tools/skills/ai-tools-technical-docs/ref-index.py" \
    "/opt/ai-tools/skills/ai-tools-technical-docs/ref-index.py"; do
    [[ -r "${candidate}" ]] && { RI="${candidate}"; break; }
done

if [[ -z "${RI}" ]]; then
    skip "references" "ref-index.py not readable in the repo or in either shipped location"; finish; exit
fi
if ! command -v python3 >/dev/null 2>&1; then
    skip "references" "python3 not available"; finish; exit
fi

mktestdir
note "tool" "${RI}"

# run_ri <argument...>: run the tool from inside TESTDIR, leaving its output in OUT and its
# status in RC. A finding makes `check` exit 1, which `|| RC=$?` keeps non-fatal under set -e.
RC=0 OUT=""
run_ri() {
    RC=0
    OUT="$(cd "${TESTDIR}" && python3 "${RI}" "$@" 2>&1)" || RC=$?
}

# fixture <relative path> <line...>: write a fixture under TESTDIR, creating its directory.
fixture() {
    local path="$1"; shift
    mkdir -p "${TESTDIR}/$(dirname "${path}")"
    printf '%s\n' "$@" > "${TESTDIR}/${path}"
}

# Every result line names its CASE, never the fixture text: the fixtures hold deliberate defects,
# and a transcript that is read and grepped does not carry them. A failure prints the report.
# reports <finding> <case> <argument...>: PASS when `check` over the arguments reports the finding.
reports() {
    local finding="$1" case="$2"; shift 2
    run_ri check "$@"
    if grep -q -- "^[^:]*:[0-9]*: ${finding} " <<<"${OUT}"; then
        pass "${case}: reports ${finding}"
    else
        fail "${case}: did NOT report ${finding}; output: ${OUT}"
    fi
}
# silent <case> <argument...>: PASS when `check` over the arguments is silent and exits 0.
silent() {
    local case="$1"; shift
    run_ri check "$@"
    if [[ "${RC}" -eq 0 && -z "${OUT}" ]]; then
        pass "${case}: silent (rc 0)"
    else
        fail "${case}: expected no finding; rc ${RC}, output: ${OUT}"
    fi
}
assert_grep() {  # assert_grep <pattern> <text> <description>
    if grep -q -- "$1" <<<"$2"; then pass "$3"; else fail "$3 -- pattern '$1' absent from: $2"; fi
}

# ── The tree is held to its committed index, through the repository wrapper ───────────────────
WRAPPER="${ROOT}/tools/ref-index.sh"
if [[ -r "${WRAPPER}" ]] && git -C "${ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
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
else
    skip "TEST-RI-01..02-tree" "not a git checkout with tools/ref-index.sh"
fi

# ── A section target and a caption target, cited from another file with the generated destination ───
fixture docs/a.md '# Doc A' '' '## Two project models <a id="ref-section-a1b2"></a>' '' 'Text.' '' \
    '<a id="ref-table-c3d4"></a>**Altitudes and who owns which fact**' '' '| a | b |' '|---|---|' '| 1 | 2 |' '' \
    '## Security model — what `SANDBOX_USER` can do' '' 'More.'
fixture docs/b.md '# Doc B' '' \
    'The owner rule [ref-section-a1b2](a.md#ref-section-a1b2) and the table [ref-table-c3d4](a.md#ref-table-c3d4).' \
    'Navigation [What SANDBOX_USER can do](a.md#security-model--what-sandbox_user-can-do) and [Doc A](a.md).'
silent TEST-RI-03-clean docs/a.md docs/b.md

# ── Each finding, and the corrected form beside it ────────────────────────────────────────────
fixture docs/dup.md '## Another <a id="ref-section-a1b2"></a>'
reports duplicate TEST-RI-04-duplicate docs/a.md docs/b.md docs/dup.md
# An id is unique across kinds, so a table reusing a section's id is a defect of its own.
fixture docs/dupid.md '<a id="ref-table-a1b2"></a>**Another table**' '' '| a |' '|---|'
reports duplicate-id TEST-RI-04-duplicate-id docs/a.md docs/dupid.md

fixture docs/undef.md 'See [ref-section-z9z9](a.md#ref-section-z9z9).'
reports undefined TEST-RI-05-undefined docs/a.md docs/undef.md

fixture docs/self.md '## Own section <a id="ref-section-e5f6"></a>' '' 'See [ref-section-e5f6](#ref-section-e5f6).'
reports same-file TEST-RI-06-same-file docs/self.md
assert_grep '\[Own section\](#own-section)' "${OUT}" "TEST-RI-06-same-file: the report names the jump link to use"

# A listing's caption sits before a fence and a table's before a table row; any other kind's
# caption sits before whatever block follows it.
fixture docs/orphan.md '<a id="ref-listing-g7h8"></a>**A listing**' '' 'Prose, not a fence.'
reports misplaced TEST-RI-07-misplaced docs/orphan.md
fixture docs/drawn.md '<a id="ref-listing-g7h8"></a>**A listing**' '' '```' 'code' '```'
silent TEST-RI-07-misplaced-fenced docs/drawn.md
fixture docs/callout.md '<a id="ref-callout-g7h9"></a>**A note**' '' '> Prose in a quote block.'
silent TEST-RI-07-any-block docs/callout.md
fixture docs/loose.md 'Text <a id="ref-section-g8h0"></a> in a paragraph.'
reports misplaced TEST-RI-07-anchor-in-prose docs/loose.md

fixture docs/bare.md 'See [ref-section-a1b2] for the models.'
reports missing TEST-RI-08-missing docs/a.md docs/bare.md
run_ri relink docs/a.md docs/bare.md
assert_grep 'relinked docs/bare.md' "${OUT}" "TEST-RI-08-relink: relink rewrites the file"
silent TEST-RI-08-relink-clean docs/a.md docs/bare.md
assert_grep '\[ref-section-a1b2\](a.md#ref-section-a1b2)' "$(cat "${TESTDIR}/docs/bare.md")" \
    "TEST-RI-08-relink-part: the bare reftag is given its generated destination"

# A target that moved: the citing file still carries the old path.
fixture docs/stale.md 'See [ref-section-a1b2](old/a.md#ref-section-a1b2).'
reports stale TEST-RI-09-stale docs/a.md docs/stale.md
assert_grep '\[ref-section-a1b2\](a.md#ref-section-a1b2)' "${OUT}" "TEST-RI-09-stale: the report prints the corrected destination"
run_ri relink docs/a.md docs/stale.md
silent TEST-RI-09-relink docs/a.md docs/stale.md
# ...and one that moved INTO the citing file: the same-file report, which relink leaves alone.
fixture docs/moved.md '## Two project models <a id="ref-section-i9j0"></a>' '' 'See [ref-section-i9j0](a.md#ref-section-i9j0).'
reports same-file TEST-RI-09-moved-in docs/moved.md
run_ri relink docs/moved.md
assert_grep 'a.md#ref-section-i9j0' "$(cat "${TESTDIR}/docs/moved.md")" "TEST-RI-09-moved-in: relink leaves a same-file site as written"

# Navigation and file links are ordinary links, checked for resolving; they do not take a reftag.
# The slug keeps the text of a backticked span, which is the CLAUDE.md heading shape.
fixture docs/nav.md '# Title' '' '**Contents**: [Requirements](#requirements) · [Gone](#no-such-heading)' '' \
    '## Requirements' '' 'See [missing](nope.md) and [the models](a.md#ref-section-a1b2).'
reports link TEST-RI-10-link-anchor docs/a.md docs/nav.md
assert_grep 'no-such-heading.*cite its reftag' "${OUT}" "TEST-RI-10-link-anchor: a jump to a heading that is gone is reported, with the reftag hint"
assert_grep 'nope.md does not exist' "${OUT}" "TEST-RI-10-link-file: a link to a file that is gone is reported"
if grep -q 'requirements\|sandbox_user' <<<"${OUT}"; then
    fail "TEST-RI-10-link-ok: a resolving link was reported: ${OUT}"
else
    pass "TEST-RI-10-link-ok: a resolving slug, with a span in its heading, is not reported"
fi

# ── Code targets and a URI, cited from a document and from a source file ──────────────────────
fixture src/s.sh '#!/usr/bin/env bash' '# FN-K1L2: chown_path' '# args: $1 path' 'chown_path() {' \
    '    echo "MSG-M3N4: $1 is not in allowed projects"' '}' 'other() { :; }'
fixture src/t.sh '# The refusal is MSG-M3N4, driven in the unit test; see FN-K1L2.'
fixture docs/code.md 'The helper [FN-K1L2](../src/s.sh) prints [MSG-M3N4](../src/s.sh).' '' \
    '[URI-O5P6]: https://example.invalid/spec "The spec"' '' 'The spec [URI-O5P6](https://example.invalid/spec).'
silent TEST-RI-11-code-targets src/s.sh src/t.sh docs/code.md
fixture docs/code-stale.md 'The spec [URI-O5P6](https://example.invalid/old) and [FN-K1L2](s.sh).'
reports stale TEST-RI-11-uri-stale src/s.sh docs/code.md docs/code-stale.md
fixture src/u.sh '# see FN-Q7R8, which is nowhere'
reports undefined TEST-RI-11-code-undefined src/u.sh

# ── A fenced block and a backticked span are not read ─────────────────────────────────────────
fixture docs/quoted.md 'Write `[ref-section-z9z9](x.md#ref-section-z9z9)` and `## H <a id="ref-section-z9z8"></a>`.' '' \
    '```' '## Fenced <a id="ref-section-z9z7"></a>' '[ref-section-z9z6](x.md#ref-section-z9z6)' '```'
silent TEST-RI-12-quoted docs/quoted.md

# ── A quoted reftag is an example: indexed as one, its id reserved, and not a target ─────────
fixture docs/ex.md 'A caption reads `<a id="ref-figure-e9x9"></a>**A figure**` in the grammar.'
fixture docs/exref.md 'See [ref-figure-e9x9](ex.md#ref-figure-e9x9).'
reports undefined TEST-RI-12-example-cited docs/ex.md docs/exref.md
run_ri generate docs/ex.md
assert_grep '^| e9x9 | ref-figure-e9x9 | example | docs/ex.md |  |$' "${OUT}" \
    "TEST-RI-12-example-row: an example reftag is a row named example, with its id first"

# ── generate: document order, the cited-by column, and the empty tree ─────────────────────────
run_ri generate docs/a.md docs/b.md src/s.sh src/t.sh docs/code.md --out index.md
assert_grep '^| a1b2 | \[ref-section-a1b2\](docs/a.md#ref-section-a1b2) | Two project models | docs/a.md | docs/b.md |$' \
    "${OUT}$(cat "${TESTDIR}/index.md")" "TEST-RI-13-generate-row: a row carries the id, the reftag link, name, file, and cited-by"
first="$(grep -n 'ref-section-a1b2\|ref-table-c3d4\|FN-K1L2' "${TESTDIR}/index.md" | head -3 | cut -d: -f1 | tr '\n' ' ')"
if [[ "${first}" == "$(tr ' ' '\n' <<<"${first}" | grep . | sort -n | tr '\n' ' ')" ]]; then
    pass "TEST-RI-13-generate-order: rows follow file and position"
else
    fail "TEST-RI-13-generate-order: ${first}"
fi
assert_grep '^| k1l2 | \[FN-K1L2\](src/s.sh) | chown_path | src/s.sh | docs/code.md, src/t.sh |$' \
    "$(cat "${TESTDIR}/index.md")" "TEST-RI-13-generate-code: a code target links to its file and lists every citing file"
run_ri generate --at docs/index.md docs/a.md
assert_grep '(a.md#ref-section-a1b2)' "${OUT}" "TEST-RI-13-generate-at: --at computes the links from where the index lives"
: > "${TESTDIR}/empty.md"
run_ri generate empty.md
if [[ "${RC}" -eq 0 ]] && ! grep -q '^| \[' <<<"${OUT}"; then
    pass "TEST-RI-14-empty: a tree with no reftag is a valid index"
else
    fail "TEST-RI-14-empty: rc ${RC}; ${OUT}"
fi

# ── new: each family's form, and an id the index already holds is not drawn ───────────────────
# The id is a letter, a digit, a letter, a digit, in the family's case.
for family_form in 'section:ref-section-[a-z][0-9][a-z][0-9]' 'table:ref-table-[a-z][0-9][a-z][0-9]' \
                   'fn:FN-[A-Z][0-9][A-Z][0-9]' 'msg:MSG-[A-Z][0-9][A-Z][0-9]' 'uri:URI-[A-Z][0-9][A-Z][0-9]'; do
    run_ri new "${family_form%%:*}" --index index.md
    assert_grep "^${family_form#*:}$" "${OUT}" "TEST-RI-15-new-${family_form%%:*}: prints a reftag of the family's form"
done
run_ri kinds
assert_grep '^section .*ref-section-<id>' "${OUT}" "TEST-RI-15-kinds: the registry lists each kind with what it names"
assert_grep '^uri .*URI-<ID>' "${OUT}" "TEST-RI-15-kinds-code: the code families are listed with the kinds"
run_ri new spreadsheet --index index.md
if [[ "${RC}" -eq 2 ]]; then pass "TEST-RI-15-new-unknown: an unknown family is refused"; else fail "TEST-RI-15-new-unknown: rc ${RC}"; fi

# ── where: the live line and the span by the kind's syntax ────────────────────────────────────
run_ri where ref-section-a1b2 --index index.md
assert_grep '^docs/a.md:3 (10 lines) Two project models$' "${OUT}" "TEST-RI-16-where-section: a section spans to the next heading"
run_ri where FN-K1L2 --index index.md
assert_grep '^src/s.sh:2 (5 lines) chown_path$' "${OUT}" "TEST-RI-16-where-fn: a function spans its doc comment and body"
run_ri where ref-section-z9z9 --index index.md
if [[ "${RC}" -eq 1 ]]; then pass "TEST-RI-16-where-unknown: a reftag the index lacks exits 1"; else fail "TEST-RI-16-where-unknown: rc ${RC}"; fi

finish
