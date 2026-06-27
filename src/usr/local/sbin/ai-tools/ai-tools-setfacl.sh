#!/usr/bin/env bash
# /usr/local/sbin/ai-tools/ai-tools-setfacl
# Applies the per-project POSIX ACL that lets the owning operator and the sandbox agent co-write
# an approved tree regardless of either party's umask -- the permission companion to
# ai-tools-setgid's group-ownership inheritance. An access + inherited-default ACL grants rwX to
# the @SANDBOX_GROUP@ group (the agent's access to operator-written files) and to the resolved
# operator (the operator's access to agent-written files), others denied. The operator grant is
# what lets the operator co-write the tree -- work tree, and .git under --with-git -- without
# joining @SANDBOX_GROUP@ and without waiting on the ownership handback.
#
# Runs as root via sudo under ai-tools --project-claim (no-NOPASSWD, like ai-tools-lockdown);
# CAP_FOWNER lets it ACL files the operator does not own. The walk skips secret-named,
# '!'-excluded, pruned, and foreign-owned paths.
#
# Deploy:
#   sudo install -o root -g root -m 750 \
#       src/usr/local/sbin/ai-tools/ai-tools-setfacl.sh /usr/local/sbin/ai-tools/ai-tools-setfacl

set -euo pipefail

# Args: an optional --with-git flag (anywhere) enables the one-shot .git normalization
# pass; the remaining argument is the absolute project path.
WITH_GIT=false
TARGET=""
for arg in "$@"; do
    case "${arg}" in
        --with-git) WITH_GIT=true ;;
        -*) printf 'ai-tools-setfacl: unknown option: %s\n' "${arg}" >&2; exit 2 ;;
        *)  [[ -z "${TARGET}" ]] && TARGET="${arg}" \
                || { printf 'ai-tools-setfacl: too many arguments\n' >&2; exit 2; } ;;
    esac
done
[[ -n "${TARGET}" ]] \
    || { printf 'usage: ai-tools-setfacl [--with-git] <absolute-project-path>\n' >&2; exit 2; }
readonly TARGET WITH_GIT

# Operator-identity resolver (operator.lib.sh): resolves the operator that owns the project. A
# missing lib leaves ai_tools_resolve_owner a fail-closed stub, so the tree is left untouched.
readonly OPERATOR_LIB="/usr/local/lib/ai-tools/operator.lib.sh"
# shellcheck source=/dev/null
source "${OPERATOR_LIB}" 2>/dev/null || ai_tools_resolve_owner() { return 1; }
readonly GROUP="@SANDBOX_GROUP@"
# Operator-independent half of the ACL (see the header for the two-grant model); ACL_SPEC prepends
# user:<operator> after resolve_owner. rwX executes only on dirs/already-exec files; other::--- denies world.
readonly ACL_BASE="group:${GROUP}:rwX,other::---"
# Two identities may legitimately hold a project tree's files: the resolved operator and the
# sandbox account. A file belonging to a third party (root, another developer) is left untouched --
# claim must not pull a foreign file into the agent's group, even one the operator placed in the
# tree. Matched by numeric UID; PROJECTS_UID is the resolved operator (set below).
readonly SANDBOX_UID="$(id -u "@SANDBOX_USER@" 2>/dev/null || echo -1)"

# Shared leveled logger: journald (always) + the root-only file /var/log/ai-tools/setfacl.log.
# Best-effort -- a no-op fallback keeps the helper working if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-setfacl"
AI_TOOLS_LOG_FILE="setfacl.log"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=/dev/null
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log() { :; }; ai_tools_log_debug() { :; }; ai_tools_log_info() { :; }
    ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
fi

# Heavy/transient trees pruned from the walk come from the shared library (the single
# source of truth, also used by session-hook.sh and ai-tools-setgid). Unreadable
# (broken install) -> empty -> no pruning: slower walk, still correct.
readonly PRUNE_LIB="/usr/local/lib/ai-tools/prune-dirs.lib.sh"
AI_TOOLS_PRUNE_NAMES=()
# shellcheck source=/dev/null
[[ -r "${PRUNE_LIB}" ]] && source "${PRUNE_LIB}" || true

