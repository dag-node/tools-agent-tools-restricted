#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/libexec/ai-tools/ai-tools-setgid
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
# Owner-only directories are the exception: the operator sealed them, so they are left out of
# the agent's group, the sandbox residue they carry is stripped, and their subtree is skipped
# with them -- see owner-only.lib.sh, which ai-tools-setfacl/-lockdown/-chown share.
#
# Idempotent: applies only the dirs that need it, safe to run every session start.
#
# Invocation: the handback socket's SETGID verb (ai-tools-handback daemon, root).
#   Not a sudo target -- ai-tools has no sudo rights.
#
# Installed 750 root:root, so only root runs it. Deploying from a checkout:
# docs/install-from-source.md.

set -euo pipefail

# Every disclosure this helper prints goes through warn, so the component prefix is stated once
# here instead of at each site. A leading message code (msg.lib.sh states the form) is printed on
# its own line ahead of the message, the shape tests/lib/harness.sh's assert_msg reads. Matched
# inline, since this helper reports before msg.lib.sh is loaded. Its one refusal exits 3 at its
# own site, so there is no status for a die() to carry.
# The code it printed is left in _warn_code, so a site that also RECORDS the situation passes
# the variable and the code literal stays at the emit call the reference index reads as its
# definition (messaging.rule.md).
_warn_code=""
warn() {
    local IFS=' ' code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    _warn_code="${code}"
    printf 'ai-tools-setgid: %s\n' "$*" >&2
}

readonly TARGET="${1:?usage: ai-tools-setgid <absolute-project-path>}"

# Operator-identity resolver (operator.lib.sh): resolves the operator that owns the project. A
# missing lib leaves ai_tools_resolve_owner a fail-closed stub, so the tree is left untouched.
readonly OPERATOR_LIB="/usr/local/lib/ai-tools/operator.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/operator.lib.sh
source "${OPERATOR_LIB}" 2>/dev/null || ai_tools_resolve_owner() { return 1; }
readonly GROUP="@SANDBOX_GROUP@"
# Two identities may legitimately hold a project tree's dirs: the resolved operator and the sandbox
# account. A directory belonging to a third party (root, another developer) is left untouched --
# normalization must not pull a foreign dir into the agent's group -- and COUNTED, so a walk that
# normalized no directory is reported rather than silent; the project root hitting the guard is called
# out on its own, since it means the whole claim granted no access. Matched by numeric UID;
# PROJECTS_UID is the resolved operator (set by the owner resolution).
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
    ai_tools_log_structured() { :; }; ai_tools_log_coded() { :; }
fi

# Directory-skip selector from the shared library (single source of truth, also used by
# session-hook.sh and ai-tools-lockdown). A missing lib (broken install) leaves a stub that
# descends everywhere -- a slower but correct walk.
readonly SKIP_DIRS_LIB="/usr/local/lib/ai-tools/skip-dirs.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/skip-dirs.lib.sh
source "${SKIP_DIRS_LIB}" 2>/dev/null \
    || ai_tools_skip_find_expr() { AI_TOOLS_SKIP_FIND_EXPR=(); return 0; }

# Secret-name matcher (defense in depth): the walk skips a dir whose basename looks
# like a secret (e.g. .env), so a private dir is not exposed to the agent group when the
# operator did not '!'-exclude it. Best-effort, unlike ai-tools-chown's fail-closed load:
# the '!' exclusions are the authoritative control, so a matcher that will not load leaves
# the exclusions as the only skip instead of stopping the claim.
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

# Which paths the operator sealed, and what may be stripped from one (owner-only.lib.sh, the
# reference for the seal and the strip alike). Required and fail-closed like safe-paths.lib.sh:
# an unusable library must not leave this walk unable to recognize a sealed directory.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/owner-only.lib.sh
source /usr/local/lib/ai-tools/owner-only.lib.sh
if ! declare -F ai_tools_is_owner_only >/dev/null 2>&1 \
        || ! declare -F ai_tools_strip_sandbox_residue >/dev/null 2>&1; then
    # One library, one defect, one remedy, so this refusal shares its code with ai-tools-setfacl
    # and ai-tools-lockdown: it is DEFINED in ai-tools-setfacl and cited here from the format
    # string below, which keeps one situation to one definition (messaging.rule.md's twin rule).
    printf 'MSG-G4P4\nai-tools-setgid: FATAL: owner-only.lib.sh defines no owner-only guard\n' >&2
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
ai_tools_assert_safe_target "${canonical}" "setgid normalization" || exit 3

