#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/reclaim.sh
# Hermetic unit tests for the deployed ai-tools-reclaim helper: it hands agent-owned files under a project back
# to the operator via ai-tools-chown, including the .git tree the sweeps skip, while leaving the heavy/transient trees
# (node_modules, ...) agent-owned -- and `--full` reclaims those too. Runs the installed helper against a /tmp testdir +
# dummy allowlist; does not write a path outside.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly HELPER="/usr/local/libexec/ai-tools/ai-tools-reclaim"
section "ai-tools-reclaim: on-demand ownership reclaim (unit)"

if [[ ! -x "${HELPER}" ]]; then
    skip "ai-tools-reclaim" "not installed at ${HELPER}"; finish; exit
fi

mktestdir
proj="${TESTDIR}/proj"
mkdir -p "${proj}/.git/objects/ab" "${proj}/node_modules/pkg" "${proj}/src"
mk_allowlist "@ ${proj}"

# Agent-owned fixtures: a work-tree file, a .git object, a node_modules file.
wt="${proj}/src/app.js";            : > "${wt}"
go="${proj}/.git/objects/ab/obj";   : > "${go}"
nm="${proj}/node_modules/pkg/i.js"; : > "${nm}"

own() { stat -c '%U' "$1" 2>/dev/null; }

# (0) Two-phase, empty set: no path agent-owned yet (the fixtures are root-owned), so the collect phase reports exactly
# that and stops before any confirmation or change.
noop_out="$(setsid "${HELPER}" "${proj}" < /dev/null 2>&1 > /dev/null || true)"
# The code separates this outcome from the refusal of a path no allowlist covers, which reports an empty hand-back set
# as well.
assert_msg MSG-J6B2 "${noop_out}" "a tree with nothing agent-owned reports the empty hand-back set"

chown -R "${SANDBOX_USER}:${SANDBOX_GROUP}" "${proj}"

# (A) Default: work tree + .git reclaimed to the operator; node_modules left agent-owned. Under setsid there is no
# controlling tty, so the batch confirm takes its yes default; the helper reports the pre-scan count and the handed-back
# total on stderr.
runA_out="$(setsid "${HELPER}" "${proj}" < /dev/null 2>&1 > /dev/null || true)"
if [[ "$(own "${wt}")" == "${PROJECTS_USER}" && "$(own "${go}")" == "${PROJECTS_USER}" ]]; then
    pass "default reclaims the work tree and .git to ${PROJECTS_USER}"
else
    fail "default did not reclaim: app.js=$(own "${wt}") .git/obj=$(own "${go}")"
fi
if grep -qE 'agent-owned path\(s\) under' <<<"${runA_out}" \
        && grep -qE 'handed back [0-9]+ path\(s\)' <<<"${runA_out}"; then
    pass "batch run reports the pre-scan count and the handed-back total"
else
    fail "batch run output missing count/summary: ${runA_out}"
fi
if [[ "$(own "${nm}")" == "${SANDBOX_USER}" ]]; then
    pass "default leaves node_modules agent-owned (heavy tree skipped)"
else
    fail "default unexpectedly reclaimed node_modules: $(own "${nm}")"
fi

# (B) `--full` also reclaims the heavy trees.
setsid "${HELPER}" --full "${proj}" < /dev/null > /dev/null 2>&1 || true
if [[ "$(own "${nm}")" == "${PROJECTS_USER}" ]]; then
    pass "--full reclaims node_modules too"
else
    fail "--full did not reclaim node_modules: $(own "${nm}")"
fi

# (C) a path no operator's allowlist covers is left untouched (fail-closed).
out="${TESTDIR}/outside"; mkdir -p "${out}/sub"; of="${out}/sub/f"; : > "${of}"
chown -R "${SANDBOX_USER}:${SANDBOX_GROUP}" "${out}"
setsid "${HELPER}" "${out}" < /dev/null > /dev/null 2>&1 || true
if [[ "$(own "${of}")" == "${SANDBOX_USER}" ]]; then
    pass "a non-allowlisted path is left untouched (fail-closed)"
else
    fail "non-allowlisted path was reclaimed: $(own "${of}")"
fi

