#!/usr/bin/env bash
# tests/boundary/access.sh
# Boundary: what the sandbox account can and cannot actually reach at runtime, probed AS the
# agent (runuser -u ai-tools). Each check names the threat its boundary prevents. "can"
# checks confirm access the sandbox needs to function; "cannot" checks confirm control-plane
# integrity and secret isolation. Non-destructive (test -r/-w/-x); the one unlink attempt
# targets a DECOY file (projects-user-owned, in the sticky .claude dir) so real control-plane
# files are never at risk. Run as root via sudo; drops to the agent per check.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

section "Sandbox access boundaries (run as the agent)"

if ! command -v runuser >/dev/null; then
    skip "sandbox access boundaries" "runuser not available"; finish; exit
fi

# Config dir traversal: the allowlist and secret-pattern config live under
# ~/.config/ai-tools (700). If the agent could traverse it, it could read the allowlist,
# read secret-patterns to learn what triggers quarantine, or forge entries -- all via plain
# file I/O, no sudo.
confdir="${PROJECTS_HOME}/.config/ai-tools"
if ! runuser -u "${SANDBOX_USER}" -- test -x "${confdir}" 2>/dev/null; then
    pass "cannot traverse ${confdir} (700 ${PROJECTS_USER}:${PROJECTS_GROUP}): allowlist + secret config unreachable to agent"
else
    fail "can traverse ${confdir} -- agent could read/tamper with the allowlist or secret-pattern config"
fi

# Secret-pattern library (640 root:root) defines what filenames trigger quarantine. The lib
# dir (750 root:ai-tools) is traversable, but the file's group is root, so traversal does not
# imply read. If readable, the agent could route secrets through a name not in the list.
splib=/usr/local/lib/ai-tools/secret-patterns.lib.sh
if ! runuser -u "${SANDBOX_USER}" -- test -r "${splib}" 2>/dev/null; then
    pass "cannot read ${splib} (640 root:root): secret classifier is opaque to the agent"
else
    fail "can read ${splib} -- agent can inspect the secret-pattern matcher and avoid triggering it"
fi

# Prune-dir library (640 root:ai-tools) is sourced by session-hook.sh while it runs AS the
# agent. Group read is intentional and required; the content is not sensitive.
pdlib=/usr/local/lib/ai-tools/prune-dirs.lib.sh
if runuser -u "${SANDBOX_USER}" -- test -r "${pdlib}" 2>/dev/null; then
    pass "can read ${pdlib} (640 root:ai-tools): required by session-hook.sh at runtime"
else
    fail "cannot read ${pdlib} -- session-hook.sh will fail to source the prune list"
fi

# /usr/local/sbin/ai-tools (750 root:root) holds the root helpers. Listing it lets the agent
# enumerate helper names and probe for discrepancies against what sudoers authorises.
sbindir=/usr/local/sbin/ai-tools
if ! runuser -u "${SANDBOX_USER}" -- test -r "${sbindir}" 2>/dev/null; then
    pass "cannot list ${sbindir} (750 root:root): helper names not enumerable by agent"
else
    fail "can list ${sbindir} -- agent can enumerate root helper names"
fi

# settings.json (640) declares the hooks and the permissions allow/deny lists. Write access
# would let the agent expand its tool scope, drop deny rules, or remove hooks -- no signal.
sf=/opt/ai-tools/.claude/settings.json
if ! runuser -u "${SANDBOX_USER}" -- test -w "${sf}" 2>/dev/null; then
    pass "cannot write ${sf} (640 no group-write): agent cannot extend its own allowed tool scope"
else
    fail "can write ${sf} -- agent could add permissions.allow rules, remove deny rules, or drop hooks"
fi

# Even without file write, a group-writer of the DIRECTORY could unlink+recreate the file.
# The sticky bit on .claude (3770) forbids that: you can only unlink a file you own OR in a
# dir you own; the agent owns neither. Tested with a DECOY (same ownership, same dir).
_decoy="$(mktemp /opt/ai-tools/.claude/.test_sticky_XXXXXX)"
chown "${PROJECTS_USER}:${SANDBOX_GROUP}" "${_decoy}"
chmod 640 "${_decoy}"
_cleanup+=("${_decoy}")
runuser -u "${SANDBOX_USER}" -- rm -f "${_decoy}" 2>/dev/null || true
if [[ -e "${_decoy}" ]]; then
    pass "sticky .claude: agent cannot unlink ${PROJECTS_USER}-owned files (replacement attack blocked)"
else
    fail "sticky .claude FAILED: agent deleted a ${PROJECTS_USER}-owned file -- settings.json and hooks can be replaced"
fi

# post-tool-hook.sh (750) fires after every Write/Edit. Overwriting it with an empty script
# would skip handback and secret quarantine for the rest of the session.
hook=/opt/ai-tools/.claude/post-tool-hook.sh
if ! runuser -u "${SANDBOX_USER}" -- test -w "${hook}" 2>/dev/null; then
    pass "cannot write ${hook} (750 no group-write): hand-back and quarantine hooks protected"
else
    fail "can write ${hook} -- agent could empty the hook and disable hand-back / secret quarantine"
fi

# session-hook.sh (750) runs the Stop sweep and SessionStart reclaim. Overwriting it would
# leave agent-owned files in the tree and skip setgid normalisation.
shook=/opt/ai-tools/.claude/session-hook.sh
if ! runuser -u "${SANDBOX_USER}" -- test -w "${shook}" 2>/dev/null; then
    pass "cannot write ${shook} (750 no group-write): stop-sweep and session-start protected"
else
    fail "can write ${shook} -- agent could disable the stop-sweep or session-start reclaim"
fi

# nvm-update.sh (550) is run by the daily timer AS the projects user. Injection here executes
# arbitrary commands in the projects user's context on the next timer fire -- persistent.
updater=/opt/ai-tools/bin/nvm-update.sh
if ! runuser -u "${SANDBOX_USER}" -- test -w "${updater}" 2>/dev/null; then
    pass "cannot write ${updater} (550 no group-write): scheduled updater protected from code injection"
else
    fail "can write ${updater} -- agent could inject commands run as ${PROJECTS_USER} by the daily timer"
fi

# Hooks must remain agent-executable, or Claude Code silently skips them and the entire
# hand-back / quarantine system stops with no error.
if runuser -u "${SANDBOX_USER}" -- test -x "${hook}" 2>/dev/null; then
    pass "can execute ${hook} (750 group-exec): PostToolUse hook will fire"
else
    fail "cannot execute ${hook} -- hook will be silently skipped by Claude Code"
fi
if runuser -u "${SANDBOX_USER}" -- test -x "${shook}" 2>/dev/null; then
    pass "can execute ${shook} (750 group-exec): Stop and SessionStart hooks will fire"
else
    fail "cannot execute ${shook} -- stop-sweep / session-start silently skipped"
fi

finish
