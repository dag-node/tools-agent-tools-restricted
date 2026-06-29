#!/usr/bin/env bash
# /usr/local/sbin/ai-tools/ai-tools-setgid
# Normalizes group ownership and the setgid bit on the directories of an approved
# project, so that files EITHER an operator OR the agent creates there are born
# in group @SANDBOX_GROUP@ -- the shared group both can read/write. setgid carries
# that group onto new files regardless of the creator's own group membership, which
# is what lets an operator be a NON-member of @SANDBOX_GROUP@ (defence in depth:
# the operator's home configs are then unreachable from the sandbox group)
# while the agent can still read/write everything it hands back.
#
# Invoked as root two ways: by `ai-tools --project-claim` via operator `sudo` (the operator is not
# a SANDBOX_GROUP member, so changing the project's group needs root), and by the ai-tools-handback
# daemon when the SessionStart hook (session-hook.sh session-start) sends a SETGID request over the
# handback socket. The handback path runs IN ai_tools_handback_t (inherited from the daemon, no
# domain transition); the claim path runs as root in the operator's sudo context.
# The agent that triggers it cannot read the allowlist, so the project path it
# passes is UNTRUSTED and re-validated here against the same allow/exclude rules.
#
# Idempotent: applies only the dirs that need it, safe to run every session start.
#
# Invocation: the handback socket's SETGID verb (ai-tools-handback daemon, root).
#   Not a sudo target -- ai-tools has no sudo rights.
#
# Deploy:
#   sudo install -o root -g root -m 750 \
#       src/usr/local/sbin/ai-tools/ai-tools-setgid.sh /usr/local/sbin/ai-tools/ai-tools-setgid

set -euo pipefail

readonly TARGET="${1:?usage: ai-tools-setgid <absolute-project-path>}"

# Operator-identity resolver (operator.lib.sh): resolves the operator that owns the project. A
# missing lib leaves ai_tools_resolve_owner a fail-closed stub, so the tree is left untouched.
readonly OPERATOR_LIB="/usr/local/lib/ai-tools/operator.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/operator.lib.sh
source "${OPERATOR_LIB}" 2>/dev/null || ai_tools_resolve_owner() { return 1; }
readonly GROUP="@SANDBOX_GROUP@"
# Two identities may legitimately hold a project tree's dirs: the resolved operator and the sandbox
# account. A directory belonging to a third party (root, another developer) is left untouched --
# normalization must not pull a foreign dir into the agent's group. Matched by numeric UID;
# PROJECTS_UID is the resolved operator (set below).
SANDBOX_UID="$(id -u "@SANDBOX_USER@" 2>/dev/null || echo -1)"
readonly SANDBOX_UID

# Shared leveled logger: journald (always) + the root-only file /var/log/ai-tools/setgid.log.
# Best-effort -- a no-op fallback keeps the helper working if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-setgid"
AI_TOOLS_LOG_FILE="setgid.log"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/log.lib.sh
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log() { :; }; ai_tools_log_debug() { :; }; ai_tools_log_info() { :; }
    ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
fi

# Directory-skip selector from the shared library (single source of truth, also used by
# session-hook.sh and ai-tools-lockdown). A missing lib (broken install) leaves a stub that
# skips nothing -- a slower but correct walk.
readonly SKIP_DIRS_LIB="/usr/local/lib/ai-tools/skip-dirs.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/skip-dirs.lib.sh
source "${SKIP_DIRS_LIB}" 2>/dev/null \
    || ai_tools_skip_find_expr() { AI_TOOLS_SKIP_FIND_EXPR=(); return 0; }

# Secret-name matcher (defense in depth): never apply the sandbox group to a dir
# whose basename looks like a secret (e.g. .env), so a private dir is not exposed
# to the agent group even if the operator forgot to '!'-exclude it. We run as root,
# so we can read the 640 root:root lib. Best-effort -- the '!' allowlist exclusions
# remain the authoritative control; if the matcher cannot load, fall back to them.
readonly SECRET_PATTERNS_LIB="/usr/local/lib/ai-tools/secret-patterns.lib.sh"
_secret_loaded=false
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/secret-patterns.lib.sh
if source "${SECRET_PATTERNS_LIB}" 2>/dev/null && ai_tools_load_secret_patterns 2>/dev/null; then
    _secret_loaded=true
