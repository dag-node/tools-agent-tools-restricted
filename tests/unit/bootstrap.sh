#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/bootstrap.sh
# Unit test for report_shadowed_operators -- the lines `ai-tools-admin system bootstrap` closes with when an enrolled
# operator's shell would run an agent of the launcher's name from somewhere other than /usr/local/bin.
#
# What gives it teeth is that this report is the last thing said before a host is treated as ready. A run that named
# nobody on a shadowed host would state readiness over an operator whose next `claude` starts an UNCONFINED session
# as them, and one that named an account on every host would be read past. So both directions are driven, and so is
# what the report tells the operator to do: the message names the account, the launcher and the binary that wins,
# and the two ways out are the enrolment command that ranks the wrapper first and the path to remove.
#
# The reading underneath it is path-order.lib.sh's and is pinned in unit/path-order.sh; what this file covers is
# the composition -- which operators are asked about, what is printed per record, that finding a fault does not become
# this command's exit status, and that no init file is written.
#
# The helper is SOURCED, not run: it stops at the guard before its provisioning, so one function is driven with no
# toolchain to install. Each case runs in its own bash, because the helper and the harness both declare SANDBOX_USER
# readonly. The libraries are sourced BEFORE the stubs, so the include guard makes the helper's own `source` a no-op
# and the stubs stand; the helper reads them at their installed paths, so a host without them skips rather than driving
# a different library.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="/usr/local/libexec/ai-tools/ai-tools-bootstrap"
[[ -r "${HELPER}" ]] || HELPER="${ROOT}/src/usr/local/libexec/ai-tools/ai-tools-bootstrap.sh"
PATH_ORDER_LIB="/usr/local/lib/ai-tools/path-order.lib.sh"
OPERATOR_LIB="/usr/local/lib/ai-tools/operator.lib.sh"
# Where a second agent of the wrapper's name is found on a real host. This project's wrapper is /usr/local/bin/claude;
# what can win ahead of it is the operator's own `npm i -g` under their nvm, or the vendor package's /usr/bin/claude --
# the same file as /bin/claude, which is the spelling the reading prints where /bin is the usr-merge symlink and PATH
# carries that form. Each is outside /usr/local/bin, so each shadows the wrapper, and the report names the one the shell
# would run.
SHADOW_NVM="/home/op/.nvm/versions/node/v22.0.0/bin/claude"
SHADOW_PKG="/usr/bin/claude"
SHADOW_MERGED="/bin/claude"

section "ai-tools-admin system bootstrap: the shadowed-operator report (unit)"

if [[ ! -r "${HELPER}" ]]; then
    skip "shadowed-operator report" "helper not readable (neither installed nor in a checkout)"
    finish; exit
fi
if [[ ! -r "${PATH_ORDER_LIB}" || ! -r "${OPERATOR_LIB}" ]]; then
    skip "shadowed-operator report" "the helper reads ${PATH_ORDER_LIB} and ${OPERATOR_LIB}, which this host has not deployed"
    finish; exit
fi

mktestdir
READ_MARKER="${TESTDIR}/read-was-taken"
WRITE_MARKER="${TESTDIR}/init-was-rewritten"

# run_report <stub-code> -- drive one case and echo everything it said, with the function's own status on a last `rc=`
# line. The stubs land between the libraries and the helper, which is the one order in which they survive: sourced first
# they would be overwritten, and sourced after the helper they would not be in place when it runs.
run_report() {
    bash -c '
        set -euo pipefail
        # shellcheck source=/dev/null
        source "$1"
        # shellcheck source=/dev/null
        source "$2"
        eval "$4"
        # shellcheck source=/dev/null
        source "$3"
        declare -F report_shadowed_operators >/dev/null 2>&1 \
            || { printf "NO SUCH FUNCTION\n"; exit 0; }
        rc=0
        report_shadowed_operators || rc=$?
        printf "rc=%s\n" "${rc}"
    ' _ "${PATH_ORDER_LIB}" "${OPERATOR_LIB}" "${HELPER}" "$1" 2>&1 || true
}

# The stubs a case composes from. `stub_reading <state> <users> <winner>` answers for the named accounts
# with that winner and leaves every other account reading as a host whose ordering is right, so a case states
# which accounts are shadowed and by which binary rather than restating the reading. Each recording that a reading was
# taken at all, which is what (F) asserts the absence of.
stub_operators() { printf 'ai_tools_load_operators() { AI_TOOLS_OPERATORS=(%s); }\n' "$*"; }
stub_unenrolled() { printf 'ai_tools_load_operators() { AI_TOOLS_OPERATORS=(); return 1; }\n'; }
stub_reading() {
    printf '
ai_tools_path_order_read_user() {
    : > "%s"
    AI_TOOLS_PATH_ORDER_WINNERS=( "claude=${AI_TOOLS_PATH_ORDER_WRAPPER_DIR}/claude" )
    AI_TOOLS_PATH_ORDER_SHADOW=""
    AI_TOOLS_PATH_ORDER_STATE=%s
    for _shadowed in %s; do
        [[ "$1" == "${_shadowed}" ]] || continue
        AI_TOOLS_PATH_ORDER_SHADOW="%s"
        AI_TOOLS_PATH_ORDER_WINNERS=( "claude=${AI_TOOLS_PATH_ORDER_SHADOW}" )
        AI_TOOLS_PATH_ORDER_STATE=shadowed
        return 1
    done
    return 0
}
ai_tools_path_order_repoint_user() { : > "%s"; }
' "${READ_MARKER}" "${1:-wired}" "${2:-}" "${3:-}" "${WRITE_MARKER}"
}