# Secret-name matcher (defense in depth): never apply the group ACL to a path whose
# basename looks like a secret (e.g. .env), so a private file is not re-exposed to the
# agent group even if the operator forgot to '!'-exclude it. We run as root, so we can
# read the 640 root:root lib. Best-effort -- the '!' allowlist exclusions remain the
# authoritative control; if the matcher cannot load, fall back to them.
readonly SECRET_PATTERNS_LIB="/usr/local/lib/ai-tools/secret-patterns.lib.sh"
_secret_loaded=false
# shellcheck source=/dev/null
if source "${SECRET_PATTERNS_LIB}" 2>/dev/null && ai_tools_load_secret_patterns 2>/dev/null; then
    _secret_loaded=true
fi
_is_secret_name() {
    ${_secret_loaded} || return 1
    ai_tools_is_secret_basename "$(basename -- "$1")"
}

# Without setfacl (or on a filesystem without ACL support) there is nothing to do --
# warn once and exit cleanly (best-effort, mirrors the other helpers' fail-soft).
command -v setfacl >/dev/null 2>&1 \
    || { ai_tools_log_warn "setfacl not found -- skipping ACL normalization for ${TARGET}"; exit 0; }

# Canonicalise the argument; block symlink traversal of the path itself.
canonical="$(realpath -e "${TARGET}" 2>/dev/null)" || exit 0
[[ -d "${canonical}" ]] || exit 0

# Resolve the operator that owns this project (operator.lib.sh); no owner -> do nothing. The guard
# below then acts only on paths the resolved operator or the sandbox account hold.
ai_tools_resolve_owner "${canonical}" || exit 0
readonly ALLOWLIST="${AI_TOOLS_RESOLVED_ALLOWLIST}" PROJECTS_UID
# Prepend the resolved operator's named grant (its access to agent-written files).
readonly ACL_SPEC="user:${PROJECTS_USER}:rwX,${ACL_BASE}"

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
# contents; a glob matches as-is. Same semantics as ai-tools-setgid / ai-tools-chown.
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

# _safe_setfacl <path>: apply the ACL to <path>, TOCTOU-safe. The agent is a group-
# writer on project dirs and could swap an entry for a symlink between the find that
# enumerates it and the setfacl that acts on it; setfacl would then follow the symlink
# and ACL an arbitrary target (e.g. /etc) as root. Pin the inode with an open fd and
# operate through /proc/self/fd, re-checking it is still the same inode -- a swap to a
# symlink reopens a different inode and fails the identity check. Directories get the
# access AND default ACL; regular files the access ACL only. Mirrors ai-tools-setgid's
# pinned-fd apply. Returns 0 on apply, 1 when skipped or on error.
_safe_setfacl() {
    local path="$1" normalize="${2:-}" expect_ident fd got_ident got_uid got_ftype
    expect_ident="$(stat -c '%d:%i' "${path}" 2>/dev/null)" || return 1
    { exec {fd}< "${path}"; } 2>/dev/null || return 1
    # %u BEFORE %F: %F ("regular empty file") is multi-word and must be the last field.
    read -r got_ident got_uid got_ftype \
        < <(stat -L -c '%d:%i %u %F' "/proc/self/fd/${fd}" 2>/dev/null) \
        || { exec {fd}<&-; return 1; }
    if [[ "${got_ident}" != "${expect_ident}" ]]; then
        exec {fd}<&-
        return 1
    fi
    # Owner guard (checked on the pinned inode, TOCTOU-safe): only the projects user's
    # or the sandbox account's own files are eligible; anything else is left untouched.
    if [[ "${got_uid}" != "${PROJECTS_UID}" && "${got_uid}" != "${SANDBOX_UID}" ]]; then
        exec {fd}<&-
        return 1
    fi
    local rc=0
    if [[ "${normalize}" == "normalize" ]]; then
        # Group ownership (plus setgid on dirs) so future entries inherit group GROUP --
        # the ownership inheritance ai-tools-setgid gives the work tree, applied here to
        # .git. Operates on the pinned fd, TOCTOU-safe like the ACL below.
        chgrp -- "${GROUP}" "/proc/self/fd/${fd}" 2>/dev/null || rc=1
        [[ "${got_ftype}" == directory ]] \
            && { chmod -- g+s "/proc/self/fd/${fd}" 2>/dev/null || rc=1; }
    fi
    case "${got_ftype}" in
        directory)
            setfacl    -m "${ACL_SPEC}" "/proc/self/fd/${fd}" 2>/dev/null || rc=1
            setfacl -d -m "${ACL_SPEC}" "/proc/self/fd/${fd}" 2>/dev/null || rc=1
            ;;
        "regular file"|"regular empty file")
            setfacl    -m "${ACL_SPEC}" "/proc/self/fd/${fd}" 2>/dev/null || rc=1
            ;;
        *)  # symlink / fifo / device / socket -- never ACL these
            exec {fd}<&-
            return 1
            ;;
    esac
    exec {fd}<&-
    return "${rc}"
}

