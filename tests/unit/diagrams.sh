#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/diagrams.sh
# Holds the diagrams to the docs-pages rule: every SVG under docs/static/diagrams/ is what a layout
# in tools/generators/diagrams.py draws, through the generator's `stale` verb, and every diagram sits on a page GitHub
# renders. The first section runs the generator on a copy in the test's testdir, changes one SVG, removes another
# and plants one no layout draws, so the verb shows it reports what it exists to report before its verdict on the tree
# is read. The second runs the verb over the checkout. The third reads the tracked files: each SVG is embedded
# by a page, each embedding names a tracked SVG, each diagram follows its ref-diagram caption, and a Mermaid fence
# or an SVG embedding sits in README.md or under docs/ alone, so a diagram dropped or renamed on one side is reported
# until the other side follows. Skipped outside a checkout that carries the generator; the third section also outside
# a git checkout.
#
# Hermetic: the copy is written in the test's own /tmp testdir. Pure text generation, so it does not need privilege
# of its own.
#
# The fixture text carries backticks that are content, not expansions, and a reftag caption, so the tree-wide reftag
# check does not read this file (the marker on the next line).
# ref-index: ignore-file
# shellcheck disable=SC2016
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GENERATOR="${ROOT}/tools/generators/diagrams.py"
section "diagrams: every committed SVG is what its layout generates (unit)"

if ! command -v python3 >/dev/null 2>&1; then
    skip "diagrams" "python3 not available"; finish; exit
fi
if [[ ! -r "${GENERATOR}" ]]; then
    skip "diagrams" "not a checkout (no ${GENERATOR})"; finish; exit
fi

mktestdir

