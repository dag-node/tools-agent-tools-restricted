#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/libexec/ai-tools/ai-tools-lockdown
# Proactively revoke ai-tools' access to credential files under the CURRENT
# project. Walks the current working directory and, for every path whose basename
# matches a secret pattern -- the SAME set ai-tools-chown uses, from the shared
# library and config file -- applies:
#       regular file -> 600        directory -> 700        owner -> <you>:<you>
# so ai-tools, neither owner nor a permitted group member, cannot read it. The owner's own
# private group is the target, matching ai-tools-chown's handling of an agent-written secret:
# leaving the group as @SANDBOX_GROUP@ would re-expose the file the moment its mode is widened.
# Each locked path also has its sandbox residue stripped (owner-only.lib.sh), for the same
# reason -- the mode alone does not hold.
#
# A second pass then seals the paths the operator sealed by MODE rather than by name: every path
# already owner-only gets the same residue stripped, so a directory or file sealed after the
# claim does not wait for the next claim to be cleaned up. That pass only ever removes the
# sandbox's reach, so unlike the lock it runs without a confirmation.
#
# Unlike ai-tools-chown (reactive: fires per agent-written path and acts only on
# ai-tools-owned paths), this is a USER-run pre-flight sweep -- it also locks down
# pre-existing, user-owned secrets the agent could otherwise read (e.g. an
# appsettings.json checked into the project). It honours the same allowlist: it
# runs only when the CWD is an allowed project, and skips any '!'-excluded path.
#
# Runs as root via sudo, invoked by YOU -- not ai-tools (no sudoers grant lets
# ai-tools run it):
#       cd /path/to/project
#       sudo ai-tools-lockdown [--dry-run|-n] [--yes|-y]
#
# Deploy:
#   sudo install -o root -g root -m 750 \
#       src/usr/local/libexec/ai-tools/ai-tools-lockdown.sh /usr/local/libexec/ai-tools/ai-tools-lockdown

set -euo pipefail

readonly SECRET_PATTERNS_LIB="/usr/local/lib/ai-tools/secret-patterns.lib.sh"

# Operator-identity resolver (operator.lib.sh): secrets are locked to the operator that owns the
# current directory. A missing lib leaves ai_tools_resolve_owner a fail-closed stub, so the resolve
# below dies rather than lock secrets to the wrong identity.
readonly OPERATOR_LIB="/usr/local/lib/ai-tools/operator.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/operator.lib.sh
source "${OPERATOR_LIB}" 2>/dev/null || ai_tools_resolve_owner() { return 1; }

# Directory-skip selector from the shared library (single source of truth, shared with
# session-hook.sh and ai-tools-setgid). A missing lib leaves a stub that descends everywhere.
readonly SKIP_DIRS_LIB="/usr/local/lib/ai-tools/skip-dirs.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/skip-dirs.lib.sh
source "${SKIP_DIRS_LIB}" 2>/dev/null \
    || ai_tools_skip_find_expr() { AI_TOOLS_SKIP_FIND_EXPR=(); return 0; }

# Shared leveled logger: journald (always) + the root-only file /var/log/ai-tools/lockdown.log.
# Best-effort -- a no-op fallback keeps the helper working if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-lockdown"
AI_TOOLS_LOG_FILE="lockdown.log"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/log.lib.sh
# Required, fail-closed: this helper prints agent-named paths to stderr and the log, so it
# needs ai_tools_log_sanitize -- a missing logger must refuse, not emit an agent path raw.
if ! source "${LOG_LIB}"; then
    printf 'ai-tools-lockdown: FATAL: cannot source %s\n' "${LOG_LIB}" >&2
    exit 1
fi

log()  { printf 'ai-tools-lockdown: %s\n' "$*"; }
warn() { printf 'ai-tools-lockdown: warn: %s\n' "$*" >&2; }
die()  { printf 'ai-tools-lockdown: error: %s\n' "$*" >&2; exit 1; }