# Walk the project's directories and files (pruning heavy trees, one filesystem) and
# ACL each. find emits a dir before its contents (pre-order), so when a dir is
# '!'-excluded or secret-named we record it as a skip-prefix and skip its whole
# subtree; an excluded/secret regular file is skipped on its own.
declare -a expr=( "${canonical}" -xdev )
if (( ${#AI_TOOLS_PRUNE_NAMES[@]} > 0 )); then
    expr+=( '(' )
    for i in "${!AI_TOOLS_PRUNE_NAMES[@]}"; do
        (( i > 0 )) && expr+=( -o )
        expr+=( -name "${AI_TOOLS_PRUNE_NAMES[$i]}" )
    done
    expr+=( ')' -prune -o )
fi
expr+=( '(' -type d -o -type f ')' -print0 )

declare -i applied=0
find "${expr[@]}" 2>/dev/null \
    | { declare -a skip=()
        _under_skip() { local p; for p in "${skip[@]:-}"; do
            [[ -n "${p}" && ( "$1" == "${p}" || "$1" == "${p}/"* ) ]] && return 0; done; return 1; }
        while IFS= read -r -d '' p; do
            _under_skip "${p}" && continue
            if _is_excluded "${p}" || _is_secret_name "${p}"; then
                [[ -d "${p}" ]] && skip+=("${p}")     # skip the whole subtree of a dir
                continue
            fi
            _safe_setfacl "${p}" && applied=$(( applied + 1 )) || true
        done
        # The count is local to this subshell (pipe); log it here.
        ai_tools_log_info "ACL-normalized ${applied} path(s) under ${canonical}"
      } || true

# .git normalization (opt-in via --with-git): the main walk skips .git, but when the
# operator intends the agent to share git history, normalize it here in one pass -- group
# GROUP + setgid on its dirs and the same default+access group ACL, so commits the operator
# makes stay agent-accessible. Secret-named and '!'-excluded entries are still skipped (a
# stray credential committed into .git stays private). A `.git` FILE (submodule/worktree
# pointer) is not a tree to normalize, so the -d guard skips it. Idempotent. The loop runs
# in this shell (process substitution, not a pipe), so the counter survives.
gitdir="${canonical}/.git"
if ${WITH_GIT} && [[ -d "${gitdir}" ]] && ! _is_excluded "${gitdir}"; then
    declare -i git_applied=0
    declare -a gskip=()
    _under_gskip() { local q; for q in "${gskip[@]:-}"; do
        [[ -n "${q}" && ( "$1" == "${q}" || "$1" == "${q}/"* ) ]] && return 0; done; return 1; }
    while IFS= read -r -d '' p; do
        _under_gskip "${p}" && continue
        if _is_excluded "${p}" || _is_secret_name "${p}"; then
            [[ -d "${p}" ]] && gskip+=("${p}")        # skip a secret/excluded subtree whole
            continue
        fi
        _safe_setfacl "${p}" normalize && git_applied=$(( git_applied + 1 )) || true
    done < <(find "${gitdir}" -xdev '(' -type d -o -type f ')' -print0 2>/dev/null)
    ai_tools_log_info "normalized ${git_applied} path(s) under ${gitdir} (group ${GROUP}, setgid dirs, ACL)"
fi

exit 0
