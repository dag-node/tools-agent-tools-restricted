#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/lib/ai-tools/sessions.lib.sh
# Whether any process of the sandbox account is live, read from the kernel's cgroup tree. The reader the recursive
# relabels gate on: a `restorecon -R` over a tree the account can write resolves each path again before it writes
# the label, so a live process of the account can swap a directory for a symlink inside the walk and send the label
# elsewhere. The gate, its predicate and the residual are in cli.rule.md; relabel.lib.sh calls it.
#
# THE ENUMERATION IS A TWIN OF ai-tools-stop's, not a call into it. The stop helper is the original: it does not load
# a project library, so a stop does not depend on one (stop.rule.md, ref-section-e8k5), and this file cannot be the copy
# it sources. Four functions here are its cgroup2_mount, has_own_tasks, find_session_cgroups and cgroup_is_live
# under this module's names, with the slice and the manager directory taken as arguments where the helper reads its
# globals SANDBOX_SLICE and MANAGER_SERVICE. Each body is otherwise the helper's, and tests/unit/sessions.sh holds each
# pair equal through `declare -f`, so a fix to either copy fails the suite until it reaches the other. The comments
# explaining each body stay in the helper.
#
# What this file adds is the one thing the stop helper refuses to have: an exemption by name. The stop helper does not
# spare a cgroup, because on a DAC-only host a session can move its tasks into any cgroup it names. This reader exempts
# the user manager's own plumbing, and that is sound only where a relabel runs, which is where it is called: a relabel
# does not walk where SELinux is Disabled, and where the policy is loaded ai_tools_t can neither write a cgroup file
# nor reach its user manager to ask for a unit, so the names under the slice are the ones ai-tools-run and the manager
# gave them. The plumbing is what an idle account's slice holds: the manager's init.scope and the dbus broker it starts
# on first use (the units `ai-tools stop` lists as account plumbing). A login session scope (session-N.scope) is not
# plumbing: it holds a process of the account that a `sudo -u` started.
#
# Sourced, not executed. Deployed 644 root:root: shipped logic alone, sourced by root (the relabel helpers,
# the installers) and by the operator's CLI, which reads the world-readable cgroup files unprivileged.
# sandbox-exec.lib.sh is loaded best-effort for the account's uid; without it the state reads as unreadable.

# Include guard, as an if-statement: `[[ ]] && return` returns 1 for an unset guard and trips a sourcing shell's
# `set -e`.
if [[ -n "${_AI_TOOLS_SESSIONS__LOADED:-}" ]]; then
    return 0
fi
# shellcheck source=SCRIPTDIR/sandbox-exec.lib.sh
source "${BASH_SOURCE[0]%/*}/sandbox-exec.lib.sh" 2>/dev/null || true

_AI_TOOLS_SESSIONS__LOADED=1

# The user manager's own units, as glob patterns over a cgroup's path relative to the manager's directory: init.scope
# directly under it, and the dbus broker under whichever slice the manager starts it in.
# shellcheck disable=SC2034  # read by tests/unit/sessions.sh, which names the set it exempts
readonly -a AI_TOOLS_SESSIONS__PLUMBING_UNITS=(
    init.scope
    dbus-broker.service '*/dbus-broker.service'
    dbus.service '*/dbus.service'
)

# ── The twins of ai-tools-stop's enumeration ─────────────────────────────────────────────────
# ai_tools_sessions__read_cgroup2_mount: print the cgroup v2 hierarchy's mount point, read from /proc/mounts; return 1
#   where none is mounted. Twin of ai-tools-stop's cgroup2_mount.
ai_tools_sessions__read_cgroup2_mount() {
    local mount_point fstype
    while read -r _ mount_point fstype _; do
        [[ "${fstype}" == "cgroup2" ]] && { printf '%s' "${mount_point}"; return 0; }
    done < /proc/mounts
    return 1
}