# (D) The children's stderr is folded: a message every ai-tools-chown child writes -- a refused registry of another
# operator, which each child loads again -- prints once with the number of paths, ahead of the tally. Driven on the fold
# itself, from the checkout's helper where the suite runs from one, since a second operator's refused registry is not
# a fixture this suite can place. The fold's two globals and two functions are extracted and run in a shell of their
# own; each child's text is one call.
reclaim_source="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/src/usr/local/libexec/ai-tools/ai-tools-reclaim.sh"
[[ -r "${reclaim_source}" ]] || reclaim_source="${HELPER}"
fold_code="$(grep -E '^declare -(A|a) CHILD_MESSAGE' "${reclaim_source}"
             awk '/^_fold_child_messages\(\) \{/,/^}/' "${reclaim_source}"
             awk '/^_print_folded_child_messages\(\) \{/,/^}/' "${reclaim_source}")"
if [[ "${fold_code}" != *'_fold_child_messages() {'* || "${fold_code}" != *'_print_folded_child_messages() {'* \
        || "${fold_code}" != *'declare -A CHILD_MESSAGE_COUNT'* ]]; then
    fail "${reclaim_source} does not define the fold's globals and functions"
else
    refused=$'MSG-B8U2\nregistry line refused -- /home/op/r line 2'
    # Six children: one writes the refusal and a secret notice, one writes the refusal twice, one the refusal alone,
    # one nothing, one a plain line beside a coded one, and one ends on a code line alone.
    fold_out="$(bash -c "${fold_code}"'
        _fold_child_messages "$1"; _fold_child_messages "$2"; _fold_child_messages "$3"; _fold_child_messages ""
        _fold_child_messages "$4"; _fold_child_messages "$5"; _print_folded_child_messages' _ \
        "${refused}"$'\na secret-named file: /p/a' "${refused}"$'\n'"${refused}" "${refused}" \
        $'chown: a plain line\nMSG-T9M5\ndeclined' $'MSG-J4W5' 2>&1)"
    fold_want="${refused} (3 paths)"$'\n''a secret-named file: /p/a'$'\n''chown: a plain line'$'\n'
    fold_want+=$'MSG-T9M5\ndeclined\nMSG-J4W5'
    if [[ "${fold_out}" == "${fold_want}" ]]; then
        pass "a message three children wrote prints once with (3 paths); a repeat in one child counts once"
    else
        fail "the children's messages fold: got '${fold_out//$'\n'/~}', expected '${fold_want//$'\n'/~}'"
    fi
fi

# (E) A signal stops the handback after the child in flight is counted: bash runs the trap once the child's command
# substitution completes, so the stop reports that child's notice and counts its path, and the next child does not
# start. Driven on the loop extracted from the same source as (D), with ai-tools-chown a shell function that marks
# its path, waits a second, and writes a coded notice; the same run without the signal is the control. Three more
# signals land at a command boundary, sent from a DEBUG trap on the command SIGNAL_AT opens: one ahead of the first
# child, which must start no child; one between the stop read and the first child's start, where the trap runs after
# that child, which must be counted and the stop reported after it; and one at the trap removal, which must still report
# the stop.
loop_code="$(printf '%s\n' "${fold_code}"
             awk '/^_stop_on_signal\(\) \{/,/^}/' "${reclaim_source}"
             awk '/^declare -i confirmed=0/ { on = 1 } on { print } on && /^trap - INT TERM$/ { getline; print; exit }' \
                 "${reclaim_source}")"
# shellcheck disable=SC2016  # the loop header and the last stop read are matched as the helper's own text
if [[ "${loop_code}" != *'_stop_on_signal() {'* || "${loop_code}" != *'for path in "${paths[@]}"; do'* \
        || "${loop_code}" != *$'trap - INT TERM\n(( stop_status )) && _stop_on_signal "${stop_status}"' ]]; then
    fail "${reclaim_source} does not define the handback loop and its signal stop"