# Resolve the operator that owns this project (operator.lib.sh); no owner -> exit without acting. The
# owner guard then acts only on dirs the resolved operator or the sandbox account hold.
ai_tools_resolve_owner "${canonical}" || exit 0
readonly ALLOWLIST="${AI_TOOLS_RESOLVED_ALLOWLIST}" PROJECTS_UID

# This run normalizes one project for one operator, so the operator and the project
# ride as per-run log context (logging.rule.md).
AI_TOOLS_LOG_OPERATOR="${PROJECTS_USER}"
AI_TOOLS_LOG_PROJECT="${canonical}"

# Shared config grammar (ai_tools_conf_path_entry; see conf.lib.sh), the ONE parser the
# allowlist is read with -- end-of-line comments, and quotes for a path carrying a space or a
# literal '#'. REQUIRED like safe-paths.lib.sh: the bare source under set -e aborts if it is
# missing, rather than leaving a bare filter that would mis-read an entry ai-tools-chown reads
# correctly, so a path this walk skips is one the handback still acts on. Include-guarded.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/conf.lib.sh
source /usr/local/lib/ai-tools/conf.lib.sh

declare -a allowed=()
declare -a excluded=()
while IFS= read -r entry || [[ -n "${entry}" ]]; do
    # One shared grammar (conf.lib.sh): whole-line and end-of-line comments, and quotes for a
    # path carrying a space or a literal '#'. A line that does not denote an entry is skipped.
    ai_tools_conf_path_entry "${entry}" || continue
    entry="${_ai_tools_conf_value}"
    if [[ "${entry}" == '!'* ]]; then
        excluded+=("${entry:1}")              # strip leading !, keep raw (may glob)
    else
        dir="$(realpath -e "${entry}" 2>/dev/null)" || continue
        allowed+=("${dir}")
    fi
done < "${ALLOWLIST}"

# _is_excluded <abs-path>: 0 if covered by a '!' rule. A plain path also covers its
# contents; a glob matches as-is. Same semantics as ai-tools-chown / ai-tools-lockdown,
# which read the allowlist through the same conf.lib.sh grammar.
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
    # eligible (re-verified TOCTOU-safe on the pinned inode); skip anything else.
    # Return 3, not 1, so the walk can tell a third-party owner from a stat failure and
    # report it. Without that split, a walk whose every directory was foreign-owned reports the
    # same as one that had no directory to touch.
    [[ "${owner_uid}" == "${PROJECTS_UID}" || "${owner_uid}" == "${SANDBOX_UID}" ]] || return 3
    # No work to do when already group GROUP and already setgid -- unless the dir is owner-only,
    # where that state is inherited residue the pinned-fd path strips.
    if [[ "${grp}" == "${GROUP}" ]] && (( (0${mode} & 02000) != 0 )) \
            && ! ai_tools_is_owner_only "${mode}"; then
        return 0
    fi

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
    # or the sandbox account's own dirs are eligible; anything else is left untouched
    # and reported (3, as for a refused path).
    if [[ "${got_uid}" != "${PROJECTS_UID}" && "${got_uid}" != "${SANDBOX_UID}" ]]; then
        exec {fd}<&-
        return 3
    fi
    # Group and mode come from the pinned inode, so the seal decision and the strip act on the
    # same directory the mutation would. A sealed dir is left out of the agent's group and its
    # residue stripped (owner-only.lib.sh); returning 2 tells the walk to skip its subtree too.
    local got_grp got_mode
    read -r got_grp got_mode \
        < <(stat -L -c '%G %a' "/proc/self/fd/${fd}" 2>/dev/null) \
        || { exec {fd}<&-; return 1; }
    if ai_tools_is_owner_only "${got_mode}"; then
        if ai_tools_strip_sandbox_residue "${fd}" directory "${got_grp}" "${got_mode}" \
                "${PROJECTS_GROUP:-}"; then
            ai_tools_log_structured info \
                "sealed ${dir} (owner-only; stripped ${AI_TOOLS_RESIDUE_ACTIONS[*]})" \
                "AI_TOOLS_PATH=${dir}"
        fi
        exec {fd}<&-
        return 2
    fi
    local regrouped=0
    [[ "${grp}" != "${GROUP}" ]] && { chgrp -- "${GROUP}" "/proc/self/fd/${fd}"; regrouped=1; }
    chmod -- g+s "/proc/self/fd/${fd}"
    exec {fd}<&-
    # Record the change (the early return stays silent for a no-op dir).
    if (( regrouped )); then
        ai_tools_log_structured info "normalized ${dir} (group ${grp} -> ${GROUP}, +setgid)" \
            "AI_TOOLS_PATH=${dir}"
    else
        ai_tools_log_structured info "normalized ${dir} (+setgid)" "AI_TOOLS_PATH=${dir}"
    fi
    return 0
}

