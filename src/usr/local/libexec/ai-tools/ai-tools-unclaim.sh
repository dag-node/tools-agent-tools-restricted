#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/libexec/ai-tools/ai-tools-unclaim
# Reverses the filesystem side of a project claim: hands an approved project tree back
# to a target group and revokes the agent's access. For every eligible path it:
#   1. clears all extended ACL entries and the default ACL (`setfacl -b`), removing the access
#      entries claim seeded -- group:@SANDBOX_GROUP@ for the agent and user:<operator> for the
#      operator -- AND the default ACL, so no claim grant lingers and new files no longer inherit
#      auto group-write;
#   2. changes the group owner to <target-group> (the operator's own group by default, or
#      any group the operator chose), moving the tree out of @SANDBOX_GROUP@;
#   3. removes group WRITE: 660 -> 640, 770 -> 750, 400 stays 400. Group READ stays, so the
#      new group owner can still read/traverse. Group EXECUTE stays on a directory (traversal)
#      and on a genuine script (owner has execute), but is stripped on a data file that landed
#      group-executable -- `setfacl -b` above promotes the tree's `group::r-x` base into the
#      mode, so a plain file the agent wrote can surface as 0650; the strip is keyed on
#      OWNER-execute (the bit git records) so a script keeps group r-x (750) while a data file
#      drops to 640. On DIRECTORIES the setgid bit claim added is also cleared (`chmod g-w,g-s`),
#      returning the tree to plain perms -- a numeric chmod cannot clear a directory's setgid,
#      only symbolic `g-s` can. Files keep their setuid/setgid bits (an sgid binary is not
#      silently altered): only the group write and any stray group execute are removed.
# Net effect: the agent (group @SANDBOX_GROUP@) loses access via both the group owner and
# the named ACL entry, and the tree carries plain Unix permissions under the new group.
#
# Invoked as root via sudo by the management CLI (ai-tools --project-unclaim), the same
# no-NOPASSWD model as ai-tools-relabel/-lockdown/-setfacl. Running as root is required to
# chgrp to an arbitrary group and to act on files the projects user does not own. The
# project path and target group the CLI passes are re-validated here, and the path must
# resolve at or under a registered project (allowed-projects) or the helper is a no-op.
#
# Two modes, differing ONLY in which paths they accept -- never in what they do to a path
# they accept, so one reversal is described once and tested once:
#   default      the whole tree is authorized by its allowlist entry, and every eligible path
#                in it is reverted.
#   --unlisted   the tree is in NO allowlist (a claimed project copied or moved elsewhere and
#                never unclaimed), so it does not carry authorization of its own. The membership
#                check is replaced by a per-path residue gate (_is_residue): a path is touched
#                only while it still bears the ai-tools fingerprint -- owned by the sandbox
#                account, grouped to it, or carrying its named ACL entry. A path that was
#                never part of a claim is left byte-for-byte as it is, so running this on the
#                wrong directory leaves it exactly as it was. This mode additionally hands sandbox-OWNED
#                inodes back to the invoking operator (ai-tools-reclaim, which normally does
#                that, refuses an unlisted path) and resets a leftover ai_tools_project_t
#                label. --full extends the walk into the skip-listed heavy trees, where
#                residue survives a copy exactly like everywhere else.
#
# Owner guard: only the projects user's and the sandbox account's own files are touched;
# anything owned by a third party (root, another developer) is left untouched, mirroring
# the claim helpers. Under --unlisted the "projects user" is the operator who invoked sudo,
# validated against OPERATORS, since no allowlist entry can name the owner of an unlisted
# tree -- so one operator can never rewrite another's files.
# Hardlink guard: a regular file with more than one name is refused in BOTH modes, the same
# boundary ai-tools-chown enforces -- chgrp and chmod act on the inode, which a second name
# can reach from outside the tree, so acting would change a path the walk never authorized.
#
# This is the one refusal here that leaves MORE access than acting would: the inode keeps its
# group, so after the project is deregistered the agent still holds those files through it. That
# is accepted rather than resolved, because the alternative is worse -- the second name is outside
# the tree and this pass does not authorize a change out there, and for the common case (`git clone
# --local`, which hardlinks .git/objects to the source repo) acting would silently rewrite the
# ORIGIN's objects. What the guard owes the operator instead is disclosure: refusals are counted,
# reported to the terminal with what they leave behind, and handed the `find -links +1` that lists
# them, never folded into a silent skip count.
# Secret-named and '!'-excluded paths are skipped (a locked secret
# stays where it is), and heavy/transient trees are skipped -- the same rules as setgid/
# setfacl, via the shared libraries. .git is the exception: the main walk skips it like the
# other heavy trees, but a dedicated one-shot pass reverts it (it is the tree a claim groups,
# and optionally normalizes, for the agent), so the unclaim fully revokes the agent's access
# to git history.
#
# NOT a round trip. The reversal normalizes; it does not restore. `setfacl -b` clears every
# extended ACL -- including entries that predate the claim and are unrelated to the
# agent -- and group write comes off, so a path the claim opened lands on 640 (750 when the
# owner has execute) under the target group. What it does NOT do is put back the world bits:
# the claim's ACL walk set other::--- on every path it touched, so 644 and 664 both arrive
# here as 660 and leave as 640. An owner-only path (0600/0700) is the exception at both ends
# -- the claim skips it as out of the agent's reach, so there is no change to reverse and it
# passes through unchanged. No prior state is recorded anywhere, so no pass can restore it;
# the CLI says so before it asks and tells the operator to back up first.
#
# Idempotent: re-running on an already-unclaimed tree finds no ACL left to clear, regroups to the
# same group, and removes an already-absent write bit -- all no-ops.
#
# Deploy:
#   sudo install -o root -g root -m 750 \
#       src/usr/local/libexec/ai-tools/ai-tools-unclaim.sh /usr/local/libexec/ai-tools/ai-tools-unclaim