# ── (A) Each shape of shadowing binary is named, as the shell would print it ──────────────────
out="$(run_report "$(stub_operators op; stub_reading wired op "${SHADOW_NVM}")")"
if [[ "${out}" == *"NO SUCH FUNCTION"* ]]; then
    fail "the helper does not define report_shadowed_operators when sourced"
    finish; exit 1
fi
for winner in "${SHADOW_NVM}" "${SHADOW_PKG}" "${SHADOW_MERGED}"; do
    out="$(run_report "$(stub_operators op; stub_reading wired op "${winner}")")"
    assert_msg MSG-K2D4 "${out}" "an agent at ${winner} is reported at its own message code"
    if grep -qF "operator op who types claude would run ${winner}" <<<"${out}"; then
        pass "the message names the account, the launcher and ${winner}"
    else
        fail "the message does not name what the operator has to act on (${out})"
    fi
done

# ── (B) Both ways out are named, against the vendor package's own path ───────────────────────
out="$(run_report "$(stub_operators op; stub_reading wired op "${SHADOW_PKG}")")"
if grep -qF "sudo ai-tools-admin operators add op" <<<"${out}"; then
    pass "the first way out is the enrolment command that ranks the wrapper first"
else
    fail "the report does not name the command that fixes the ordering (${out})"
fi
if grep -qF "or remove that install:        ${SHADOW_PKG}" <<<"${out}"; then
    pass "the second way out names the install to remove"
else
    fail "the report does not offer removing the agent that wins (${out})"
fi

# ── (C) A fault the host owns is not this command's exit status ──────────────────────────────
# The provisioning succeeded; what the report found is a state of the operator's shell, and a non-zero status here would
# report the toolchain install as failed.
if grep -qx 'rc=0' <<<"${out}"; then
    pass "a report that found a shadowed operator still returns 0"
else
    fail "the report returned non-zero for a fault it only reports ($(grep '^rc=' <<<"${out}"))"
fi

# ── (D) It does not rewrite an init file ─────────────────────────────────────────────────────────────
# `operators add` is this project's one writer of the guard line, behind its confirm; a report that repointed on its own
# would edit an operator's home without asking.
if [[ ! -e "${WRITE_MARKER}" ]]; then
    pass "the report does not reach an init-file write"
else
    fail "the report called the repoint, which belongs to operators add"
fi

# ── (E) Every enrolled operator is asked about ───────────────────────────────────────────────
out="$(run_report "$(stub_operators op two; stub_reading wired "op two" "${SHADOW_PKG}")")"
if [[ "$(grep -c '^MSG-K2D4$' <<<"${out}")" -eq 2 ]]; then
    pass "each shadowed operator is named by a record of its own"
else
    fail "the report does not carry one record per shadowed operator (${out})"
fi

# ── (F) Every other state is silence ─────────────────────────────────────────────────────────
# A host whose ordering is right, and one whose reading could not be taken, are the runs an operator sees most; a line
# on either teaches them to read past the one that matters.
for state in wired clear unknown; do
    out="$(run_report "$(stub_operators op; stub_reading "${state}" "" "")")"
    if grep -q 'MSG-K2D4' <<<"${out}"; then
        fail "named an operator whose ordering read as ${state}"
        break
    fi
done
if ! grep -q 'MSG-K2D4' <<<"${out}"; then
    pass "an operator who reaches the wrapper is named by no line, whatever the state"
fi

# ── (G) An unenrolled host asks about nobody ─────────────────────────────────────────────────
# Bootstrap runs before the first enrolment as often as after it, and a reading is a login shell per account: with no
# operator recorded there is no account to read and none to name.
rm -f "${READ_MARKER}"
out="$(run_report "$(stub_unenrolled; stub_reading wired op "${SHADOW_PKG}")")"
if grep -q 'MSG-K2D4' <<<"${out}"; then
    fail "named an operator on a host that has enrolled none (${out})"
elif [[ -e "${READ_MARKER}" ]]; then
    fail "took a login-shell reading with no operator enrolled"
else
    pass "an unenrolled host is neither read nor reported on"
fi

finish