# Which paths the operator sealed, and what may be stripped from one (owner-only.lib.sh, the
# reference for both). Required and fail-closed like safe-paths.lib.sh: an unusable library
# must not leave a locked path carrying the residue that would re-expose it.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/owner-only.lib.sh
source /usr/local/lib/ai-tools/owner-only.lib.sh
if ! declare -F ai_tools_is_owner_only >/dev/null 2>&1 \
        || ! declare -F ai_tools_strip_sandbox_residue >/dev/null 2>&1; then
    printf 'ai-tools-lockdown: FATAL: owner-only.lib.sh defines no owner-only guard\n' >&2
    exit 3
fi

# Protected-paths backstop (safe-paths.lib.sh): refuse to act on a system directory even
# when the allowlist includes it. See safe-paths.rule.md.
readonly SAFE_PATHS_LIB="/usr/local/lib/ai-tools/safe-paths.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/safe-paths.lib.sh
source "${SAFE_PATHS_LIB}"

# Shared yes/no prompt (ai_tools_msg_confirm; see msg.lib.sh). REQUIRED like
# safe-paths.lib.sh: the bare source under set -e aborts if it is missing -- a valid
# install ships it, so there is no fallback. Include-guarded, so this is a no-op when
# safe-paths.lib.sh above already loaded it.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/msg.lib.sh
source /usr/local/lib/ai-tools/msg.lib.sh
# Fixed 80-column frame for any box this helper renders, aligned with the CLI's.
export AI_TOOLS_MSG_FULLWIDTH=1

usage() {
    cat >&2 <<'EOF'
usage: cd <project> && sudo ai-tools-lockdown [options]

  -n, --dry-run   list paths that would be locked down; make no changes
  -y, --yes       apply without the interactive confirmation prompt
  -h, --help      show this help

Locks down secret-matching paths under the current directory:
  files -> 600, directories -> 700, owner <you>:<you>.
Runs only when the current directory is an allowed project.
EOF
}

# ── Argument parsing ─────────────────────────────────────────────────────────
DRY_RUN=false
ASSUME_YES=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=true ;;
        -y|--yes)     ASSUME_YES=true ;;
        -h|--help)    usage; exit 0 ;;
        *)            usage; die "unknown argument: $1" ;;
    esac
    shift
done

# ── Guards ───────────────────────────────────────────────────────────────────
[[ "${EUID}" -eq 0 ]] || die "run with sudo"
# The invoker (who ran sudo) must not be the agent; the OWNER files are handed back to comes
# from the enrolled operator identity, not the invoker, so a foreign sudo invocation still
# restores ownership to the configured operator rather than to itself.
readonly INVOKER="${SUDO_USER:?run via sudo (SUDO_USER unset)}"
[[ "${INVOKER}" != "@SANDBOX_USER@" ]] || die "must be run by you, not ai-tools"

# Resolve the invoking shell's working directory (sudo preserves it).
target="$(pwd -P)" || die "cannot determine current directory"
target="$(realpath -e "${target}" 2>/dev/null)" || die "cannot resolve ${target}"
# Refuse the whole pass if the working directory is a protected system directory.
ai_tools_assert_safe_target "${target}" "lockdown" || exit 3

# Resolve the operator that owns this directory; secrets are locked to it. lockdown runs only
# inside an allowed project, so the directory must resolve to an operator.
ai_tools_resolve_owner "${target}" \
    || die "this directory is not in allowed projects for current operator: ${target}"
readonly ALLOWLIST="${AI_TOOLS_RESOLVED_ALLOWLIST}"
# The owner's own private group, spelled per docs/naming-conventions.md -- the same target
# ai-tools-chown gives an agent-written secret, so a secret ends up identically owned whether it
# was locked down proactively or quarantined on write.
readonly OWNER="${PROJECTS_USER}:${PROJECTS_GROUP}"
# Two identities may legitimately hold a path in a claimed tree: the resolved operator and the
# sandbox account. The seal pass acts on those only, as every other walk does -- a path held by a
# third party (root, another developer) is left untouched.
SANDBOX_UID="$(id -u "@SANDBOX_USER@" 2>/dev/null || echo -1)"
readonly SANDBOX_UID