set -euo pipefail

readonly USAGE="usage: ai-tools-unclaim <absolute-project-path> <target-group> [--unlisted] [--full]"
TARGET="${1:?${USAGE}}"
TARGET_GROUP="${2:?${USAGE}}"
shift 2

# --unlisted: act on a tree that is NOT in any allowed-projects (a claimed project copied or
# moved elsewhere and never unclaimed). It swaps one gate for another rather than removing one:
# the allowlist-membership check below is skipped, and every path must instead carry the
# ai-tools residue fingerprint (_is_residue) to be touched at all. The protected-paths backstop,
# the owner guard, the hardlink guard, and the secret/'!' skips all still apply, so the mode is
# strictly NARROWER per path than a listed unclaim and identical in what it does to a path it
# accepts. --full additionally walks the skip-listed heavy trees (node_modules, .venv, caches),
# where residue would otherwise survive a copy.
UNLISTED=false
FULL=false
for _arg in "$@"; do
    case "${_arg}" in
        --unlisted) UNLISTED=true ;;
        --full)     FULL=true ;;
        *) printf 'ai-tools-unclaim: unknown option: %s\n%s\n' "${_arg}" "${USAGE}" >&2; exit 2 ;;
    esac
done
unset _arg
readonly TARGET TARGET_GROUP UNLISTED FULL

# Operator-identity resolver (operator.lib.sh): resolves the operator that owns the project. A
# missing lib leaves ai_tools_resolve_owner a fail-closed stub, so the tree is left untouched.
readonly OPERATOR_LIB="/usr/local/lib/ai-tools/operator.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/operator.lib.sh
source "${OPERATOR_LIB}" 2>/dev/null || ai_tools_resolve_owner() { return 1; }
# Two identities may legitimately hold a project tree (see ai-tools-setfacl); a file belonging to a
# third party is left untouched. Matched by numeric UID; PROJECTS_UID is the resolved operator.
SANDBOX_UID="$(id -u "@SANDBOX_USER@" 2>/dev/null || echo -1)"
# The sandbox GID is the residue fingerprint's cheapest arm: a claim chgrp's the tree to it,
# and every copy method that carries residue at all (cp -a, rsync -a, mv, tar -p) preserves it.
SANDBOX_GID="$(getent group "@SANDBOX_GROUP@" 2>/dev/null | cut -d: -f3)"
[[ -n "${SANDBOX_GID}" ]] || SANDBOX_GID=-1
readonly SANDBOX_UID SANDBOX_GID

# Shared leveled logger: journald (always) + the root-only file /var/log/ai-tools/unclaim.log.
AI_TOOLS_LOG_TAG="ai-tools-unclaim"
AI_TOOLS_LOG_FILE="unclaim.log"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/log.lib.sh
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log() { :; }; ai_tools_log_debug() { :; }; ai_tools_log_info() { :; }
    ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
fi

