#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/format.sh
# Unit test for tools/format.sh, the front door of the width policy. What it holds is the
# contract between the checker and the fillers: every file goes to the filler for the kind the
# checker names, at the column the checker names, and a kind with no filler is reported and left
# as it was -- the failure this exists to prevent is the comment filler pointed at a Markdown
# page, which rewraps the commands in its fenced blocks. The scope rule is pinned from both
# sides, since it is what bounds the diff a run produces: with no file named, only the paragraph
# a diff touched is filled and an over-width paragraph the commit already held is left, while
# `--files` fills that one too and an untracked file is filled whole either way. What may be
# formatted at all is the explicit scope: a unit file, a log and a Makefile in the fixture are
# outside it, so `--all` counts and leaves them, and one named on the command line is reported
# and skipped, as is a path outside the repository. The closing report is pinned by its exit
# status: 0 when no measured line is left over its column, 1 when a line no filler can shorten
# remains or a filler refused a file. Hermetic: a fixture repository in the testdir, formatted
# from inside it, with this checkout's tools. The comment-filler cases skip without Emacs. A
# fixture holds a reftag as text, so the tree-wide reference check does not read this file (the
# marker on the next line).
# ref-index: ignore-file
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="${ROOT}/tools/format.sh"
GATE="${ROOT}/tools/verify-reflow.py"
PC="${ROOT}/src/usr/share/ai-tools/skills/ai-tools-technical-docs/prose-check.py"
section "format: the width policy's front door (unit)"

if [[ ! -r "${TOOL}" ]]; then
    skip "format" "tool not found at ${TOOL}"; finish; exit
fi
if ! command -v python3 >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    skip "format" "python3 or git not available"; finish; exit
fi

mktestdir
repo="${TESTDIR}/repo"
mkdir -p "${repo}/src/etc" "${repo}/notes"
long="$(printf 'word %.0s' $(seq 1 30))"   # 150 columns of prose, over every column
cat > "${repo}/page.md" <<EOF
# A page

${long}

A short paragraph.
EOF
printf '# A router\n\n%s\n' "${long}" > "${repo}/notes/CLAUDE.md"
printf '#!/usr/bin/env bash\n# %s\nx=1\n' "${long}" > "${repo}/script.sh"
printf '# %s\nKEY=value\n' "${long}" > "${repo}/src/etc/x.conf"
printf '.TH X 1\n%s\n' "${long}" > "${repo}/page.1"
printf 'RIFF\0\0WEBP\n# %s\n' "${long}" > "${repo}/image.webp"
printf '# Index\n\n<!-- prose-check: ignore-file -->\n\n%s\n' "${long}" > "${repo}/notes/index.md"
# Data another program parses, each with a comment or a line long enough for a filler to want.
printf '[Unit]\n# %s\nDescription=x\n' "${long}" > "${repo}/unit.service"
printf '%s\n' "${long}" > "${repo}/notes.log"
printf '# %s\nall:\n\ttrue\n' "${long}" > "${repo}/Makefile"
git -C "${repo}" init -q
git -C "${repo}" config user.email t@example.invalid
git -C "${repo}" config user.name t
git -C "${repo}" add -A
git -C "${repo}" -c commit.gpgsign=false commit -qm base

# run_format <argument...>: run the tool from inside the fixture repository, leaving its output
# in OUT and its status in RC.
RC=0 OUT=""
run_format() {
    RC=0
    OUT="$(cd "${repo}" && bash "${TOOL}" "$@" 2>&1)" || RC=$?
}
restore() { git -C "${repo}" checkout -q -- . ; }
longest() { awk '{ if (length > n) n = length } END { print n + 0 }' "$1"; }

# (1) A named page goes to the Markdown filler at its reader's column: 79 for the page, 120 for
# the router, and the reflow is pure by the gate.
run_format page.md notes/CLAUDE.md
if (( $(longest "${repo}/page.md") <= 79 && $(longest "${repo}/page.md") > 60 )); then
    pass "a page is filled at 79"
else
    fail "page.md longest line is $(longest "${repo}/page.md"): ${OUT}"
fi
if (( $(longest "${repo}/notes/CLAUDE.md") <= 120 && $(longest "${repo}/notes/CLAUDE.md") > 80 )); then
    pass "a router is filled at 120"
