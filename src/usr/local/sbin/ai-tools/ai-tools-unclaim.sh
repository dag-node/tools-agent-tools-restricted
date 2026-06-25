#!/usr/bin/env bash
# /usr/local/sbin/ai-tools/ai-tools-unclaim
# Reverses the filesystem side of a project claim: hands an approved project tree back
# to a target group and revokes the agent's access. For every eligible path it:
#   1. clears all extended ACL entries and the default ACL (`setfacl -b`), removing the
#      group:@SANDBOX_GROUP@ access entry AND the default ACL claim seeded -- so no agent
#      grant lingers and new files no longer inherit auto group-write;
#   2. changes the group owner to <target-group> (the operator's own group by default, or
#      any group the operator chose), moving the tree out of @SANDBOX_GROUP@;
#   3. removes group WRITE: 660 -> 640, 770 -> 750, 400 stays 400. Group read/execute is
#      kept, so the new group owner can still read/traverse; only writing is disabled. On
#      DIRECTORIES the setgid bit claim added is also cleared (`chmod g-w,g-s`), returning
#      the tree to plain perms -- a numeric chmod cannot clear a directory's setgid, only
#      symbolic `g-s` can. Files keep their setuid/setgid bits (an sgid binary is not
#      silently altered).
# Net effect: the agent (group @SANDBOX_GROUP@) loses access via both the group owner and
# the named ACL entry, and the tree carries plain Unix permissions under the new group.
#
# Invoked as root via sudo by the management CLI (ai-tools --project-unclaim), the same
# no-NOPASSWD model as ai-tools-relabel/-lockdown/-setfacl. Running as root is required to
# chgrp to an arbitrary group and to act on files the projects user does not own. The
# project path and target group the CLI passes are re-validated here.
#
# Owner guard: only the projects user's and the sandbox account's own files are touched;
# anything owned by a third party (root, another developer) is left untouched, mirroring
# the claim helpers. Secret-named and '!'-excluded paths are skipped (a locked secret
# stays where it is), and heavy/transient trees are pruned -- the same rules as setgid/
# setfacl, via the shared libraries. .git is the exception: the main walk skips it like the
# other heavy trees, but a dedicated one-shot pass reverts it (it is the tree a claim groups,
# and optionally normalizes, for the agent), so the unclaim fully revokes the agent's access
# to git history.
#
# Idempotent: re-running on an already-unclaimed tree clears nothing new, regroups to the
# same group, and removes an already-absent write bit -- all no-ops.
#
# Deploy:
#   sudo install -o root -g root -m 750 \
#       src/usr/local/sbin/ai-tools/ai-tools-unclaim.sh /usr/local/sbin/ai-tools/ai-tools-unclaim

set -euo pipefail

readonly TARGET="${1:?usage: ai-tools-unclaim <absolute-project-path> <target-group>}"
readonly TARGET_GROUP="${2:?usage: ai-tools-unclaim <absolute-project-path> <target-group>}"

# Operator identity (PROJECTS_USER/HOME/GROUP, plus the numeric PROJECTS_UID) from
# /etc/ai-tools/operator.conf via the shared resolver. AI_TOOLS_OPERATOR_CONF /
# AI_TOOLS_ALLOWLIST override the paths -- root-only test hooks: sudo strips them
# (env_reset, not in env_keep) and the handback daemon execs this with its own environment,
# so neither the operator nor the agent can inject them in production.
readonly OPERATOR_LIB="/usr/local/lib/ai-tools/operator.lib.sh"
# shellcheck source=/dev/null
if source "${OPERATOR_LIB}" 2>/dev/null; then
    ai_tools_load_operator || true
else
    PROJECTS_USER=''; PROJECTS_HOME=''; PROJECTS_GROUP=''; PROJECTS_UID=-1