# Directory-skip selector (shared single source of truth). A missing lib leaves a stub that
# descends into every directory -- a slower but correct walk.
readonly SKIP_DIRS_LIB="/usr/local/lib/ai-tools/skip-dirs.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/skip-dirs.lib.sh
source "${SKIP_DIRS_LIB}" 2>/dev/null \
    || ai_tools_skip_find_expr() { AI_TOOLS_SKIP_FIND_EXPR=(); return 0; }

# Secret-name matcher: never touch a secret-named path (a locked secret stays put). We
# run as root, so we can read the 640 root:root lib. Best-effort -- falls back to the
# '!' allowlist exclusions if the matcher cannot load.
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

# Validate the target group exists before touching anything (fail-closed).
getent group "${TARGET_GROUP}" >/dev/null 2>&1 \
    || { ai_tools_log_error "unknown target group '${TARGET_GROUP}' -- nothing changed"; exit 1; }

# Protected-paths backstop (safe-paths.lib.sh): refuse to act on a system directory even
# when the allowlist includes it. See safe-paths.rule.md.
readonly SAFE_PATHS_LIB="/usr/local/lib/ai-tools/safe-paths.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/safe-paths.lib.sh
source "${SAFE_PATHS_LIB}"

# Canonicalise the argument; block symlink traversal of the path itself.
canonical="$(realpath -e "${TARGET}" 2>/dev/null)" || exit 0
[[ -d "${canonical}" ]] || exit 0
# Refuse the whole pass if the project root is a protected system directory.
ai_tools_assert_safe_target "${canonical}" "unclaim" || exit 3

if ${UNLISTED}; then
    # No allowlist entry names this tree, so its owner cannot be resolved from one. The identity
    # bounding the walk is instead the operator who INVOKED sudo, validated against OPERATORS in
    # operator.conf: operator A can never rewrite operator B's files, and a direct root call with
    # no sudo context is refused rather than defaulting to some operator. Fails closed at every
    # step -- an unresolvable caller, an unconfigured one, or an unloadable operator.lib (whose
    # functions are then undefined, so the `||` fires) all stop the pass before any mutation.
    caller_uid="${SUDO_UID:-}"
    [[ -n "${caller_uid}" ]] \
        || { ai_tools_log_error "--unlisted needs an invoking operator (no SUDO_UID) -- nothing changed"; exit 1; }
    caller="$(id -un "${caller_uid}" 2>/dev/null)" \
        || { ai_tools_log_error "--unlisted: unknown invoking uid ${caller_uid} -- nothing changed"; exit 1; }
    ai_tools_load_operators 2>/dev/null \
        || { ai_tools_log_error "--unlisted: no operators configured -- nothing changed"; exit 1; }
    _is_operator=false
    for op in "${AI_TOOLS_OPERATORS[@]}"; do
        [[ "${op}" == "${caller}" ]] && { _is_operator=true; break; }
    done
    ${_is_operator} \
        || { ai_tools_log_error "--unlisted: ${caller} is not a configured operator -- nothing changed"; exit 1; }
    PROJECTS_UID="${caller_uid}"
    # The caller's own allowlist is still read below, for its '!' exclusions and for the
    # "already registered" refusal: a glob rule the operator wrote to keep a path out of reach
    # keeps it out of reach here too. Resolved through operator.lib's own path helper so the
    # AI_TOOLS_ALLOWLIST test hook applies here exactly as it does on the resolve_owner path.
    is_primary=secondary
    [[ "${caller}" == "${AI_TOOLS_OPERATORS[0]}" ]] && is_primary=primary
    ALLOWLIST="$(_ai_tools_operator_allowlist "${caller}" "${is_primary}")"
else
    # Resolve the operator that owns this project (operator.lib.sh); no owner -> exit without acting. The guard
    # below then acts only on paths the resolved operator or the sandbox account hold.
    ai_tools_resolve_owner "${canonical}" || exit 0
    ALLOWLIST="${AI_TOOLS_RESOLVED_ALLOWLIST}"
fi
readonly ALLOWLIST PROJECTS_UID

declare -a allowed=()
declare -a excluded=()
if [[ -r "${ALLOWLIST}" ]]; then
    while IFS= read -r entry || [[ -n "${entry}" ]]; do
        [[ -z "${entry}" || "${entry}" == '#'* ]] && continue
        if [[ "${entry}" == '!'* ]]; then
            excluded+=("${entry:1}")
        else
            dir="$(realpath -e "${entry}" 2>/dev/null)" || continue
            allowed+=("${dir}")
        fi
    done < "${ALLOWLIST}"
