#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/fill-comments.sh
# Unit test for tools/fill-comments.sh, the Emacs-driven formatter for the comment wrap rule
# (tools/emacs/ai-tools-fill.el). A formatter that rewrites source files is judged on the lines it
# leaves as they were as much as on the lines it fills, so one fixture carries every shape: a long
# prose paragraph, which must come back inside the column and with no line ending on a tie word --
# the filler's own rule, which no checker reads; and an aligned comment table, a linter directive,
# a commented default, a shebang and a code line, each of which must come back byte-identical.
# A second run must leave the file as the first left it, and `--lines` must confine the fill to a
# paragraph it names. Where the checker is present its `--wrap` mode is the oracle for the filled
# paragraph. A repo dev tool, not a deployed artifact, so the test runs from the checkout; skipped
# without Emacs.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="${ROOT}/tools/fill-comments.sh"
PC="${ROOT}/src/usr/share/ai-tools/skills/ai-tools-technical-docs/prose-check.py"
section "fill-comments: the comment wrap formatter (unit)"

if [[ ! -r "${TOOL}" ]]; then
    skip "fill-comments" "tool not found at ${TOOL}"; finish; exit
fi
if ! command -v emacs >/dev/null 2>&1; then
    skip "fill-comments" "emacs not installed"; finish; exit
fi

mktestdir
f="${TESTDIR}/sample.sh"
cat > "${f}" <<'EOF'
#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/sample.sh
# The helper reads the list from the operator whose allowlist covers the path, and it acts only on a path that operator or the sandbox account holds, so a foreign-owned file is left untouched by the walk.
#
#   name          what it holds
#   comment-width  a line over the column
#KEY=a default that is a setting rather than prose, however long the line runs on past the column
# shellcheck disable=SC2034  # read by the sourced library, whose contract names the
x=1
# ── A section banner ──────────────────────────────────────────────────
# A banner is followed by prose at once, and the prose is filled on its own while the banner stays where it is.
y=2   # a trailing comment is code to the filler
# A paragraph that a checker marker follows at once, which the filler must leave on its own line.
# ref-index: ignore-file
z=3
# A sentence that ends here.
# Another sentence follows it.
w=4
# A paragraph that a doc comment's contract lines follow, long enough to need rewrapping at the column.
# args:  <user> <systemctl args...>
# $1 path  $2 existed(1/0)  $3 kept(1/0)  $4 detail (optional parenthetical)
# ai_tools_example <arg>   -- an aligned signature line whose columns are a table, not a sentence
q=5
# on  | verdict
# yes | ok
# no  | refuse and say why, in a line long enough that a filler would otherwise rewrap it here
r=6
cat > /dev/null <<'INNER'
# A seeded config header inside a heredoc body: data this file writes rather than prose of its own, and long enough that a filler would want to rewrap it.
INNER
# <![CDATA[
# a CDATA payload the reader gets byte for byte, long enough that a filler would rewrap it
# ]]>
# <pre>
# preformatted output whose line breaks are content, long enough that a filler would rewrap it
# </pre>
s=7
# Spans stay whole: a sentence long enough to reach the column where `ai-tools --status` is named, then a span wider than the column, `sudo ai-tools-admin selinux groups enable tmpmap apphost localipc buildexec`, and the tie rule beside a span, so that no line ends on the `750 root:root` mode of the pin.
t=8
EOF
cp "${f}" "${TESTDIR}/before.sh"

if bash "${TOOL}" --width 72 "${f}" >/dev/null 2>&1; then
    pass "the tool runs over a shell file"
else
    fail "the tool failed: $(bash "${TOOL}" --width 72 "${f}" 2>&1 | tail -3)"; finish; exit
fi

# (1) The prose paragraph is filled: inside the column, several lines, and clean under `--wrap`.
para="$(sed -n '4,/^#$/p' "${f}" | sed '$d')"
if (( $(wc -l <<< "${para}") > 1 )) && awk 'length > 72 {exit 1}' <<< "${para}"; then
    pass "the long paragraph is filled at 72 columns"
