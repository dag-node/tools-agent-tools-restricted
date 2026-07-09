#!/usr/bin/env bash
# tests/unit/reclaim.sh
# Hermetic unit tests for the deployed ai-tools-reclaim helper: it hands agent-owned files under a
# project back to the operator via ai-tools-chown, including the .git tree the sweeps skip, while
# leaving the heavy/transient trees (node_modules, ...) agent-owned -- and --full reclaims those
# too. Runs the installed helper against a /tmp testdir + dummy allowlist; writes nothing outside.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly HELPER="/usr/local/sbin/ai-tools/ai-tools-reclaim"
section "ai-tools-reclaim: on-demand ownership reclaim (unit)"

if [[ ! -x "${HELPER}" ]]; then
    skip "ai-tools-reclaim" "not installed at ${HELPER}"; finish; exit
fi

mktestdir
proj="${TESTDIR}/proj"
mkdir -p "${proj}/.git/objects/ab" "${proj}/node_modules/pkg" "${proj}/src"
mk_allowlist "${proj}"

# Agent-owned fixtures: a work-tree file, a .git object, a node_modules file.
wt="${proj}/src/app.js";            : > "${wt}"
go="${proj}/.git/objects/ab/obj";   : > "${go}"
nm="${proj}/node_modules/pkg/i.js"; : > "${nm}"

own() { stat -c '%U' "$1" 2>/dev/null; }

# (0) Two-phase, empty set: nothing agent-owned yet (the fixtures are root-owned), so
# the collect phase reports exactly that and stops before any confirmation or change.
noop_out="$(setsid "${HELPER}" "${proj}" < /dev/null 2>&1 > /dev/null || true)"
if grep -qF "nothing to reclaim" <<<"${noop_out}"; then
    pass "a tree with nothing agent-owned reports 'nothing to reclaim'"
else
    fail "no-op run did not report 'nothing to reclaim': ${noop_out}"
fi

chown -R "${SANDBOX_USER}:${SANDBOX_GROUP}" "${proj}"

# (A) Default: work tree + .git reclaimed to the operator; node_modules left agent-owned.
# Under setsid there is no controlling tty, so the batch confirm takes its yes default;
# the helper reports the pre-scan count and the handed-back total on stderr.
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

# (B) --full also reclaims the heavy trees.
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

finish
