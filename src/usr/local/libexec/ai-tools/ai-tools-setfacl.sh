#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/libexec/ai-tools/ai-tools-setfacl
# Applies the per-project POSIX ACL that lets the owning operator and the sandbox agent co-write
# an approved tree regardless of either party's umask -- the permission companion to
# ai-tools-setgid's group-ownership inheritance. An access + inherited-default ACL grants rwX to
# the @SANDBOX_GROUP@ group (the agent's access to operator-written files) and to the resolved
# operator (the operator's access to agent-written files), others denied. The operator grant is
# what lets the operator co-write the tree -- work tree, and .git under --with-git -- without
# joining @SANDBOX_GROUP@ and without waiting on the ownership handback.
#
# Owner-only paths are never granted. When a path's mode grants neither group nor other bits
# (0600, 0700), no grant is applied to it -- not group:@SANDBOX_GROUP@:rwX (the agent's) nor
# user:<operator>:rwX (the operator's) -- a directory is given no default ACL, the mask is not
# recalculated, and the mode bits are untouched. That mode is the operator's standing decision to
# keep the path out of the sandbox account's reach, and a claim does not overrule it. What the
# walk does instead is STRIP the sandbox residue such a path still carries (owner-only.lib.sh),
# so the seal does not rest on the mode alone staying put.
# It holds on the main walk and in the --with-git pass alike; a skipped directory takes its
# subtree with it, since the sandbox account cannot enter the directory to use a grant inside it.
# To opt a path in, widen its mode and re-claim -- a manual step rather than a prompt, because a
# standing denial should not fall to a single keypress.
#
# Every skip is counted and reported. On a project ROOT it means the sandbox account cannot enter
# the tree at all; under --with-git it means the git history the operator asked to share was not
# shared. Both are outcomes the operator has to be told, not left to infer from later behaviour.
#
# What this prevents: setfacl -m recalculates the mask to cover the entries it adds, so granting
# an owner-only path returns a 0600 file as 0660 with @SANDBOX_GROUP@ holding effective rw, and a
# 0700 directory as 0770 -- write on the directory, hence the power to unlink what it holds.
# secret-handling.rule.md's "keep it in a 700 <you>:<you> dir" advice rests on that directory
# case. setfacl -n (add the entry, leave the mask alone) is not used either: it would leave a
# dormant grant that any later chmod widening the group bits activates.
#
# Runs as root via sudo under ai-tools --project-claim (no-NOPASSWD, like ai-tools-lockdown);
# CAP_FOWNER lets it ACL files the operator does not own. The walk skips secret-named,
# '!'-excluded, skip-list, and foreign-owned paths. Alongside the ACL, the walk normalizes
# the primary group of a DRIFTED path -- group-accessible yet not group @SANDBOX_GROUP@
# (it arrived by rename, inheriting neither the setgid group nor the default ACL) -- so a
# re-claim's drift scan (acl_drift_scan in the CLI) finds the tree settled.
#
# Deploy:
#   sudo install -o root -g root -m 750 \
#       src/usr/local/libexec/ai-tools/ai-tools-setfacl.sh /usr/local/libexec/ai-tools/ai-tools-setfacl

set -euo pipefail

# Args: an optional --with-git flag (anywhere) enables the one-shot .git normalization
# pass; the remaining argument is the absolute project path.
WITH_GIT=false
TARGET=""
for arg in "$@"; do
    case "${arg}" in
        --with-git) WITH_GIT=true ;;
        -*) printf 'ai-tools-setfacl: unknown option: %s\n' "${arg}" >&2; exit 2 ;;
        *)  if [[ -z "${TARGET}" ]]; then
                TARGET="${arg}"
            else
                printf 'ai-tools-setfacl: too many arguments\n' >&2; exit 2
            fi ;;
    esac
done
[[ -n "${TARGET}" ]] \
    || { printf 'usage: ai-tools-setfacl [--with-git] <absolute-project-path>\n' >&2; exit 2; }
readonly TARGET WITH_GIT

