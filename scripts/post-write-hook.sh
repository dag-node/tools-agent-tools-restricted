#!/usr/bin/env bash
# /opt/ai-tools/.claude/post-write-hook.sh
# PostToolUse hook for Write|Edit tools. Restores @INSTALL_USER@:ai-tools ownership
# on files Claude Code rewrote via atomic rename (which stamps the writer's UID).
#
# Exits early -- without calling sudo -- when:
#   - the approved-projects allowlist does not exist
#   - the tool input contains no file path
#   - the file is already owned @INSTALL_USER@:ai-tools
#
# The sudo call (and the PAM session it generates) is therefore only made
# when ownership actually needs to change. ai-tools-chown also strips world
# bits (chmod o=) in the same root call, correcting the execute bit that the
# Write tool sets on shebang files regardless of umask.
#
# Deploy: sudo install -o ai-tools -g ai-tools -m 750 \
#             scripts/post-write-hook.sh /opt/ai-tools/.claude/post-write-hook.sh

set -euo pipefail

readonly ALLOWLIST="@INSTALL_HOME@/.config/ai-tools/allowed-projects"
readonly EXPECTED_OWNER="@INSTALL_USER@:ai-tools"

# No allowlist -- do nothing (closed by default)
[[ -f "${ALLOWLIST}" ]] || exit 0

# Extract file path from hook stdin JSON
file="$(jq -r '.tool_input.file_path // empty' 2>/dev/null)" || exit 0
[[ -n "${file}" ]] || exit 0

# Skip when ownership is already correct
current="$(stat -c '%U:%G' "${file}" 2>/dev/null)" || exit 0
[[ "${current}" == "${EXPECTED_OWNER}" ]] && exit 0

# Delegate to root-owned validator -- it checks the allowlist before chowning
sudo /usr/local/sbin/ai-tools-chown "${file}" 2>/dev/null || true
