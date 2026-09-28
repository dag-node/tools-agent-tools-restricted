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

# The directories a host tool this library runs is taken from, in order, and never the caller's PATH: a PATH entry such
# as `/usr/bin/../../tmp/x` passes a prefix check and names a directory an unprivileged writer holds.
readonly _AI_TOOLS_SANDBOX_EXEC_SYSTEM_PATH=/usr/sbin:/usr/bin:/sbin:/bin

# _ai_tools_sandbox_exec_tool_path <name> : print the absolute path of a host tool this helper execs, looked up
#   in the system binary directories alone; non-zero and a warning where none of them holds an executable of that name.
_ai_tools_sandbox_exec_tool_path() {
    local tool_name="$1" directory
    for directory in /usr/sbin /usr/bin /sbin /bin; do
        if [[ -f "${directory}/${tool_name}" && -x "${directory}/${tool_name}" ]]; then
            printf '%s' "${directory}/${tool_name}"
            return 0
        fi
    done
    _ai_tools_sandbox_exec_warn "ai_tools_as_sandbox: ${tool_name} is not in the system binary directories -- not run"
    return 1
}

# _ai_tools_sandbox_exec_scope_available : return 0 when a transient scope can be opened for a run -- systemd-run
#   and systemctl at their system paths, and the system manager answering a probe run -- with the answer kept for this
#   process. A scope is the boundary a descendant cannot leave: a process that opens a session of its own stays
#   in the scope's cgroup, so ending the scope ends it. A run without one is refused, since the session setsid opens
#   is a boundary a descendant's own setsid leaves.
_ai_tools_sandbox_exec_scope_available() {
    if [[ -z "${_AI_TOOLS_SANDBOX_EXEC_SCOPE_AVAILABLE:-}" ]]; then
        _AI_TOOLS_SANDBOX_EXEC_SCOPE_AVAILABLE=no
        [[ -x /usr/bin/systemd-run && -x /usr/bin/systemctl && -x /usr/bin/true ]] \
            && /usr/bin/systemd-run --scope --quiet --collect -- /usr/bin/true >/dev/null 2>&1 \
            && _AI_TOOLS_SANDBOX_EXEC_SCOPE_AVAILABLE=yes
    fi
    [[ "${_AI_TOOLS_SANDBOX_EXEC_SCOPE_AVAILABLE}" == yes ]]
}

