#!/usr/bin/env bash
# tests/unit/control-plane.sh
# Unit test for the control-plane re-own manifest (control-plane.lib.sh), the single source that
# ai-tools-enroll (step 5 and the --reassert an RPM %posttrans runs) and install.sh share to lock
# the /opt/ai-tools control plane to the operator. Hermetic: it sources the deployed lib against a
# /tmp fixture tree via the AI_TOOLS_CONTROL_PLANE_HOME root-only test hook, then asserts the
# security boundary -- each directory's mode, control files chowned but NOT re-moded, the launcher
# symlink's LINK (not its target) re-owned, the group-writable state file at 0460, and the
# agent-owned subtrees and .git left untouched (a manifest edit that re-owned .git would expose
# committed blobs to the agent). Run as root via sudo (needed to set fixture ownership).

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly LIB="/usr/local/lib/ai-tools/control-plane.lib.sh"
section "control-plane re-own manifest (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "control-plane re-own" "library not readable at ${LIB}"; finish; exit
fi

mktestdir
CP="${TESTDIR}/opt-ai-tools"
mkdir -p "${CP}"/{bin,.claude,.nvm,.cache,.local,.npm,.git}

# Control files: content mode 640, which reown must PRESERVE -- it chowns these, never chmods them.
readonly CP_TEST_FILES=(
    bin/claude-run bin/nvm-update.sh
    .claude/settings.json .claude/post-tool-hook.sh .claude/session-hook.sh
    .gitconfig .gitignore
)
for f in "${CP_TEST_FILES[@]}"; do
    : > "${CP}/${f}"; chmod 640 "${CP}/${f}"
done
# Group-writable state file: reown re-modes it to 0460.
: > "${CP}/.claude.json"; chmod 600 "${CP}/.claude.json"
# Launcher symlink -> a sentinel target NOT in the manifest. reown must chown the LINK (chown -h)
# and leave the target's ownership untouched.
: > "${CP}/symlink-target-sentinel"; chmod 640 "${CP}/symlink-target-sentinel"
ln -s symlink-target-sentinel "${CP}/bin/claude"
# Agent-owned subtrees + .git: sentinel mode 0700; reown must not touch them.
chmod 0700 "${CP}/.nvm" "${CP}/.cache" "${CP}/.local" "${CP}/.npm" "${CP}/.git"

# Start the whole tree as the package's neutral root:root placeholder, then re-own it.
chown -R root:root "${CP}"

# Source the manifest pointed at the fixture, then re-own to the harness's projects user + the
# sandbox group (the same globals enroll/install set in production).
export AI_TOOLS_CONTROL_PLANE_HOME="${CP}"
# shellcheck source=/dev/null
source "${LIB}"
reown_control_plane

# Boundary modes on the home and its locked / setgid+sticky directories.
check_file "${CP}"         "${PROJECTS_USER}" "${SANDBOX_GROUP}" 2750
check_file "${CP}/bin"     "${PROJECTS_USER}" "${SANDBOX_GROUP}" 550
check_file "${CP}/.claude" "${PROJECTS_USER}" "${SANDBOX_GROUP}" 3770

# Control files: owner changed to the operator, content mode 640 preserved.
for f in "${CP_TEST_FILES[@]}"; do
    check_file "${CP}/${f}" "${PROJECTS_USER}" "${SANDBOX_GROUP}" 640
done

# Group-writable state file: re-owned and re-moded to 0460.
check_file "${CP}/.claude.json" "${PROJECTS_USER}" "${SANDBOX_GROUP}" 460

# Launcher symlink: the LINK is re-owned (find does not dereference), the target is untouched.
link_owner="$(find "${CP}/bin/claude" -maxdepth 0 -printf '%u\n')"
if [[ "${link_owner}" == "${PROJECTS_USER}" ]]; then
    pass "launcher symlink: the link is re-owned to ${PROJECTS_USER} (target untouched)"
else
    fail "launcher symlink: link owner ${link_owner}, expected ${PROJECTS_USER}"
fi
check_file "${CP}/symlink-target-sentinel" root root 640

# Agent-owned subtrees and the operator-private .git: left exactly as they were (root:root 0700).
for d in .nvm .cache .local .npm .git; do
    check_file "${CP}/${d}" root root 700
done

finish
