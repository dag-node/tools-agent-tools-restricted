#!/usr/bin/env bash
# /usr/local/sbin/ai-tools/chown
# Restores @PROJECTS_USER@:ai-tools ownership on files and directories created or
# overwritten by Claude Code. Called by the PostToolUse hook via sudo (ai-tools
# -> root). Accepts a single regular-file or directory target; for directories it
# strips world bits while preserving group rwx so the agent can keep working in a
# dir it created.
#
# Reads @PROJECTS_HOME@/.config/ai-tools/allowed-projects for allow and exclude rules.
# That file is owned @PROJECTS_USER@:@PROJECTS_USER@ 600 -- root reads it here on ai-tools' behalf.
#
# Sudoers rule (in /etc/sudoers.d/ai-tools-claude):
#   ai-tools ALL=(root) NOPASSWD: /usr/local/sbin/ai-tools/chown
#
# Deploy:
#   sudo install -o root -g root -m 750 \
#       scripts/ai-tools-chown.sh /usr/local/sbin/ai-tools/chown

set -euo pipefail

readonly TARGET="${1:?usage: ai-tools-chown <absolute-path>}"
readonly ALLOWLIST="@PROJECTS_HOME@/.config/ai-tools/allowed-projects"
# Ordinary files are chowned to OWNER (group ai-tools, readable by the agent).
# Secret-named files are chowned to SECRET_OWNER (the user's private group) with
# group+world bits stripped, so ai-tools -- neither owner nor group member --
# cannot read the contents. ai-tools is a group-writer on the project dir, not
# its owner, so it can still unlink/replace the path: this revokes read, not
# directory control.
readonly OWNER="@PROJECTS_USER@:@SANDBOX_GROUP@"
readonly SECRET_OWNER="@PROJECTS_USER@:@PROJECTS_GROUP@"
readonly AUDIT_LOG="/var/log/ai-tools-chown.log"

# Shared secret-name matcher, sourced (not executed) so this helper and
# ai-tools-lockdown classify basenames by the SAME patterns from the SAME config
# file (@PROJECTS_HOME@/.config/ai-tools/secret-patterns). Failing to source it
# would leave secret classification undefined, so abort rather than fall through
# and hand a secret back as an ordinary file -- exiting non-zero simply skips this
# path's handback (it stays ai-tools-owned), which is fail-closed, not a leak.
readonly SECRET_PATTERNS_LIB="/usr/local/lib/ai-tools/secret-patterns.lib.sh"
# shellcheck source=/dev/null
if ! source "${SECRET_PATTERNS_LIB}"; then
    printf 'ai-tools-chown: FATAL: cannot source %s\n' "${SECRET_PATTERNS_LIB}" >&2
    exit 1
fi

# _notify_secret: emit a one-line NOTICE that a secret-named file was written and
# ai-tools' read access revoked, to stderr (the PostToolUse hook relays it into
# the session) and the root-owned audit log. Logging is best-effort, never blocks.
# args:  path  old_owner  new_owner  old_mode  new_mode
_notify_secret() {
    local path="$1" old_owner="$2" new_owner="$3" old_mode="$4" new_mode="$5" msg
    printf -v msg 'NOTICE: secret-named file written by agent considered breached, rotate the secret: %s (ai-tools read access revoked; owner %s -> %s, mode %s -> %s)' \
        "${path}" "${old_owner}" "${new_owner}" "${old_mode}" "${new_mode}"
    printf 'ai-tools-chown: %s\n' "${msg}" >&2
    ( umask 077; printf '%s %s\n' "$(date -Is)" "${msg}" >> "${AUDIT_LOG}" ) 2>/dev/null || true
}

# No allowlist -- do nothing silently (hook skips this call when no allowlist exists)
[[ -f "${ALLOWLIST}" ]] || exit 0

# Resolve to canonical path to block symlink traversal
canonical="$(realpath -e "${TARGET}" 2>/dev/null)" || exit 0

# Classify the basename against the shared secret-name patterns. A match sets
# is_secret, so the apply path chowns the file to SECRET_OWNER, strips group+world
# bits, and emits a NOTICE via _notify_secret. The patterns live in the user-owned
# config file read by the library (basename-safe globs only; no bare 'config' that
# would match innocuous files). Per-project secrets belong in ! allowlist
# exclusions, which leave ownership intact.
is_secret=false
if ai_tools_is_secret_basename "$(basename "${canonical}")"; then
    is_secret=true