else
    fail "CLAUDE.md longest line is $(longest "${repo}/notes/CLAUDE.md"): ${OUT}"
fi
if ( cd "${repo}" && python3 "${GATE}" --base HEAD page.md notes/CLAUDE.md >/dev/null 2>&1 ); then
    pass "the reflow is pure by the gate"
else
    fail "the gate reports the reflow: $(cd "${repo}" && python3 "${GATE}" --base HEAD page.md notes/CLAUDE.md 2>&1 | head -3)"
fi
if [[ "${RC}" -eq 0 ]]; then pass "exits 0 when nothing is left over its column"
else fail "exited ${RC} on a clean run: ${OUT}"; fi
restore

# (2) A kind with no filler is reported and left as it was: a page carrying the ignore-file
# marker, which the checker reads as generated. A man page and a binary file never reach the
# checker, since the scope keeps them out (section 6).
run_format notes/index.md
if grep -q 'skipped notes/index.md (generated)' <<<"${OUT}"; then
    pass "a generated page is reported as skipped, with the kind"
else
    fail "the skip report is missing: ${OUT}"
fi
if git -C "${repo}" diff --quiet -- notes/index.md; then
    pass "...and it is not changed"
else
    fail "a skipped file was changed: $(git -C "${repo}" diff --stat)"
fi

# (3) A source file goes to the comment filler at 120, and a config header at 72.
if ! command -v emacs >/dev/null 2>&1; then
    skip "source and header dispatch" "emacs not installed"
else
    run_format script.sh src/etc/x.conf
    if (( $(longest "${repo}/script.sh") <= 120 && $(longest "${repo}/script.sh") > 72 )) \
            && grep -qx 'x=1' "${repo}/script.sh"; then
        pass "a source comment is filled at 120 and the code line is left"
    else
        fail "script.sh longest line is $(longest "${repo}/script.sh"): ${OUT}"
    fi
    if (( $(longest "${repo}/src/etc/x.conf") <= 72 )) && grep -qx 'KEY=value' "${repo}/src/etc/x.conf" \
            && python3 "${PC}" --config-header "${repo}/src/etc/x.conf" >/dev/null 2>&1; then
        pass "a config header under src/etc/ is filled at 72 and holds to --config-header"
    else
        fail "x.conf longest line is $(longest "${repo}/src/etc/x.conf"): ${OUT}"
    fi
    restore
fi

# (4) The default scope is the paragraphs a diff touched. The commit holds an over-width
# paragraph; an edit appends another and adds an untracked page. With no file named, the appended
# paragraph and the untracked page are filled and the committed paragraph is left; `--files`
# then fills the committed one too.
printf '\n%s\n' "${long} appended" >> "${repo}/page.md"
printf '# New\n\n%s\n' "${long}" > "${repo}/new.md"
run_format
if grep -qF "${long}" "${repo}/page.md" && ! grep -qF "${long} appended" "${repo}/page.md" \
        && (( $(longest "${repo}/new.md") <= 79 )); then
    pass "no file named: the touched paragraph and the untracked page are filled, the committed paragraph is left"
else
    fail "the default scope did not hold: $(git -C "${repo}" diff --stat; head -8 "${repo}/page.md")"
fi
run_format --files
if ! grep -qF "${long}" "${repo}/page.md" && (( $(longest "${repo}/page.md") <= 79 )); then
    pass "--files fills the whole of a changed file"
else
    fail "--files left the committed paragraph: $(head -6 "${repo}/page.md")"
fi
restore; rm -f "${repo}/new.md"

# (5) `--all` warns and reads every tracked file; the report exits 1 while a line no filler can
# shorten remains -- an anchor line the filler protects and the checker measures.
printf '\n<a id="ref-table-x1y2"></a>**A caption line that is long enough to run past the column on its own**\n' >> "${repo}/page.md"
git -C "${repo}" add -A && git -C "${repo}" -c commit.gpgsign=false commit -qm anchor
run_format --all
if grep -q 'every tracked file' <<<"${OUT}"; then pass "--all warns before reading the tree"
else fail "--all did not warn: ${OUT}"; fi
if [[ "${RC}" -eq 1 ]] && grep -q 'document-width' <<<"${OUT}" && grep -q '1 over-width line(s) left' <<<"${OUT}"; then
    pass "exits 1 and names the line no filler can shorten"
