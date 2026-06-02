#!/usr/bin/env bash
# /usr/local/sbin/ai-tools/lockdown
# Proactively revoke ai-tools' access to credential files under the CURRENT
# project. Walks the current working directory and, for every path whose basename
# matches a secret pattern -- the SAME set ai-tools-chown uses, from the shared
# library and config file -- applies:
#       regular file -> 600        directory -> 700        owner -> <you>:ai-tools
# so ai-tools, neither owner nor a permitted group member, can no longer read it.
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
#       scripts/ai-tools-lockdown.sh /usr/local/sbin/ai-tools/lockdown

set -euo pipefail

readonly SECRET_PATTERNS_LIB="/usr/local/lib/ai-tools/secret-patterns.lib.sh"
readonly ALLOWLIST="@PROJECTS_HOME@/.config/ai-tools/allowed-projects"

# Pruned directory names from the shared library (single source of truth, shared
# with sandbox-sweep.sh and ai-tools-setgid). Unreadable -> empty -> no pruning.
readonly PRUNE_LIB="/usr/local/lib/ai-tools/prune-dirs.lib.sh"
AI_TOOLS_PRUNE_NAMES=()
# shellcheck source=/dev/null
[[ -r "${PRUNE_LIB}" ]] && source "${PRUNE_LIB}" || true

log()  { printf 'ai-tools-lockdown: %s\n' "$*"; }
warn() { printf 'ai-tools-lockdown: warn: %s\n' "$*" >&2; }
die()  { printf 'ai-tools-lockdown: error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat >&2 <<'EOF'
usage: cd <project> && sudo ai-tools-lockdown [options]

  -n, --dry-run   list paths that would be locked down; make no changes
  -y, --yes       apply without the interactive confirmation prompt
  -h, --help      show this help

Locks down secret-matching paths under the current directory:
  files -> 600, directories -> 700, owner <you>:ai-tools.
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
readonly PROJECTS_USER="${SUDO_USER:?run via sudo (SUDO_USER unset)}"
[[ "${PROJECTS_USER}" != "@SANDBOX_USER@" ]] || die "must be run by you, not ai-tools"
readonly OWNER="${PROJECTS_USER}:@SANDBOX_GROUP@"

# Resolve the invoking shell's working directory (sudo preserves it).
target="$(pwd -P)" || die "cannot determine current directory"
target="$(realpath -e "${target}" 2>/dev/null)" || die "cannot resolve ${target}"

# ── Allowlist (allow + ! exclude), same parse as ai-tools-chown ──────────────
[[ -f "${ALLOWLIST}" ]] || die "allowlist not found: ${ALLOWLIST}"
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
# shellcheck source=/dev/null
if ! source "${SECRET_PATTERNS_LIB}"; then
    die "cannot source ${SECRET_PATTERNS_LIB}"
fi
ai_tools_load_secret_patterns

# ── Enumerate secret-matching paths under the target ─────────────────────────
# find -P (default): never follow symlinks; -type f/-type d already exclude them.
declare -a expr=( "${target}" -xdev )
if (( ${#AI_TOOLS_PRUNE_NAMES[@]} > 0 )); then
    expr+=( '(' )
    for i in "${!AI_TOOLS_PRUNE_NAMES[@]}"; do
        (( i > 0 )) && expr+=( -o )
        expr+=( -name "${AI_TOOLS_PRUNE_NAMES[$i]}" )
    done
    expr+=( ')' -prune -o )
fi
expr+=( '(' -type f -o -type d ')' -print0 )

declare -a hits=()
while IFS= read -r -d '' path; do
    _is_excluded "${path}" && continue
    ai_tools_is_secret_basename "$(basename "${path}")" || continue
    hits+=("${path}")
done < <(find "${expr[@]}" 2>/dev/null)

if [[ "${#hits[@]}" -eq 0 ]]; then
    log "no secret-matching paths under ${target}"
    exit 0
fi

# ── Report, confirm, apply ───────────────────────────────────────────────────
printf 'ai-tools-lockdown: %d secret-matching path(s) under %s:\n' \
    "${#hits[@]}" "${target}" >&2
for path in "${hits[@]}"; do
    if [[ -d "${path}" ]]; then
        printf '  [dir]  %s\n' "${path}" >&2
    else
        printf '  [file] %s\n' "${path}" >&2
    fi
done

if ${DRY_RUN}; then
    log "dry-run: no changes made"
    exit 0
fi

if ! ${ASSUME_YES}; then
    if [[ -t 0 ]] || { [[ -c /dev/tty ]] && { : < /dev/tty; } 2>/dev/null; }; then
        printf 'Set files 600 / dirs 700, chown %s, revoking ai-tools access? [y/N] ' \
            "${OWNER}" > /dev/tty
        read -r response < /dev/tty
        [[ "${response}" =~ ^[yY] ]] || { log "aborted; no changes made"; exit 0; }
    else
        die "no TTY for confirmation; re-run with --yes to apply non-interactively"
    fi
fi

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
    exec {fd}<&-
    printf '  locked %s  ->  %s %s\n' "${path}" "${OWNER}" "${mode}" >&2
    return 0
}

declare -i done_count=0 skip_count=0
for path in "${hits[@]}"; do
    if _safe_apply "${path}"; then
        done_count=$(( done_count + 1 ))
    else
        skip_count=$(( skip_count + 1 ))
    fi
done

if (( skip_count > 0 )); then
    log "locked ${done_count} path(s); skipped ${skip_count} (see warnings above)"
else
    log "locked ${done_count} path(s)"
fi
