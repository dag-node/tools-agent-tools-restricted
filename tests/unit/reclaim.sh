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
# a fixture this suite can place.
reclaim_source="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/src/usr/local/libexec/ai-tools/ai-tools-reclaim.sh"
[[ -r "${reclaim_source}" ]] || reclaim_source="${HELPER}"
fold_function="$(awk '/^_report_child_messages\(\) \{/,/^}/' "${reclaim_source}")"
if [[ -z "${fold_function}" ]]; then
    fail "${reclaim_source} does not define _report_child_messages"
else
    printf '%s\n' MSG-B8U2 "registry line refused -- /home/op/r line 2" "a secret-named file: /p/a" $'\036' \
        MSG-B8U2 "registry line refused -- /home/op/r line 2" MSG-B8U2 "registry line refused -- /home/op/r line 2" \
        $'\036' MSG-B8U2 "registry line refused -- /home/op/r line 2" $'\036' > "${TESTDIR}/children.err"
    fold_out="$(bash -c "${fold_function}"$'\n''_report_child_messages "$1"' _ "${TESTDIR}/children.err" 2>&1)"
    fold_want="MSG-B8U2"$'\n'"registry line refused -- /home/op/r line 2 (3 paths)"$'\n'"a secret-named file: /p/a"
    if [[ "${fold_out}" == "${fold_want}" ]]; then
        pass "a message three children wrote prints once with (3 paths); a child repeating it counts once"
    else
        fail "the children's messages fold: got '${fold_out//$'\n'/~}', expected '${fold_want//$'\n'/~}'"
    fi
fi

finish
