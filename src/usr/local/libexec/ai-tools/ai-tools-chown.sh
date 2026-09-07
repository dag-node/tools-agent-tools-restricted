#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/libexec/ai-tools/ai-tools-chown
# Restores operator:ai-tools ownership on files and directories an agent session
# created or overwrote. Invoked as root by the ai-tools-handback daemon
# (ai_tools_handback_t) when a session's hooks, or ai-tools-run's session-end sweep
# for an agent that declares none, send a CHOWN request over the handback socket.
# Accepts a single regular-file or directory target; for directories it strips world
# bits while preserving group rwx so the agent can keep working in a dir it created.
# An interactive invocation confirms per path; --yes skips that for a batch caller
# (ai-tools-reclaim) that already confirmed its whole set.
#
# Reads the operator's allowed-projects allowlist for allow and exclude rules (its path is
# derived from the operator identity in /etc/ai-tools/operator.conf). That file is owned by
# the operator 600 -- root reads it here on ai-tools' behalf.
#
# Invocation: the handback socket's CHOWN verb (ai-tools-handback daemon, root).
#   Not a sudo target -- ai-tools has no sudo rights (the session runs under NNP,
#   which drops sudo's SUID bit).
#
# Installed 750 root:root, so only root runs it. Deploying from a checkout:
# docs/install-from-source.md.

set -euo pipefail

# Args: an optional --yes flag (anywhere) skips the interactive per-path confirmation --
# a batch caller (ai-tools-reclaim) that already took ONE confirmation for the whole set
# passes it so a long walk does not re-ask per path. The remaining argument is the path.
ASSUME_YES=false
TARGET=""
for arg in "$@"; do
    case "${arg}" in
        -y|--yes) ASSUME_YES=true ;;
        -*) printf 'ai-tools-chown: unknown option: %s\n' "${arg}" >&2; exit 2 ;;
        *)  if [[ -z "${TARGET}" ]]; then
                TARGET="${arg}"
            else
                printf 'ai-tools-chown: too many arguments\n' >&2; exit 2
            fi ;;
    esac
done
[[ -n "${TARGET}" ]] \
    || { printf 'usage: ai-tools-chown [-y|--yes] <absolute-path>\n' >&2; exit 2; }
readonly TARGET ASSUME_YES

# Operator-identity resolver (operator.lib.sh): resolves the operator that owns a path. A missing
# lib leaves ai_tools_resolve_owner a fail-closed stub, so the path is left ai-tools-owned rather
# than handed back unclassified.
readonly OPERATOR_LIB="/usr/local/lib/ai-tools/operator.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/operator.lib.sh
source "${OPERATOR_LIB}" 2>/dev/null || ai_tools_resolve_owner() { return 1; }

# Shared leveled logger: journald (always) + the root-only file /var/log/ai-tools/chown.log.
# Best-effort -- a no-op fallback keeps the helper working if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-chown"
AI_TOOLS_LOG_FILE="chown.log"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/log.lib.sh
# Required, fail-closed: this helper prints agent-named paths to stderr and the log, so it
# needs ai_tools_log_sanitize -- a missing logger must refuse, not emit an agent path raw.
if ! source "${LOG_LIB}"; then
    printf 'ai-tools-chown: FATAL: cannot source %s\n' "${LOG_LIB}" >&2
    exit 1
fi

# Shared secret-name matcher, sourced (not executed) so this helper and ai-tools-lockdown
# classify basenames by the SAME patterns from the SAME config file (the operator's
# secret-patterns, resolved via the operator identity). Required and fail-closed: exiting
# non-zero here skips this path's handback, which secret-handling.rule.md states is the safe
# outcome -- the path stays ai-tools-owned instead of being handed back unclassified.
readonly SECRET_PATTERNS_LIB="/usr/local/lib/ai-tools/secret-patterns.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/secret-patterns.lib.sh
if ! source "${SECRET_PATTERNS_LIB}"; then
    printf 'ai-tools-chown: FATAL: cannot source %s\n' "${SECRET_PATTERNS_LIB}" >&2
    exit 1
fi

# Which paths the operator sealed, and what may be stripped from one (owner-only.lib.sh, the
# reference for the seal and the strip alike). Required and fail-closed like safe-paths.lib.sh:
# an unusable library must not leave a quarantined secret carrying the residue that would
# re-expose it.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/owner-only.lib.sh
source /usr/local/lib/ai-tools/owner-only.lib.sh
if ! declare -F ai_tools_strip_sandbox_residue >/dev/null 2>&1; then
    printf 'ai-tools-chown: FATAL: owner-only.lib.sh defines no residue strip\n' >&2
    exit 3
