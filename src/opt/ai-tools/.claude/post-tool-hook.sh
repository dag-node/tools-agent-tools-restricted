#!/usr/bin/env bash
# /opt/ai-tools/.claude/post-tool-hook.sh
# PostToolUse hook for Write|Edit tools. Restores operator:ai-tools ownership
# on files Claude Code rewrote via atomic rename (which stamps the writer's UID).
#
# Runs as ai-tools. It deliberately does NOT pre-check the approved-projects
# allowlist: that file lives under the operator's home .config (mode 700, owned by
# the operator), which ai-tools cannot traverse -- so a `[[ -f ALLOWLIST ]]`
# test here is always false and would make the hook a permanent no-op. The
# allowlist is enforced authoritatively by ai-tools-chown, which runs as root
# and CAN read it (and is the real security boundary regardless).
#
# This hook only decides, cheaply and as ai-tools, whether a handback call is
# even worth making. It exits early -- without calling the client -- when:
#   - the tool input contains no file path
#   - the file is not owned by ai-tools (already handed back, or never agent-written)
#
# Ownership handback is delegated to the socket privilege bridge
# (/usr/local/bin/ai-tools-handback-client), which connects to
# ai-tools-handback.socket (a root daemon) and sends a CHOWN request.  This
# replaces the former `sudo ai-tools-chown` calls, which fail silently under
# NNP (PR_SET_NO_NEW_PRIVS, forced by RestrictNamespaces=yes in the session
# service unit) because NNP drops sudo's SUID bit before it can switch uid.
#
# Deploy: sudo install -o ai-tools -g ai-tools -m 750 \
#             src/opt/ai-tools/.claude/post-tool-hook.sh /opt/ai-tools/.claude/post-tool-hook.sh

set -euo pipefail

# Shared leveled logger -- journald only (this hook runs as the agent and cannot
# write the root-only /var/log/ai-tools files; the sudo helper it calls records the
# actual file mutation there). Best-effort no-op fallback if the lib is missing.
AI_TOOLS_LOG_TAG="ai-tools-hook"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=/dev/null
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log() { :; }; ai_tools_log_debug() { :; }; ai_tools_log_info() { :; }
    ai_tools_log_warn() { :; }; ai_tools_log_error() { :; }
fi

# Extract file path from hook stdin JSON
file="$(jq -r '.tool_input.file_path // empty' 2>/dev/null)" || exit 0
[[ -n "${file}" ]] || exit 0

# Hand the written file back. Call only for a path the agent itself wrote -- one currently
# owned by @SANDBOX_USER@ -- which is exactly the set ai-tools-chown will act on (its own
# owner guard) and the same signal the parent-dir walk below uses, so an already-handed-back
# file (operator-owned, or a quarantined secret) makes no socket call. Delegate to the
# root-owned validator: it checks the allowlist (as root, which can read it), chowns + strips
# world bits, and for secret-named files revokes ai-tools access and prints a NOTICE. Let that
# stderr through (do NOT redirect to /dev/null) so Claude Code surfaces the NOTICE in the session.
current_user="$(stat -c '%U' "${file}" 2>/dev/null || true)"
if [[ "${current_user}" == "@SANDBOX_USER@" ]]; then
    ai_tools_log_debug "PostToolUse handing back ${file} (owner ${current_user})"
    /usr/local/bin/ai-tools-handback-client CHOWN "${file}" || true
fi

# Normalize any directories the write just created. Claude Code's Write tool
# makes missing parent dirs owned by ai-tools at the agent's umask -- often
# world-traversable and never handed back. Walk upward from the file's directory
# and hand back each ai-tools-owned dir, stopping at the first dir the agent does
# NOT own: that is the pre-existing user tree (the project root and above, which
# is <you>-owned), so the walk never leaves the project. The common case -- writing
# into an existing dir -- breaks on the first iteration with no socket call.
# ai-tools-chown re-validates each path against the allowlist as root.
dir="$(dirname -- "${file}")"
while [[ "${dir}" != "/" && "${dir}" != "." ]]; do
    [[ "$(stat -c '%U' "${dir}" 2>/dev/null || true)" == "@SANDBOX_USER@" ]] || break
    /usr/local/bin/ai-tools-handback-client CHOWN "${dir}" || true
    dir="$(dirname -- "${dir}")"
done