else
    fail "expected rc 1 with the anchor line reported; rc ${RC}: ${OUT}"
fi
# The scope is an explicit list of what the formatter owns. The man page, the binary, the unit
# file, the log and the Makefile are outside it: counted, and left as written.
if grep -q '5 file(s) outside the scope left as written' <<<"${OUT}" \
        && git -C "${repo}" diff --quiet -- page.1 image.webp unit.service notes.log Makefile; then
    pass "--all counts the files outside the scope and leaves them as written"
else
    fail "a file outside the scope was formatted or not counted: ${OUT}; $(git -C "${repo}" diff --stat)"
fi
restore

# (6) A file named on the command line is read from where the command was run and taken to the
# repository root; one outside the scope, or outside the repository, is reported and skipped
# rather than formatted.
printf '# %s\n' "${long}" > "${TESTDIR}/outside.md"
run_format unit.service "${TESTDIR}/outside.md"
if grep -q 'skipped unit.service (outside the scope)' <<<"${OUT}" \
        && grep -qF "skipped ${TESTDIR}/outside.md (outside the repository)" <<<"${OUT}" \
        && git -C "${repo}" diff --quiet -- unit.service \
        && (( $(longest "${TESTDIR}/outside.md") > 79 )); then
    pass "a named file outside the scope or the repository is reported and skipped"
else
    fail "a named file was formatted or not reported: ${OUT}"
fi
OUT="$(cd "${repo}/notes" && bash "${TOOL}" CLAUDE.md 2>&1)" || true
if (( $(longest "${repo}/notes/CLAUDE.md") <= 120 && $(longest "${repo}/notes/CLAUDE.md") > 80 )); then
    pass "a named file is read from the directory the command was run in"
else
    fail "the file named from a subdirectory was not filled: ${OUT}"
fi
restore

# (7) A file a filler refuses is reported with its reason, left as it was, and counted in the
# exit status; the closing report measures only what was read whole.
printf '# Bad\n\n%s \033[31mred\033[0m\n' "${long}" > "${repo}/bad.md"
run_format bad.md
if [[ "${RC}" -eq 1 ]] && grep -q 'fill-markdown: refused bad.md: line 3 holds U+001B' <<<"${OUT}" \
        && grep -q '1 file(s) read, 0 over-width line(s) left' <<<"${OUT}" \
        && (( $(longest "${repo}/bad.md") > 80 )); then
    pass "a refused file is reported, left as it was, and exits 1"
else
    fail "the refusal did not hold (rc ${RC}): ${OUT}"
fi
rm -f "${repo}/bad.md"

# (8) The formatter is among the files it fills. Bash reads a script a command at a time, so one
# rewritten under a running bash is read on from the old offset, into the middle of a line, and
# the run dies of a command that is not one; each shell tool is one function called on its last
# line, which bash parses whole before running. The fixture takes a copy of the tools and the
# checker at the layout they resolve each other by, with a long comment line put at the top of
# each shell tool so that the fill changes the file under the bash running it.
if ! command -v emacs >/dev/null 2>&1; then
    skip "the formatter among the files it fills" "emacs not installed"
else
    mkdir -p "${repo}/src/usr/share/ai-tools/skills/ai-tools-technical-docs"
    cp "${PC}" "${repo}/src/usr/share/ai-tools/skills/ai-tools-technical-docs/"
    cp -r "${ROOT}/tools" "${repo}/tools"
    rm -rf "${repo}/tools/__pycache__"
    sed -i "2i # ${long}" "${repo}/tools/format.sh" "${repo}/tools/fill-comments.sh"
    git -C "${repo}" add -A && git -C "${repo}" -c commit.gpgsign=false commit -qm tools
    rc=0; OUT="$(cd "${repo}" && bash tools/format.sh tools/format.sh tools/fill-comments.sh 2>&1)" || rc=$?
    if [[ "${rc}" -eq 0 ]] && grep -q '2 file(s) read, 0 over-width line(s) left' <<<"${OUT}" \
            && ! grep -q 'command not found' <<<"${OUT}" \
            && ! git -C "${repo}" diff --quiet -- tools/format.sh tools/fill-comments.sh; then
        pass "the formatter fills its own shell tools and completes"
    else
        fail "the run over its own tools did not complete (rc ${rc}): $(tail -3 <<<"${OUT}")"
    fi
fi

finish