# ── The verb reports a changed and a missing SVG, on a copy ───────────────────────────────────
# The generator writes under its own checkout's docs/static/diagrams/, so the copy keeps the tools/generators/ depth.
COPY="${TESTDIR}/tools/generators/diagrams.py"
OUT="${TESTDIR}/docs/static/diagrams"
mkdir -p "$(dirname "${COPY}")"
cp "${GENERATOR}" "${COPY}"
python3 "${COPY}" generate
mapfile -t SVGS < <(find "${OUT}" -name '*.svg' -type f | sort)
if (( ${#SVGS[@]} >= 2 )); then
    pass "TEST-DG-01-generate: generate writes the SVGs (${#SVGS[@]})"
else
    fail "TEST-DG-01-generate: generate wrote ${#SVGS[@]} SVG(s) under ${OUT}"
fi

rc=0; out="$(python3 "${COPY}" stale 2>&1)" || rc=$?
if (( rc == 0 )); then
    pass "TEST-DG-02-fresh: stale exits 0 right after generate"
else
    fail "TEST-DG-02-fresh: rc ${rc}; ${out}"
fi

printf ' ' >> "${SVGS[0]}"
rm -f "${SVGS[1]}"
LEFTOVER="${OUT}/dropped-layout-light.svg"
printf '<svg/>\n' > "${LEFTOVER}"
rc=0; out="$(python3 "${COPY}" stale 2>&1)" || rc=$?
if (( rc == 1 )) && grep -qF -- "${SVGS[0]} is stale" <<<"${out}" && grep -qF -- "${SVGS[1]} is stale" <<<"${out}"; then
    pass "TEST-DG-03-reported: stale exits 1 naming a changed and a missing SVG"
else
    fail "TEST-DG-03-reported: rc ${rc}; ${out}"
fi
if (( rc == 1 )) && grep -qF -- "${LEFTOVER} is not drawn by any layout" <<<"${out}"; then
    pass "TEST-DG-04-leftover: stale names an SVG no layout draws"
else
    fail "TEST-DG-04-leftover: rc ${rc}; ${out}"
fi

# ── The tree ───────────────────────────────────────────────────────────────────────────────────
rc=0; out="$(python3 "${GENERATOR}" stale 2>&1)" || rc=$?
if (( rc == 0 )); then
    pass "TEST-DG-05-tree: every SVG under docs/static/diagrams/ matches its layout"
else
    fail "TEST-DG-05-tree: ${out}"
fi

# ── Where the diagrams sit, read from the tracked files ─────────────────────────────────────────
if ! command -v git >/dev/null 2>&1 || ! git -C "${ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    skip "diagram placement" "git not available or not a git checkout"; finish; exit
fi

# placement_findings <repository>: prints one line per finding in the repository's tracked files -- `unembedded <svg>`
# for an SVG under docs/static/diagrams/ no page embeds, `dangling <name>` for an embedding whose SVG is not tracked,
# `uncaptioned <page>:<line>` for a Mermaid fence or a <picture> whose last non-blank line before is not a ref-diagram
# caption, `misplaced <file>` for a Mermaid fence or an SVG embedding outside README.md and docs/.
placement_findings() {
    local repo="$1" svg ref name embedded
    local -a svgs pages names
    mapfile -t svgs < <(git -C "${repo}" ls-files -- 'docs/static/diagrams/*.svg')
    mapfile -t pages < <(git -C "${repo}" ls-files -- README.md 'docs/*.md')
    embedded=""
    if (( ${#pages[@]} > 0 )); then
        embedded="$(grep -ohE 'src(set)?="[^"]*static/diagrams/[^"]*"' -- "${pages[@]/#/${repo}/}" || true)"
    fi
    names=("${svgs[@]##*/}")
    for svg in "${svgs[@]}"; do
        grep -qF -- "static/diagrams/${svg##*/}\"" <<<"${embedded}" || printf 'unembedded %s\n' "${svg}"
    done
    while IFS= read -r ref; do
        [[ -n "${ref}" ]] || continue
        name="${ref##*static/diagrams/}"; name="${name%\"}"
        [[ " ${names[*]} " == *" ${name} "* ]] || printf 'dangling %s\n' "${name}"
    done <<<"${embedded}"
    if (( ${#pages[@]} > 0 )); then
        awk '/^ {0,3}```+ *mermaid|^<picture>/ && prev !~ /^<a id="ref-diagram-[a-z][0-9][a-z][0-9]"><\/a>\*\*[^*]+\*\*$/ {
                 print "uncaptioned " substr(FILENAME, length(root) + 2) ":" FNR }
             NF { prev = $0 }' root="${repo}" "${pages[@]/#/${repo}/}"
    fi
    { git -C "${repo}" grep -lE -e '^ {0,3}```+ *mermaid' -e 'src(set)?="[^"]*static/diagrams/' \
        -- . ':!README.md' ':!docs/*.md' ':!tests/unit/diagrams.sh' || true; } | sed 's/^/misplaced /'
}

# The fixture holds one finding of each kind beside a diagram placed correctly, so the reader shows it reports each
# before its verdict on the tree is read.
FIX="${TESTDIR}/placement"
mkdir -p "${FIX}/docs/static/diagrams" "${FIX}/man"
printf '<svg/>\n' > "${FIX}/docs/static/diagrams/kept-light.svg"
printf '<svg/>\n' > "${FIX}/docs/static/diagrams/unused-light.svg"
printf '%s\n' '# Page' '' '<a id="ref-diagram-a1b2"></a>**Kept**' '' \
    '<picture> <img alt="Kept." src="static/diagrams/kept-light.svg"> </picture>' \
    '<img alt="Gone." src="static/diagrams/renamed-light.svg">' '' '```mermaid' 'flowchart LR' '  a --> b' '```' \
    > "${FIX}/docs/page.md"
printf '.TH PAGE 1\n```mermaid\nflowchart LR\n  a --> b\n```\n' > "${FIX}/man/page.1"
git -C "${FIX}" init -q && git -C "${FIX}" add -A
FIX_OUT="$(placement_findings "${FIX}")"
if [[ "${FIX_OUT}" == $'unembedded docs/static/diagrams/unused-light.svg\ndangling renamed-light.svg\nuncaptioned docs/page.md:8\nmisplaced man/page.1' ]]; then
    pass "TEST-DG-06-control: the fixture's unembedded SVG, dangling embedding, uncaptioned and misplaced blocks are each reported"
else
    fail "TEST-DG-06-control: the reader printed: ${FIX_OUT//$'\n'/; }"
fi

TREE_OUT="$(placement_findings "${ROOT}")"
if [[ -z "${TREE_OUT}" ]]; then
    pass "TEST-DG-07-placed: each tracked SVG is embedded, each embedding resolves, and each diagram is captioned in README.md or docs/"
else
    fail "TEST-DG-07-placed: ${TREE_OUT//$'\n'/; }"
fi

finish