else
    mkdir -p "${TESTDIR}/marks"
    # shellcheck disable=SC2016  # expanded by the inner bash, not here
    loop_run='set -euo pipefail
        trap '"'"'[[ -n "${SIGNAL_AT-}" && -z "${signal_sent-}" && "${BASH_COMMAND}" == "${SIGNAL_AT}"* ]] \
            && { signal_sent=1; kill -TERM $$; }'"'"' DEBUG
        warn() { printf "%s\n" "$*" >&2; }
        ai_tools_log__structured() { :; }
        chown_stub() { : > "${MARKS}/${2##*/}"; sleep 1; printf "MSG-T9M5\na secret-named file: %s\n" "$2" >&2; }
        CHOWN_BIN=chown_stub canonical=/p paths=(/p/a /p/b)
        '"${loop_code}"'
        printf "confirmed=%s\n" "${confirmed}"'
    stop_rc=0
    MARKS="${TESTDIR}/marks" bash -c "${loop_run}" > "${TESTDIR}/stop.out" 2>&1 &
    stop_pid=$!
    sleep 0.3
    kill -TERM "${stop_pid}"
    wait "${stop_pid}" || stop_rc=$?
    stop_out="$(< "${TESTDIR}/stop.out")"
    stop_marks="$(find "${TESTDIR}/marks" -type f | wc -l)"
    if (( stop_rc == 143 )) && [[ "$(grep -c '^a secret-named file: /p/a$' <<<"${stop_out}")" == 1 ]] \
            && grep -q 'stopped by a signal -- 1 path(s) handed back under /p' <<<"${stop_out}" \
            && (( stop_marks == 1 )); then
        pass "a signal during a child stops after it: its notice printed once, its path counted, exit 143"
    else
        fail "a signal during a child: exit ${stop_rc}, ${stop_marks} child(ren) started, output '${stop_out//$'\n'/~}'"
    fi
    rm -f "${TESTDIR}/marks/"*
    stop_rc=0
    stop_out="$(MARKS="${TESTDIR}/marks" SIGNAL_AT='child_messages=""' bash -c "${loop_run}" 2>&1)" || stop_rc=$?
    stop_marks="$(find "${TESTDIR}/marks" -type f | wc -l)"
    if (( stop_rc == 143 && stop_marks == 0 )) \
            && grep -q 'stopped by a signal -- 0 path(s) handed back under /p' <<<"${stop_out}"; then
        pass "a signal ahead of the first child starts no child and reports the stop with 0 paths"
    else
        fail "a signal ahead of the first child: exit ${stop_rc}, ${stop_marks} child(ren) started, output '${stop_out//$'\n'/~}'"
    fi
    rm -f "${TESTDIR}/marks/"*
    stop_rc=0
    # The read has passed and the child's command is next: bash runs the trap after that command, so the child starts.
    stop_out="$(MARKS="${TESTDIR}/marks" SIGNAL_AT='child_messages="$(' bash -c "${loop_run}" 2>&1)" || stop_rc=$?
    stop_marks="$(find "${TESTDIR}/marks" -type f | wc -l)"
    if (( stop_rc == 143 && stop_marks == 1 )) \
            && grep -q 'stopped by a signal -- 1 path(s) handed back under /p' <<<"${stop_out}"; then
        pass "a signal between the stop read and the child's start is read after that child: counted, stop reported, exit 143"
    else
        fail "a signal between the read and the child: exit ${stop_rc}, ${stop_marks} child(ren) started, output '${stop_out//$'\n'/~}'"
    fi
    rm -f "${TESTDIR}/marks/"*
    stop_rc=0
    stop_out="$(MARKS="${TESTDIR}/marks" SIGNAL_AT='trap - INT TERM' bash -c "${loop_run}" 2>&1)" || stop_rc=$?
    if (( stop_rc == 143 )) && grep -q 'stopped by a signal -- 2 path(s) handed back under /p' <<<"${stop_out}" \
            && ! grep -qx 'confirmed=2' <<<"${stop_out}"; then
        pass "a signal at the trap removal is read: the stop is reported with both paths, not a success"
    else
        fail "a signal at the trap removal: exit ${stop_rc}, output '${stop_out//$'\n'/~}'"
    fi
    rm -f "${TESTDIR}/marks/"*
    stop_rc=0
    stop_out="$(MARKS="${TESTDIR}/marks" bash -c "${loop_run}" 2>&1)" || stop_rc=$?
    if (( stop_rc == 0 )) && grep -qx 'confirmed=2' <<<"${stop_out}"; then
        pass "without a signal the same loop hands back both paths and exits 0 (the control)"
    else
        fail "the loop without a signal: exit ${stop_rc}, output '${stop_out//$'\n'/~}'"
    fi
fi

finish
