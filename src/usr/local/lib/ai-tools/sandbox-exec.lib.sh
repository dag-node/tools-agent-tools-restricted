#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/sandbox-exec.lib.sh
# The one route by which a root process runs a file the sandbox account can write -- nvm, npm, node and every agent
# package under /opt/ai-tools/.nvm -- and the identity check a function that executes or sources such a file requires
# of its own process. The invariant is in CLAUDE.md ("Root and the operator do not execute what the sandbox can write");
# its mechanism is in updater.rule.md.
#
# ai_tools_as_sandbox runs a command as the sandbox account with no controlling terminal, no inherited descriptor
# above 2, a clean environment, a bound on its run, and each of its streams through the log allowlist.
# ai_tools_is_sandbox_account answers whether this process is that account, which is what the updater and the toolchain
# writers require before they source nvm.sh or run npm: a process of any other account that ran them would execute
# the tree with that account's authority.
#
# Sourced, not executed. Deployed 644 root:root: it holds shipped logic and the account name the installer substituted,
# and does not read any operator data. It depends on no provider resolver, so a bootstrap provisioning Node alone,
# with no manifest to read, loads it whole. log.lib.sh is loaded best-effort for the stream sanitizer; without it
# the child's output is withheld and a line on stderr says so, since a byte from the toolchain reaches a terminal
# or the journal only through the allowlist.

# Include guard, as an if-statement: `[[ ]] && return` returns 1 for an unset guard and trips a sourcing shell's
# `set -e`.
if [[ -n "${_AI_TOOLS_SANDBOX_EXEC_LIB_LOADED:-}" ]]; then
    return 0
fi
# shellcheck source=SCRIPTDIR/log.lib.sh
source "${BASH_SOURCE[0]%/*}/log.lib.sh" 2>/dev/null || true

_AI_TOOLS_SANDBOX_EXEC_LIB_LOADED=1

# The sandbox account, the value the installer substitutes. A source-tree copy holds the token, which no account
# resolves, so every run through an unsubstituted copy refuses.
readonly _AI_TOOLS_SANDBOX_ACCOUNT="@SANDBOX_USER@"

# The bound on one run, seconds, and the environment name a root caller sets to move it: the npm and nvm steps behind
# this helper are network-bound, so the default is wide, and it exists so a hung child ends the step instead
# of the provisioning run.
readonly _AI_TOOLS_AS_SANDBOX_TIMEOUT_DEFAULT=1800

# _ai_tools_sandbox_exec_warn [code] <message...> : report to stderr (the terminal, or the journal a unit routes it
#   to) and, when log.lib.sh loaded, to journald. A leading message code goes on its own line ahead of the message,
#   the shape tests/lib/harness.sh's assert_msg reads.
_ai_tools_sandbox_exec_warn() {
    local code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    printf 'ai-tools: %s\n' "$*" >&2
    declare -F ai_tools_log_warn >/dev/null 2>&1 && ai_tools_log_warn "sandbox-exec: $*"
    return 0
}

# ai_tools_sandbox_uid : print the sandbox account's uid, or an empty string where the account does not resolve.
ai_tools_sandbox_uid() {
    local sandbox_uid
    sandbox_uid="$(getent passwd -- "${_AI_TOOLS_SANDBOX_ACCOUNT}" 2>/dev/null | cut -d: -f3)"
    [[ "${sandbox_uid}" =~ ^[0-9]+$ ]] || return 0
    printf '%s' "${sandbox_uid}"
}

# ai_tools_is_sandbox_account : return 0 when this process runs as the sandbox account, a resolved uid other than 0;
#   non-zero for root, for an operator, and where the account does not resolve.
ai_tools_is_sandbox_account() {
    local sandbox_uid
    sandbox_uid="$(ai_tools_sandbox_uid)"
    [[ -n "${sandbox_uid}" && "${sandbox_uid}" -ne 0 && "${EUID:-$(id -u)}" -eq "${sandbox_uid}" ]]
}

# _ai_tools_sandbox_exec_timeout_seconds : print the seconds one run may take: AI_TOOLS_AS_SANDBOX_TIMEOUT where it
#   is a whole number of seconds, at least one, the default otherwise -- a malformed value narrows to the default, never
#   to no bound.
_ai_tools_sandbox_exec_timeout_seconds() {
    local timeout_seconds="${AI_TOOLS_AS_SANDBOX_TIMEOUT:-}"
    [[ "${timeout_seconds}" =~ ^[1-9][0-9]*$ ]] || timeout_seconds="${_AI_TOOLS_AS_SANDBOX_TIMEOUT_DEFAULT}"
    printf '%s' "${timeout_seconds}"
}