# _ai_tools_sandbox_exec_end_scope <scope-unit> : SIGTERM, then SIGKILL five seconds later, to every process
#   in the scope's cgroup, whatever session or process group each has opened since.
_ai_tools_sandbox_exec_end_scope() {
    local scope_unit="$1" signal
    for signal in TERM KILL; do
        /usr/bin/systemctl kill --signal="SIG${signal}" "${scope_unit}" >/dev/null 2>&1 || true
        [[ "${signal}" == TERM ]] && sleep 5
    done
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
#     - a bound on its run (_ai_tools_sandbox_exec_timeout_seconds), held through the draining of its output: past
#       it, every process of the run gets SIGTERM, then SIGKILL, and the call returns 124 under MSG-W8B7, so a hung
#       child -- or a descendant it left holding its output open -- ends the step rather than the run. The run is
#       a transient systemd scope, the boundary a descendant cannot leave whatever session it opens; where the system
#       manager does not answer, the run is refused under MSG-Q2K6 rather than made with a weaker boundary.
#   Every host tool -- setsid, runuser, env, bash, and the sleep and getent beside them -- comes from the system
#   binary directories, never from the caller's PATH. Returns the command's own status; returns 1 without running
#   anything when the caller is not root (runuser needs root), <account> is not the sandbox account, a host tool is
#   absent from those directories, no scope can be opened, or no command was given.
ai_tools_as_sandbox() {
    local PATH="${_AI_TOOLS_SANDBOX_EXEC_SYSTEM_PATH}"
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
    if ! _ai_tools_sandbox_exec_scope_available; then
        _ai_tools_sandbox_exec_warn MSG-Q2K6 "cannot open a transient scope for a run as ${account} (systemd-run --scope did not start a probe: no system manager answers here) -- a run outside one could leave a process behind, so $(printf '%q' "$1") was not run"
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

    # The boundary the bound ends is the transient scope: `systemd-run --scope` registers its own pid in the scope
    # and execs the command, so the child's pid is the run's first process. Job control off for the start, so setsid
    # finds a process that is not a group leader and execs in place rather than forking.
    local scope_unit="ai-tools-sandbox-exec-$$-${RANDOM}${RANDOM}.scope" job_control_was_enabled=0
    [[ -o monitor ]] && job_control_was_enabled=1
    set +m
    /usr/bin/systemd-run --scope --quiet --collect --unit="${scope_unit%.scope}" -- \
        "${setsid_path}" --wait "${runuser_path}" -u "${account}" -- \
        "${env_path}" -i HOME="${sandbox_home}" PATH=/usr/bin:/bin LANG=C.UTF-8 \
        "${bash_path}" -c "${close_descriptors_then_exec}" _ "$@" \
        <&"${stdin_fd}" >&"${stdout_fd}" 2>&"${stderr_fd}" &
    local child_pid=$!
    (( job_control_was_enabled )) && set -m

    # One deadline for the run and the draining of its output; the child is polled once a second.
    local timeout_seconds deadline timed_out=0
    timeout_seconds="$(_ai_tools_sandbox_exec_timeout_seconds)"
    deadline=$(( SECONDS + timeout_seconds ))
    while kill -0 "${child_pid}" 2>/dev/null; do
        if (( SECONDS >= deadline )); then
            timed_out=1
            _ai_tools_sandbox_exec_end_scope "${scope_unit}"
            break
        fi
        sleep 1
    done
    local command_exit_status=0
    wait "${child_pid}" 2>/dev/null || command_exit_status=$?

    # The sanitizers end at EOF, which comes when the last holder of each pipe closes it: this shell's copies now,
    # and whatever the child left running with the pipe as its output. That leftover is held to the same deadline --
    # past it the boundary is ended, and a sanitizer still open after that is ended too, so the call returns.
    exec {stdout_fd}>&- {stderr_fd}>&-
    (( stdin_fd == 0 )) || exec {stdin_fd}<&-
    local sanitizer_pid leftover_held_output=0
    for sanitizer_pid in ${stdout_sanitizer_pid} ${stderr_sanitizer_pid}; do
        while kill -0 "${sanitizer_pid}" 2>/dev/null; do
            if (( SECONDS >= deadline )); then
                if (( ! timed_out )); then
                    timed_out=1
                    leftover_held_output=1
                    _ai_tools_sandbox_exec_end_scope "${scope_unit}"
                fi
                kill -0 "${sanitizer_pid}" 2>/dev/null && kill -TERM "${sanitizer_pid}" 2>/dev/null
                break
            fi
            sleep 0.2
        done
        wait "${sanitizer_pid}" 2>/dev/null || true
    done
    (( output_withheld )) && _ai_tools_sandbox_exec_warn "output of $(printf '%q' "$1") withheld: log.lib.sh, which sanitizes it, did not load"
    if (( timed_out )); then
        local what_ran_over="ran past"
        (( leftover_held_output )) && what_ran_over="exited, then a process it left behind held its output open past"
        _ai_tools_sandbox_exec_warn MSG-W8B7 "ended a command as ${account} that ${what_ran_over} ${timeout_seconds}s, with every process of its scope ${scope_unit}: $(printf '%q' "$1") -- the step did not complete; re-run it, or set AI_TOOLS_AS_SANDBOX_TIMEOUT=<seconds> for a slower host"
        return 124
    fi
    return "${command_exit_status}"
}