# Operator-identity resolver (operator.lib.sh): resolves the operator that owns the project. A
# missing lib leaves ai_tools_resolve_owner a fail-closed stub, so the tree is left untouched.
readonly OPERATOR_LIB="/usr/local/lib/ai-tools/operator.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/operator.lib.sh
source "${OPERATOR_LIB}" 2>/dev/null || ai_tools_resolve_owner() { return 1; }
readonly GROUP="@SANDBOX_GROUP@"
# Operator-independent half of the ACL (see the header for the two-grant model); ACL_SPEC prepends
# user:<operator> after resolve_owner. rwX executes only on dirs/already-exec files; other::--- denies world.
readonly ACL_BASE="group:${GROUP}:rwX,other::---"
# Two identities may legitimately hold a project tree's files: the resolved operator and the
# sandbox account. A file belonging to a third party (root, another developer) is left untouched --
# claim must not pull a foreign file into the agent's group, even one the operator placed in the
# tree -- and COUNTED, so a walk that granted no path is reported rather than silent; the project
# root hitting the guard is called out on its own, since it means the claim granted no access at
# all. Matched by numeric UID; PROJECTS_UID is the resolved operator (set below).
SANDBOX_UID="$(id -u "@SANDBOX_USER@" 2>/dev/null || echo -1)"
readonly SANDBOX_UID

# Shared leveled logger: journald (always) + the root-only file /var/log/ai-tools/setfacl.log.
# Best-effort -- a no-op fallback keeps the helper working if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-setfacl"
AI_TOOLS_LOG_FILE="setfacl.log"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/log.lib.sh
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log() { :; }; ai_tools_log_debug() { :; }; ai_tools_log_info() { :; }
    ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
fi

# Directory-skip selector from the shared library (single source of truth, also used by
# session-hook.sh and ai-tools-setgid). A missing lib (broken install) leaves a stub that
# descends everywhere -- a slower but correct walk.
readonly SKIP_DIRS_LIB="/usr/local/lib/ai-tools/skip-dirs.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/skip-dirs.lib.sh
source "${SKIP_DIRS_LIB}" 2>/dev/null \
    || ai_tools_skip_find_expr() { AI_TOOLS_SKIP_FIND_EXPR=(); return 0; }

# Secret-name matcher (defense in depth): never apply the group ACL to a path whose
# basename looks like a secret (e.g. .env), so a private file is not re-exposed to the
# agent group even if the operator forgot to '!'-exclude it. We run as root, so we can
# read the 640 root:root lib. Best-effort -- the '!' allowlist exclusions remain the
# authoritative control; if the matcher cannot load, fall back to them.
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

# Without setfacl (or on a filesystem without ACL support) there is no ACL to apply --
# warn once and exit cleanly (best-effort, mirrors the other helpers' fail-soft).
command -v setfacl >/dev/null 2>&1 \
    || { ai_tools_log_warn "setfacl not found -- skipping ACL normalization for ${TARGET}"; exit 0; }

# Which paths the operator sealed, and what may be stripped from one (owner-only.lib.sh, the
# reference for both). Required and fail-closed like safe-paths.lib.sh: an unusable library must
# not leave this walk unable to recognize a sealed path.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/owner-only.lib.sh
source /usr/local/lib/ai-tools/owner-only.lib.sh
if ! declare -F ai_tools_is_owner_only >/dev/null 2>&1 \
        || ! declare -F ai_tools_strip_sandbox_residue >/dev/null 2>&1; then
    printf 'ai-tools-setfacl: FATAL: owner-only.lib.sh defines no owner-only guard\n' >&2
    exit 3
fi

# Protected-paths backstop (safe-paths.lib.sh): refuse to act on a system directory even
# when the allowlist includes it. See safe-paths.rule.md.
readonly SAFE_PATHS_LIB="/usr/local/lib/ai-tools/safe-paths.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/safe-paths.lib.sh
source "${SAFE_PATHS_LIB}"

# Canonicalise the argument; block symlink traversal of the path itself.
canonical="$(realpath -e "${TARGET}" 2>/dev/null)" || exit 0
[[ -d "${canonical}" ]] || exit 0
# Refuse the whole pass if the project root is a protected system directory.
ai_tools_assert_safe_target "${canonical}" "ACL grant" || exit 3

