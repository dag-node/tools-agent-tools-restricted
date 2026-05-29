#!/usr/bin/env bash
# /usr/local/sbin/ai-tools-chown
# Restores xd:ai-tools ownership on files created or overwritten by Claude
# Code. Called by the PostToolUse hook via sudo (ai-tools -> root).
#
# Only operates on files under a directory listed in the allowlist, so
# secrets or sensitive files outside approved project paths cannot have
# their ownership silently changed.
#
# Allowlist: /home/xd/.config/ai-tools/allowed-projects
#   One absolute directory path per line; lines starting with # are ignored.
#   Owned xd:xd 600 -- ai-tools cannot read or modify it directly.
#   Root reads it here on ai-tools' behalf.
#
# Sudoers rule (in /etc/sudoers.d/ai-tools-claude):
#   ai-tools ALL=(root) NOPASSWD: /usr/local/sbin/ai-tools-chown
#
# Deploy:
#   sudo install -o root -g root -m 755 \
#       scripts/ai-tools-chown.sh /usr/local/sbin/ai-tools-chown

set -euo pipefail

readonly TARGET="${1:?usage: ai-tools-chown <absolute-path>}"
readonly ALLOWLIST="/home/xd/.config/ai-tools/allowed-projects"
readonly OWNER="xd:ai-tools"

# No allowlist -- do nothing silently (hook skips this call when no allowlist exists)
[[ -f "${ALLOWLIST}" ]] || exit 0

# Resolve to canonical path to block symlink traversal
canonical="$(realpath -e "${TARGET}" 2>/dev/null)" || exit 0

while IFS= read -r entry || [[ -n "${entry}" ]]; do
    [[ -z "${entry}" || "${entry}" == '#'* ]] && continue
    dir="$(realpath -e "${entry}" 2>/dev/null)" || continue
    if [[ "${canonical}" == "${dir}" || "${canonical}" == "${dir}/"* ]]; then
        exec /usr/bin/chown "${OWNER}" "${canonical}"
    fi
done < "${ALLOWLIST}"

# Target is outside every approved directory -- exit non-zero but silently.
# The hook uses "|| true" so this does not interrupt Claude Code.
exit 1
