#!/usr/bin/env bash
# /usr/local/sbin/ai-tools/ai-tools-chown
# Restores operator:ai-tools ownership on files and directories created or
# overwritten by Claude Code. Invoked as root by the ai-tools-handback daemon
# (ai_tools_handback_t) when the PostToolUse/Stop/SessionStart hooks send a CHOWN
# request over the handback socket. Accepts a single regular-file or directory
# target; for directories it strips world bits while preserving group rwx so the
# agent can keep working in a dir it created.
#
# Reads the operator's allowed-projects allowlist for allow and exclude rules (its path is
# derived from the operator identity in /etc/ai-tools/operator.conf). That file is owned by
# the operator 600 -- root reads it here on ai-tools' behalf.
#
# Invocation: the handback socket's CHOWN verb (ai-tools-handback daemon, root).
#   Not a sudo target -- ai-tools has no sudo rights (the session runs under NNP,
#   which drops sudo's SUID bit).
#
# Deploy:
#   sudo install -o root -g root -m 750 \
#       src/usr/local/sbin/ai-tools/ai-tools-chown.sh /usr/local/sbin/ai-tools/ai-tools-chown

set -euo pipefail

readonly TARGET="${1:?usage: ai-tools-chown <absolute-path>}"

# Operator-identity resolver (operator.lib.sh): resolves the operator that owns a path. A missing
# lib leaves ai_tools_resolve_owner a fail-closed stub, so the path is left ai-tools-owned rather
# than handed back unclassified.
readonly OPERATOR_LIB="/usr/local/lib/ai-tools/operator.lib.sh"
# shellcheck source=/dev/null
source "${OPERATOR_LIB}" 2>/dev/null || ai_tools_resolve_owner() { return 1; }

# Shared leveled logger: journald (always) + the root-only file /var/log/ai-tools/chown.log.
# Best-effort -- a no-op fallback keeps the helper working if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-chown"
AI_TOOLS_LOG_FILE="chown.log"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=/dev/null
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log() { :; }; ai_tools_log_debug() { :; }; ai_tools_log_info() { :; }
    ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
fi

# Shared secret-name matcher, sourced (not executed) so this helper and
# ai-tools-lockdown classify basenames by the SAME patterns from the SAME config
# file (the operator's secret-patterns, resolved via the operator identity). Failing to source it
# would leave secret classification undefined, so abort rather than fall through
# and hand a secret back as an ordinary file -- exiting non-zero simply skips this
# path's handback (it stays ai-tools-owned), which is fail-closed, not a leak.
readonly SECRET_PATTERNS_LIB="/usr/local/lib/ai-tools/secret-patterns.lib.sh"
# shellcheck source=/dev/null
if ! source "${SECRET_PATTERNS_LIB}"; then
    printf 'ai-tools-chown: FATAL: cannot source %s\n' "${SECRET_PATTERNS_LIB}" >&2
    exit 1
fi

# Protected-paths backstop (safe-paths.lib.sh): refuse to act on a system directory even
# when the allowlist includes it. A missing lib leaves a no-op stub, so the helper still
# works -- the allowlist and owner-guard remain, and the wrapper/CLI carry the same check.
readonly SAFE_PATHS_LIB="/usr/local/lib/ai-tools/safe-paths.lib.sh"
# shellcheck source=/dev/null
source "${SAFE_PATHS_LIB}" 2>/dev/null || ai_tools_assert_safe_target() { return 0; }

# _notify_secret: emit a one-line NOTICE that a secret-named file was written and
# ai-tools' read access revoked, to stderr (the PostToolUse hook relays it into the
# session) and -- at WARNING level -- to journald + the root-owned chown.log. Logging
# is best-effort, never blocks.
# args:  path  old_owner  new_owner  old_mode  new_mode
_notify_secret() {
    local path="$1" old_owner="$2" new_owner="$3" old_mode="$4" new_mode="$5" msg
    printf -v msg 'NOTICE: secret-named file written by agent considered breached, rotate the secret: %s (ai-tools read access revoked; owner %s -> %s, mode %s -> %s)' \
        "${path}" "${old_owner}" "${new_owner}" "${old_mode}" "${new_mode}"
    printf 'ai-tools-chown: %s\n' "${msg}" >&2
    ai_tools_log_warn "${msg}"
}

# Resolve to canonical path to block symlink traversal
canonical="$(realpath -e "${TARGET}" 2>/dev/null)" || exit 0

# Defense in depth: never act on a protected system directory, even if the allowlist
# (mis)includes it. Fail-closed before any ownership change.
ai_tools_assert_safe_target "${canonical}" "ownership handback" || exit 3

# Resolve the operator that owns this path (operator.lib.sh); no owner -> leave it untouched.
# Ordinary files go to OWNER (group ai-tools, agent-readable); secret-named files to SECRET_OWNER
# (the operator and their primary group) at mode 600 -- readable only by the operator, so the agent
# loses read while the operator keeps it. ai-tools stays a group-writer on the project dir (not its
# owner), so it can still unlink/replace the path: read is revoked from the agent, not control.
ai_tools_resolve_owner "${canonical}" || exit 0
readonly ALLOWLIST="${AI_TOOLS_RESOLVED_ALLOWLIST}"
readonly OWNER="${PROJECTS_USER}:@SANDBOX_GROUP@"
readonly SECRET_OWNER="${PROJECTS_USER}:${PROJECTS_GROUP}"

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
                    printf 'apply? [Y]/n '
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
            # Record the privileged mutation. A secret is the alarming case (WARNING,
            # via _notify_secret); an ordinary file or directory handback is routine
            # bookkeeping (INFO). Both name the path, owner change and mode change.
            if ${is_secret}; then
                _notify_secret "${canonical}" "${current_owner}" "${target_owner}" \
                    "${current_mode}" "${new_mode}"
            else
                ${is_dir} && _kind=directory || _kind=file
                ai_tools_log_info "handed back ${_kind} ${canonical} (owner ${current_owner} -> ${target_owner}, mode ${current_mode} -> ${new_mode})"
            fi
            exec {fd}<&-
            exit 0
        fi
    done
fi

# Not under any allowed directory, or not matched after exclusion check
exit 1