fi

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
            # lstat). Act on a regular file or a directory; reject symlinks and
            # devices. For a regular file, nlink must be 1: a freshly written
            # file is never hardlinked, and a hardlink could point at a sensitive
            # file outside the tree. Directories legitimately have nlink >= 2
            # (their own '.' plus each child's '..'), so the nlink guard applies
            # to regular files only.
            read -r expect_ident nlink ftype \
                < <(stat -c '%d:%i %h %F' "${canonical}" 2>/dev/null) || exit 0
            is_dir=false
            case "${ftype}" in
                "regular file"|"regular empty file") [[ "${nlink}" -eq 1 ]] || exit 0 ;;
                "directory")                         is_dir=true ;;
                *)                                   exit 0 ;;
            esac
            # A directory is the agent's own workspace, never a secret to revoke
            # (and revoking the agent's access to a dir it must keep writing into
            # would break it). Never apply secret handling to a directory.
            ${is_dir} && is_secret=false

            current_owner="$(stat -c '%U:%G' "${canonical}" 2>/dev/null)" || exit 0
            current_mode="$( stat -c '%a'    "${canonical}" 2>/dev/null)" || exit 0

            # Act ONLY on paths the agent itself wrote. Claude Code's Write/Edit
            # tools create files (and any missing parent dirs) via atomic rename,
            # which stamps them ai-tools-owned; a handed-back path is <you>-owned.
            # So "currently ai-tools-owned" means "the agent just created or
            # overwrote this". Anything NOT ai-tools-owned is a pre-existing user
            # file or directory the agent could not have written -- leave it
            # completely untouched: never re-chown it, never strip its bits, and
            # for a secret-named path never raise a false 'breached' NOTICE about a
            # secret the agent never had access to. Acting on a non-ai-tools
            # directory would additionally GRANT ai-tools the group rwx below on a
            # dir it never owned. The pinned-inode re-check below makes this owner
            # read race-safe: an ai-tools-owned inode's user field cannot change
            # except via root.
            [[ "${current_owner%%:*}" == "@SANDBOX_USER@" ]] || exit 0

            # Directories: hand to OWNER, strip world bits but GUARANTEE group
            #   rwx (g+rwx,o=) so the agent -- now only a group member of a dir it
            #   created and may still be writing into -- can still traverse and
            #   add files. This mirrors the project root (<you>:ai-tools, group-writable).
            # Secret-named files: hand to SECRET_OWNER (the user's private group)
            #   and strip BOTH group and world bits (go=), removing ai-tools' read
            #   access to the contents.
            # Ordinary files: hand to OWNER, keep group ai-tools readable, strip
            #   only the world bits (o=).
            if ${is_dir}; then
                target_owner="${OWNER}"
                chmod_arg="g+rwx,o="
                new_mode="$(printf '%o' "$(( (8#${current_mode} | 070) & ~7 ))")"
            elif ${is_secret}; then
                target_owner="${SECRET_OWNER}"
                chmod_arg="go="
                new_mode="$(printf '%o' "$(( 8#${current_mode} & ~077 ))")"
            else
                target_owner="${OWNER}"
                chmod_arg="o="
                new_mode="$(printf '%o' "$(( 8#${current_mode} & ~7 ))")"
            fi
            if [[ "${new_mode}" != "${current_mode}" ]]; then
                perm_info="  perms:  ${current_mode} -> ${new_mode}"
            else
                perm_info="  perms:  ${current_mode} (unchanged)"
            fi
            if ${is_secret}; then
                perm_info+="  [ai-tools access removed]"
            fi

            # Interactive invocation (terminal available): show changes and confirm.
            # Non-interactive (hook context, stdin is a pipe): apply silently --
            # the allowlist is the user's standing authorisation.
            if [[ -t 0 ]] || { [[ -c /dev/tty ]] && { : < /dev/tty; } 2>/dev/null; }; then
                {
                    printf '\nchown: %s\n' "${canonical}"
                    printf '  owner:  %s -> %s\n' "${current_owner}" "${target_owner}"
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
            # NB: brace-group the redirection. A bare `exec {fd}< file 2>/dev/null`
            # applies 2>/dev/null to the SHELL permanently (exec with no command),
            # which would swallow the secret-file NOTICE emitted on stderr below.
            # The group scopes 2>/dev/null to just the open; fd2 is restored after.
            { exec {fd}< "${canonical}"; } 2>/dev/null || exit 0
            read -r got_ident got_nlink got_ftype \
                < <(stat -L -c '%d:%i %h %F' "/proc/self/fd/${fd}" 2>/dev/null) \
                || { exec {fd}<&-; exit 0; }
            case "${got_ftype}" in
                "regular file"|"regular empty file") ${is_dir} && { exec {fd}<&-; exit 0; } ;;
                "directory")                         ${is_dir} || { exec {fd}<&-; exit 0; } ;;
                *)                                   exec {fd}<&-; exit 0 ;;
            esac
            # Inode must match the one validated pre-open (catches a path swap);
            # for a regular file, link count must still be 1 (dirs are exempt).
            if [[ "${got_ident}" != "${expect_ident}" ]] \
               || { ! ${is_dir} && [[ "${got_nlink}" -ne 1 ]]; }; then
                exec {fd}<&-
                exit 0
            fi
            # chown/chmod follow the /proc magic symlink to the pinned inode.
            # chmod also corrects the execute bit Claude Code's Write tool sets on
            # shebang files (755 not 750); o= for ordinary files, go= for secrets.
            /usr/bin/chown -- "${target_owner}" "/proc/self/fd/${fd}"
            /usr/bin/chmod -- "${chmod_arg}"    "/proc/self/fd/${fd}"
            if ${is_secret}; then
                _notify_secret "${canonical}" "${current_owner}" "${target_owner}" \
                    "${current_mode}" "${new_mode}"
            fi
            exec {fd}<&-
            exit 0
        fi
    done
fi

# Not under any allowed directory, or not matched after exclusion check
exit 1
