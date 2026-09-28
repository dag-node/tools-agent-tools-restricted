#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/sandbox-exec.sh
# Unit test for sandbox-exec.lib.sh: the one route by which a root process runs a file the sandbox account can write,
# and the identity check beside it.
#
# Each property the helper gives its child is asserted from inside the child, and each refusal in its fail direction:
# a caller that is not root, an account that is root, an account that is not the sandbox's, and a malformed bound each
# leave the command unrun or narrow to the default. The child is asserted to run as the account with no controlling
# terminal, no descriptor above 2, a clean environment, each stream through the allowlist, the command's own status,
# and a bound past which every process of its session is gone. The identity check is driven from the vantage the suite
# has -- root, and the projects user through runuser -- so both negatives are real accounts.
#
# The library's account name is what the installer substituted, so a source-tree copy (the fallback when no library is
# installed) holds a token no account resolves, and every case that needs the account skips through the library's own
# refusal. Root for the child's properties, like the helper; the refusals and the pure bound reader run unprivileged.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="/usr/local/lib/ai-tools/sandbox-exec.lib.sh"
[[ -r "${LIB}" ]] || LIB="${REPO_ROOT}/src/usr/local/lib/ai-tools/sandbox-exec.lib.sh"

section "sandbox-exec: a command run as the sandbox account from root (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "sandbox-exec" "library not found at ${LIB}"; finish; exit
fi
mktestdir
# shellcheck source=../../src/usr/local/lib/ai-tools/sandbox-exec.lib.sh
source "${LIB}"

# ── The bound: a whole number of seconds, or the default ──────────────────────────────────────
while IFS='|' read -r value want what; do
    [[ -n "${what}" ]] || continue
    got="$(AI_TOOLS_AS_SANDBOX_TIMEOUT="${value}" _ai_tools_sandbox_exec_timeout_seconds)"
    [[ "${got}" == "${want}" ]] && pass "bound ${what} -> ${want}s" || fail "bound ${what}: got '${got}', want '${want}'"
done <<'ROWS'
|1800|unset is the default
5|5|a value in seconds is taken
0|1800|zero narrows to the default, never to no bound
abc|1800|a word narrows to the default
-5|1800|a negative narrows to the default
ROWS

# ── Refusals that need no account ─────────────────────────────────────────────────────────────
if [[ "${EUID}" -ne 0 ]]; then
    rc=0; out="$(ai_tools_as_sandbox ai-tools id 2>&1)" || rc=$?
    [[ "${rc}" -eq 1 && "${out}" == *"needs root"* ]] \
        && pass "a caller that is not root is refused, and nothing runs" || fail "non-root call: rc ${rc}: ${out}"
    ai_tools_is_sandbox_account && fail "an unprivileged caller reads as the sandbox account" \
        || pass "an unprivileged caller that is not the sandbox account is not one"
    skip "the sandbox child's properties" "needs root, which runuser does"
    finish; exit
fi

require_root
sandbox_uid="$(ai_tools_sandbox_uid)"
if [[ -z "${sandbox_uid}" ]]; then
    rc=0; out="$(ai_tools_as_sandbox "${SANDBOX_USER}" id 2>&1)" || rc=$?
    [[ "${rc}" -eq 1 && "${out}" == *"is not the sandbox account"* ]] \
        && pass "an account the library cannot resolve refuses every run" || fail "unresolved account: rc ${rc}: ${out}"
    skip "the sandbox child's properties" "the library at ${LIB} names no account this host has (a source-tree copy)"
    finish; exit
fi

# ── Identity: root is refused as a target and as a caller ─────────────────────────────────────
rc=0; out="$(ai_tools_as_sandbox root id 2>&1)" || rc=$?
[[ "${rc}" -eq 1 && "${out}" == *"is not the sandbox account"* ]] \
    && pass "root as the target account is refused, and nothing runs" || fail "root target: rc ${rc}: ${out}"
rc=0; out="$(ai_tools_as_sandbox "${PROJECTS_USER}" id 2>&1)" || rc=$?
[[ "${rc}" -eq 1 && "${out}" == *"is not the sandbox account"* ]] \
    && pass "an operator account as the target is refused" || fail "operator target: rc ${rc}: ${out}"
rc=0; out="$(ai_tools_as_sandbox 'no such account' id 2>&1)" || rc=$?
[[ "${rc}" -eq 1 && "${out}" == *"is not the sandbox account"* ]] \
    && pass "a name outside the account charset is refused" || fail "malformed name: rc ${rc}: ${out}"
ai_tools_is_sandbox_account && fail "root reads as the sandbox account" || pass "root is not the sandbox account"
# shellcheck disable=SC2016  # the inner shell expands these, not this one
out="$(runuser -u "${PROJECTS_USER}" -- bash -c 'source "$1"; ai_tools_is_sandbox_account && echo yes || echo no' _ "${LIB}" 2>/dev/null)"
[[ "${out}" == no ]] && pass "the projects user is not the sandbox account" || fail "projects user read as: ${out}"
out="$(ai_tools_as_sandbox "${SANDBOX_USER}" bash -c 'source "$1"; ai_tools_is_sandbox_account && echo yes || echo no' _ "${LIB}" 2>/dev/null)"
[[ "${out}" == yes ]] && pass "the sandbox account reads as itself from inside the child" || fail "sandbox account read as: ${out}"

