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
# `--files` fills that one too and an untracked file is filled whole either way. The closing
# report is pinned by its exit status: 0 when no measured line is left over its column, 1 when a
# line no filler can shorten remains. Hermetic: a fixture repository in the testdir, formatted
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

# (1) A named page goes to the Markdown filler at its reader's column: 80 for the page, 120 for
# the router, and the reflow is pure by the gate.
run_format page.md notes/CLAUDE.md
if (( $(longest "${repo}/page.md") <= 80 && $(longest "${repo}/page.md") > 60 )); then
    pass "a page is filled at 80"
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

# (2) A kind with no filler is reported and left as it was: a man page, a binary file.
run_format page.1 image.webp
if grep -q 'skipped page.1 (man)' <<<"${OUT}" && grep -q 'skipped image.webp (binary)' <<<"${OUT}"; then
    pass "a man page and a binary file are reported as skipped, with the kind"
else
    fail "the skip report is missing: ${OUT}"
fi
if git -C "${repo}" diff --quiet -- page.1 image.webp; then
    pass "...and neither is changed"
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
        && (( $(longest "${repo}/new.md") <= 80 )); then
    pass "no file named: the touched paragraph and the untracked page are filled, the committed paragraph is left"
else
    fail "the default scope did not hold: $(git -C "${repo}" diff --stat; head -8 "${repo}/page.md")"
fi
run_format --files
if ! grep -qF "${long}" "${repo}/page.md" && (( $(longest "${repo}/page.md") <= 80 )); then
    pass "--files fills the whole of a changed file"
else
    fail "--files left the committed paragraph: $(head -6 "${repo}/page.md")"
fi
restore; rm -f "${repo}/new.md"

# (5) `--all` warns and reads every tracked file; the report exits 1 while a line no filler can
# shorten remains -- an anchor line the filler protects and the checker measures.
printf '\n<a id="ref-table-x1y2"></a>**A caption line that is long enough to run past eighty columns on its own**\n' >> "${repo}/page.md"
git -C "${repo}" add -A && git -C "${repo}" -c commit.gpgsign=false commit -qm anchor
run_format --all
if grep -q 'every tracked file' <<<"${OUT}"; then pass "--all warns before reading the tree"
else fail "--all did not warn: ${OUT}"; fi
if [[ "${RC}" -eq 1 ]] && grep -q 'document-width' <<<"${OUT}" && grep -q '1 over-width line(s) left' <<<"${OUT}"; then
    pass "exits 1 and names the line no filler can shorten"
else
    fail "expected rc 1 with the anchor line reported; rc ${RC}: ${OUT}"
fi
restore

finish
