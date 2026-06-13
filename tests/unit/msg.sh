#!/usr/bin/env bash
# tests/unit/msg.sh
# Hermetic unit tests for the shared message formatter (msg.lib.sh): the box never
# exceeds 80 columns, every framed line is a '#' comment (paste-safe), the wrap never
# ends a line on a tie-word (preposition/article/conjunction) and never splits a single
# token (paths survive), and plain mode keeps a phrase on one line so the test suite's
# substring greps still match. Pure formatting -- no root, no install dependency: the
# library carries no token substitution, so the repo source IS the deployed artifact. The
# test validates the source of truth directly (so it never reports a false failure against a
# not-yet-redeployed installed copy), falling back to the installed path outside a checkout.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/src/usr/local/lib/ai-tools/msg.lib.sh"
[[ -r "${LIB}" ]] || LIB="/usr/local/lib/ai-tools/msg.lib.sh"
section "msg.lib.sh: box width, paste-safety, ties, plain-mode (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "msg.lib.sh" "not found at install path or in src/"; finish; exit
fi
# shellcheck source=/dev/null
source "${LIB}"

# Tie-words the wrap must never strand at a line end (subset of the library's set, the
# ones these fixtures exercise).
readonly TIES=" a an the and or nor but for of to in on at by with from into under via as "

# A long sentence whose natural break points fall on tie-words, plus a long unbreakable
# token (an absolute path) that must stay intact.
LONG="The agent writes files to the project and hands them back to you on the next turn \
for review by the operator, then waits at /opt/ai-tools/very/long/path/that/should/not/be/split/ever \
before it continues."

# (1) Box never exceeds 80 columns.
over="$(AI_TOOLS_MSG_BOX=1 ai_tools_msg NOTICE 1 "${LONG}" | awk '{ if (length($0) > 80) print }')"
if [[ -z "${over}" ]]; then
    pass "every framed line is <= 80 columns"
else
    fail "framed line(s) exceed 80 columns:"$'\n'"${over}"
fi

# (2) Every framed line starts with '#' (the whole block is a shell comment).
bad="$(AI_TOOLS_MSG_BOX=1 ai_tools_msg NOTICE 1 "${LONG}" | grep -vE '^(#|$)' || true)"
if [[ -z "${bad}" ]]; then
    pass "every framed line begins with '#' (paste-safe comment)"
else
    fail "framed line(s) do not begin with '#':"$'\n'"${bad}"
fi

