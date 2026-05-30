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
# Ordinary files are chowned to OWNER (group ai-tools, readable by the agent).
# Secret-named files are chowned to SECRET_OWNER (the user's private group) with
# group+world bits stripped, so ai-tools -- neither owner nor group member --
# cannot read the contents. ai-tools is a group-writer on the project dir, not
# its owner, so it can still unlink/replace the path: this revokes read, not
# directory control.
readonly OWNER="@INSTALL_USER@:ai-tools"
readonly SECRET_OWNER="@INSTALL_USER@:@INSTALL_GROUP@"
readonly AUDIT_LOG="/var/log/ai-tools-chown.log"

# Emit a one-line NOTICE that a secret-named file was written and ai-tools access
# revoked. Written to stderr (the PostToolUse hook relays it into the session)
# and appended to a root-owned audit log; logging is best-effort and never blocks.
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

# Credential/secret basename patterns. A match no longer skips the file -- it is
# handed back like any other (chown + world-bit strip) but ALSO flagged via
# _notify_secret on the apply path, so the user is told whenever the agent wrote
# something secret-looking. Basename-safe globs only (deliberately no bare
# 'config' etc. that would flag innocuous files). Per-project secrets should be
# carved out with ! in the allowlist; that path still leaves ownership intact.
is_secret=false
_base="$(basename "${canonical}")"
for _pat in \
    '.env' '.env.*' '.environment' '.environment.*' \
    'secret' 'secret.*' '*.secret' 'secrets' 'secrets.*' \
    'credentials' 'credentials.*' \
    'id_rsa' 'id_dsa' 'id_ecdsa' 'id_ed25519' 'authorized_keys' '*.ppk' \
    '*.pem' '*.key' '*.priv' '*.p12' '*.pfx' '*.crt' '*.pkcs12' \
    '*.jks' '*.keystore' '*.p8' '*.asc' '*.gpg' \
    'kubeconfig' '.pgpass' '.git-credentials' '.dockercfg' '.htpasswd' \
    '.npmrc' '.pypirc' '.netrc'
do
    if [[ "${_base}" == ${_pat} ]]; then
        is_secret=true
        break
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

            # Secret-named files: hand to the user's private group and strip BOTH
            # group and world bits (go=), removing ai-tools' read access to the
            # contents. Ordinary files: keep group ai-tools readable, strip only
            # the world bits (o=).
            if ${is_secret}; then
                target_owner="${SECRET_OWNER}"
                chmod_arg="go="
                clear_mask=077
            else
                target_owner="${OWNER}"
                chmod_arg="o="
                clear_mask=007
            fi
            new_mode="$(printf '%o' "$(( 8#${current_mode} & ~(8#${clear_mask}) ))")"
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
