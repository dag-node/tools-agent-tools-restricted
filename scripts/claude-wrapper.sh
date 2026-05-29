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

# Allowlist guard: Claude Code only runs in explicitly approved directories.
# Create ~/.config/ai-tools/allowed-projects (one path per line) before use.
ALLOWLIST="${HOME}/.config/ai-tools/allowed-projects"
if [[ ! -f "${ALLOWLIST}" ]]; then
    echo "claude: approved-projects allowlist not found" >&2
    printf 'claude: create %s and add project directories\n' "${ALLOWLIST}" >&2
    exit 1
fi
cwd="$(realpath -e "${PWD}" 2>/dev/null)" \
    || { echo "claude: cannot resolve working directory" >&2; exit 1; }
approved=false
while IFS= read -r entry || [[ -n "${entry}" ]]; do
    [[ -z "${entry}" || "${entry}" == '#'* ]] && continue
    dir="$(realpath -e "${entry}" 2>/dev/null)" || continue
    if [[ "${cwd}" == "${dir}" || "${cwd}" == "${dir}/"* ]]; then
        approved=true
        break
    fi
done < "${ALLOWLIST}"
if [[ "${approved}" != true ]]; then
    echo "claude: $(pwd): not in approved projects list" >&2
    printf 'claude: add it to %s to enable Claude Code here\n' "${ALLOWLIST}" >&2
    exit 1
fi

exec sudo -u ai-tools -g ai-tools -- "${CLAUDE_REAL}" "$@"