# ── Allowlist (allow + ! exclude), same parse as ai-tools-chown ──────────────
declare -a allowed=()
declare -a excluded=()
while IFS= read -r entry || [[ -n "${entry}" ]]; do
    [[ -z "${entry}" || "${entry}" == '#'* ]] && continue
    if [[ "${entry}" == '!'* ]]; then
        excluded+=("${entry:1}")                  # keep raw (may contain glob)
    else
        d="$(realpath -e "${entry}" 2>/dev/null)" || continue
        allowed+=("${d}")
    fi
done < "${ALLOWLIST}"

# _is_excluded <abs-path>: 0 if the path is covered by a '!' rule. A plain path
# also covers its contents; a glob matches as-is. Mirrors ai-tools-chown.
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

# _is_allowed <abs-path>: 0 if the path is at or under an allowed directory.
_is_allowed() {
    local path="$1" d
    [[ "${#allowed[@]}" -gt 0 ]] || return 1
    for d in "${allowed[@]}"; do
        [[ "${path}" == "${d}" || "${path}" == "${d}/"* ]] && return 0
    done
    return 1
}

_is_allowed  "${target}" || die "${target} is not an allowed project (see ${ALLOWLIST})"
_is_excluded "${target}" && die "${target} is excluded in the allowlist; nothing to do"

# ── Shared secret matcher ────────────────────────────────────────────────────
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/secret-patterns.lib.sh
if ! source "${SECRET_PATTERNS_LIB}"; then
    die "cannot source ${SECRET_PATTERNS_LIB}"
fi
ai_tools_load_secret_patterns

# ── Enumerate secret-matching paths under the target ─────────────────────────
# find -P (default): never follow symlinks; -type f/-type d already exclude them.
ai_tools_skip_find_expr lockdown '' "${target}"
declare -a expr=( "${target}" -xdev "${AI_TOOLS_SKIP_FIND_EXPR[@]}" \
                  '(' -type f -o -type d ')' -print0 )

declare -a hits=()
while IFS= read -r -d '' path; do
    _is_excluded "${path}" && continue
    ai_tools_is_secret_basename "$(basename "${path}")" || continue
    hits+=("${path}")
done < <(find "${expr[@]}" 2>/dev/null)

# ── Enumerate owner-only paths to seal ───────────────────────────────────────
# The pass above finds paths by NAME. This one finds the paths sealed by MODE -- anything
# already owner-only that still carries the group, setgid bit or ACL entries it inherited when
# it was created inside the claimed tree. Stripping those is what makes such a seal survive a
# later chmod; owner-only.lib.sh is the reference for what comes off.
#
# `! -perm /077` selects "no group and no other bit set", the owner-only predicate, in the
# kernel -- so the filter avoids a stat per path. A sealed DIRECTORY is printed and then pruned,
# taking its subtree with it exactly as ai-tools-setgid/-setfacl do: the sandbox account cannot
# enter it, so no path inside is reachable through it. Secret-named paths are left to the lock
# pass above, which seals them itself.
declare -a sealed=()
while IFS= read -r -d '' path; do
    _is_excluded "${path}" && continue
    ai_tools_is_secret_basename "$(basename "${path}")" && continue
    sealed+=("${path}")
done < <(find "${target}" -xdev "${AI_TOOLS_SKIP_FIND_EXPR[@]}" \
              '(' -type d ! -perm /077 -print0 -prune ')' -o \
              '(' -type f ! -perm /077 -print0 ')' 2>/dev/null)

# Label for log lines: DRY_RUN holds the string "true"/"false" (both non-empty), so
# select on its value, not with ${DRY_RUN:+...} which would always expand.
if ${DRY_RUN}; then scan_mode=" (dry-run)"; else scan_mode=""; fi

if [[ "${#hits[@]}" -eq 0 && "${#sealed[@]}" -eq 0 ]]; then
    log "no secret-matching paths, and no owner-only paths to seal, under ${target}"
    ai_tools_log_info "scan${scan_mode}: nothing to do under ${target}"
    exit 0
fi