# ── The child's properties ────────────────────────────────────────────────────────────────────
out="$(ai_tools_as_sandbox "${SANDBOX_USER}" id -un 2>/dev/null)"
[[ "${out}" == "${SANDBOX_USER}" ]] && pass "the command runs as ${SANDBOX_USER}" || fail "ran as '${out}'"

# No controlling terminal: /dev/tty does not open, which is the terminal a child could otherwise inject into. A control
# first, since the suite may itself run without one.
if (exec 3</dev/tty) 2>/dev/null; then
    # shellcheck disable=SC2016  # the inner shell expands these, not this one
    out="$(ai_tools_as_sandbox "${SANDBOX_USER}" bash -c '(exec 3</dev/tty) 2>/dev/null && echo has-tty || echo no-tty' 2>/dev/null)"
    [[ "${out}" == no-tty ]] && pass "the child has no controlling terminal, although this process has one" \
        || fail "the child opened /dev/tty: ${out}"
else
    note "controlling terminal" "this run has none, so the child's absence of one is not a contrast here"
fi

# No descriptor above 2: one this process holds open is closed in the child. The control is the same probe run
# through plain runuser, where the descriptor is inherited.
exec 9<"${LIB}"
# shellcheck disable=SC2016  # the inner shell expands these, not this one
control="$(runuser -u "${SANDBOX_USER}" -- bash -c '[[ -e /proc/self/fd/9 ]] && echo open || echo closed' 2>/dev/null)"
# shellcheck disable=SC2016  # the inner shell expands these, not this one
out="$(ai_tools_as_sandbox "${SANDBOX_USER}" bash -c '[[ -e /proc/self/fd/9 ]] && echo open || echo closed' 2>/dev/null)"
exec 9<&-
if [[ "${control}" != open ]]; then
    fail "control: descriptor 9 did not reach a plain runuser child (${control}), so the close is not measured"
elif [[ "${out}" == closed ]]; then
    pass "a descriptor this process holds open is closed in the child"
else
    fail "descriptor 9 reached the child: ${out}"
fi

# A clean environment: a variable this process exports does not reach the child; HOME is the account's.
# shellcheck disable=SC2016  # the inner shell expands these, not this one
out="$(AI_TOOLS_TEST_LEAK=1 ai_tools_as_sandbox "${SANDBOX_USER}" bash -c 'printf "%s|%s" "${AI_TOOLS_TEST_LEAK:-unset}" "${HOME}"' 2>/dev/null)"
[[ "${out}" == "unset|$(getent passwd "${SANDBOX_USER}" | cut -d: -f6)" ]] \
    && pass "the child's environment is clean, and HOME is the account's" || fail "child environment: ${out}"

# Both streams through the allowlist, kept apart; a tab survives for a caller reading a wire format.
ai_tools_as_sandbox "${SANDBOX_USER}" bash -c 'printf "a\tb \033[2Jout\n"; printf "\033]0;err\n" >&2' \
    >"${TESTDIR}/as-out" 2>"${TESTDIR}/as-err" || true
if [[ "$(<"${TESTDIR}/as-out")" == $'a\tb ?[2Jout' && "$(<"${TESTDIR}/as-err")" == '?]0;err' ]]; then
    pass "stdout and stderr reach the caller apart, each through the allowlist, a tab kept"
else
    fail "streams: out '$(tr '\t\033' '>?' <"${TESTDIR}/as-out")' err '$(tr '\033' '?' <"${TESTDIR}/as-err")'"
fi

rc=0; ai_tools_as_sandbox "${SANDBOX_USER}" bash -c 'exit 7' >/dev/null 2>&1 || rc=$?
[[ "${rc}" -eq 7 ]] && pass "the command's own status is returned" || fail "status: ${rc}, want 7"

out="$(ai_tools_as_sandbox "${SANDBOX_USER}" cat <<<'from a heredoc' 2>/dev/null)"
[[ "${out}" == 'from a heredoc' ]] && pass "stdin the caller gives passes" || fail "stdin: '${out}'"

# The bound: a command that outlives it is ended with every process of its session, and the call says so. The child
# starts a grandchild that would outlive a kill of the child alone, and the marker names this run so a stray sleep
# of another run is not read.
marker="ai-tools-test-sandbox-exec-$$"
rc=0; out="$(AI_TOOLS_AS_SANDBOX_TIMEOUT=2 ai_tools_as_sandbox "${SANDBOX_USER}" bash -c \
    "sleep 300 '${marker}' & sleep 300 '${marker}'" 2>&1)" || rc=$?
sleep 1
if [[ "${rc}" -ne 124 ]]; then
    fail "a command past the bound returned ${rc}, want 124: ${out}"
else
    assert_msg MSG-W8B7 "${out}" "a command past the bound is reported under its code"
    if pgrep -u "${SANDBOX_USER}" -f "${marker}" >/dev/null 2>&1; then
        fail "a process of the ended session survives the bound"
        pkill -u "${SANDBOX_USER}" -f "${marker}" || true
    else
        pass "no process of the ended session survives the bound, the grandchild included"
    fi
fi

finish
