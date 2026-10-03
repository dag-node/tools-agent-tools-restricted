#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/libexec/ai-tools/ai-tools-lockdown
# Revokes ai-tools' read access to credential files under the CURRENT project ahead of a session. Walks the working
# directory and, for every path whose basename matches a secret pattern -- the set ai-tools-chown uses, from the shared
# library and the operator's config file -- applies:
#       regular file -> 600        directory -> 700        owner -> <you>:<you>
# and strips the path's sandbox residue (owner-only.lib.sh). A second pass strips the same residue from every path
# already owner-only under the target, whatever its name, without a confirmation, since it removes the sandbox's reach
# alone; the target itself is left out (the enumeration states why). Why the owner's private group is the target,
# and how this sweep relates to ai-tools-chown's per-write quarantine, are secret-handling.rule.md's.
#
# Run by YOU, as root via sudo, from inside an allowed project (usage() states the options); a '!'-excluded CWD is
# refused. A declined confirmation exits 6, so a caller tells a decline from a lockdown that ran. `--gate` is
# the claim's and the clone's secret gate in one call -- the CLI's calling contract, so not in usage(): one sudo,
# so a host whose sudo asks for the password on every invocation asks once. It lists each path relative to the project,
# asks with a default of yes (the answer without a terminal), summarizes the lock in one line, and writes every
# secret-matching path NUL-terminated to stdout, which does not carry any other byte.
#
# The walk does not take a skip list: a secret under a heavy tree such as `node_modules` is reached through the project
# root's traversal, the tree's own world bits and the recursive relabel, which the claim's walks skipping that tree do
# not close, and the clone's normalize opens the tree outright. Under `.git` it prunes `objects`, `refs` and `logs`
# alone -- the subtrees git names itself, an object by its hash and a ref and its reflog by the branch name, so no
# secret-named file lands there by an operator's choice, and a ref locked owner-only would refuse git to the agent --
# and walks `hooks`, `info` and the rest, where a template or a resumed clone puts an operator-written file
# (`hooks/deploy.pem`). The set is fixed here rather than read from skip-dirs.lib.sh, whose categories an operator edits
# in operator.conf: it is a coverage decision, and a name added to a category there would reopen the gap. The per-path
# match runs in this shell without a subprocess, which keeps a walk over such a tree to seconds.
#
# Installed 750 root:root. Its domain rule is secret-handling.rule.md.

set -euo pipefail

readonly SECRET_PATTERNS_LIB="/usr/local/lib/ai-tools/secret-patterns.lib.sh"

log()  { printf 'ai-tools-lockdown: %s\n' "$*"; }
# A leading message code (msg.lib.sh states the form) is printed on its own line ahead of the message, the shape
# tests/lib/harness.sh's assert_msg reads. Matched inline, since these helpers report before the library is loaded.
# The code warn printed is left in _warn_code, for a site that also records the situation through log.lib.sh: the log
# call passes the variable, so the code literal stays at the emit call the reference index reads as its definition
# (messaging.rule.md).
_warn_code=""
warn() {
    local code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    _warn_code="${code}"
    printf 'ai-tools-lockdown: warn: %s\n' "$*" >&2
}
die() {
    local code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    printf 'ai-tools-lockdown: error: %s\n' "$*" >&2; exit 1
}
# die_usage: die's form for a command line the helper refuses to run, with the usage status 2.
die_usage() {
    local code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    printf 'ai-tools-lockdown: error: %s\n' "$*" >&2; exit 2
}

# Operator-identity resolver (operator.lib.sh): secrets are locked to the operator that owns the current directory.
# A missing lib leaves ai_tools_resolve_owner a fail-closed stub, so the resolve resolution dies rather than lock
# secrets to the wrong identity.
readonly OPERATOR_LIB="/usr/local/lib/ai-tools/operator.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/operator.lib.sh
source "${OPERATOR_LIB}" 2>/dev/null || ai_tools_resolve_owner() { return 1; }

