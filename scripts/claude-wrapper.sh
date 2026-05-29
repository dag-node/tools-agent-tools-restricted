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

# Test the symlink itself with -L, NOT -e: -e dereferences the full chain
# (bin/claude -> versioned bin/claude -> .../claude-code/bin/claude.exe), and the
# package dir claude-code/ is mode 700 owned ai-tools. The invoking user cannot
# stat the final target (EACCES), so -e would report "not found" on a perfectly
# valid link. -L checks link existence without traversing past the first hop;
# the readlink + string validation below handle correctness, and the binary is
# only ever reached via sudo as ai-tools.
if [[ ! -L "${CLAUDE_LINK}" ]]; then
    echo "ERROR: claude symlink not found at ${CLAUDE_LINK}" >&2
    echo "       Run: systemctl --user start nvm-update.service" >&2
    exit 1
fi

# Resolve the stable symlink ONE hop -- it points directly at the versioned
# .../node/<ver>/bin/claude, which is exactly the path the sudoers rule matches.
#
# Do NOT use realpath (or readlink -f): the versioned bin/claude is itself an
# npm symlink into the package (-> .../claude-code/bin/claude.exe). Following
# it fully would (a) yield a path the sudoers NOPASSWD rule cannot match, so
# sudo would deny/prompt, and (b) require traversing the package directory
# (mode 700, owned ai-tools), which the invoking user cannot enter -- realpath
# would fail with EACCES and, under set -e, abort the wrapper with no message.
CLAUDE_REAL="$(readlink -- "${CLAUDE_LINK}")" \
    || { echo "ERROR: ${CLAUDE_LINK} is not a symlink -- reinstall or run nvm-update.sh" >&2; exit 1; }

# Safety: the target must be an absolute, ..-free path under the ai-tools nvm
# tree matching the versioned binary the sudoers rule allows. This blocks
# path-injection if the symlink is tampered with, using only string checks so
# no filesystem traversal beyond the symlink itself is required.
case "${CLAUDE_REAL}" in
    "${AI_TOOLS_NVM_DIR}/versions/node/"*/bin/claude) ;;
    *) echo "ERROR: resolved claude path '${CLAUDE_REAL}' is not an approved ai-tools binary" >&2
       exit 1 ;;
esac
if [[ "${CLAUDE_REAL}" == *"/../"* ]]; then
    echo "ERROR: resolved claude path '${CLAUDE_REAL}' contains parent-directory references" >&2
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