fi

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

# Refuse a '!'-excluded target outright, and in the default mode a target outside every
# registered project: unclaim must never modify permissions outside allowed-projects. Same gate
# as ai-tools-setgid/-setfacl (a silent no-op on a foreign target). The management CLI runs the
# hand-back BEFORE it drops the allowlist entry, so a legitimate unclaim still resolves its owner
# above and stays listed here. --unlisted swaps this whole-tree gate for the per-path residue
# gate in _safe_unclaim; it never runs with neither.
_is_excluded "${canonical}" && exit 0
if ${UNLISTED}; then
    # --unlisted is for a tree NO allowlist names. If the caller's own allowlist does name it,
    # the caller chose the wrong mode: refuse rather than run the narrower per-path gate over a
    # registered project, where the full walk is what the operator asked for.
    if _is_allowed "${canonical}"; then
        ai_tools_log_error "--unlisted on a registered project ${canonical} -- use the listed mode; nothing changed"
        exit 1
    fi
else
    _is_allowed "${canonical}" || exit 0
fi

# _is_residue <fd> <uid> <gid>: 0 when the pinned inode still carries the ai-tools fingerprint --
# owned by the sandbox account, grouped to it, or carrying a named ACL entry for it. The UNION of
# the three is what makes the gate safe to run outside the allowlist: a partially handed-back tree
# can retain any one of them alone, and testing only the group would leave an ai-tools-OWNED file
# untouched, where the agent keeps access through the user bits. Read from the pinned fd, so it
# describes the same inode the mutation acts on. Only the uid/gid arms are free; the ACL read
# runs only when both miss.
_is_residue() {
    local fd="$1" uid="$2" gid="$3"
    [[ "${uid}" == "${SANDBOX_UID}" ]] && return 0
    [[ "${gid}" == "${SANDBOX_GID}" ]] && return 0
    getfacl -c -- "/proc/self/fd/${fd}" 2>/dev/null \
        | grep -q "^\(default:\)\?group:@SANDBOX_GROUP@:"
}