# _ai_tools_sessions__list_session_cgroups <slice-dir> <manager-service-dir>: print one cgroup directory per unit
#   under the slice, and each slice holding tasks directly; the manager unit is descended into and never printed.
#   A unit is printed whether or not it holds a task, so a caller tests each with _ai_tools_sessions__is_cgroup_live.
#   Needs dotglob and nullglob in the calling shell, as the helper sets them at file scope: without dotglob
#   a dot-named cgroup drops out of the walk. Twin of ai-tools-stop's find_session_cgroups.
_ai_tools_sessions__list_session_cgroups() {
    [[ -d "$1" ]] || return 0
    local -a stack=("$1")
    local current child leaf
    _ai_tools_sessions__has_own_tasks "$1" && printf '%s\n' "$1"
    while (( ${#stack[@]} )); do
        current="${stack[-1]}"; unset 'stack[-1]'
        for child in "${current}"/*/; do
            child="${child%/}"
            [[ -d "${child}" ]] || continue
            leaf="${child##*/}"
            if [[ "${child}" == "$2" ]]; then
                _ai_tools_sessions__has_own_tasks "${child}" && printf '%s\n' "${child}"
                stack+=("${child}")
                continue
            fi
            if [[ "${leaf}" == *.service || "${leaf}" == *.scope ]]; then
                printf '%s\n' "${child}"
            else
                _ai_tools_sessions__has_own_tasks "${child}" && printf '%s\n' "${child}"
                stack+=("${child}")
            fi
        done
    done
}

# _ai_tools_sessions__has_own_tasks <cgroup-dir>: succeed when a task sits in this cgroup's own cgroup.procs, and when
#   that file exists and cannot be read. Twin of ai-tools-stop's has_own_tasks.
_ai_tools_sessions__has_own_tasks() {
    local first_task=""
    [[ -e "$1/cgroup.procs" ]] || return 1
    read -r first_task 2>/dev/null < "$1/cgroup.procs"
    [[ -n "${first_task}" ]] && return 0
    [[ -r "$1/cgroup.procs" ]] || return 0
    read -r first_task 2>/dev/null < "$1/cgroup.threads"
    [[ -n "${first_task}" ]]
}

# _ai_tools_sessions__is_cgroup_live <cgroup-dir>: succeed while a task remains in the cgroup or a descendant, from
#   cgroup.events' `populated` field, or from a walk where the file is absent; an answer it cannot read succeeds.
#   A removed directory is the one failure that reads empty. Twin of ai-tools-stop's cgroup_is_live.
_ai_tools_sessions__is_cgroup_live() {
    [[ -d "$1" ]] || return 1
    local field value
    if [[ -e "$1/cgroup.events" ]]; then
        if [[ -r "$1/cgroup.events" ]]; then
            while read -r field value; do
                [[ "${field}" == "populated" ]] || continue
                [[ "${value}" == "0" ]] && return 1
                return 0
            done 2>/dev/null < "$1/cgroup.events"
        fi
        return 0
    fi
    local -a directories=("$1")
    local index=0 current child
    while (( index < ${#directories[@]} )); do
        current="${directories[index]}"; index=$(( index + 1 ))
        _ai_tools_sessions__has_own_tasks "${current}" && return 0
        for child in "${current}"/*/; do
            child="${child%/}"
            [[ -d "${child}" ]] && directories+=("${child}")
        done
    done
    return 1
}

# ── The reader ───────────────────────────────────────────────────────────────────────────────
# _ai_tools_sessions__is_plumbing <cgroup-dir> <manager-service-dir>: succeed when the cgroup is one of the manager's
#   own units (AI_TOOLS_SESSIONS__PLUMBING_UNITS), matched on its path relative to the manager's directory.
_ai_tools_sessions__is_plumbing() {
    local relative pattern
    [[ "$1" == "$2/"* ]] || return 1
    relative="${1#"$2/"}"
    for pattern in "${AI_TOOLS_SESSIONS__PLUMBING_UNITS[@]}"; do
        # shellcheck disable=SC2053  # the pattern is this file's constant, matched as a glob
        [[ "${relative}" == ${pattern} ]] && return 0
    done
    return 1
}

# ai_tools_sessions__list_live_sessions <uid>: print each live cgroup under the account's slice user-<uid>.slice
#   that is not the manager's plumbing, one per line. Returns 0 with an empty listing when the account has no slice,
#   and 1 where the reading cannot be made: a uid that is not a number, no cgroup v2 mount, or a user.slice or account
#   slice this process cannot enter and list.
ai_tools_sessions__list_live_sessions() {
    local uid="${1:-}" mount slice manager cgroup
    [[ "${uid}" =~ ^[0-9]+$ ]] || return 1
    mount="$(ai_tools_sessions__read_cgroup2_mount)" || return 1
    [[ -n "${mount}" && -d "${mount}/user.slice" && -x "${mount}/user.slice" ]] || return 1
    slice="${mount}/user.slice/user-${uid}.slice"
    manager="${slice}/user@${uid}.service"
    [[ -e "${slice}" ]] || return 0
    [[ -d "${slice}" && -r "${slice}" && -x "${slice}" ]] || return 1
    # A subshell, so the walk's glob options do not reach the caller's shell.
    (
        shopt -s dotglob nullglob
        while IFS= read -r cgroup; do
            [[ -n "${cgroup}" ]] || continue
            _ai_tools_sessions__is_plumbing "${cgroup}" "${manager}" && continue
            _ai_tools_sessions__is_cgroup_live "${cgroup}" && printf '%s\n' "${cgroup}"
        done < <(_ai_tools_sessions__list_session_cgroups "${slice}" "${manager}")
    )
}

# ai_tools_sessions__read_live_session_state_for_uid <uid>: print `live` when a process of the account <uid> is live
#   outside its manager's plumbing, `none` when none is, and `unreadable` when the reading cannot be made
#   (ai_tools_sessions__list_live_sessions returning 1). A caller gating a walk treats `unreadable` as `live`.
#   Always returns 0, so the answer is read from stdout.
ai_tools_sessions__read_live_session_state_for_uid() {
    local live
    if ! live="$(ai_tools_sessions__list_live_sessions "${1:-}")"; then
        printf 'unreadable\n'
    elif [[ -n "${live}" ]]; then
        printf 'live\n'
    else
        printf 'none\n'
    fi
    return 0
}

# ai_tools_sessions__read_live_session_state: the same answer for the sandbox account, its uid read through
#   sandbox-exec.lib.sh; where that library did not load or does not
#   resolve an account, the answer is `unreadable`.
ai_tools_sessions__read_live_session_state() {
    local uid=""
    if declare -F ai_tools_sandbox_exec__read_sandbox_uid >/dev/null 2>&1; then
        uid="$(ai_tools_sandbox_exec__read_sandbox_uid)"
    fi
    ai_tools_sessions__read_live_session_state_for_uid "${uid}"
}