# (3) No CONTENT line ends on a tie-word (the no-trailing-preposition rule). Content
# lines start "# " (rules start "#-"); strip the frame and inspect the last word.
tie_violation=""
while IFS= read -r l; do
    [[ "${l}" == '# '* ]] || continue          # skip the top/bottom rules
    body="${l#\# }"; body="${body%#}"           # drop "# " prefix and trailing "#"
    body="${body%"${body##*[![:space:]]}"}"     # rtrim padding
    last="${body##* }"
    if [[ "${TIES}" == *" ${last} "* ]]; then
        tie_violation="${l}"; break
    fi
done < <(AI_TOOLS_MSG_BOX=1 ai_tools_msg NOTICE 1 "${LONG}")
if [[ -z "${tie_violation}" ]]; then
    pass "no wrapped line ends on a tie-word"
else
    fail "a wrapped line ends on a tie-word: ${tie_violation}"
fi

# (4) A single over-long token (the path) is never split across lines.
if AI_TOOLS_MSG_BOX=1 ai_tools_msg NOTICE 1 "${LONG}" \
        | grep -qF '/opt/ai-tools/very/long/path/that/should/not/be/split/ever'; then
    pass "an unbreakable token (path) survives wrapping intact"
else
    fail "an unbreakable token was split across lines"
fi

# (5) Plain mode (non-tty / forced) keeps a multi-word phrase on ONE line so the suite's
# substring greps still match.
phrase='invalid or absent CLAUDE_EXEC -- cannot launch'
if AI_TOOLS_MSG_PLAIN=1 ai_tools_msg_error "claude-run: ${phrase}" 2>&1 \
        | grep -qF "${phrase}"; then
    pass "plain mode keeps the phrase on one line (grep-friendly)"
else
    fail "plain mode split or dropped the phrase"
fi

# (6) The box is framed: first line is a titled top rule, last a bottom rule.
mapfile -t boxlines < <(AI_TOOLS_MSG_BOX=1 ai_tools_msg ERROR 1 "short message")
if [[ -z "${boxlines[0]}" && "${boxlines[1]}" == '#-- ERROR '* && "${boxlines[-1]}" =~ ^#-+#$ ]]; then
    pass "box has a leading blank, a titled top rule, and a bottom rule"
else
    fail "box framing wrong: lead='${boxlines[0]}' top='${boxlines[1]}' bottom='${boxlines[-1]}'"
fi

# ── ai_tools_msg_block: titled guidance screen with verbatim commands ──────────────
# block() goes to stderr; capture it. Indented command lines stay verbatim (one line),
# a flush-left prose line wraps, and an over-wide command overflows the right border.
CMD='       /usr/local/bin/ai-tools --sandbox-create /a/very/long/path/that/overflows/the/right/border/of/the/box'
mapfile -t blk < <(AI_TOOLS_MSG_BOX=1 ai_tools_msg_block "This project is not claimed yet" \
    "Two ways to make the current directory available to the sandboxed agent:" \
    "" \
    "  1. Claim it in place:" \
    "       /usr/local/bin/ai-tools --project-claim" \
    "${CMD}" 2>&1)

# (7) The title sits in the top rule.
if [[ -z "${blk[0]}" && "${blk[1]}" == '#-- This project is not claimed yet '* ]]; then
    pass "block carries the requested border title"
else
    fail "block title wrong: '${blk[0]}'"
fi

# (8) Every block line begins with '#' (paste-safe), overflow line included.
if printf '%s\n' "${blk[@]}" | grep -qvE '^(#|$)'; then
    fail "a block line does not begin with '#'"
else
    pass "every block line begins with '#' (paste-safe)"
fi

# (9) A short indented command stays verbatim on ONE line (not wrapped/split).
if printf '%s\n' "${blk[@]}" | grep -qF '/usr/local/bin/ai-tools --project-claim'; then
    pass "an indented command stays verbatim on one line"
else
    fail "an indented command was reflowed"
fi

# (10) The over-wide command overflows intact (its own line > 80, whole command present).
over_line="$(printf '%s\n' "${blk[@]}" | grep -F 'overflows/the/right/border' || true)"
if [[ -n "${over_line}" && ${#over_line} -gt 80 ]] \
        && grep -qF -- '--sandbox-create /a/very/long/path/that/overflows/the/right/border/of/the/box' <<<"${over_line}"; then
    pass "an over-wide command overflows the border intact"
else
    fail "over-wide command not kept whole on its own line: '${over_line}'"
fi

# (11) Orphan control: a final single-word widow is pulled up. At width 74 the sample wraps
# to a "does." widow without it; with it, the tie-glued tail ("for what each does.") drops to
# the last line and the first line ends on a substantial word, not a little function word.
mapfile -t wl < <(ai_tools_msg_wrap 74 \
    "Both default to the current directory. See 'ai-tools --help' for what each does.")
if (( ${#wl[@]} == 2 )) && [[ "${wl[1]}" == *" "* && "${wl[0]}" == *"--help'" ]]; then
    pass "orphan control pulls the stranded tail down (no single-word widow)"
else
    fail "orphan control wrong: $(printf '[%s]' "${wl[@]}")"
fi

# (12) ai_tools_msg_pick returns the default with no terminal (setsid detaches /dev/tty), so
# an unattended run never blocks on input and takes the safe default.
sel="$(setsid bash -c 'source "'"${LIB}"'"; ai_tools_msg_pick 3 a b c' </dev/null 2>/dev/null || true)"
if [[ "${sel}" == "3" ]]; then
    pass "ai_tools_msg_pick yields the default when no terminal is present"
else
    fail "ai_tools_msg_pick did not default without a tty (got '${sel}')"
fi

# (13) Caller-IFS independence: the claude wrapper sets IFS=$'\n\t' (no space). The wrap must
# still split on spaces and wrap, not collapse the line into one over-wide unbreakable unit.
ifs_over="$(IFS=$'\n\t'; AI_TOOLS_MSG_BOX=1 ai_tools_msg ERROR 1 \
    "claude: /home/x/Development/NDF26/ClaudeCodeRestricted is not accessible to the sandbox now" \
    | awk '{ if (length($0) > 80) print }')"
if [[ -z "${ifs_over}" ]]; then
    pass "wrap is independent of the caller's IFS (no space) -- still wraps within 80"
else
    fail "caller IFS=\$'\\n\\t' broke wrapping (over-wide line):"$'\n'"${ifs_over}"
fi

# (14) Fixed-width mode: AI_TOOLS_MSG_FULLWIDTH pins every box to 80 columns regardless of
# content, so a sequence of prompts aligns. A short and a longer message must frame identically.
short_w="$(AI_TOOLS_MSG_BOX=1 AI_TOOLS_MSG_FULLWIDTH=1 ai_tools_msg ERROR 1 "short" | awk '/^#/&&!s{print length;s=1}')"
long_w="$(AI_TOOLS_MSG_BOX=1 AI_TOOLS_MSG_FULLWIDTH=1 ai_tools_msg ERROR 1 \
    "a considerably longer message that on its own would still fit under the cap" | awk '/^#/&&!s{print length;s=1}')"
if [[ "${short_w}" == "80" && "${long_w}" == "80" ]]; then
    pass "AI_TOOLS_MSG_FULLWIDTH pins boxes to a uniform 80 columns"
else
    fail "fixed-width frames not 80 cols (short=${short_w}, long=${long_w})"
fi

finish