fi
_is_secret_name() {
    ${_secret_loaded} || return 1
    ai_tools_is_secret_basename "$(basename -- "$1")"
}

# Protected-paths backstop (safe-paths.lib.sh): refuse to act on a system directory even
# when the allowlist includes it. See safe-paths.rule.md.
readonly SAFE_PATHS_LIB="/usr/local/lib/ai-tools/safe-paths.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/safe-paths.lib.sh
source "${SAFE_PATHS_LIB}"

# Canonicalise the argument; block symlink traversal of the path itself.
canonical="$(realpath -e "${TARGET}" 2>/dev/null)" || exit 0
[[ -d "${canonical}" ]] || exit 0
# Refuse the whole pass if the project root is a protected system directory.
ai_tools_assert_safe_target "${canonical}" "setgid normalization" || exit 3

# Resolve the operator that owns this project (operator.lib.sh); no owner -> do nothing. The
# owner-guard below then acts only on dirs the resolved operator or the sandbox account hold.
ai_tools_resolve_owner "${canonical}" || exit 0
readonly ALLOWLIST="${AI_TOOLS_RESOLVED_ALLOWLIST}" PROJECTS_UID

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
    local dir="$1" expect_ident grp mode owner_uid fd got_ident got_ftype got_uid
    read -r expect_ident owner_uid grp mode \
        < <(stat -c '%d:%i %u %G %a' "${dir}" 2>/dev/null) || return 1
    # Owner guard: only the projects user's or the sandbox account's own dirs are
    # eligible (re-verified TOCTOU-safe on the pinned inode below); skip anything else.
    [[ "${owner_uid}" == "${PROJECTS_UID}" || "${owner_uid}" == "${SANDBOX_UID}" ]] || return 1
    # Nothing to do when already group GROUP and already setgid.
    [[ "${grp}" == "${GROUP}" ]] && (( (0${mode} & 02000) != 0 )) && return 0

    { exec {fd}< "${dir}"; } 2>/dev/null || return 1
    # %u BEFORE %F so the multi-word %F ("directory") stays the last field.
    read -r got_ident got_uid got_ftype \
        < <(stat -L -c '%d:%i %u %F' "/proc/self/fd/${fd}" 2>/dev/null) \
        || { exec {fd}<&-; return 1; }
    if [[ "${got_ftype}" != "directory" || "${got_ident}" != "${expect_ident}" ]]; then
        exec {fd}<&-
        return 1
    fi
    # Owner guard (checked on the pinned inode, TOCTOU-safe): only the projects user's
    # or the sandbox account's own dirs are eligible; anything else is left untouched.
    if [[ "${got_uid}" != "${PROJECTS_UID}" && "${got_uid}" != "${SANDBOX_UID}" ]]; then
        exec {fd}<&-
        return 1
    fi
    local regrouped=0
    [[ "${grp}" != "${GROUP}" ]] && { chgrp -- "${GROUP}" "/proc/self/fd/${fd}"; regrouped=1; }
    chmod -- g+s "/proc/self/fd/${fd}"
    exec {fd}<&-
    # Record the actual change (the early return above logs nothing for a no-op dir).
    if (( regrouped )); then
        ai_tools_log_info "normalized ${dir} (group ${grp} -> ${GROUP}, +setgid)"
    else
        ai_tools_log_info "normalized ${dir} (+setgid)"
    fi
    return 0
}

# Walk the project's directories (skipping heavy trees, one filesystem) and
# normalize each. find emits a dir before its contents (pre-order), so when a dir
# is '!'-excluded or secret-named we record it as a skip-prefix and skip its whole
# subtree -- never flipping the group anywhere under a private/secret dir.
ai_tools_skip_find_expr setgid
declare -a expr=( "${canonical}" -xdev "${AI_TOOLS_SKIP_FIND_EXPR[@]}" -type d -print0 )

find "${expr[@]}" 2>/dev/null \
    | { declare -a skip=()
        _under_skip() { local p; for p in "${skip[@]:-}"; do
            [[ -n "${p}" && ( "$1" == "${p}" || "$1" == "${p}/"* ) ]] && return 0; done; return 1; }
        while IFS= read -r -d '' d; do
            _under_skip "${d}" && continue
            if _is_excluded "${d}" || _is_secret_name "${d}"; then
                skip+=("${d}"); continue
            fi
            _safe_setgid "${d}" || true
        done
      } || true

exit 0
