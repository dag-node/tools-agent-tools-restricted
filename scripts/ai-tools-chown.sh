#!/usr/bin/env bash
# /usr/local/sbin/ai-tools-chown
# Restores @INSTALL_USER@:ai-tools ownership on files created or overwritten by Claude
# Code. Called by the PostToolUse hook via sudo (ai-tools -> root).
#
# Reads @INSTALL_HOME@/.config/ai-tools/allowed-projects for allow and exclude rules.
# That file is owned @INSTALL_USER@:@INSTALL_USER@ 600 -- root reads it here on ai-tools' behalf.
#
# Sudoers rule (in /etc/sudoers.d/ai-tools-claude):
#   ai-tools ALL=(root) NOPASSWD: /usr/local/sbin/ai-tools-chown
#
# Deploy:
#   sudo install -o root -g root -m 750 \
#       scripts/ai-tools-chown.sh /usr/local/sbin/ai-tools-chown

set -euo pipefail

readonly TARGET="${1:?usage: ai-tools-chown <absolute-path>}"
readonly ALLOWLIST="@INSTALL_HOME@/.config/ai-tools/allowed-projects"
readonly OWNER="@INSTALL_USER@:ai-tools"

# No allowlist -- do nothing silently (hook skips this call when no allowlist exists)
[[ -f "${ALLOWLIST}" ]] || exit 0

# Resolve to canonical path to block symlink traversal
canonical="$(realpath -e "${TARGET}" 2>/dev/null)" || exit 0

# Hardcoded basename protections -- always skipped, allowlist cannot override.
# Prevents accidental ownership changes on credential and secret files.
_base="$(basename "${canonical}")"
for _pat in \
    '.env' '.env.*' \
    '*.pem' '*.key' '*.p12' '*.pfx' '*.crt' \
    '.npmrc' '.pypirc' '.netrc' \
    '.aiignore' \
    'credentials' 'credentials.*'
do
    if [[ "${_base}" == ${_pat} ]]; then
        exit 0
    fi
done
unset _base _pat

declare -a allowed=()
declare -a excluded=()

while IFS= read -r entry || [[ -n "${entry}" ]]; do
    [[ -z "${entry}" || "${entry}" == '#'* ]] && continue
    if [[ "${entry}" == '!'* ]]; then
        excluded+=("${entry:1}")              # strip leading !, keep raw (may contain glob)
    else
        dir="$(realpath -e "${entry}" 2>/dev/null)" || continue
        allowed+=("${dir}")
    fi
done < "${ALLOWLIST}"

# Exclusions are checked first and override allows
if [[ "${#excluded[@]}" -gt 0 ]]; then
    for pat in "${excluded[@]}"; do
        pat="${pat%/}"                         # normalise: strip trailing slash
        if [[ "${canonical}" == ${pat} ]]; then
            exit 0                             # excluded -- leave ownership intact
        fi
        # For plain paths (no glob), also protect directory contents
        if [[ "${pat}" != *'*'* && "${canonical}" == "${pat}/"* ]]; then
            exit 0
        fi
    done
fi

# Check if target falls under any allowed directory
if [[ "${#allowed[@]}" -gt 0 ]]; then
    for dir in "${allowed[@]}"; do
        if [[ "${canonical}" == "${dir}" || "${canonical}" == "${dir}/"* ]]; then

            # Inspect the path WITHOUT following symlinks (GNU stat defaults to
            # lstat). Act only on a plain regular file with link count 1: this
            # rejects symlinks, directories and devices, and nlink > 1 means the
            # path is hardlinked -- a freshly written file never is, and a
            # hardlink could point at a sensitive file outside the tree.
            read -r expect_ident nlink ftype \
                < <(stat -c '%d:%i %h %F' "${canonical}" 2>/dev/null) || exit 0
            case "${ftype}" in "regular file"|"regular empty file") ;; *) exit 0 ;; esac
            [[ "${nlink}" -eq 1 ]] || exit 0

            current_owner="$(stat -c '%U:%G' "${canonical}" 2>/dev/null)" || exit 0
            current_mode="$( stat -c '%a'    "${canonical}" 2>/dev/null)" || exit 0
            if (( 8#${current_mode} & 7 )); then
                new_mode="$(printf '%o' "$(( 8#${current_mode} & ~7 ))")"
                perm_info="  perms:  ${current_mode} -> ${new_mode} (world bits removed)"
            else
                perm_info="  perms:  ${current_mode} (unchanged)"
            fi

            # Interactive invocation (terminal available): show changes and confirm.
            # Non-interactive (hook context, stdin is a pipe): apply silently --
            # the allowlist is the user's standing authorisation.
            if [[ -t 0 ]] || { [[ -c /dev/tty ]] && { : < /dev/tty; } 2>/dev/null; }; then
                {
                    printf '\nchown: %s\n' "${canonical}"
                    printf '  owner:  %s -> %s\n' "${current_owner}" "${OWNER}"
                    printf '%s\n' "${perm_info}"
                    printf 'apply? [Y/n] '
                } > /dev/tty
                read -r response < /dev/tty
                [[ "${response}" =~ ^[nN] ]] && exit 0
            fi

            # TOCTOU-safe apply. Every check above ran against the path *string*,
            # but ai-tools owns the project directory and can unlink and recreate
            # this path -- as a symlink, a hardlink, or a different file -- at any
            # instant. chmod has no --no-dereference, so a symlink swapped in
            # before it would let root chmod an arbitrary file (e.g. /etc/shadow).
            #
            # Pin the inode with an open fd and act through /proc/self/fd: a held
            # fd cannot be redirected by a later path swap. open() does follow a
            # symlink swapped in just before it, so after opening we re-verify the
            # fd resolves to the SAME inode validated above, still a regular file,
            # still link count 1. Any mismatch means a race -- bail.
            exec {fd}< "${canonical}" 2>/dev/null || exit 0
            read -r got_ident got_nlink got_ftype \
                < <(stat -L -c '%d:%i %h %F' "/proc/self/fd/${fd}" 2>/dev/null) \
                || { exec {fd}<&-; exit 0; }
            case "${got_ftype}" in "regular file"|"regular empty file") ;; *) exec {fd}<&-; exit 0 ;; esac
            if [[ "${got_ident}" != "${expect_ident}" || "${got_nlink}" -ne 1 ]]; then
                exec {fd}<&-
                exit 0
            fi
            # chown/chmod follow the /proc magic symlink to the pinned inode.
            # Strip world bits too: Claude Code's Write tool chmod +x on shebang
            # files sets +x for all (755 not 750); chmod o= corrects it.
            /usr/bin/chown -- "${OWNER}" "/proc/self/fd/${fd}"
            /usr/bin/chmod -- o=        "/proc/self/fd/${fd}"
            exec {fd}<&-
            exit 0
        fi
    done
fi

# Not under any allowed directory, or not matched after exclusion check
exit 1
