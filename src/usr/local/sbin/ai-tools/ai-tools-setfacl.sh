#!/usr/bin/env bash
# /usr/local/sbin/ai-tools/ai-tools-setfacl
# Applies the per-project POSIX ACL that gives group @SANDBOX_GROUP@ permission
# inheritance across an approved project tree, the companion to ai-tools-setgid's
# group-OWNERSHIP inheritance. setgid carries the shared group onto new files; a
# POSIX default ACL carries the shared group's rwX PERMISSION onto them, umask-
# independent -- so a file the projects user's `git checkout`/`merge` writes under a
# restrictive umask (e.g. 077) stays group-accessible instead of being born 600 and
# locking the agent out. Two layers are applied to every directory:
#   - an ACCESS ACL  group:@SANDBOX_GROUP@:rwX,other::---  -- grants the shared group
#     read/write (X = execute only on dirs/already-exec files) on the existing entry
#     and strips ALL "other" access NOW (the claim-time cleanup: whatever stray
#     other-readable state the tree arrived in -- clone, tarball, prior umask -- is
#     normalized to others-denied);
#   - a DEFAULT ACL with the same spec -- inherited by every entry created later, so
#     new files/dirs are born group-accessible and others-denied regardless of the
#     creator's umask. `other::---` is pinned explicitly (not left for setfacl to
#     clone from the directory's current mode, which on a permissive-umask 0755 dir
#     would seed default:other::r-x and leak read access to every future file).
# Regular files get the ACCESS ACL only (default ACLs apply to directories).
#
# Invoked as root via sudo by the management CLI (ai-tools --project-claim), the same
# no-NOPASSWD model as ai-tools-relabel and ai-tools-lockdown: the projects user is
# prompted for a password; the sandbox account has no grant for it. Running as root
# (CAP_FOWNER) is required to ACL files the projects user does not own (e.g. agent-
# written files from a prior session). The project path the CLI passes is re-validated
# here against the same allow/exclude rules the other helpers use.
#
# Idempotent: setfacl is declarative, so a re-run on an already-normalized tree is a
# no-op. Safe to run at every claim.
#
# Secret-named files and directories are SKIPPED (never granted the group ACL), so a
# secret the operator forgot to '!'-exclude is not re-exposed to the agent group;
# ai-tools-lockdown remains the authoritative secret control. Heavy/transient trees
# (.git, node_modules, ...) are pruned, sharing the prune list with the sweep and
# ai-tools-setgid.
#
# Deploy:
#   sudo install -o root -g root -m 750 \
#       src/usr/local/sbin/ai-tools/ai-tools-setfacl.sh /usr/local/sbin/ai-tools/ai-tools-setfacl

set -euo pipefail

readonly TARGET="${1:?usage: ai-tools-setfacl <absolute-project-path>}"
# Allowlist. AI_TOOLS_ALLOWLIST overrides the installed path when set -- a root-only test
# hook: sudo strips it (env_reset, not in env_keep) and the handback daemon execs this with
# its own environment, so neither the operator nor the agent can inject it in production.
readonly ALLOWLIST="${AI_TOOLS_ALLOWLIST:-@PROJECTS_HOME@/.config/ai-tools/allowed-projects}"
readonly GROUP="@SANDBOX_GROUP@"
# rwX: read/write always, execute only where it already makes sense (dirs, exec files),
# so data files are not made spuriously executable. other::--- strips all world access.
readonly ACL_SPEC="group:${GROUP}:rwX,other::---"
# The two legitimate co-owners of a project tree: the projects user and the sandbox
# account. A path owned by anyone else (root, another developer) is NEVER touched --
# claim must not pull a foreign-owned file into the agent's group, even one the operator
# placed in the tree. Resolved to UIDs for a robust numeric compare (a uid with no
# passwd entry still compares correctly). -1 (no such user) matches nothing.
readonly PROJECTS_UID="$(id -u "@PROJECTS_USER@" 2>/dev/null || echo -1)"
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

# No allowlist -- do nothing silently (fail-closed; mirrors ai-tools-setgid).
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
    local path="$1" expect_ident fd got_ident got_uid got_ftype
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

exit 0
