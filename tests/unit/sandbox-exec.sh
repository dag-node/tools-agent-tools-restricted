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
    # The identity check against this process: yes only where the invoker is the resolved sandbox account, which
    # a development run as that account is.
    if [[ -n "$(ai_tools_sandbox_uid)" && "${EUID}" -eq "$(ai_tools_sandbox_uid)" ]]; then
        ai_tools_is_sandbox_account && pass "the sandbox account, running this file itself, reads as itself" \
            || fail "the sandbox account running this file does not read as itself"
    else
        ai_tools_is_sandbox_account && fail "an unprivileged caller that is not the sandbox account reads as it" \
            || pass "an unprivileged caller that is not the sandbox account is not one"
    fi
    skip "the sandbox child's properties" "needs root, which runuser does"
    finish; exit
fi

require_root
sandbox_uid="$(ai_tools_sandbox_uid)"
if [[ -z "${sandbox_uid}" ]]; then
    rc=0; out="$(ai_tools_as_sandbox "${SANDBOX_USER}" id 2>&1)" || rc=$?
    [[ "${rc}" -eq 1 && "${out}" == *"is not the sandbox account"* ]] \
        && pass "an account the library cannot resolve refuses every run" || fail "unresolved account: rc ${rc}: ${out}"
    # The installed copy names the account the installer substituted; one still holding the token was installed without
    # substitution and refuses every provisioning step, which is a defect and not a state to skip through.
    if [[ "${LIB}" == /usr/local/lib/ai-tools/* ]]; then
        fail "the installed ${LIB} names no account this host has -- the account token was not substituted at install"
    else
        skip "the sandbox child's properties" "the library at ${LIB} names no account this host has (a source-tree copy)"
    fi
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

# count_marked <marker> : the number of the sandbox account's processes whose command line carries the marker. pgrep
# exits 1 for no match, which is the answer 0 here and not an error; any other non-zero status is one, reported
# and returned, so a broken count never reads as "none left".
count_marked() {
    local listing="" rc=0
    listing="$(pgrep -u "${SANDBOX_USER}" -f "$1" 2>/dev/null)" || rc=$?
    case "${rc}" in
        0) printf '%s\n' "${listing}" | wc -l ;;
        1) printf 0 ;;
        *) printf 'count_marked: pgrep exited %s\n' "${rc}" >&2; return 1 ;;
    esac
}

# The command receives its arguments byte for byte: a scope's own expansion of `${NAME}` and `$NAME` (off on the systemd
# shipped today, announced as on by default later) is switched off, so a snippet carrying `$1` or `${HOME}` reaches bash
# unchanged rather than emptied by systemd-run before privilege drops.
out="$(ai_tools_as_sandbox "${SANDBOX_USER}" printf '%s|%s|%s' '$1' '${HOME}' '${X:-d}' 2>/dev/null)"
[[ "${out}" == '$1|${HOME}|${X:-d}' ]] && pass "arguments shaped like variables reach the command unexpanded" \
    || fail "systemd-run rewrote the arguments: '${out}'"

# How long a start takes here -- the scope's bus call, runuser's PAM session, the trampoline -- measured on a command
# that exits at once, since a loaded host gives it seconds where this one gives it a fraction. The bound, drain
# and escape cases size their bound from it, so a slow start does not read as a cleanup failure, and a fast one is
# not waited for longer than it takes.
started=${SECONDS}
ai_tools_as_sandbox "${SANDBOX_USER}" /usr/bin/true >/dev/null 2>&1 || true
start_latency=$(( SECONDS - started ))
bound_seconds=$(( start_latency * 2 + 6 ))
note "start latency" "${start_latency}s for a command that exits at once; the bound cases use a ${bound_seconds}s bound"

# wait_marked <marker> <count> <helper-pid> : poll until <count> marked processes are alive or the helper has exited,
# and print the count seen last. The helper's own bound is what ends the poll where the processes never appear.
wait_marked() {
    local marker="$1" want="$2" helper="$3" seen=0
    while :; do
        seen="$(count_marked "${marker}")" || seen=-1
        (( seen >= want )) && break
        kill -0 "${helper}" 2>/dev/null || break
        sleep 0.2
    done
    printf '%s' "${seen}"
}

# The bound: a command that outlives it is ended with every process of its run, and the call says so. The child execs
# into a sleep and first starts a grandchild sleep in a subshell, each carrying this run's marker as its argv[0]
# (`exec -a`), so `pgrep -f` finds exactly these; the case asserts the two are alive before the bound and gone after it.
# The helper runs in the background so the processes can be counted while it waits.
marker="ai-tools-test-sandbox-exec-$$"
# shellcheck disable=SC2016  # the inner shell expands these, not this one
AI_TOOLS_AS_SANDBOX_TIMEOUT="${bound_seconds}" ai_tools_as_sandbox "${SANDBOX_USER}" bash -c \
    '( exec -a "$1" sleep 300 ) & exec -a "$1" sleep 300' _ "${marker}" >/dev/null 2>"${TESTDIR}/bound-err" &
helper_pid=$!
alive_before="$(wait_marked "${marker}" 2 "${helper_pid}")"
rc=0; wait "${helper_pid}" || rc=$?
sleep 1
alive_after="$(count_marked "${marker}")" || alive_after=-1
if [[ "${alive_before}" -lt 2 ]]; then
    fail "control: the bound case started ${alive_before} marked process(es) before the helper returned ${rc}, so its cleanup is not measured: $(<"${TESTDIR}/bound-err")"
elif [[ "${rc}" -ne 124 ]]; then
    fail "a command past the bound returned ${rc}, want 124: $(<"${TESTDIR}/bound-err")"
else
    assert_msg MSG-W8B7 "$(<"${TESTDIR}/bound-err")" "a command past the bound is reported under its code"
    [[ "${alive_after}" -eq 0 ]] && pass "no process of the ended run survives the bound, the grandchild included" \
        || fail "${alive_after} process(es) of the ended run survive the bound"
fi
pkill -u "${SANDBOX_USER}" -f "${marker}" 2>/dev/null || true

# The bound holds through the draining of the output: the child exits at once and leaves a grandchild holding the output
# pipe, so a wait for that pipe's end alone would last as long as the grandchild. The call must return within the bound
# and a grace, as 124, with the grandchild gone.
marker="ai-tools-test-sandbox-exec-drain-$$"
started=${SECONDS}
# shellcheck disable=SC2016  # the inner shell expands these, not this one
rc=0; AI_TOOLS_AS_SANDBOX_TIMEOUT="${bound_seconds}" ai_tools_as_sandbox "${SANDBOX_USER}" bash -c \
    '( exec -a "$1" sleep 300 ) & exit 0' _ "${marker}" >/dev/null 2>"${TESTDIR}/drain-err" || rc=$?
elapsed=$(( SECONDS - started ))
sleep 1
alive_after="$(count_marked "${marker}")" || alive_after=-1
if [[ "${rc}" -eq 124 && "${elapsed}" -le $(( bound_seconds + 20 )) && "${alive_after}" -eq 0 ]]; then
    pass "a child that exited leaving a process on its output pipe is ended at the bound (${elapsed}s), and the call returns 124"
else
    fail "exited child with an open pipe: rc ${rc} (want 124), ${elapsed}s (want <= $(( bound_seconds + 20 ))), ${alive_after} left: $(<"${TESTDIR}/drain-err")"
fi
pkill -u "${SANDBOX_USER}" -f "${marker}" 2>/dev/null || true

# The boundary is the scope, not the session: a descendant that opens a session of its own (`setsid -f`) and keeps
# the output pipe is still in the run's cgroup, so it is ended at the bound with the rest. The control counts it alive
# before the bound, from a background helper as in the first bound case.
marker="ai-tools-test-sandbox-exec-escape-$$"
# shellcheck disable=SC2016  # the inner shell expands these, not this one
AI_TOOLS_AS_SANDBOX_TIMEOUT="${bound_seconds}" ai_tools_as_sandbox "${SANDBOX_USER}" bash -c \
    'setsid -f bash -c "exec -a \"\$1\" sleep 300" _ "$1"; exec -a "$1" sleep 300' _ "${marker}" \
    >/dev/null 2>"${TESTDIR}/escape-err" &
helper_pid=$!
alive_before="$(wait_marked "${marker}" 2 "${helper_pid}")"
rc=0; wait "${helper_pid}" || rc=$?
sleep 1
alive_after="$(count_marked "${marker}")" || alive_after=-1
if [[ "${alive_before}" -lt 2 ]]; then
    fail "control: the escape case started ${alive_before} marked process(es) before the helper returned ${rc}, so the scope's reach is not measured: $(<"${TESTDIR}/escape-err")"
elif [[ "${rc}" -eq 124 && "${alive_after}" -eq 0 ]]; then
    pass "a descendant that opened its own session is ended at the bound with the rest of the run"
else
    fail "descendant in its own session: rc ${rc} (want 124), ${alive_after} left: $(<"${TESTDIR}/escape-err")"
fi
pkill -u "${SANDBOX_USER}" -f "${marker}" 2>/dev/null || true

# Without a scope the run is refused, not made with a weaker boundary: the probe answers no, and the command does not
# run. Driven in a shell of its own, so the cached probe answer of this shell is not disturbed.
# shellcheck disable=SC2016  # the inner shell expands these, not this one
rc=0; out="$(bash -c 'source "$1"; _ai_tools_sandbox_exec_scope_available() { return 1; }
    ai_tools_as_sandbox "$2" touch "$3"' _ "${LIB}" "${SANDBOX_USER}" "${TESTDIR}/no-scope-ran" 2>&1)" || rc=$?
if [[ "${rc}" -eq 1 && ! -e "${TESTDIR}/no-scope-ran" ]]; then
    assert_msg MSG-Q2K6 "${out}" "a run with no scope to open is refused under its code, and the command does not run"
else
    fail "no scope: rc ${rc} (want 1), ran: $([[ -e "${TESTDIR}/no-scope-ran" ]] && echo yes || echo no): ${out}"
fi

finish