# _safe_unclaim <path>: clear ACL, regroup, drop group write -- TOCTOU-safe via a pinned
# fd (see ai-tools-setfacl for the rationale). Owner-guarded on the pinned inode.
#
# Returns 0 when the path was changed, 2 when it was refused as a hardlink (the caller counts
# and reports those), 1 for every other skip.
_safe_unclaim() {
    local path="$1" expect_ident fd got_ident got_uid got_gid got_nlink got_ftype
    expect_ident="$(stat -c '%d:%i' "${path}" 2>/dev/null)" || return 1
    { exec {fd}< "${path}"; } 2>/dev/null || return 1
    # %F ("regular empty file") is multi-word, so it must be the last field.
    read -r got_ident got_uid got_gid got_nlink got_ftype \
        < <(stat -L -c '%d:%i %u %g %h %F' "/proc/self/fd/${fd}" 2>/dev/null) \
        || { exec {fd}<&-; return 1; }
    if [[ "${got_ident}" != "${expect_ident}" ]]; then exec {fd}<&-; return 1; fi
    # Owner guard: only the projects user's or the sandbox account's own files.
    if [[ "${got_uid}" != "${PROJECTS_UID}" && "${got_uid}" != "${SANDBOX_UID}" ]]; then
        exec {fd}<&-; return 1
    fi
    case "${got_ftype}" in
        directory) ;;
        "regular file"|"regular empty file")
            # Hardlink guard, the same boundary ai-tools-chown enforces: an inode with more
            # than one name can be reached from OUTSIDE this tree, and chgrp/chmod act on the
            # inode, so acting here would change a path the walk never authorized. Directories
            # legitimately have nlink >= 2 ('.' plus each child's '..'), so this applies to
            # regular files only.
            if [[ "${got_nlink}" -ne 1 ]]; then exec {fd}<&-; return 2; fi
            ;;
        *) exec {fd}<&-; return 1 ;;            # never touch symlinks/fifos/devices
    esac
    # Residue gate (--unlisted only): outside the allowlist the tree does not carry authorization
    # of its own, so a path is touched ONLY while it still bears the ai-tools fingerprint. A
    # path that never belonged to a claim is left byte-for-byte as it is.
    if ${UNLISTED} && ! _is_residue "${fd}" "${got_uid}" "${got_gid}"; then
        exec {fd}<&-; return 1
    fi
    local rc=0
    # Order: clear ACL (incl. default) -> regroup -> drop group write, so chmod acts on
    # clean mode bits and no masked ACL grant survives. On directories also clear the
    # setgid bit (added by claim) so the tree returns to plain perms (770 -> 750); a
    # numeric chmod cannot clear a directory's setgid, only the symbolic g-s can. Files
    # keep their setuid/setgid bits untouched (an sgid binary must not be silently
    # altered); only group write is removed there (660 -> 640).
    setfacl -b   "/proc/self/fd/${fd}" 2>/dev/null || rc=1
    chgrp -- "${TARGET_GROUP}" "/proc/self/fd/${fd}" 2>/dev/null || rc=1
    # --unlisted only: hand a sandbox-OWNED inode back to the invoking operator. Regrouping
    # alone would leave the agent its access through the USER bits, and the ownership sweep
    # that covers this for a registered project (ai-tools-reclaim) refuses an unlisted path,
    # so this pass is the only one that can reach it. A path the operator already owns is
    # left alone -- this never changes ownership away from a third party, which the owner
    # guard above has already excluded.
    if ${UNLISTED} && [[ "${got_uid}" == "${SANDBOX_UID}" ]]; then
        chown -- "${PROJECTS_UID}" "/proc/self/fd/${fd}" 2>/dev/null || rc=1
    fi
    if [[ "${got_ftype}" == "directory" ]]; then
        chmod g-w,g-s "/proc/self/fd/${fd}" 2>/dev/null || rc=1
    else
        # Drop group WRITE; also drop a stray group EXECUTE on a data file. setfacl -b
        # above promoted the ACL's group:: base (r-x on a tree the agent wrote) into the
        # mode, so a data file can land group-executable (0650); strip that, keyed on
        # OWNER-execute (the bit git records) so a genuine script (owner rwx) keeps group
        # r-x (-> 750) while a data file (owner rw) drops to 640. Relative g-w[,g-x]
        # leaves any setuid/setgid bit on the file untouched (an sgid binary is not altered).
        local fmode gxarg=""
        fmode="$(stat -L -c '%a' "/proc/self/fd/${fd}" 2>/dev/null)" || fmode=""
        if [[ -n "${fmode}" ]] && (( ( ( 8#${fmode} >> 6 ) & 1 ) == 0 )); then
            gxarg=",g-x"
        fi
        chmod "g-w${gxarg}" "/proc/self/fd/${fd}" 2>/dev/null || rc=1
    fi
    exec {fd}<&-
    return "${rc}"
}

# Walk the project's directories and files (one filesystem; heavy trees skipped unless --full).
# A '!'-excluded or secret-named directory has its whole subtree skipped; an excluded or
# secret regular file is skipped on its own. find runs WITHOUT -L, so a symlink is listed but
# never descended: a symlink loop inside the tree is unreachable by construction and needs neither
# cycle detection, and -xdev keeps the walk off other filesystems and bind mounts.
if ${FULL}; then
    # --full: the skip list is a walk-cost optimization, and residue hidden in a skipped tree
    # (node_modules, .venv, caches) survives a copy exactly like the rest.
    AI_TOOLS_SKIP_FIND_EXPR=()
else
    ai_tools_skip_find_expr unclaim '' "${canonical}"
fi
declare -a expr=( "${canonical}" -xdev "${AI_TOOLS_SKIP_FIND_EXPR[@]}" \
                  '(' -type d -o -type f ')' -print0 )

declare -i changed=0
find "${expr[@]}" 2>/dev/null \
    | { declare -a skip=()
        declare -i hardlinked=0 rc=0
        _under_skip() { local p; for p in "${skip[@]:-}"; do
            [[ -n "${p}" && ( "$1" == "${p}" || "$1" == "${p}/"* ) ]] && return 0; done; return 1; }
        while IFS= read -r -d '' p; do
            _under_skip "${p}" && continue
            if _is_excluded "${p}" || _is_secret_name "${p}"; then
                [[ -d "${p}" ]] && skip+=("${p}")
                continue
            fi
            rc=0; _safe_unclaim "${p}" || rc=$?
            case "${rc}" in
                0) changed=$(( changed + 1 )) ;;
                2) hardlinked=$(( hardlinked + 1 )) ;;
            esac
        done
        ai_tools_log_info "unclaimed ${changed} path(s) under ${canonical} (group -> ${TARGET_GROUP}, group write removed)"
        # Surfaced, never silent, and with its CONSEQUENCE: a refused hardlink is a path the
        # operator asked to change that keeps the group it has -- so after the project is
        # deregistered those inodes still carry the agent's group, which is the one thing an
        # unclaim is for. The refusal is still right (the inode is reachable from outside the tree,
        # and this pass does not authorize a change out there), so what the operator needs is to be told
        # plainly and handed the command that lists them, not a silent difference between counts.
        if (( hardlinked )); then
            ai_tools_log_warn "left ${hardlinked} hardlinked file(s) under ${canonical} untouched -- they keep group @SANDBOX_GROUP@"
            printf 'ai-tools-unclaim: left %d hardlinked file(s) untouched -- an inode with more than one name can be reached from outside this tree, so changing it here would change a path this pass never authorized. They KEEP the group they have, so the agent is not off them: list them with\n  find %s -xdev -type f -links +1 -group @SANDBOX_GROUP@\n' \
                "${hardlinked}" "${canonical}" >&2
        fi
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
    declare -i git_changed=0 git_hardlinked=0 grc=0
    declare -a gskip=()
    _under_gskip() { local q; for q in "${gskip[@]:-}"; do
        [[ -n "${q}" && ( "$1" == "${q}" || "$1" == "${q}/"* ) ]] && return 0; done; return 1; }
    while IFS= read -r -d '' p; do
        _under_gskip "${p}" && continue
        if _is_excluded "${p}" || _is_secret_name "${p}"; then
            [[ -d "${p}" ]] && gskip+=("${p}")
            continue
        fi
        grc=0; _safe_unclaim "${p}" || grc=$?
        case "${grc}" in
            0) git_changed=$(( git_changed + 1 )) ;;
            2) git_hardlinked=$(( git_hardlinked + 1 )) ;;
        esac
    done < <(find "${gitdir}" -xdev '(' -type d -o -type f ')' -print0 2>/dev/null)
    ai_tools_log_info "unclaimed ${git_changed} path(s) under ${gitdir} (group -> ${TARGET_GROUP}, group write removed)"
    # `git clone --local` hardlinks .git/objects to the source repo, so a locally-cloned tree
    # legitimately hits the hardlink guard here in bulk. Refusing is the correct outcome --
    # those inodes are shared with the origin, and changing one changes the origin's copy --
    # but it has to be said out loud, or the operator reads a partial revert as a complete one.
    if (( git_hardlinked )); then
        ai_tools_log_warn "left ${git_hardlinked} hardlinked file(s) under ${gitdir} untouched -- they keep group @SANDBOX_GROUP@"
        printf 'ai-tools-unclaim: left %d hardlinked file(s) in .git untouched -- a local git clone shares object files with the source repo, so changing them would change the origin. They KEEP the group they have: list them with\n  find %s -xdev -type f -links +1 -group @SANDBOX_GROUP@\n' \
            "${git_hardlinked}" "${gitdir}" >&2
    fi