else
    fail "the paragraph was not filled at 72: $(printf '%s' "${para}" | head -3)"
fi
if [[ -r "${PC}" ]] && command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "${para}" > "${TESTDIR}/para.sh"
    if python3 "${PC}" --wrap --width 72 "${TESTDIR}/para.sh" >/dev/null 2>&1; then
        pass "the filled paragraph holds to the column (checker --wrap)"
    else
        fail "the filled paragraph breaks the width rule: $(python3 "${PC}" --wrap --width 72 "${TESTDIR}/para.sh" 2>&1 | head -4)"
    fi
else
    skip "width oracle" "prose-check.py or python3 not available"
fi

# Which word may end a line is the FORMATTER's alone -- prose-check measures width and does not
# read a line's last word -- so the tie behaviour is asserted here, against the set the filler
# itself declares.
# A word closing a sentence is not a tie, so the last line of the paragraph is read like any other.
ties="$(sed -n '/defconst ai-tools-tie-words/,/^ *"/p' "${ROOT}/tools/emacs/ai-tools-fill.el" \
    | tr -d "'()\"" | tr ' ' '\n' | grep -E '^[a-z]+$' | sort -u)"
if [[ -z "${ties}" ]]; then
    skip "tie behaviour" "the filler's word list could not be read from ai-tools-fill.el"
elif ! awk -v ties="${ties}" '
        BEGIN { n = split(ties, t, "\n"); for (i = 1; i <= n; i++) tie[t[i]] = 1 }
        { last = $NF
          if (last ~ /[.!?]$/) next          # a tie word closing a sentence is not a tie
          sub(/[^a-zA-Z]+$/, "", last)
          if (tolower(last) in tie) exit 1 }' <<< "${para}"; then
    fail "the filler left a line ending on a tie word: $(printf '%s' "${para}" | head -3)"
else
    pass "the filler ends no line on a tie word (its own fill-nobreak-predicate)"
fi

# A sentence that ended a line joins the next with ONE space. Emacs adds a second one at such a
# join and only the squeeze pass takes it back, so a fill that skips that pass doubles the space
# on every sentence a paragraph carries -- silently, and on every line the formatter touches.
if grep -qxF '# A sentence that ends here. Another sentence follows it.' "${f}"; then
    pass "a sentence that ended a line joins the next with one space"
else
    fail "the join doubled the sentence space: $(grep -n 'ends here' "${f}")"
fi

# (2) Every other shape comes back byte-identical.
same() {  # same <description> <before-pattern>: the matching line is unchanged and still present
    if grep -qxF -- "$(grep -F -- "$2" "${TESTDIR}/before.sh")" "${f}"; then pass "$1 is left as it was"
    else fail "$1 was rewritten"; fi
}
same "the shebang"            '#!/usr/bin/env bash'
same "the SPDX header"        'SPDX-License-Identifier'
same "the path line"          '# tests/unit/sample.sh'
same "a linter directive"     'shellcheck disable'
same "the table header"       'name          what it holds'
same "a table row"            'comment-width  a line'
same "a commented default"    '#KEY=a default'
same "a section banner"       '# ── A section banner'
same "a code line with a trailing comment" 'y=2   #'
# A checker marker joined into the paragraph it follows stops marking, so it ends the run before it.
same "a checker marker line"  '# ref-index: ignore-file'
# A contract line and an aligned signature are code: their columns are read as written, and a
# fill that takes one for a sentence wraps the columns away and leaves the fragment mid-paragraph.
same "an args: contract line"  '# args:  <user>'
same "a positional contract line" '# $1 path  $2 existed'
same "an aligned signature line" '# ai_tools_example <arg>'
# A table's rows are prose-shaped, and its columns are carried by a vertical rule the next row
# repeats at the same column. Its cells are two spaces apart at most, so the three-space column
# rule does not reach it and the rule reading the vertical is what leaves it as written.
same "a comment table's heading row" '# on  | verdict'
same "a comment table's widest row"  '# no  | refuse and say why'
# A heredoc body is data the file writes, so a comment marker in it is that data's. The mode's
# syntax is what says so, which is why the fixture is a shell file with a real heredoc in it.
same "a comment line inside a heredoc body" '# A seeded config header inside a heredoc body'
# A CDATA section and a `<pre>` block hold text a reader gets byte for byte, so a line break in
# one is content. Neither is in the tree yet; the rule is here before the first one arrives.
same "a CDATA payload line" '# a CDATA payload the reader gets'
same "a <pre> block line"   '# preformatted output whose line breaks are content'
if (( $(grep -c 'A paragraph that a doc comment' "${f}") == 1 )) \
        && grep -q '^# A paragraph that a doc comment' "${f}" \
        && ! grep -q "contract lines follow, long enough to need rewrapping at the column." "${f}"; then
    pass "the paragraph before a contract line is filled, and ends there"