# Shared leveled logger: journald (always) + the root-only file /var/log/ai-tools/lockdown.log. Best-effort -- a no-op
# fallback keeps the helper working if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-lockdown"
AI_TOOLS_LOG_FILE="lockdown.log"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/log.lib.sh
# Required, fail-closed: this helper prints agent-named paths to stderr and the log, so it needs ai_tools_log_sanitize
# -- a missing logger must refuse, not emit an agent path raw.
if ! source "${LOG_LIB}"; then
    die MSG-F6D9 "cannot source ${LOG_LIB}"
fi

# Which paths the operator sealed, and what may be stripped from one (owner-only.lib.sh, the reference for the seal
# and the strip alike). Required and fail-closed like safe-paths.lib.sh: an unusable library must not leave a locked
# path carrying the residue that would re-expose it.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/owner-only.lib.sh
source /usr/local/lib/ai-tools/owner-only.lib.sh
if ! declare -F ai_tools_is_owner_only >/dev/null 2>&1 \
        || ! declare -F ai_tools_strip_sandbox_residue >/dev/null 2>&1; then
    # One library, one defect, one remedy, so this refusal shares its code with ai-tools-setfacl and ai-tools-setgid: it
    # is DEFINED in ai-tools-setfacl and cited here from the format string below, which keeps one situation to one
    # definition (messaging.rule.md's twin rule).
    printf 'MSG-G4P4\nai-tools-lockdown: FATAL: owner-only.lib.sh defines no owner-only guard\n' >&2
    exit 3
fi

# Protected-paths backstop (safe-paths.lib.sh): refuse to act on a system directory even when the allowlist includes it.
# See safe-paths.rule.md.
readonly SAFE_PATHS_LIB="/usr/local/lib/ai-tools/safe-paths.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/safe-paths.lib.sh
source "${SAFE_PATHS_LIB}"

# Shared yes/no prompt (ai_tools_msg_confirm; see msg.lib.sh). REQUIRED like safe-paths.lib.sh: the bare source
# under `set -e` aborts if it is missing -- a valid install ships it, so there is no fallback. Include-guarded, so this
# is a no-op when safe-paths.lib.sh already loaded it.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/msg.lib.sh
source /usr/local/lib/ai-tools/msg.lib.sh
# Fixed 80-column frame for any box this helper renders, aligned with the CLI's.
export AI_TOOLS_MSG_FULLWIDTH=1

usage() {
    cat >&2 <<'EOF'
usage: cd <project> && sudo ai-tools-lockdown [options]

  --dry-run       list paths that would be locked down; make no changes
  -y, --yes       apply without the interactive confirmation prompt
  -h, --help      show this help

Locks down secret-matching paths under the current directory:
  files -> 600, directories -> 700, owner <you>:<you>.
Runs only when the current directory is an allowed project.
Exits 6 when you decline the confirmation; no path is changed.
EOF
}

# ── Argument parsing ─────────────────────────────────────────────────────────
DRY_RUN=false
ASSUME_YES=false
GATE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=true ;;
        -y|--yes)     ASSUME_YES=true ;;
        --gate)       GATE=true ;;
        -h|--help)    usage; exit 0 ;;
        *)            usage; die MSG-G2T3 "unknown argument: $1" ;;
    esac
    shift
done
# A combination the run cannot honour is refused with the usage status before any scan, whether or not the option is one
# usage() lists. A dry run neither changes a path nor asks, so `--yes` beside it does not answer any question; the CLI's
# projects lockdown refuses the same line first, before its sudo, and defines the code this cites.
if ${DRY_RUN} && ${ASSUME_YES}; then
    printf 'MSG-P5P8\nai-tools-lockdown: error: --yes has no effect with --dry-run, which neither changes a path nor asks\n' >&2
    exit 2
fi
# `--gate` writes the found paths for its caller to read back as the result of a lock, and a dry run exits 0 without
# locking, so the pair would report a lock that did not happen.
if ${GATE} && ${DRY_RUN}; then
    die_usage MSG-G8S6 "--gate and --dry-run do not combine -- --gate locks what it lists"
fi

