#!/usr/bin/env bash
# ~/.local/bin/claude
# Sandboxed claude wrapper. Resolves the current versioned claude binary
# under /opt/ai-tools via a stable symlink maintained by nvm-update.sh,
# then re-executes it as the ai-tools user via sudo.
# Placed before nvm shims in PATH so it shadows any nvm-managed claude.

set -euo pipefail
IFS=$'\n\t'

readonly AI_TOOLS_NVM_DIR="/opt/ai-tools/.nvm"
readonly CLAUDE_LINK="/opt/ai-tools/bin/claude"

if [[ ! -e "${CLAUDE_LINK}" ]]; then
    echo "ERROR: claude symlink not found at ${CLAUDE_LINK}" >&2
    echo "       Run: systemctl --user start nvm-update.service" >&2
    exit 1
fi

# Resolve symlink -- sudoers matches the real versioned path, not the symlink
CLAUDE_REAL="$(realpath "${CLAUDE_LINK}")"

# Safety: confirm resolved path is under the ai-tools nvm directory
if [[ "${CLAUDE_REAL}" != "${AI_TOOLS_NVM_DIR}/"* ]]; then
    echo "ERROR: resolved claude path '${CLAUDE_REAL}' is outside ${AI_TOOLS_NVM_DIR}" >&2
    exit 1
fi

exec sudo -u ai-tools -g ai-tools -- "${CLAUDE_REAL}" "$@"