# Resolve the operator that owns this project (operator.lib.sh); no owner -> exit without acting. The guard
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
    local path="$1" normalize="${2:-}" expect_ident fd got_ident got_uid got_grp got_mode got_ftype
    expect_ident="$(stat -c '%d:%i' "${path}" 2>/dev/null)" || return 1
    { exec {fd}< "${path}"; } 2>/dev/null || return 1
    # %u/%G/%a BEFORE %F: %F ("regular empty file") is multi-word and must be the last field.
    read -r got_ident got_uid got_grp got_mode got_ftype \
        < <(stat -L -c '%d:%i %u %G %a %F' "/proc/self/fd/${fd}" 2>/dev/null) \
        || { exec {fd}<&-; return 1; }
    if [[ "${got_ident}" != "${expect_ident}" ]]; then
        exec {fd}<&-
        return 1
    fi
    # Owner guard (checked on the pinned inode, TOCTOU-safe): only the projects user's
    # or the sandbox account's own files are eligible; anything else is left untouched.
    # Returns 3, not 1, so the walk can tell a third-party owner from a stat failure and
    # report it: a walk that granted no path must not read as one with no path to grant.
    if [[ "${got_uid}" != "${PROJECTS_UID}" && "${got_uid}" != "${SANDBOX_UID}" ]]; then
        exec {fd}<&-
        return 3
    fi
    # Owner-only guard: the operator sealed this path and the claim honours it. Granting it would
    # be worse than a no-op -- `setfacl -m` RECALCULATES the mask, so the grant on a 0600 file
    # raises its mask from --- to rw- and hands the agent EFFECTIVE read/write while `ls -l` still
    # shows `-rw-------` and only the trailing `+` hints anything changed. Strip the residue the
    # path carries instead (owner-only.lib.sh), and report it: an owner-only .git under
    # --with-git is a deliberate no-op the operator has to be told about, not a share that
    # quietly skipped.
    if ai_tools_is_owner_only "${got_mode}"; then
        ai_tools_strip_sandbox_residue "${fd}" "${got_ftype}" "${got_grp}" "${got_mode}" \
            "${PROJECTS_GROUP:-}" || true
        exec {fd}<&-
        return 2
    fi
    local rc=0
    # Group ownership (plus setgid on dirs) so future entries inherit group GROUP -- the
    # ownership inheritance ai-tools-setgid gives the work tree's directories. Applied
    # unconditionally under 'normalize' (the .git pass), and on the main walk to a DRIFTED
    # path: group-accessible (any group/other bit) yet not group GROUP -- it arrived by
    # rename, inheriting neither the setgid group nor the default ACL; the same predicate
    # the CLI's acl_drift_scan reports. The chgrp is what settles the drift report: an ACL
    # entry alone grants access but leaves the primary group foreign, so the scan would
    # re-flag the path on every claim. Operates on the pinned fd, TOCTOU-safe like the ACL.
    local fix_group=false
    if [[ "${normalize}" == "normalize" ]]; then
        fix_group=true
    elif [[ "${got_grp}" != "${GROUP}" ]] && (( 8#${got_mode} & 077 )); then
        fix_group=true
    fi
    if ${fix_group}; then
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

# Walk the project's directories and files (skipping heavy trees, one filesystem) and
# ACL each. find emits a dir before its contents (pre-order), so when a dir is
# '!'-excluded or secret-named we record it as a skip-prefix and skip its whole
# subtree; an excluded/secret regular file is skipped on its own.
ai_tools_skip_find_expr setfacl '' "${canonical}"
declare -a expr=( "${canonical}" -xdev "${AI_TOOLS_SKIP_FIND_EXPR[@]}" \
                  '(' -type d -o -type f ')' -print0 )

declare -i applied=0
find "${expr[@]}" 2>/dev/null \
    | { declare -a skip=()
        declare -i owneronly=0 thirdparty=0 rc=0
        declare root_thirdparty=false
        _under_skip() { local p; for p in "${skip[@]:-}"; do
            [[ -n "${p}" && ( "$1" == "${p}" || "$1" == "${p}/"* ) ]] && return 0; done; return 1; }
        while IFS= read -r -d '' p; do
            _under_skip "${p}" && continue
            if _is_excluded "${p}" || _is_secret_name "${p}"; then
                [[ -d "${p}" ]] && skip+=("${p}")     # skip the whole subtree of a dir
                continue
            fi
            rc=0; _safe_setfacl "${p}" || rc=$?
            case "${rc}" in
                0) applied=$(( applied + 1 )) ;;
                2) owneronly=$(( owneronly + 1 ))
                   # A skipped DIRECTORY keeps its whole subtree out of the walk: an
                   # unreachable directory's contents cannot be granted through it, and
                   # descending would grant paths the operator sealed off at the parent.
                   [[ -d "${p}" ]] && skip+=("${p}") ;;
                3) thirdparty=$(( thirdparty + 1 ))
                   # The project root decides whether the ACL grant happened at all -- see
                   # the same split in ai-tools-setgid.
                   [[ "${p}" == "${canonical}" ]] && root_thirdparty=true ;;
            esac
        done
        # The counts are local to this subshell (pipe); log them here.
        ai_tools_log_info "ACL-normalized ${applied} path(s) under ${canonical}"
        if (( owneronly )); then
            ai_tools_log_info "left ${owneronly} owner-only path(s) under ${canonical} out of the agent's reach"
            printf 'ai-tools-setfacl: left %d owner-only path(s) (0600/0700) out of the sandbox account'"'"'s reach\n' \
                "${owneronly}" >&2
        fi
        # Surfaced for the same reason as the setgid walk's: the owner guard is the one skip
        # that can leave a claim reporting success having granted no access.
        if (( thirdparty )); then
            ai_tools_log_warn "left ${thirdparty} path(s) under ${canonical} untouched: owned by neither ${PROJECTS_USER} nor @SANDBOX_USER@"
            if ${root_thirdparty}; then
                printf 'ai-tools-setfacl: the project directory itself is owned by neither %s nor %s -- no ACL was applied, and the agent gets no access to this tree\n' \
                    "${PROJECTS_USER}" "@SANDBOX_USER@" >&2
            else
                printf 'ai-tools-setfacl: left %d path(s) owned by neither %s nor %s untouched -- the agent gets no access to them\n' \
                    "${thirdparty}" "${PROJECTS_USER}" "@SANDBOX_USER@" >&2
            fi
        fi
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
    declare -i git_owneronly=0 git_thirdparty=0 grc=0
    while IFS= read -r -d '' p; do
        _under_gskip "${p}" && continue
        if _is_excluded "${p}" || _is_secret_name "${p}"; then
            [[ -d "${p}" ]] && gskip+=("${p}")        # skip a secret/excluded subtree whole
            continue
        fi
        grc=0; _safe_setfacl "${p}" normalize || grc=$?
        case "${grc}" in
            0) git_applied=$(( git_applied + 1 )) ;;
            2) git_owneronly=$(( git_owneronly + 1 ))
               [[ -d "${p}" ]] && gskip+=("${p}") ;;
            3) git_thirdparty=$(( git_thirdparty + 1 )) ;;
        esac
    done < <(find "${gitdir}" -xdev '(' -type d -o -type f ')' -print0 2>/dev/null)
    ai_tools_log_info "normalized ${git_applied} path(s) under ${gitdir} (group ${GROUP}, setgid dirs, ACL)"
    # --with-git is an explicit opt-in, so a .git the owner-only guard seals off is a share
    # that did NOT happen. Silence here would leave the operator believing history is shared.
    if (( git_owneronly )); then
        ai_tools_log_info "left ${git_owneronly} owner-only path(s) under ${gitdir} out of the agent's reach"
        printf 'ai-tools-setfacl: %d owner-only path(s) under .git were NOT shared (0600/0700) -- git history stays out of the sandbox account'"'"'s reach\n' \
            "${git_owneronly}" >&2
    fi
    # Same disclosure as the main walk, for the same reason the owner-only count is disclosed
    # here: --with-git is an explicit opt-in, so a share that did not happen must be said.
    if (( git_thirdparty )); then
        ai_tools_log_warn "left ${git_thirdparty} path(s) under ${gitdir} untouched: owned by neither ${PROJECTS_USER} nor @SANDBOX_USER@"
        printf 'ai-tools-setfacl: %d path(s) under .git were NOT shared -- owned by neither %s nor %s\n' \
            "${git_thirdparty}" "${PROJECTS_USER}" "@SANDBOX_USER@" >&2
    fi
fi

exit 0