# Under `--gate` stdout carries the secret-matching paths alone, NUL-terminated, on descriptor 3; every line this helper
# prints for a person goes to stderr, so no report line can be read back as a path.
if ${GATE}; then exec 3>&1 1>&2; fi

# ── Guards ───────────────────────────────────────────────────────────────────
[[ "${EUID}" -eq 0 ]] || die MSG-E9A3 "run with sudo"
# The invoker (who ran sudo) must not be the agent; the OWNER files are handed back to comes from the enrolled operator
# identity, not the invoker, so a foreign sudo invocation still restores ownership to the configured operator rather
# than to itself.
readonly INVOKER="${SUDO_USER:?run via sudo (SUDO_USER unset)}"
[[ "${INVOKER}" != "@SANDBOX_USER@" ]] || die MSG-M8A8 "must be run by you, not ai-tools"

# Resolve the invoking shell's working directory (sudo preserves it).
target="$(pwd -P)" || die MSG-V7Y3 "cannot determine current directory"
target="$(realpath -e "${target}" 2>/dev/null)" || die MSG-D5F4 "cannot resolve ${target}"
# Refuse the whole pass if the working directory is a protected system directory.
ai_tools_assert_safe_target "${target}" "lockdown" || exit 3

# Resolve the operator that owns this directory; secrets are locked to it. lockdown runs only inside an allowed project,
# so the directory must resolve to an operator.
ai_tools_resolve_owner "${target}" \
    || die MSG-K8Z6 "this directory is not in allowed projects for current operator: ${target}"
readonly ALLOWLIST="${AI_TOOLS_RESOLVED_ALLOWLIST}"
readonly OWNER="${PROJECTS_USER}:${PROJECTS_GROUP}"

# This run locks one project down for one operator, so the operator and the project ride as per-run log context
# (logging.rule.md).
AI_TOOLS_LOG_OPERATOR="${PROJECTS_USER}"
AI_TOOLS_LOG_PROJECT="${target}"
# Two identities may legitimately hold a path in a claimed tree: the resolved operator and the sandbox account. The seal
# pass acts on those only, as every other walk does -- a path held by a third party (root, another developer) is left
# untouched.
SANDBOX_UID="$(id -u "@SANDBOX_USER@" 2>/dev/null || echo -1)"
readonly SANDBOX_UID

# Shared config grammar (ai_tools_conf_path_entry; see conf.lib.sh), the ONE parser the allowlist is read with --
# end-of-line comments, and quotes for a path carrying a space or a literal '#'. REQUIRED like safe-paths.lib.sh:
# the bare source under `set -e` aborts if it is missing, rather than leaving a bare filter that would mis-read an entry
# ai-tools-chown reads correctly, so a path this walk skips is one the handback still acts on. Include-guarded.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/conf.lib.sh
source /usr/local/lib/ai-tools/conf.lib.sh

# ── Allowlist (allow + ! exclude), the read every helper and the launch gate make ──────────────
declare -a allowed=()
# shellcheck disable=SC2034  # filled and read through its name by the conf.lib.sh loader and matcher
declare -a excluded=()
# One shared read (conf.lib.sh): allow entries resolved; exclusions as written and, through symlinks the operator
# or root owns, resolved beside them. A file that cannot be read leaves both arrays empty, so the target is not allowed.
ai_tools_conf_allowlist_load "${ALLOWLIST}" allowed excluded || true

# _is_excluded <abs-path>: 0 if the path is covered by a '!' rule (ai_tools_conf_path_excluded, conf.lib.sh -- the match
# every reader of the allowlist makes).
_is_excluded() { ai_tools_conf_path_excluded "$1" excluded; }

# _is_allowed <abs-path>: 0 if the path is at or under an allowed directory.
_is_allowed() {
    local path="$1" d
    [[ "${#allowed[@]}" -gt 0 ]] || return 1
    for d in "${allowed[@]}"; do
        [[ "${path}" == "${d}" || "${path}" == "${d}/"* ]] && return 0
    done
    return 1
}

