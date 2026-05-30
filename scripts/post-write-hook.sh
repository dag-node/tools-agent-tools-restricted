#!/usr/bin/env bash
# /opt/ai-tools/.claude/post-write-hook.sh
# PostToolUse hook for Write|Edit tools. Restores @INSTALL_USER@:ai-tools ownership
# on files Claude Code rewrote via atomic rename (which stamps the writer's UID).
#
# Runs as ai-tools. It deliberately does NOT pre-check the approved-projects
# allowlist: that file lives under @INSTALL_HOME@/.config (mode 700, owned
# @INSTALL_USER@), which ai-tools cannot traverse -- so a `[[ -f ALLOWLIST ]]`
# test here is always false and would make the hook a permanent no-op. The
# allowlist is enforced authoritatively by ai-tools-chown, which runs as root
# and CAN read it (and is the real security boundary regardless).
#
# This hook only decides, cheaply and as ai-tools, whether a sudo call is even
# worth making. It exits early -- without calling sudo -- when:
#   - the tool input contains no file path
#   - the file is already owned @INSTALL_USER@:ai-tools
#
# The sudo call (and the PAM session it generates) is therefore only made when
# ownership actually needs to change. ai-tools-chown also strips world bits
# (chmod o=) in the same root call, correcting the execute bit that the Write
# tool sets on shebang files regardless of umask.
#
# Deploy: sudo install -o ai-tools -g ai-tools -m 750 \
#             scripts/post-write-hook.sh /opt/ai-tools/.claude/post-write-hook.sh

set -euo pipefail

readonly EXPECTED_OWNER="@INSTALL_USER@:ai-tools"

# Extract file path from hook stdin JSON
file="$(jq -r '.tool_input.file_path // empty' 2>/dev/null)" || exit 0
[[ -n "${file}" ]] || exit 0

# Skip when ownership is already correct (avoids a sudo/PAM session per write)
current="$(stat -c '%U:%G' "${file}" 2>/dev/null)" || exit 0
[[ "${current}" == "${EXPECTED_OWNER}" ]] && exit 0

# Delegate to the root-owned validator -- it checks the allowlist (as root,
# which can read it), chowns + strips world bits, and for secret-named files
# revokes ai-tools access and prints a NOTICE. Let that stderr through (do NOT
# redirect to /dev/null) so Claude Code surfaces the NOTICE in the session.
sudo /usr/local/sbin/ai-tools-chown "${file}" || true