fi

# Protected-paths backstop (safe-paths.lib.sh): refuse to act on a system directory even
# when the allowlist includes it. See safe-paths.rule.md.
readonly SAFE_PATHS_LIB="/usr/local/lib/ai-tools/safe-paths.lib.sh"
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/safe-paths.lib.sh
source "${SAFE_PATHS_LIB}"

# Shared config grammar (ai_tools_conf_path_entry; see conf.lib.sh), which reads the
# allowlist this helper gates every path on. REQUIRED like safe-paths.lib.sh: the bare source
# under set -e aborts if it is missing, rather than leaving a parser that does not match any name and
# silently declines every hand-back. Include-guarded, so a second source is a no-op.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/conf.lib.sh
source /usr/local/lib/ai-tools/conf.lib.sh

# Shared yes/no prompt (ai_tools_msg_confirm; see msg.lib.sh). REQUIRED like
# safe-paths.lib.sh: the bare source under set -e aborts if it is missing -- a valid
# install ships it, so there is no fallback. Include-guarded, so this is a no-op when
# safe-paths.lib.sh above already loaded it.
# shellcheck source=SCRIPTDIR/../../lib/ai-tools/msg.lib.sh
source /usr/local/lib/ai-tools/msg.lib.sh
# Fixed 80-column frame for any box this helper renders, aligned with the CLI's.
export AI_TOOLS_MSG_FULLWIDTH=1