_is_allowed  "${target}" || die MSG-V7Y7 "not an allowed project: ${target} (see ${ALLOWLIST})"
_is_excluded "${target}" && die MSG-J3F9 "excluded in the allowlist: ${target}; nothing to do"

# ── Shared secret matcher ────────────────────────────────────────────────────
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/secret-patterns.lib.sh
if ! source "${SECRET_PATTERNS_LIB}"; then
    die MSG-Q7C6 "cannot source ${SECRET_PATTERNS_LIB}"
fi
# Read after the operator is bound, which names the file. A present file the loader returns 1 for refuses the run:
# a sweep on the baseline would skip the names that operator wrote, and a `--gate` caller reads exit 0 as every secret
# locked (secret-handling.rule.md).
ai_tools_load_secret_patterns || die "the operator's secret-patterns file could not be read, so no path was scanned or locked"

# _scan <list-file> <find-arg...>: run find into <list-file> with its stderr apart, and die when find does not exit 0
# or writes to stderr. A walk that could not read part of the tree has not found every secret in it, and a scan read
# as complete when it was not is how a caller would expose one.
SCAN_DIR="$(mktemp -d)" || die MSG-U8F7 "cannot create a private directory for the scan"
trap 'rm -rf "${SCAN_DIR}"' EXIT
_scan() {
    local list="$1" rc=0; shift
    find "$@" > "${list}" 2> "${SCAN_DIR}/find.err" || rc=$?
    if (( rc != 0 )) || [[ -s "${SCAN_DIR}/find.err" ]]; then
        die MSG-X4B9 "the scan of ${target} could not read the whole tree (find exit ${rc}): $(ai_tools_log_sanitize "$(head -c 300 "${SCAN_DIR}/find.err")")"
    fi
}

# ── Enumerate secret-matching paths under the target ─────────────────────────
# `find -P` (the default) does not follow a symlink, and `-type f`/`-type d` exclude one anyway. Both walks prune
# the three `.git` subtrees the header names, at any depth, so a nested repository's are pruned the same way.
declare -a git_prune=( '(' -type d '(' -path '*/.git/objects' -o -path '*/.git/refs' -o -path '*/.git/logs' ')' ')' \
                       -prune -o )
declare -a expr=( "${target}" -xdev "${git_prune[@]}" '(' -type f -o -type d ')' -print0 )

declare -a hits=()
_scan "${SCAN_DIR}/hits" "${expr[@]}"
while IFS= read -r -d '' path; do
    _is_excluded "${path}" && continue
    ai_tools_is_secret_basename "${path##*/}" || continue
    hits+=("${path}")
done < "${SCAN_DIR}/hits"

# ── Enumerate owner-only paths to seal ───────────────────────────────────────
# The lock pass finds paths by NAME. This one finds the paths sealed by MODE -- anything already owner-only that still
# carries the group, setgid bit or ACL entries it inherited when it was created inside the claimed tree. Stripping those
# is what makes such a seal survive a later chmod; owner-only.lib.sh is the reference for what comes off.
#
# `! -perm /077` selects "no group and no other bit set", the owner-only predicate, in the kernel -- so the filter
# avoids a stat per path. A sealed DIRECTORY is printed and then pruned, taking its subtree with it exactly
# as `ai-tools-{setgid,setfacl}` do: the sandbox account cannot enter it, so no path inside is reachable through it.
# Secret-named paths are left to the lock pass, which seals them itself.
#
# The target itself is left out of the list. The seal exists for a private path inside a shared tree, and the walk's
# root is the registered project directory, whose reachability is the claim's own question. `ai-tools projects clone`
# runs its `git clone` under a pinned `umask 077`, so a clone reaches the secret gate owner-only throughout and grouped
# to the sandbox account by the setgid clone area; with the root on the list, a first run on a tip commit holding
# a secret would seal the root alone -- clearing its setgid bit and moving its group to the operator's own --
# and normalize_clone, which restores the mode bits and not the group, would leave the agent refused at the root
# of a clone reported ready. An owner-only root is still pruned, so the paths under it are sealed on a later run once
# the root is open. `-mindepth 1` is not this: it would stop the prune at the root and descend into such a clone,
# where every depth-one entry is owner-only for the same reason and in the sandbox group by setgid inheritance,
# and the pass would move all of them to the operator's group.
declare -a sealed=()
_scan "${SCAN_DIR}/sealed" "${target}" -xdev "${git_prune[@]}" \
    '(' -type d ! -perm /077 -print0 -prune ')' -o '(' -type f ! -perm /077 -print0 ')'
