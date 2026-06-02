#!/usr/bin/env bash
# /opt/ai-tools/.claude/post-tool-hook.sh
# PostToolUse hook for Write|Edit tools. Restores @PROJECTS_USER@:ai-tools ownership
# on files Claude Code rewrote via atomic rename (which stamps the writer's UID).
#
# Runs as ai-tools. It deliberately does NOT pre-check the approved-projects
# allowlist: that file lives under @PROJECTS_HOME@/.config (mode 700, owned
# @PROJECTS_USER@), which ai-tools cannot traverse -- so a `[[ -f ALLOWLIST ]]`
# test here is always false and would make the hook a permanent no-op. The
# allowlist is enforced authoritatively by ai-tools-chown, which runs as root
# and CAN read it (and is the real security boundary regardless).
#
# This hook only decides, cheaply and as ai-tools, whether a sudo call is even
# worth making. It exits early -- without calling sudo -- when:
#   - the tool input contains no file path
#   - the file is already owned @PROJECTS_USER@:ai-tools
#
# The sudo call (and the PAM session it generates) is therefore only made when
# ownership actually needs to change. ai-tools-chown also strips world bits
# (chmod o=) in the same root call, correcting the execute bit that the Write
# tool sets on shebang files regardless of umask.
#
# Deploy: sudo install -o ai-tools -g ai-tools -m 750 \
#             scripts/post-tool-hook.sh /opt/ai-tools/.claude/post-tool-hook.sh

set -euo pipefail

readonly EXPECTED_OWNER="@PROJECTS_USER@:@SANDBOX_GROUP@"

# Extract file path from hook stdin JSON
file="$(jq -r '.tool_input.file_path // empty' 2>/dev/null)" || exit 0
[[ -n "${file}" ]] || exit 0

# Hand the written file back. Skip the sudo/PAM session when ownership is already
# correct. Delegate to the root-owned validator -- it checks the allowlist (as
# root, which can read it), chowns + strips world bits, and for secret-named
# files revokes ai-tools access and prints a NOTICE. Let that stderr through (do
# NOT redirect to /dev/null) so Claude Code surfaces the NOTICE in the session.
current="$(stat -c '%U:%G' "${file}" 2>/dev/null || true)"
if [[ -n "${current}" && "${current}" != "${EXPECTED_OWNER}" ]]; then
    sudo /usr/local/sbin/ai-tools/chown "${file}" || true
fi

# Normalize any directories the write just created. Claude Code's Write tool
# makes missing parent dirs owned by ai-tools at the agent's umask -- often
# world-traversable and never handed back. Walk upward from the file's directory
# and hand back each ai-tools-owned dir, stopping at the first dir the agent does
# NOT own: that is the pre-existing user tree (the project root and above, which
# is <you>-owned), so the walk never leaves the project. The common case -- writing
# into an existing dir -- breaks on the first iteration with no sudo call.
# ai-tools-chown re-validates each path against the allowlist as root.
dir="$(dirname -- "${file}")"
while [[ "${dir}" != "/" && "${dir}" != "." ]]; do
    [[ "$(stat -c '%U' "${dir}" 2>/dev/null || true)" == "@SANDBOX_USER@" ]] || break
    sudo /usr/local/sbin/ai-tools/chown "${dir}" || true
    dir="$(dirname -- "${dir}")"
done