# _notify_secret: emit a one-line NOTICE that a secret-named file was written and
# ai-tools' read access revoked, to stderr (the PostToolUse hook relays it into the
# session) and -- at WARNING level -- to journald + the root-owned chown.log. log.lib.sh
# wraps each sink in `|| true`, so a sink that cannot be written never blocks the NOTICE.
# args:  path  old_owner  new_owner  old_mode  new_mode
_notify_secret() {
    local path="$1" old_owner="$2" new_owner="$3" old_mode="$4" new_mode="$5" msg
    path="$(ai_tools_log_sanitize "${path}")"   # agent-named path -> stderr + log: safe display
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
# The two owners the branches below choose between: OWNER is the shared group an ordinary file
# returns to, SECRET_OWNER the operator's own private group a quarantined secret goes to. What
# each one grants and what it deliberately leaves the agent is in secret-handling.rule.md.
ai_tools_resolve_owner "${canonical}" || exit 0
readonly ALLOWLIST="${AI_TOOLS_RESOLVED_ALLOWLIST}"
readonly OWNER="${PROJECTS_USER}:@SANDBOX_GROUP@"
readonly SECRET_OWNER="${PROJECTS_USER}:${PROJECTS_GROUP}"

# Classify the basename against the shared secret-name patterns, which the library reads
# from the operator's own config (secret-handling.rule.md covers the set and how an
# operator narrows it). A match sets is_secret, which selects the quarantine branch and
# the NOTICE further down.
is_secret=false
if ai_tools_is_secret_basename "$(basename "${canonical}")"; then
    is_secret=true
fi

declare -a allowed=()
declare -a excluded=()

while IFS= read -r entry || [[ -n "${entry}" ]]; do
    # One shared grammar (conf.lib.sh): whole-line and end-of-line comments, and quotes for a
    # path carrying a space or a literal `#`. A line that does not denote an entry is skipped.
    ai_tools_conf_path_entry "${entry}" || continue
    entry="${_ai_tools_conf_value}"
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

            # lstat (the GNU stat default), so a symlink is seen as itself and
            # refused along with the devices. A regular file must have nlink 1: a
            # freshly written file has one link, and a hardlink could point at a
            # sensitive file outside the tree. A directory legitimately has nlink >= 2
            # (its own '.' plus each child's '..'), so that guard is for files.
            read -r expect_ident nlink ftype \
                < <(stat -c '%d:%i %h %F' "${canonical}" 2>/dev/null) || exit 0
            is_dir=false
            case "${ftype}" in
                "regular file"|"regular empty file") [[ "${nlink}" -eq 1 ]] || exit 0 ;;
                "directory")                         is_dir=true ;;
                *)                                   exit 0 ;;
            esac
            # A directory is the agent's own workspace rather than a secret to
            # revoke: taking away access to a dir it must keep writing into would
            # break it.
            ${is_dir} && is_secret=false

            current_owner="$(stat -c '%U:%G' "${canonical}" 2>/dev/null)" || exit 0
            current_mode="$( stat -c '%a'    "${canonical}" 2>/dev/null)" || exit 0

            # The agent-written guard: act only on a path currently ai-tools-owned.
            # What that ownership signals and what an unowned path is spared are in
            # ownership-and-hooks.rule.md. The owner is read from the path string
            # here, which the pinned-inode re-check below makes race-safe: moving an
            # ai-tools-owned inode's user field takes root, which the agent lacks.
            [[ "${current_owner%%:*}" == "@SANDBOX_USER@" ]] || exit 0

            # Three targets, in this order: a directory, a secret-named file, then an
            # ordinary file split on OWNER-execute -- the only exec bit git records.
            # What each target hands back and why is in ownership-and-hooks.rule.md
            # (directories and ordinary files) and secret-handling.rule.md (secrets);
            # new_mode mirrors each chmod arithmetically for the report below.
            if ${is_dir}; then
                target_owner="${OWNER}"
                chmod_arg="g+rwx,o="
                new_mode="$(printf '%o' "$(( (8#${current_mode} | 070) & ~7 ))")"
            elif ${is_secret}; then
                target_owner="${SECRET_OWNER}"
                chmod_arg="go="
                new_mode="$(printf '%o' "$(( 8#${current_mode} & ~077 ))")"
            elif (( ( 8#${current_mode} >> 6 ) & 1 )); then
                target_owner="${OWNER}"        # owner executes -> genuine script, keep group r-x
                chmod_arg="o="
                new_mode="$(printf '%o' "$(( 8#${current_mode} & ~7 ))")"
            else
                target_owner="${OWNER}"        # data file -> also drop the stray group/mask execute
                chmod_arg="g-x,o="
                new_mode="$(printf '%o' "$(( 8#${current_mode} & ~7 & ~010 ))")"
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
            # the allowlist is the user's standing authorisation. --yes skips the
            # prompt for a batch caller that already confirmed the whole set.
            if ! ${ASSUME_YES} \
                    && { [[ -t 0 ]] || { [[ -c /dev/tty ]] && { : < /dev/tty; } 2>/dev/null; }; }; then
                {
                    printf '\nchown: %s\n' "$(ai_tools_log_sanitize "${canonical}")"
                    printf '  owner:  %s -> %s\n' "${current_owner}" "${target_owner}"
                    printf '%s\n' "${perm_info}"
                } > /dev/tty
                ai_tools_msg_confirm "Apply?" y || exit 0
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
            # chown/chmod follow the /proc magic symlink to the pinned inode, so both
            # act on the descriptor the checks above validated rather than on the name.
            /usr/bin/chown -- "${target_owner}" "/proc/self/fd/${fd}"
            /usr/bin/chmod -- "${chmod_arg}"    "/proc/self/fd/${fd}"
            # A quarantined secret is owner-only now, so strip the residue the mode only masks:
            # a file born in a claimed tree carries the project's inherited group ACL entry, and
            # `go=` leaves it in place, dormant (owner-only.lib.sh). Ordinary files keep theirs --
            # the agent is meant to go on co-writing those.
            # Every value handed to the strip is read from the PINNED inode, ${got_ftype}
            # included: the strip acts through that descriptor, so what describes it comes
            # from it. The pre-open ${ftype} is a second read of a path that may since have
            # been swapped, which the type check above keeps equal to this one.
            if ${is_secret} \
                    && read -r sec_grp sec_mode \
                        < <(stat -L -c '%G %a' "/proc/self/fd/${fd}" 2>/dev/null); then
                ai_tools_strip_sandbox_residue "${fd}" "${got_ftype}" "${sec_grp}" "${sec_mode}" \
                    "${PROJECTS_GROUP}" || true
            fi
            # Record the privileged mutation. A secret is the alarming case (WARNING,
            # via _notify_secret); an ordinary file or directory handback is routine
            # bookkeeping (INFO). Both name the path, owner change and mode change.
            if ${is_secret}; then
                _notify_secret "${canonical}" "${current_owner}" "${target_owner}" \
                    "${current_mode}" "${new_mode}"
            else
                ${is_dir} && _kind="directory" || _kind="file"
                ai_tools_log_info "handed back ${_kind} ${canonical} (owner ${current_owner} -> ${target_owner}, mode ${current_mode} -> ${new_mode})"
            fi
            exec {fd}<&-
            exit 0
        fi
    done
fi

# Not under any allowed directory, or not matched after exclusion check
exit 1