else
    fail "the run did not end at the contract line: $(grep -n -A2 'A paragraph that a doc' "${f}")"
fi
# The prose after the banner is filled on its own: it still opens on the line after the banner,
# it now spans several lines, and no line of it runs past the column.
after="$(awk '/A section banner/ {on=1; next} /^y=2/ {on=0} on' "${f}")"
if [[ "${after}" == "# A banner is followed by prose at once,"* ]] && (( $(wc -l <<< "${after}") > 1 )) \
        && awk 'length > 72 {exit 1}' <<< "${after}"; then
    pass "prose after a banner is filled on its own, without absorbing the banner"
else
    fail "the paragraph after the banner was not filled as expected: $(printf '%s' "${after}" | head -3)"
fi

# A break never falls inside a code span: the literal a span holds is what `git grep` finds, and
# only on one line. The rule is the Markdown filler's, which takes the span's definition from the
# checker; this filler states it again, so it is asserted here on its own output.
span_whole() {  # span_whole <literal>: PASS when the filled fixture holds the literal on one line
    if [[ "$(grep -c -F -- "$1" "${f}")" -ge 1 ]]; then pass "code span whole on one line: $1"
    else fail "code span split across lines: $1"; fi
}
span_whole 'ai-tools --status'
span_whole '750 root:root'
# shellcheck disable=SC2016
if grep -qxF -- '# `sudo ai-tools-admin selinux groups enable tmpmap apphost localipc buildexec`,' "${f}"; then
    pass "a span wider than the column runs the line over, on a line of its own"
else
    fail "a span wider than the column was split: $(grep -n 'selinux groups' "${f}")"
fi

# (3) Idempotent: a second run leaves the file as the first left it.
cp "${f}" "${TESTDIR}/once.sh"
bash "${TOOL}" --width 72 "${f}" >/dev/null 2>&1
if cmp -s "${f}" "${TESTDIR}/once.sh"; then
    pass "a second run is a no-op"
else
    fail "a second run changed the file: $(diff "${TESTDIR}/once.sh" "${f}" | head -4)"
fi

# (4) `--lines` confines the fill to a paragraph meeting a range, which is how tools/format.sh
# fills what a diff touched: naming the banner's paragraph alone fills it and leaves the header
# paragraph as written.
cp "${TESTDIR}/before.sh" "${f}"
banner_line="$(grep -n 'A banner is followed' "${f}" | cut -d: -f1)"
bash "${TOOL}" --width 72 --lines "${banner_line}-${banner_line}" "${f}" >/dev/null 2>&1
if grep -qxF -- "$(sed -n 4p "${TESTDIR}/before.sh")" "${f}" \
        && (( $(awk '/A section banner/ {on=1; next} /^y=2/ {on=0} on' "${f}" | wc -l) > 1 )); then
    pass "--lines fills the named paragraph and leaves the other as written"
else
    fail "--lines did not scope the fill: $(diff "${TESTDIR}/before.sh" "${f}" | head -6)"
fi

finish