# _ai_tools_sandbox_exec_tool_path <name> : print the absolute path of a host tool this helper execs as root, resolved
#   through the caller's PATH and admitted only under the system binary directories; non-zero and a warning otherwise.
_ai_tools_sandbox_exec_tool_path() {
    local tool_name="$1" tool_path
    tool_path="$(command -v -- "${tool_name}" 2>/dev/null)" || tool_path=""
    case "${tool_path}" in
        /usr/bin/*|/usr/sbin/*|/bin/*|/sbin/*) printf '%s' "${tool_path}"; return 0 ;;
    esac
    _ai_tools_sandbox_exec_warn "ai_tools_as_sandbox: ${tool_name} is not at a system path (found $(printf '%q' "${tool_path:-nothing}")) -- not run"
    return 1
}

# _ai_tools_sandbox_exec_session_id_of <pid> : print the session id of a live process, read from /proc, or an empty
# string.
_ai_tools_sandbox_exec_session_id_of() {
    local stat_line fields_after_command_name session_id
    stat_line="$(cat "/proc/$1/stat" 2>/dev/null)" || return 0
    # The command name sits in parentheses and may hold a space, so the fields are read after the last `)`: state, ppid,
    # pgrp, session.
    fields_after_command_name="${stat_line##*) }"
    read -r _ _ _ session_id _ <<<"${fields_after_command_name}"
    [[ "${session_id}" =~ ^[0-9]+$ ]] && printf '%s' "${session_id}"
    return 0
}

# ai_tools_as_sandbox <account> <command> [arg...] : run <command> as the sandbox account for a root caller. <account>
#   names the account the caller means and is refused unless it resolves to the sandbox account's own uid: a name
#   resolving to uid 0, to another account, or to none is not run (the caller names its intent, the library holds it).
#   The child gets:
#     - no controlling terminal (setsid): a process sharing root's terminal can open /dev/tty and inject input into it
#       with TIOCSTI where the kernel permits, whatever its own descriptors point at;
#     - no terminal on stdin: a terminal is replaced with /dev/null, while a heredoc or a pipe the caller gives passes;
#     - no descriptor above 2: the host's bash closes every other one the caller's process held open (a socket,
#       a root-only file, a lock) before it execs the command, so the command starts with the three streams alone;
#     - a clean environment (`env -i`): HOME, a PATH of /usr/bin:/bin and LANG=C.UTF-8, and whatever the command itself
#       sets with a leading `env NAME=value`;
#     - its stdout and its stderr kept apart, since a caller may read stdout as a wire format, each through
#       ai_tools_log_sanitize_stream, or withheld with a line on stderr where log.lib.sh did not load;
#     - a bound on its run (_ai_tools_sandbox_exec_timeout_seconds): past it, every process of the session setsid
#       opened gets SIGTERM, then SIGKILL, and the call returns 124 under MSG-W8B7, so a hung child ends the step
#       rather than the run.
#   Returns the command's own status; returns 1 without running anything when the caller is not root (runuser needs
#   root), <account> is not the sandbox account, a host tool is off the system path, or no command was given.
ai_tools_as_sandbox() {
    local account="${1:-}"
    shift || true
    if [[ "${EUID:-$(id -u)}" -ne 0 || $# -eq 0 ]]; then
        _ai_tools_sandbox_exec_warn "ai_tools_as_sandbox: needs root and a command -- not run"
        return 1
    fi
    local sandbox_uid requested_uid=""
    sandbox_uid="$(ai_tools_sandbox_uid)"
    [[ "${account}" =~ ^[a-z_][a-z0-9_-]*$ ]] && requested_uid="$(getent passwd -- "${account}" 2>/dev/null | cut -d: -f3)"
    if [[ -z "${sandbox_uid}" || "${sandbox_uid}" -eq 0 || -z "${requested_uid}" || "${requested_uid}" != "${sandbox_uid}" ]]; then
        _ai_tools_sandbox_exec_warn "ai_tools_as_sandbox: $(printf '%q' "${account}") is not the sandbox account (${_AI_TOOLS_SANDBOX_ACCOUNT}) -- not run"
        return 1
    fi
    local setsid_path runuser_path env_path bash_path
    setsid_path="$(_ai_tools_sandbox_exec_tool_path setsid)" || return 1
    runuser_path="$(_ai_tools_sandbox_exec_tool_path runuser)" || return 1
    env_path="$(_ai_tools_sandbox_exec_tool_path env)" || return 1
    bash_path="$(_ai_tools_sandbox_exec_tool_path bash)" || return 1
    local sandbox_home
    sandbox_home="$(getent passwd -- "${account}" 2>/dev/null | cut -d: -f6)"
    [[ -n "${sandbox_home}" ]] || sandbox_home=/

    # The trampoline, run by the host's bash as the account once runuser has dropped privilege: close every descriptor
    # above 2, then exec the command. `{ exec {fd}>&-; }` scopes the close's own error to the brace group, since
    # a redirection on a bare exec stays in force for the shell.
    # shellcheck disable=SC2016  # the inner shell expands these, not this one
    local close_descriptors_then_exec='for descriptor_path in /proc/self/fd/*; do descriptor="${descriptor_path##*/}"; (( descriptor > 2 )) || continue; { exec {descriptor}>&-; } 2>/dev/null; done; exec "$@"'

    local stdin_fd=0
    [[ -t 0 ]] && exec {stdin_fd}</dev/null
    local stdout_fd stderr_fd stdout_sanitizer_pid="" stderr_sanitizer_pid="" output_withheld=0
    if declare -F ai_tools_log_sanitize_stream >/dev/null 2>&1; then
        # Each stream through its own sanitizer, whose pid $! carries after the open, so the wait at the end
        # of ai_tools_as_sandbox is for those two and not for every child of the caller's shell.
        exec {stdout_fd}> >(ai_tools_log_sanitize_stream)
        stdout_sanitizer_pid=$!
        exec {stderr_fd}> >(ai_tools_log_sanitize_stream >&2)
        stderr_sanitizer_pid=$!
    else
        exec {stdout_fd}>/dev/null {stderr_fd}>/dev/null
        output_withheld=1
    fi

    # Job control off for the start, so the child is not a process-group leader and setsid execs in place: the child's
    # pid is then the id of the session it opens, which is what the bound kills by.
    local job_control_was_enabled=0
    [[ -o monitor ]] && job_control_was_enabled=1
    set +m
    "${setsid_path}" --wait "${runuser_path}" -u "${account}" -- \
        "${env_path}" -i HOME="${sandbox_home}" PATH=/usr/bin:/bin LANG=C.UTF-8 \
        "${bash_path}" -c "${close_descriptors_then_exec}" _ "$@" \
        <&"${stdin_fd}" >&"${stdout_fd}" 2>&"${stderr_fd}" &
    local child_pid=$!
    (( job_control_was_enabled )) && set -m

    local timeout_seconds elapsed_seconds=0 timed_out=0 session_id
    timeout_seconds="$(_ai_tools_sandbox_exec_timeout_seconds)"
    while kill -0 "${child_pid}" 2>/dev/null; do
        if (( elapsed_seconds >= timeout_seconds )); then
            timed_out=1
            session_id="$(_ai_tools_sandbox_exec_session_id_of "${child_pid}")"
            if [[ "${session_id}" == "${child_pid}" ]]; then
                pkill -TERM -s "${child_pid}" 2>/dev/null || true
                sleep 5
                pkill -KILL -s "${child_pid}" 2>/dev/null || true
            else
                # The session is not the child's own (setsid forked), so only the child is reachable by pid.
                kill -TERM "${child_pid}" 2>/dev/null || true
                sleep 5
                kill -KILL "${child_pid}" 2>/dev/null || true
            fi
            break
        fi
        sleep 1
        elapsed_seconds=$(( elapsed_seconds + 1 ))
    done
    local command_exit_status=0
    wait "${child_pid}" 2>/dev/null || command_exit_status=$?

    exec {stdout_fd}>&- {stderr_fd}>&-
    (( stdin_fd == 0 )) || exec {stdin_fd}<&-
    [[ -n "${stdout_sanitizer_pid}" ]] && { wait "${stdout_sanitizer_pid}" "${stderr_sanitizer_pid}" 2>/dev/null || true; }
    (( output_withheld )) && _ai_tools_sandbox_exec_warn "output of $(printf '%q' "$1") withheld: log.lib.sh, which sanitizes it, did not load"
    if (( timed_out )); then
        _ai_tools_sandbox_exec_warn MSG-W8B7 "ended a command that ran past ${timeout_seconds}s as ${account}: $(printf '%q' "$1") -- the step did not complete; re-run it, or set AI_TOOLS_AS_SANDBOX_TIMEOUT=<seconds> for a slower host"
        return 124
    fi
    return "${command_exit_status}"
}