fi

# SELinux label reset (--unlisted only): a tree that was MOVED rather than copied keeps the
# ai_tools_project_t label it was claimed with. No fcontext rule names the new path, so
# ai-tools-relabel --remove has no rule to remove; a forced restorecon resets the tree to the
# default its location resolves to. Gated on the root actually carrying the label, so a tree
# that never had it is not relabelled as a side effect of unclaiming. Best-effort: a label
# left behind is a defence-in-depth gap, not an access grant -- the DAC reversal above has
# already removed the agent's reach.
if ${UNLISTED} && [[ "$(getenforce 2>/dev/null || echo Disabled)" != "Disabled" ]] \
        && command -v restorecon >/dev/null 2>&1; then
    if [[ "$(stat -c '%C' "${canonical}" 2>/dev/null)" == *:ai_tools_project_t:* ]]; then
        if restorecon -RF -- "${canonical}" 2>/dev/null; then
            ai_tools_log_info "reset SELinux label under ${canonical} (was ai_tools_project_t)"
        else
            ai_tools_log_warn "could not reset the SELinux label under ${canonical}"
            printf 'ai-tools-unclaim: could not reset the SELinux label -- run: sudo restorecon -RF %s\n' \
                "${canonical}" >&2
        fi
    fi
fi

exit 0
