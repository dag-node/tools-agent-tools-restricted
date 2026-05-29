#!/usr/bin/env bash
# ~/.local/bin/claude
# Sandboxed claude wrapper. Resolves the real nvm-versioned claude binary,
# then re-executes it as the ai-tools user via sudo.
# Placed before nvm shims in PATH so it shadows the direct binary.

set -euo pipefail
IFS=$'\n\t'

readonly WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Find the real claude binary, excluding this wrapper's own directory
# ---------------------------------------------------------------------------
CLAUDE_BIN="$(
    PATH="$(
        printf '%s' "${PATH}" \
            | tr ':' '\n' \
            | grep -v "^${WRAPPER_DIR}$" \
            | tr '\n' ':' \
            | sed 's/:$//'
    )"
    command -v claude 2>/dev/null || true
)"

if [[ -z "${CLAUDE_BIN}" ]]; then
    echo "ERROR: claude not found in PATH (excluding ${WRAPPER_DIR})" >&2
    exit 1
fi

# Resolve symlinks -- sudoers matches the real versioned path, not nvm symlinks
CLAUDE_REAL="$(realpath "${CLAUDE_BIN}")"

# Sanity: confirm resolved path is under ~/.nvm
readonly NVM_DIR="${NVM_DIR:-${HOME}/.nvm}"
if [[ "${CLAUDE_REAL}" != "${NVM_DIR}/"* ]]; then
    echo "ERROR: resolved claude path '${CLAUDE_REAL}' is outside NVM_DIR" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Re-execute as ai-tools
# ---------------------------------------------------------------------------
exec sudo -u ai-tools -g ai-tools -- "${CLAUDE_REAL}" "$@"
