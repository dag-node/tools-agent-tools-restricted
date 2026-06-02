#!/usr/bin/env bash
# /usr/local/sbin/ai-tools/setgid
# Normalizes group ownership and the setgid bit on the directories of an approved
# project, so that files EITHER @PROJECTS_USER@ OR the agent creates there are born
# in group @SANDBOX_GROUP@ -- the shared group both can read/write. setgid carries
# that group onto new files regardless of the creator's own group membership, which
# is what lets @PROJECTS_USER@ be a NON-member of @SANDBOX_GROUP@ (defence in depth:
# the projects user's home configs are then unreachable from the sandbox group)
# while the agent can still read/write everything it hands back.
#
# Called by the SessionStart hook (sandbox-sweep.sh session-start) via sudo
# (ai-tools -> root). Runs IN ai_tools_t (no domain transition, like ai-tools-chown).
# The agent that triggers it cannot read the allowlist, so the project path it
# passes is UNTRUSTED and re-validated here against the same allow/exclude rules.
#
# Idempotent: applies only the dirs that need it, safe to run every session start.
#
# Sudoers rule (in /etc/sudoers.d/ai-tools-claude):
#   ai-tools ALL=(root) NOPASSWD: /usr/local/sbin/ai-tools/setgid
#
# Deploy:
#   sudo install -o root -g root -m 750 \
#       scripts/ai-tools-setgid.sh /usr/local/sbin/ai-tools/setgid

set -euo pipefail

readonly TARGET="${1:?usage: ai-tools-setgid <absolute-project-path>}"
readonly ALLOWLIST="@PROJECTS_HOME@/.config/ai-tools/allowed-projects"
readonly GROUP="@SANDBOX_GROUP@"

# Heavy/transient trees pruned from the walk come from the shared library (the
# single source of truth, also used by sandbox-sweep.sh and ai-tools-lockdown).
# Unreadable (broken install) -> empty -> no pruning: slower walk, still correct.
readonly PRUNE_LIB="/usr/local/lib/ai-tools/prune-dirs.lib.sh"
AI_TOOLS_PRUNE_NAMES=()
# shellcheck source=/dev/null
[[ -r "${PRUNE_LIB}" ]] && source "${PRUNE_LIB}" || true

# No allowlist -- do nothing silently (fail-closed; mirrors ai-tools-chown).
[[ -f "${ALLOWLIST}" ]] || exit 0

# Canonicalise the argument; block symlink traversal of the path itself.
canonical="$(realpath -e "${TARGET}" 2>/dev/null)" || exit 0
[[ -d "${canonical}" ]] || exit 0

declare -a allowed=()
declare -a excluded=()
while IFS= read -r entry || [[ -n "${entry}" ]]; do
    [[ -z "${entry}" || "${entry}" == '#'* ]] && continue
    if [[ "${entry}" == '!'* ]]; then
        excluded+=("${entry:1}")              # strip leading !, keep raw (may glob)
    else
        dir="$(realpath -e "${entry}" 2>/dev/null)" || continue
        allowed+=("${dir}")
    fi
done < "${ALLOWLIST}"

# _is_excluded <abs-path>: 0 if covered by a '!' rule. A plain path also covers its
# contents; a glob matches as-is. Same semantics as ai-tools-chown / ai-tools-lockdown.
_is_excluded() {
    local path="$1" pat
    [[ "${#excluded[@]}" -gt 0 ]] || return 1
    for pat in "${excluded[@]}"; do
        pat="${pat%/}"
        [[ "${path}" == ${pat} ]] && return 0
        [[ "${pat}" != *'*'* && "${path}" == "${pat}/"* ]] && return 0
    done
    return 1
}

# _is_allowed <abs-path>: 0 if at or under an allowed directory.
_is_allowed() {
    local path="$1" d
    [[ "${#allowed[@]}" -gt 0 ]] || return 1
    for d in "${allowed[@]}"; do
        [[ "${path}" == "${d}" || "${path}" == "${d}/"* ]] && return 0
    done
    return 1
}

# The passed project root must itself be an allowed, non-excluded path.
_is_excluded "${canonical}" && exit 0
_is_allowed  "${canonical}" || exit 0

# _safe_setgid <dir>: chgrp GROUP (only if it differs) and ensure the setgid bit,
# TOCTOU-safe. The agent is a group-writer on project dirs and could swap a subdir
# for a symlink between the find that enumerates it and the chmod that acts on it;
# chmod/chgrp would then follow the symlink and act on an arbitrary directory as
# root. Pin the inode with an open fd and operate through /proc/self/fd, re-checking
# it is still the same directory. Mirrors ai-tools-chown's pinned-fd apply.
_safe_setgid() {
    local dir="$1" expect_ident grp mode fd got_ident got_ftype
    read -r expect_ident grp mode \
        < <(stat -c '%d:%i %G %a' "${dir}" 2>/dev/null) || return 1
    # Nothing to do when already group GROUP and already setgid.
    [[ "${grp}" == "${GROUP}" ]] && (( (0${mode} & 02000) != 0 )) && return 0

    { exec {fd}< "${dir}"; } 2>/dev/null || return 1
    read -r got_ident got_ftype \
        < <(stat -L -c '%d:%i %F' "/proc/self/fd/${fd}" 2>/dev/null) \
        || { exec {fd}<&-; return 1; }
    if [[ "${got_ftype}" != "directory" || "${got_ident}" != "${expect_ident}" ]]; then
        exec {fd}<&-
        return 1
    fi
    [[ "${grp}" != "${GROUP}" ]] && chgrp -- "${GROUP}" "/proc/self/fd/${fd}"
    chmod -- g+s "/proc/self/fd/${fd}"
    exec {fd}<&-
    return 0
}

# Walk the project's directories (pruning heavy trees, one filesystem) and
# normalize each. Re-check exclusion per dir so a '!'-excluded subpath is skipped.
declare -a expr=( "${canonical}" -xdev )
if (( ${#AI_TOOLS_PRUNE_NAMES[@]} > 0 )); then
    expr+=( '(' )
    for i in "${!AI_TOOLS_PRUNE_NAMES[@]}"; do
        (( i > 0 )) && expr+=( -o )
        expr+=( -name "${AI_TOOLS_PRUNE_NAMES[$i]}" )
    done
    expr+=( ')' -prune -o )
fi
expr+=( -type d -print0 )

find "${expr[@]}" 2>/dev/null \
    | while IFS= read -r -d '' d; do
        _is_excluded "${d}" && continue
        _safe_setgid "${d}" || true
      done || true

exit 0