fi
readonly ALLOWLIST="${AI_TOOLS_ALLOWLIST:-${PROJECTS_HOME}/.config/ai-tools/allowed-projects}"
# The two legitimate co-owners of a project tree (see ai-tools-setfacl). Files owned by
# anyone else are left untouched. Compared by numeric UID; PROJECTS_UID is -1 (matches
# nothing) when unenrolled.
readonly PROJECTS_UID
readonly SANDBOX_UID="$(id -u "@SANDBOX_USER@" 2>/dev/null || echo -1)"

# Shared leveled logger: journald (always) + the root-only file /var/log/ai-tools/unclaim.log.
AI_TOOLS_LOG_TAG="ai-tools-unclaim"
AI_TOOLS_LOG_FILE="unclaim.log"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=/dev/null
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log() { :; }; ai_tools_log_debug() { :; }; ai_tools_log_info() { :; }
    ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
fi

# Heavy/transient trees pruned from the walk (shared single source of truth).
readonly PRUNE_LIB="/usr/local/lib/ai-tools/prune-dirs.lib.sh"
AI_TOOLS_PRUNE_NAMES=()
# shellcheck source=/dev/null
[[ -r "${PRUNE_LIB}" ]] && source "${PRUNE_LIB}" || true

# Secret-name matcher: never touch a secret-named path (a locked secret stays put). We
# run as root, so we can read the 640 root:root lib. Best-effort -- falls back to the
# '!' allowlist exclusions if the matcher cannot load.
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

# Validate the target group exists before touching anything (fail-closed).
getent group "${TARGET_GROUP}" >/dev/null 2>&1 \
    || { ai_tools_log_error "unknown target group '${TARGET_GROUP}' -- nothing changed"; exit 1; }

# No allowlist -- do nothing silently (fail-closed; mirrors the claim helpers).
[[ -f "${ALLOWLIST}" ]] || exit 0

# Canonicalise the argument; block symlink traversal of the path itself.
canonical="$(realpath -e "${TARGET}" 2>/dev/null)" || exit 0
[[ -d "${canonical}" ]] || exit 0

declare -a allowed=()
declare -a excluded=()
while IFS= read -r entry || [[ -n "${entry}" ]]; do
    [[ -z "${entry}" || "${entry}" == '#'* ]] && continue
    if [[ "${entry}" == '!'* ]]; then
        excluded+=("${entry:1}")
    else
        dir="$(realpath -e "${entry}" 2>/dev/null)" || continue
        allowed+=("${dir}")
    fi
done < "${ALLOWLIST}"

# _is_excluded <abs-path>: 0 if covered by a '!' rule (same semantics as setgid/setfacl).
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

# Unclaim is lenient about allowlist membership in one direction: the CLI removes the
# allowlist entry around the same time, so we accept a path that is no longer listed as
# long as it is not '!'-excluded. But still refuse to act outside any registered tree
# unless the path itself is the (now possibly unlisted) target.
_is_excluded "${canonical}" && exit 0

