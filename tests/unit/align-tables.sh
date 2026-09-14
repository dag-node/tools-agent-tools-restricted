#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/align-tables.sh
# Unit test for tools/align-tables.py, the formatter for the tables a comment carries. What it
# asserts is the property a reader checks by eye and a tool has to check mechanically: after a
# fix every separator in the block sits at one column, the `+` of the rule line included. The
# fixture is a truth table whose widest cell overflows its column, the case a majority vote gets
# wrong: it squeezes that row, where the column has to grow in every row. The three rules over a
# cell's own alignment are pinned with it -- the heading centred over its column, a column of
# numbers right, and a column padded wider than its content keeping that padding -- so a clean
# `check` says a `fix` would leave every line as it is. Two negatives close it: a paragraph whose
# lines happen to carry a pipe is left as written, and a second run is a no-op. A file that is not
# plain text is refused through the reader every formatter shares, reported and left as it was.
# A repo dev tool, not a deployed artifact, so the test runs from the checkout.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="${ROOT}/tools/align-tables.py"
section "align-tables: the comment table formatter (unit)"

if [[ ! -r "${TOOL}" ]]; then
    skip "align-tables" "tool not found at ${TOOL}"; finish; exit
fi
if ! command -v python3 >/dev/null 2>&1; then
    skip "align-tables" "python3 not available"; finish; exit
fi

mktestdir
f="${TESTDIR}/sample.sh"
# The verdict column is one short for `require-not-enforcing`, so that row's separators sit one
# column right of every other row's. The status column is counts, the mgrdom column is padded
# three wider than its content, and the last comment paragraph carries a pipe in prose.
cat > "${f}" <<'EOF'
#!/usr/bin/env bash
#   enf | mod | mgrdom          | verdict              | status
#   ----+-----+-----------------+----------------------+-------
#   no  |  -  |        -        | ok                   | 1
#   no  |  -  |        -        | require-not-enforcing | 20
#   yes | yes | init/unconf/""  | mislabel             | 3
#
# The order and the `|| true` are load-bearing: a bare `printf | systemd-cat` pipeline whose
# systemd-cat fails aborts the whole updater, and aborts it silently.
x=1
cat > /dev/null <<'INNER'
#   on   | verdict
#   yes | ok
#   no  | refuse: this row's separator sits one column left of the heading's, as the data has it
INNER
EOF
cp "${f}" "${TESTDIR}/before.sh"

# separators <line-range>: the distinct separator-column shapes the block holds, one when aligned
separators() { awk -v a="$1" -v b="$2" 'NR>=a && NR<=b {
        s = ""; for (i = 1; i <= length($0); i++) { c = substr($0, i, 1); if (c == "|" || c == "+") s = s i "," }
        print s }' "${f}" | sort -u | wc -l; }

# (1) `check` reports the block and exits non-zero.
if out="$(python3 "${TOOL}" check "${f}" 2>&1)"; then
    fail "check passed a misaligned table: ${out}"
else
    if grep -q 'do not line up' <<<"${out}"; then
        pass "check reports a table whose cells do not line up, and exits non-zero"
    else
        fail "check exited non-zero without naming the table: ${out}"
    fi
fi

# (2) `fix` lines every separator up, the rule line's `+` with them.
python3 "${TOOL}" fix "${f}" >/dev/null
if [[ "$(separators 2 6)" -eq 1 ]]; then
    pass "every separator in the block sits at one column after a fix"
else
    fail "the separators still differ: $(sed -n '2,6p' "${f}")"
fi

# (3) The wide cell widened the column; it was not squeezed.
if grep -qF '| require-not-enforcing |' "${f}" && grep -qF '| ok                    |' "${f}"; then
    pass "the column widened to its widest cell, and the other rows with it"
else
    fail "the wide row was squeezed: $(sed -n '2,6p' "${f}")"
fi

