#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/fill-comments.sh
# Unit test for tools/fill-comments.sh, the Emacs-driven formatter for the comment wrap rule
# (tools/emacs/ai-tools-fill.el). A formatter that rewrites source files is judged on the lines it
# leaves as they were as much as on the lines it fills, so one fixture carries every shape: a long prose
# paragraph, which must come back inside the column with no line ending on a tie word; an
# aligned comment table, a linter directive, a commented default, a shebang and a code line,
# each of which must come back byte-identical; and a second run must leave the file as the first
# left it. Where the
# checker is present its --wrap mode is the oracle for the filled paragraph. A repo dev tool,
# not a deployed artifact, so the test runs from the checkout; skipped without Emacs.
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
#   comment-tie   a line ending on a tie word
#KEY=a default that is a setting rather than prose, however long the line runs on past the column
# shellcheck disable=SC2034  # read by the sourced library, whose contract names the
x=1
# ── A section banner ──────────────────────────────────────────────────
# A banner is followed by prose at once, and the prose is filled on its own while the banner stays where it is.
y=2   # a trailing comment is code to the filler
EOF
cp "${f}" "${TESTDIR}/before.sh"

if bash "${TOOL}" --width 72 "${f}" >/dev/null 2>&1; then
    pass "the tool runs over a shell file"
else
    fail "the tool failed: $(bash "${TOOL}" --width 72 "${f}" 2>&1 | tail -3)"; finish; exit
fi

# (1) The prose paragraph is filled: inside the column, several lines, and clean under --wrap.
para="$(sed -n '4,/^#$/p' "${f}" | sed '$d')"
if (( $(wc -l <<< "${para}") > 1 )) && awk 'length > 72 {exit 1}' <<< "${para}"; then
    pass "the long paragraph is filled at 72 columns"
else
    fail "the paragraph was not filled at 72: $(printf '%s' "${para}" | head -3)"
fi
if [[ -r "${PC}" ]] && command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "${para}" > "${TESTDIR}/para.sh"
    if python3 "${PC}" --wrap --width 72 "${TESTDIR}/para.sh" >/dev/null 2>&1; then
        pass "the filled paragraph ends no line on a tie word (checker --wrap)"
    else
        fail "the filled paragraph breaks the wrap rule: $(python3 "${PC}" --wrap --width 72 "${TESTDIR}/para.sh" 2>&1 | head -4)"
    fi
else
    skip "wrap oracle" "prose-check.py or python3 not available"
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
same "a table row"            'comment-tie   a line'
same "a commented default"    '#KEY=a default'
same "a section banner"       '# ── A section banner'
same "a code line with a trailing comment" 'y=2   #'
# The prose after the banner is filled on its own: it still opens on the line after the banner,
# it now spans several lines, and no line of it runs past the column.
after="$(awk '/A section banner/ {on=1; next} /^y=2/ {on=0} on' "${f}")"
if [[ "${after}" == "# A banner is followed by prose at once,"* ]] && (( $(wc -l <<< "${after}") > 1 )) \
        && awk 'length > 72 {exit 1}' <<< "${after}"; then
    pass "prose after a banner is filled on its own, without absorbing the banner"
else
    fail "the paragraph after the banner was not filled as expected: $(printf '%s' "${after}" | head -3)"
fi

# (3) Idempotent: a second run leaves the file as the first left it.
cp "${f}" "${TESTDIR}/once.sh"
bash "${TOOL}" --width 72 "${f}" >/dev/null 2>&1
if cmp -s "${f}" "${TESTDIR}/once.sh"; then
    pass "a second run is a no-op"
else
    fail "a second run changed the file: $(diff "${TESTDIR}/once.sh" "${f}" | head -4)"
fi

finish
