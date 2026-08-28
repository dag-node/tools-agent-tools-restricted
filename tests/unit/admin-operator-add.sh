#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/admin-operator-add.sh
# Unit test for report_operator_role -- the lines `ai-tools-admin operator add` prints to say which
# of the two operator shapes the enrolment just produced: one that can claim projects, or one whose
# projects another operator claims for it.
#
# Worth pinning because the verdict is read out of sudo, the class that was already wrong once in
# this stack: `sudo -l` refuses SILENTLY (non-zero, no output), so a reading of it that matched a
# refusal MESSAGE matched a message sudo never sends. The property under test here is the other
# half of that lesson -- a sudo which fails for its OWN reasons must read as undetermined, never as
# a verdict about the account, because an administrator acts on this line at the moment of the
# decision and a false "no grant" sends them to a --for workflow they do not need.
#
# Each case runs in its own bash, because the helper and the harness both declare SANDBOX_USER
# readonly. sudo is stubbed as a shell FUNCTION, which overrides the PATH lookup, so no executable
# shim is needed (and the test works where /tmp is noexec) and no real sudoers is consulted. The
# helper is SOURCED, not run: its root check and its dispatch are guarded for exactly this, so one
# function is driven with no host to administer and nothing written anywhere.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Installed copy first, then the source tree. The only substitution the install applies to this
# file is the sandbox account name, which this function does not read.
HELPER="/usr/local/libexec/ai-tools/ai-tools-admin"
[[ -r "${HELPER}" ]] || HELPER="${ROOT}/src/usr/local/libexec/ai-tools/ai-tools-admin.sh"

section "ai-tools-admin operator add: the sudo-grant report (unit)"

if [[ ! -r "${HELPER}" ]]; then
    skip "operator add report" "helper not readable (neither installed nor in a checkout)"
    finish; exit
fi

# run_report <command-probe-rc> <list-probe-rc> -- source the helper in a fresh shell with sudo
# stubbed, drive report_operator_role for one account, and echo everything it said. The stub keys
# on the claim helper's path, which is the operand of the first probe and absent from the second,
# so the two probes are answered independently.
run_report() {
    bash -c '
        set -euo pipefail
        # shellcheck source=/dev/null
        source "$1"
        declare -F report_operator_role >/dev/null 2>&1 || { printf "NO SUCH FUNCTION\n"; exit 0; }
        CMD_RC="$2"; LIST_RC="$3"
        sudo() {
            local arg
            for arg in "$@"; do
                [[ "${arg}" == */ai-tools-lockdown ]] && return "${CMD_RC}"
            done
            return "${LIST_RC}"
        }
        report_operator_role svc-op
    ' _ "${HELPER}" "$1" "$2" 2>&1 || true
}

out="$(run_report 0 0)"
if [[ "${out}" == *"NO SUCH FUNCTION"* ]]; then
    fail "sourcing ${HELPER} did not define report_operator_role"
    finish; exit
fi

# 1. The grant is there: sudo answers for the claim helper, and the account needs nothing further.
if [[ "${out}" == *"holds a general sudo grant"* && "${out}" != *"--for"* ]]; then
    pass "a listed claim helper reports the grant, with no --for advice"
else
    fail "grant present should report the grant alone, got: ${out}"
fi

# 2. Refused while sudo answers: the ai-ops-only account this report exists for. It is a supported
#    shape, so the line names the command another operator claims with rather than refusing.
out="$(run_report 1 0)"
if [[ "${out}" == *"holds no general sudo grant"* \
        && "${out}" == *"ai-tools --project-claim --for svc-op"* ]]; then
    pass "a refused claim helper reports no grant and names the --for command"
else
    fail "refusal should report no grant plus the --for command, got: ${out}"
fi

# 3. sudo failing for its own reasons: indistinguishable from case 2 on the first probe alone, and
#    the reason the second exists. It must not become a verdict about the account.
out="$(run_report 1 1)"
if [[ "${out}" == *"undetermined"* && "${out}" != *"holds no general sudo grant"* ]]; then
    pass "a sudo that answers nothing reports undetermined, not a verdict"
else
    fail "an unanswering sudo must not read as a missing grant, got: ${out}"
fi

# 4. No sudo at all: nothing on the host can claim, which is a statement about the host rather than
#    about this account, and the enrolment it just did still stands.
out="$(bash -c '
    set -euo pipefail
    # shellcheck source=/dev/null
    source "$1"
    # Emptied only after the helper is loaded, so the shell itself still started: what is under
    # test is the branch that runs when sudo cannot be found, not a shell without a PATH.
    PATH="$2"
    report_operator_role svc-op
' _ "${HELPER}" "${TESTDIR:-/nonexistent}/no-such-bin-dir" 2>&1 || true)"
if [[ "${out}" == *"no sudo on this host"* && "${out}" == *"can still launch agent sessions"* ]]; then
    pass "no sudo on PATH reports the host limit, not a verdict about the account"
else
    fail "a host without sudo should report the host limit, got: ${out}"
fi

finish