# Walk the project's directories (skipping heavy trees, one filesystem) and
# normalize each. find emits a dir before its contents (pre-order), so when a dir
# is '!'-excluded or secret-named we record it as a skip-prefix and skip its whole
# subtree -- never flipping the group anywhere under a private/secret dir.
ai_tools_skip_find_expr setgid '' "${canonical}"
declare -a expr=( "${canonical}" -xdev "${AI_TOOLS_SKIP_FIND_EXPR[@]}" -type d -print0 )

find "${expr[@]}" 2>/dev/null \
    | { declare -a skip=()
        _under_skip() { local p; for p in "${skip[@]:-}"; do
            [[ -n "${p}" && ( "$1" == "${p}" || "$1" == "${p}/"* ) ]] && return 0; done; return 1; }
        declare -i sealed=0 foreign=0 thirdparty=0 rc=0
        declare root_thirdparty=false
        while IFS= read -r -d '' d; do
            _under_skip "${d}" && continue
            if _is_excluded "${d}" || _is_secret_name "${d}"; then
                skip+=("${d}"); continue
            fi
            rc=0; _safe_setgid "${d}" || rc=$?
            if (( rc == 2 )); then
                sealed=$(( sealed + 1 ))
                skip+=("${d}")          # a sealed dir takes its subtree with it
                if (( ${AI_TOOLS_RESIDUE_SURFACE:-0} )); then foreign=$(( foreign + 1 )); fi
            elif (( rc == 3 )); then
                thirdparty=$(( thirdparty + 1 ))
                # The project ROOT is the case that decides whether the claim did anything at
                # all: every directory under it inherits neither, so the agent cannot enter the
                # tree. Called out separately from the count for that reason.
                [[ "${d}" == "${canonical}" ]] && root_thirdparty=true
            fi
        done
        # The counts are local to this subshell (pipe); report them here.
        if (( sealed )); then
            ai_tools_log_structured info \
                "left ${sealed} owner-only path(s) under ${canonical} out of the agent's reach"
        fi
        # Surfaced, never silent: the owner guard is the one skip that can leave a claim having
        # granted NO ACCESS AT ALL while every other step succeeds -- an operator-owned tree claimed for a
        # different operator hits it on every directory. A count on stderr is what turns that from
        # an invisible no-op into something the claim can report.
        if (( thirdparty )); then
            if ${root_thirdparty}; then
                warn MSG-V6Q7 "the project directory itself is owned by neither ${PROJECTS_USER} nor @SANDBOX_USER@ -- nothing was normalized, and the agent gets no access to this tree"
            else
                warn MSG-B9V2 "left ${thirdparty} director(ies) owned by neither ${PROJECTS_USER} nor @SANDBOX_USER@ untouched -- the agent gets no access to them"
            fi
            # The record carries the code the operator was shown, so a query selects
            # the situation by its code while the count and the path stay in the text.
            ai_tools_log_coded warning "${_warn_code}" \
                "left ${thirdparty} director(ies) under ${canonical} untouched: owned by neither ${PROJECTS_USER} nor @SANDBOX_USER@"
        fi
        # Surfaced, never silent: a setgid the operator may have set on purpose is the one piece
        # of residue this walk declines to remove, so the operator has to hear that it stayed.
        if (( foreign )); then
            warn MSG-Z3B9 "kept the setgid bit on ${foreign} owner-only director(ies) grouped to a third party -- clear it yourself with: chmod g-s <dir>"
            ai_tools_log_coded warning "${_warn_code}" \
                "left a third-party setgid bit on ${foreign} owner-only path(s) under ${canonical}"
        fi
      } || true

exit 0