# (4) The heading is centred over its column, a column of counts is right, and a column padded
# wider than its content keeps the padding.
# The heading's padding is read off the cell rather than written out here. An odd space falls
# right, so the text sits nearer the left: the left padding is never the larger of the two.
if awk 'NR==2 { n = split($0, cell, /\|/); c = cell[3]
        left = match(c, /[^ ]/) - 1; right = match(reverse(c), /[^ ]/) - 1
        exit !(left > 1 && right > 1 && left <= right && (right - left <= 1)) }
    function reverse(s,   i, r) { for (i = length(s); i > 0; i--) r = r substr(s, i, 1); return r }' \
        "${f}"; then
    pass "the heading row is centred over its columns"
else
    fail "the heading was not centred: $(sed -n '2p' "${f}")"
fi
# A right-aligned count ends its line, so the three rows end at one column.
if [[ "$(awk 'NR>=4 && NR<=6 { print length($0) }' "${f}" | sort -u | wc -l)" -eq 1 ]] \
        && grep -qE '\| +1$' "${f}" && grep -qE '\| +20$' "${f}"; then
    pass "a column of numbers is right-aligned"
else
    fail "the counts are not right-aligned: $(sed -n '4,6p' "${f}")"
fi
if grep -qF '|        -        |' "${f}"; then
    pass "a column padded wider than its content keeps that padding"
else
    fail "the padded column was narrowed: $(sed -n '4p' "${f}")"
fi

# (5) A pipe in prose lands where the line before it has none, so such a paragraph never reaches
# the formatter.
if diff <(grep -A1 'load-bearing' "${TESTDIR}/before.sh") <(grep -A1 'load-bearing' "${f}") >/dev/null; then
    pass "a paragraph whose lines carry a pipe is left as written"
else
    fail "prose with a pipe was read as a table: $(grep -A1 'load-bearing' "${f}")"
fi

# A table inside a heredoc body is the data's, not the file's: this test's own fixture is written
# from one, so a tool that read it would rewrite what the suite drives.
if diff <(grep -A2 'on  | verdict' "${TESTDIR}/before.sh") <(grep -A2 'on  | verdict' "${f}") >/dev/null; then
    pass "a misaligned table inside a heredoc body is left as written"
else
    fail "a heredoc body's table was rewritten: $(grep -A2 'on  | verdict' "${f}")"
fi

# (6) Idempotent, and `check` is then silent and exits 0 -- a clean check says a fix would leave
# every line as it is, which is what lets the two be run in either order.
cp "${f}" "${TESTDIR}/once.sh"
python3 "${TOOL}" fix "${f}" >/dev/null
if cmp -s "${f}" "${TESTDIR}/once.sh"; then
    pass "a second fix is a no-op"
else
    fail "a second fix changed the file: $(diff "${TESTDIR}/once.sh" "${f}" | head -4)"
fi
if out="$(python3 "${TOOL}" check "${f}" 2>&1)" && [[ -z "${out}" ]]; then
    pass "check is silent on the fixed file and exits 0"
else
    fail "check still reports the fixed file: ${out}"
fi

# (8) A file that is not plain text is refused: reported with the reason, left byte-identical,
# and the run exits 1 while the file named beside it is still checked. The reader is the one
# every formatter here shares (`tools/text_file.py`); the full set of shapes it refuses is pinned
# in `fill-markdown.sh`.
esc="${TESTDIR}/escape.sh"
printf '# a | b\n# \033[31mc\033[0m | d\n' > "${esc}"
cp "${esc}" "${TESTDIR}/escape.before"
rc=0; out="$(python3 "${TOOL}" check "${esc}" "${TESTDIR}/before.sh" 2>&1)" || rc=$?
if [[ "${rc}" -eq 1 ]] && grep -qF "align-tables: refused ${esc}: line 2 holds U+001B" <<<"${out}" \
        && cmp -s "${esc}" "${TESTDIR}/escape.before" \
        && grep -q 'before.sh:2: table cells do not line up' <<<"${out}"; then
    pass "a file holding an escape sequence is refused and reported; the file beside it is checked"
else
    fail "the refusal did not hold (rc ${rc}): ${out}"
fi

finish