# ── Report, confirm, apply ───────────────────────────────────────────────────
# Log the detection (count + each path) regardless of dry-run vs apply: this is the
# audit record of what the scan SAW. The later per-path "locked" entries from
# _safe_apply record what was DONE -- distinct events, intentionally both logged.
if (( ${#hits[@]} )); then
    printf 'ai-tools-lockdown: %d secret-matching path(s) under %s:\n' \
        "${#hits[@]}" "${target}" >&2
    ai_tools_log_info "scan${scan_mode}: ${#hits[@]} secret-matching path(s) under ${target}"
    for path in "${hits[@]}"; do
        if [[ -d "${path}" ]]; then
            printf '  [dir]  %s\n' "$(ai_tools_log_sanitize "${path}")" >&2
        else
            printf '  [file] %s\n' "$(ai_tools_log_sanitize "${path}")" >&2
        fi
        ai_tools_log_info "scan: secret-matching ${path}"
    done
fi
if (( ${#sealed[@]} )); then
    ai_tools_log_info "scan${scan_mode}: ${#sealed[@]} owner-only path(s) under ${target}"
fi

# The confirm comes after the dry-run branch below, not here: a preview must never ask to apply.
#
# _safe_apply <path>: chmod (file 600 / dir 700) and chown to OWNER through a
# pinned fd, so a symlink/path swap by ai-tools (a group-writer on the project
# dir) cannot redirect root's chmod/chown onto an arbitrary file. lstat the path,
# require a regular file (nlink 1, never a hardlink to a sensitive file elsewhere)
# or a directory, open it, then re-verify the fd resolves to the same inode and
# type before acting via /proc/self/fd. Mirrors ai-tools-chown's TOCTOU-safe apply.
_safe_apply() {
    local path="$1" expect_ident nlink ftype is_dir mode fd got_ident got_nlink got_ftype
    read -r expect_ident nlink ftype \
        < <(stat -c '%d:%i %h %F' "${path}" 2>/dev/null) || return 1
    case "${ftype}" in
        "regular file"|"regular empty file")
            is_dir=false; mode=600
            [[ "${nlink}" -eq 1 ]] || { warn "skip (hardlinked, nlink=${nlink}): ${path}"; return 1; }
            ;;
        "directory") is_dir=true; mode=700 ;;
        *)           return 1 ;;
    esac

    # NB: brace-group the redirection so 2>/dev/null scopes to the open only, not
    # the shell (a bare `exec {fd}< file 2>/dev/null` redirects fd2 permanently).
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
    /usr/bin/chown -- "${OWNER}" "/proc/self/fd/${fd}"
    /usr/bin/chmod -- "${mode}"  "/proc/self/fd/${fd}"
    # The path is owner-only now, so strip the residue the mode merely masks -- the inherited
    # ACL entries and, on a directory, the setgid bit the numeric chmod above leaves standing.
    # Re-read both from the pinned inode: they are what the chown/chmod just made them.
    local now_grp now_mode
    if read -r now_grp now_mode \
            < <(stat -L -c '%G %a' "/proc/self/fd/${fd}" 2>/dev/null); then
        ai_tools_strip_sandbox_residue "${fd}" "${got_ftype}" "${now_grp}" "${now_mode}" \
            "${PROJECTS_GROUP}" || true
    fi
    exec {fd}<&-
    ai_tools_log_info "locked ${path} -> ${OWNER} ${mode}"
    printf '  locked %s  ->  %s %s\n' "$(ai_tools_log_sanitize "${path}")" "${OWNER}" "${mode}" >&2
    return 0
}

# _safe_seal <path>: strip the sandbox residue from an already-owner-only path, through a pinned
# fd like _safe_apply. It leaves mode bits and ownership as they are -- it removes only what the sandbox
# put there (owner-only.lib.sh) -- so unlike _safe_apply it asks for no confirmation.
# Returns 0 when something was stripped, 1 when there was no residue to strip or the path is out of
# scope. Sets AI_TOOLS_RESIDUE_SURFACE for the caller (a third-party setgid it declined to clear),
# and AI_TOOLS_RESIDUE_ACTIONS to what came off.
# Under --dry-run every gate above still runs and the strip itself reports instead of acting
# (AI_TOOLS_RESIDUE_DRY_RUN), so the preview is produced by the code that does the work rather
# than by a second opinion about it.
_safe_seal() {
    local path="$1" expect_ident fd got_ident got_uid got_grp got_mode got_ftype rc
    # Clear it here, not only in the strip: every return below the strip is an early one, and a
    # stale value from the previous path would be counted against this one.
    AI_TOOLS_RESIDUE_SURFACE=0
    expect_ident="$(stat -c '%d:%i' "${path}" 2>/dev/null)" || return 1
    { exec {fd}< "${path}"; } 2>/dev/null || return 1
    # %F ("regular empty file") is multi-word, so it stays the last field.
    read -r got_ident got_uid got_grp got_mode got_ftype \
        < <(stat -L -c '%d:%i %u %G %a %F' "/proc/self/fd/${fd}" 2>/dev/null) \
        || { exec {fd}<&-; return 1; }
    if [[ "${got_ident}" != "${expect_ident}" ]]; then exec {fd}<&-; return 1; fi
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
        ai_tools_log_info "sealed ${path} (owner-only; stripped ${AI_TOOLS_RESIDUE_ACTIONS[*]})"
    fi
    return "${rc}"
}

# _seal_pass: run _safe_seal over every enumerated owner-only path and report. One pass serves
# both modes -- a dry run reports what would come off and applies none of it, an apply reports what
# did -- so the preview cannot describe a pass other than the one that follows it. Under --dry-run
# each hit names its path AND what it carries, since "3 paths would change" is not something an
# operator can check before answering.
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
            ai_tools_log_info "sealed ${seal_count} owner-only path(s) under ${target}"
            log "sealed ${seal_count} owner-only path(s) (sandbox group, setgid and ACL entries removed)"
        fi
    elif (( ${#sealed[@]} )) && ${DRY_RUN}; then
        log "${#sealed[@]} owner-only path(s) checked; none carries sandbox residue"
    fi
    # Surfaced, never silent: the one piece of residue the pass declines to remove, since it cannot
    # ask whether the operator meant it.
    if (( foreign > 0 )); then
        ai_tools_log_warn "left a third-party setgid bit on ${foreign} owner-only path(s) under ${target}"
        printf 'ai-tools-lockdown: kept the setgid bit on %d owner-only director(ies) grouped to a third party -- clear it yourself with: chmod g-s <dir>\n' \
            "${foreign}" >&2
    fi
}

# A dry run stops here -- but not before previewing the seal pass, which an apply would run too.
# A preview that covers half of what follows it is the thing a preview exists to prevent.
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

# Only the secret lock asks. It changes ownership and modes the operator did not choose, whereas
# the seal pass only ever REMOVES the sandbox's reach from a path the operator already sealed --
# the same terms on which the claim walks strip, so it runs unprompted.
if (( ${#hits[@]} )) && ! ${ASSUME_YES}; then
    if [[ -t 0 ]] || { [[ -c /dev/tty ]] && { : < /dev/tty; } 2>/dev/null; }; then
        ai_tools_msg_confirm \
            "Set files 600 / dirs 700, chown ${OWNER}, revoking ai-tools access?" n \
            || { log "aborted; no changes made"; exit 0; }
    else
        die "no TTY for confirmation; re-run with --yes to apply non-interactively"
    fi
fi

declare -i done_count=0 skip_count=0
for path in "${hits[@]}"; do
    if _safe_apply "${path}"; then
        done_count=$(( done_count + 1 ))
    else
        skip_count=$(( skip_count + 1 ))
    fi
done

if (( ${#hits[@]} )); then
    if (( skip_count > 0 )); then
        ai_tools_log_warn "lockdown of ${target}: locked ${done_count} path(s), skipped ${skip_count}"
        log "locked ${done_count} path(s); skipped ${skip_count} (see warnings above)"
    else
        ai_tools_log_info "lockdown of ${target}: locked ${done_count} path(s)"
        log "locked ${done_count} path(s)"
    fi
fi

# ── Seal pass ────────────────────────────────────────────────────────────────
# Strip the residue from the paths the operator sealed by mode. Reported only when it actually
# changed something: on a settled tree this is a silent no-op, run after run.
_seal_pass