# _safe_unclaim <path>: clear ACL, regroup, drop group write -- TOCTOU-safe via a pinned
# fd (see ai-tools-setfacl for the rationale). Owner-guarded on the pinned inode.
_safe_unclaim() {
    local path="$1" expect_ident fd got_ident got_uid got_ftype
    expect_ident="$(stat -c '%d:%i' "${path}" 2>/dev/null)" || return 1
    { exec {fd}< "${path}"; } 2>/dev/null || return 1
    # %u BEFORE %F: %F ("regular empty file") is multi-word and must be the last field.
    read -r got_ident got_uid got_ftype \
        < <(stat -L -c '%d:%i %u %F' "/proc/self/fd/${fd}" 2>/dev/null) \
        || { exec {fd}<&-; return 1; }
    if [[ "${got_ident}" != "${expect_ident}" ]]; then exec {fd}<&-; return 1; fi
    # Owner guard: only the projects user's or the sandbox account's own files.
    if [[ "${got_uid}" != "${PROJECTS_UID}" && "${got_uid}" != "${SANDBOX_UID}" ]]; then
        exec {fd}<&-; return 1
    fi
    case "${got_ftype}" in
        directory|"regular file"|"regular empty file") ;;
        *) exec {fd}<&-; return 1 ;;            # never touch symlinks/fifos/devices
    esac
    local rc=0
    # Order: clear ACL (incl. default) -> regroup -> drop group write, so chmod acts on
    # clean mode bits and no masked ACL grant survives. On directories also clear the
    # setgid bit (added by claim) so the tree returns to plain perms (770 -> 750); a
    # numeric chmod cannot clear a directory's setgid, only the symbolic g-s can. Files
    # keep their setuid/setgid bits untouched (an sgid binary must not be silently
    # altered); only group write is removed there (660 -> 640).
    setfacl -b   "/proc/self/fd/${fd}" 2>/dev/null || rc=1
    chgrp -- "${TARGET_GROUP}" "/proc/self/fd/${fd}" 2>/dev/null || rc=1
    if [[ "${got_ftype}" == "directory" ]]; then
        chmod g-w,g-s "/proc/self/fd/${fd}" 2>/dev/null || rc=1
    else
        chmod g-w "/proc/self/fd/${fd}" 2>/dev/null || rc=1
    fi
    exec {fd}<&-
    return "${rc}"
}

# Walk the project's directories and files (pruning heavy trees, one filesystem). A
# '!'-excluded or secret-named directory has its whole subtree skipped; an excluded or
# secret regular file is skipped on its own.
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

declare -i changed=0
find "${expr[@]}" 2>/dev/null \
    | { declare -a skip=()
        _under_skip() { local p; for p in "${skip[@]:-}"; do
            [[ -n "${p}" && ( "$1" == "${p}" || "$1" == "${p}/"* ) ]] && return 0; done; return 1; }
        while IFS= read -r -d '' p; do
            _under_skip "${p}" && continue
            if _is_excluded "${p}" || _is_secret_name "${p}"; then
                [[ -d "${p}" ]] && skip+=("${p}")
                continue
            fi
            _safe_unclaim "${p}" && changed=$(( changed + 1 )) || true
        done
        ai_tools_log_info "unclaimed ${changed} path(s) under ${canonical} (group -> ${TARGET_GROUP}, group write removed)"
      } || true

# .git reversal: the main walk skips .git (the shared heavy-tree list), but a claim grouped
# it to @SANDBOX_GROUP@ (the recursive chgrp) and may have normalized it (ai-tools-setfacl
# --with-git: setgid + ACL), so a full unclaim must revert .git too -- otherwise the agent
# keeps git-history access through the group owner and the named ACL entry. Revert it here
# in one pass with the same per-entry reversal (clear ACL, regroup to <target-group>, drop
# group write, clear dir setgid) and the same secret/exclusion skips. Unconditional: it
# reverses the base claim's chgrp whether or not --with-git ran, and no-ops on an already-
# reverted tree. The loop runs in this shell (process substitution), so the counter survives.
gitdir="${canonical}/.git"
if [[ -d "${gitdir}" ]] && ! _is_excluded "${gitdir}"; then
    declare -i git_changed=0
    declare -a gskip=()
    _under_gskip() { local q; for q in "${gskip[@]:-}"; do
        [[ -n "${q}" && ( "$1" == "${q}" || "$1" == "${q}/"* ) ]] && return 0; done; return 1; }
    while IFS= read -r -d '' p; do
        _under_gskip "${p}" && continue
        if _is_excluded "${p}" || _is_secret_name "${p}"; then
            [[ -d "${p}" ]] && gskip+=("${p}")
            continue
        fi
        _safe_unclaim "${p}" && git_changed=$(( git_changed + 1 )) || true
    done < <(find "${gitdir}" -xdev '(' -type d -o -type f ')' -print0 2>/dev/null)
    ai_tools_log_info "unclaimed ${git_changed} path(s) under ${gitdir} (group -> ${TARGET_GROUP}, group write removed)"
fi

exit 0