while IFS= read -r -d '' path; do
    [[ "${path}" == "${target}" ]] && continue
    _is_excluded "${path}" && continue
    ai_tools_is_secret_basename "${path##*/}" && continue
    sealed+=("${path}")
done < "${SCAN_DIR}/sealed"

if ${DRY_RUN}; then scan_mode=" (dry-run)"; else scan_mode=""; fi

if [[ "${#hits[@]}" -eq 0 && "${#sealed[@]}" -eq 0 ]]; then
    ${GATE} || log "no secret-matching paths, and no owner-only paths to seal, under ${target}"
    ai_tools_log_info "scan${scan_mode}: nothing to do under ${target}"
    exit 0
fi

# ── Report, confirm, apply ───────────────────────────────────────────────────
# Log the detection (count + each path) regardless of dry-run vs apply: this is the audit record of what the scan SAW.
# The later per-path "locked" entries from _safe_apply record what was DONE -- distinct events, intentionally both
# logged.
# Under `--gate` the claim's page has already named the project, so each path is shown relative to it and indented
# under the claim's block, and the paths go to stdout NUL-terminated for the caller to exclude from what it opens;
# the result after the question is then one line, plus a line for each path that did not take its mode.
if (( ${#hits[@]} )); then
    if ${GATE}; then
        printf '  found %d secret-matching path(s):\n' "${#hits[@]}" >&2
    else
        printf 'ai-tools-lockdown: %d secret-matching path(s) under %s:\n' \
            "${#hits[@]}" "${target}" >&2
    fi
    ai_tools_log_info "scan${scan_mode}: ${#hits[@]} secret-matching path(s) under ${target}"
    for path in "${hits[@]}"; do
        shown="${path}"
        if ${GATE}; then shown="${path#"${target}"/}"; fi
        if [[ -d "${path}" ]]; then
            printf '  [dir]  %s\n' "$(ai_tools_log_sanitize "${shown}")" >&2
        else
            printf '  [file] %s\n' "$(ai_tools_log_sanitize "${shown}")" >&2
        fi
        if ${GATE}; then printf '%s\0' "${path}" >&3; fi
        ai_tools_log_info "scan: secret-matching ${path}"
    done
fi
if (( ${#sealed[@]} )); then
    ai_tools_log_info "scan${scan_mode}: ${#sealed[@]} owner-only path(s) under ${target}"
fi

# A preview must not ask to apply: the confirm sits after the dry-run branch, which exits first.
#
# _safe_apply <path>: chmod (file 600 / dir 700) and chown to OWNER through a pinned fd, so a symlink/path swap
# by ai-tools (a group-writer on the project dir) cannot redirect root's chmod/chown onto an arbitrary file. lstat
# the path, require a regular file (nlink 1, never a hardlink to a sensitive file elsewhere) or a directory, open it,
# then re-verify the fd resolves to the same inode and type, at <path> (ai_tools_pinned_fd_at_path, safe-paths.lib.sh),
# before acting via /proc/self/fd. Mirrors ai-tools-chown's TOCTOU-safe apply.
_safe_apply() {
    local path="$1" expect_ident nlink ftype is_dir mode fd got_ident got_nlink got_ftype
    read -r expect_ident nlink ftype \
        < <(stat -c '%d:%i %h %F' "${path}" 2>/dev/null) || return 1
    case "${ftype}" in
        "regular file"|"regular empty file")
            is_dir=false; mode=600
            [[ "${nlink}" -eq 1 ]] || { warn MSG-T5Y3 "skip (hardlinked, nlink=${nlink}): ${path}"; return 1; }
            ;;
        "directory") is_dir=true; mode=700 ;;
        *)           return 1 ;;
    esac

    # NB: brace-group the redirection so 2>/dev/null scopes to the open only, not the shell (a bare
    # `exec {fd}< file 2>/dev/null` redirects fd2 permanently).
    { exec {fd}< "${path}"; } 2>/dev/null || return 1
    read -r got_ident got_nlink got_ftype \
        < <(stat -L -c '%d:%i %h %F' "/proc/self/fd/${fd}" 2>/dev/null) \
        || { exec {fd}<&-; return 1; }
    case "${got_ftype}" in
        "regular file"|"regular empty file") ${is_dir} && { exec {fd}<&-; return 1; } ;;
        "directory")                         ${is_dir} || { exec {fd}<&-; return 1; } ;;
        *)                                   exec {fd}<&-; return 1 ;;
    esac
    if [[ "${got_ident}" != "${expect_ident}" ]] \
       || { ! ${is_dir} && [[ "${got_nlink}" -ne 1 ]]; }; then
        exec {fd}<&-
        return 1
    fi
    ai_tools_pinned_fd_at_path "${fd}" "${path}" || { exec {fd}<&-; return 1; }
    # Each call's status is read, and the result is read back from the pinned inode: the caller runs this inside
    # an `if`, where errexit does not apply, so a failed chown or chmod would otherwise report the path as locked.
    local now_uid now_perm
    if ! /usr/bin/chown -- "${OWNER}" "/proc/self/fd/${fd}" || ! /usr/bin/chmod -- "${mode}" "/proc/self/fd/${fd}" \
            || ! read -r now_uid now_perm < <(stat -L -c '%u %a' "/proc/self/fd/${fd}" 2>/dev/null) \
            || [[ "${now_uid}" != "${PROJECTS_UID}" ]] || (( (8#${now_perm} & 8#777) != 8#${mode} )); then
        exec {fd}<&-
        warn MSG-Y5H5 "could not lock ${path} to ${OWNER} ${mode}"
        return 1
    fi
    # The path is owner-only now, so strip the residue the mode merely masks -- the inherited ACL entries
    # and, on a directory, the setgid bit the numeric chmod leaves standing. Re-read both from the pinned inode: they
    # are what the chown/chmod just made them.
    local now_grp now_mode
    if read -r now_grp now_mode \
            < <(stat -L -c '%G %a' "/proc/self/fd/${fd}" 2>/dev/null); then
        ai_tools_strip_sandbox_residue "${fd}" "${got_ftype}" "${now_grp}" "${now_mode}" \
            "${PROJECTS_GROUP}" || true
    fi
    exec {fd}<&-
    ai_tools_log_structured info "locked ${path} -> ${OWNER} ${mode}" \
        "AI_TOOLS_PATH=${path}" "AI_TOOLS_RESULT=ok"
    if ${GATE}; then
        if ${is_dir}; then locked_dirs=$(( locked_dirs + 1 )); else locked_files=$(( locked_files + 1 )); fi
    else
        printf '  locked %s  ->  %s %s\n' "$(ai_tools_log_sanitize "${path}")" "${OWNER}" "${mode}" >&2
    fi
    return 0
}

# _safe_seal <path>: strip the sandbox residue from an already-owner-only path, through a pinned fd like _safe_apply. It
# leaves mode bits and ownership as they are, removing only what the sandbox put there (owner-only.lib.sh). Returns 0
# when something was stripped, 1 when the path does not carry any residue, or is out of scope. Sets
# AI_TOOLS_RESIDUE_SURFACE for the caller (a third-party setgid it declined to clear), and AI_TOOLS_RESIDUE_ACTIONS
# to what came off. Under `--dry-run` the strip reports instead of acting (AI_TOOLS_RESIDUE_DRY_RUN) and every gate here
# still runs; secret-handling.rule.md has why.
_safe_seal() {
    local path="$1" expect_ident fd got_ident got_uid got_grp got_mode got_ftype rc
    # Clear it here, not only in the strip: every return that precedes the strip is an early one, and a stale value
    # from the previous path would be counted against this one.
    AI_TOOLS_RESIDUE_SURFACE=0
    expect_ident="$(stat -c '%d:%i' "${path}" 2>/dev/null)" || return 1
    { exec {fd}< "${path}"; } 2>/dev/null || return 1
    # %F ("regular empty file") is multi-word, so it stays the last field.
    read -r got_ident got_uid got_grp got_mode got_ftype \
        < <(stat -L -c '%d:%i %u %G %a %F' "/proc/self/fd/${fd}" 2>/dev/null) \
        || { exec {fd}<&-; return 1; }
    if [[ "${got_ident}" != "${expect_ident}" ]]; then exec {fd}<&-; return 1; fi
    ai_tools_pinned_fd_at_path "${fd}" "${path}" || { exec {fd}<&-; return 1; }
    # Owner guard, on the pinned inode: only the operator's own or the sandbox account's paths.
    if [[ "${got_uid}" != "${PROJECTS_UID}" && "${got_uid}" != "${SANDBOX_UID}" ]]; then
        exec {fd}<&-; return 1
    fi
    case "${got_ftype}" in
        directory|"regular file"|"regular empty file") ;;
        *) exec {fd}<&-; return 1 ;;            # never touch symlinks/fifos/devices
    esac
    # Re-check the mode on the pinned inode: find matched the path, this matches the inode.
    if ! ai_tools_is_owner_only "${got_mode}"; then exec {fd}<&-; return 1; fi
    rc=1
    ai_tools_strip_sandbox_residue "${fd}" "${got_ftype}" "${got_grp}" "${got_mode}" \
        "${PROJECTS_GROUP}" && rc=0
    exec {fd}<&-
    if (( rc == 0 )) && ! ${DRY_RUN}; then
        ai_tools_log_structured info \
            "sealed ${path} (owner-only; stripped ${AI_TOOLS_RESIDUE_ACTIONS[*]})" \
            "AI_TOOLS_PATH=${path}" "AI_TOOLS_RESULT=ok"
    fi
    return "${rc}"
}

# _seal_pass: run _safe_seal over every enumerated owner-only path and report. One pass serves the preview and the apply
# alike, which is what keeps a preview describing the run that follows it (secret-handling.rule.md). Under `--dry-run`
# each hit names its path AND what it carries, since a count alone is not something an operator can check
# before answering.
_seal_pass() {
    declare -i seal_count=0 foreign=0
    local path
    for path in "${sealed[@]}"; do
        if _safe_seal "${path}"; then
            seal_count=$(( seal_count + 1 ))
            ${DRY_RUN} && printf '  [seal] %s  ->  drop %s\n' \
                "$(ai_tools_log_sanitize "${path}")" "${AI_TOOLS_RESIDUE_ACTIONS[*]}" >&2
        fi
        if (( ${AI_TOOLS_RESIDUE_SURFACE:-0} )); then foreign=$(( foreign + 1 )); fi
    done

    if (( seal_count > 0 )); then
        if ${DRY_RUN}; then
            ai_tools_log_info "dry-run: ${seal_count} owner-only path(s) under ${target} carry sandbox residue"
            log "${seal_count} of ${#sealed[@]} owner-only path(s) carry sandbox residue (listed above)"
        else
            ai_tools_log_structured info \
                "sealed ${seal_count} owner-only path(s) under ${target}" "AI_TOOLS_RESULT=ok"
            log "sealed ${seal_count} owner-only path(s) (sandbox group, setgid and ACL entries removed)"
        fi
    elif (( ${#sealed[@]} )) && ${DRY_RUN}; then
        log "${#sealed[@]} owner-only path(s) checked; none carries sandbox residue"
    fi
    # Surfaced, never silent: the one piece of residue the pass declines to remove, since it cannot ask whether
    # the operator meant it.
    if (( foreign > 0 )); then
        warn MSG-J8H9 "kept the setgid bit on ${foreign} owner-only director(ies) grouped to a third party -- clear it yourself with: chmod g-s <dir>"
        ai_tools_log_coded warning "${_warn_code}" \
            "left a third-party setgid bit on ${foreign} owner-only path(s) under ${target}"
    fi
}

# A dry run stops here, after previewing the seal pass an apply would also run: a preview must cover both passes,
# which is why this branch runs the seal before exiting.
if ${DRY_RUN}; then
    if (( ${#sealed[@]} )); then
        printf 'ai-tools-lockdown: %d owner-only path(s) under %s, checked for sandbox residue:\n' \
            "${#sealed[@]}" "${target}" >&2
        AI_TOOLS_RESIDUE_DRY_RUN=1
        _seal_pass
    fi
    log "dry-run: no changes made"
    ai_tools_log_info "dry-run: detection only, no changes under ${target}"
    exit 0
fi

# Only the secret lock asks, because it changes ownership and modes the operator did not choose. The seal pass runs
# unprompted on the terms the header states. A decline exits 6, the code ai-tools(1) reserves for an operator's explicit
# decline, spelled here rather than read from a library, so a caller tells a decline from a lockdown that ran.
# Under `--gate` the question defaults to yes and takes that default without a terminal, as the claim's gate always has:
# locking is the direction that gives the agent less, and the gate stops the claim otherwise.
if (( ${#hits[@]} )) && ! ${ASSUME_YES}; then
    if ${GATE}; then
        printf '  best effort: only names matching the secret patterns are found --\n' >&2
        printf '  lock any other secret yourself first\n' >&2
        ai_tools_msg_confirm "Lock down these secrets now?" y \
            || { ai_tools_log_info "lockdown of ${target} declined"; exit 6; }
    elif [[ -t 0 ]] || { [[ -c /dev/tty ]] && { : < /dev/tty; } 2>/dev/null; }; then
        ai_tools_msg_confirm \
            "Set files 600 / dirs 700, chown ${OWNER}, revoking ai-tools access?" n \
            || { log "declined; no changes made"; ai_tools_log_info "lockdown of ${target} declined"; exit 6; }
    else
        die MSG-G3R5 "no TTY for confirmation; re-run with --yes to apply non-interactively"
    fi
fi

declare -i done_count=0 skip_count=0 locked_dirs=0 locked_files=0
declare -a not_locked=()
for path in "${hits[@]}"; do
    if _safe_apply "${path}"; then
        done_count=$(( done_count + 1 ))
    else
        skip_count=$(( skip_count + 1 ))
        not_locked+=("${path}")
    fi
done
if ${GATE} && (( ${#hits[@]} )); then
    printf '  locked %d path(s): %d director(ies) 700, %d file(s) 600, owner %s\n' \
        "${done_count}" "${locked_dirs}" "${locked_files}" "${OWNER}" >&2
fi
for path in "${not_locked[@]}"; do
    shown="${path}"
    if ${GATE}; then shown="${path#"${target}"/}"; fi
    printf '  not locked: %s\n' "$(ai_tools_log_sanitize "${shown}")" >&2
done

if (( ${#hits[@]} )); then
    if (( skip_count > 0 )); then
        ai_tools_log_structured warning \
            "lockdown of ${target}: locked ${done_count} path(s), skipped ${skip_count}" \
            "AI_TOOLS_RESULT=failed"
        ${GATE} || log "locked ${done_count} path(s); skipped ${skip_count} (see warnings above)"
    else
        ai_tools_log_structured info "lockdown of ${target}: locked ${done_count} path(s)" \
            "AI_TOOLS_RESULT=ok"
        ${GATE} || log "locked ${done_count} path(s)"
    fi
fi

# ── Seal pass ────────────────────────────────────────────────────────────────
_seal_pass

# A secret-matching path left unlocked is still as readable as it was, so the run does not succeed over it: each one has
# its `not locked:` line, and the exit tells the claim's gate, which grants access only on 0, that the tree is not safe
# to open.
if (( skip_count > 0 )); then
    die MSG-T2J8 "secret-matching paths left unlocked under ${target}: ${skip_count}, each on a 'not locked:' line -- move, re-link or lock it by hand, then re-run"
fi
