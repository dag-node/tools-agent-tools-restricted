#!/usr/bin/env bash
# tests/integration/perms.sh
# Integration: deployed-artifact ownership/permissions and sudoers syntax. Asserts the
# installed control plane matches the security model -- root-owned helpers, the locked
# /opt/ai-tools/bin, the setgid+sticky .claude, agent-readable-but-not-writable hooks --
# and that the sudoers drop-in parses. Needs a completed install; run as root via sudo.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

section "File permissions"
check_file /usr/local/sbin/ai-tools/ai-tools-chown            root              root              750
check_file /usr/local/sbin/ai-tools/ai-tools-setgid           root              root              750
check_file /usr/local/sbin/ai-tools/ai-tools-setfacl          root              root              750
check_file /usr/local/sbin/ai-tools/ai-tools-unclaim          root              root              750
check_file /usr/local/sbin/ai-tools/ai-tools-claude-symlink   root              root              750
check_file /usr/local/sbin/ai-tools/ai-tools-lockdown         root              root              750
# SELinux project-label helper: 750 root:root -- user-run via sudo, never by the agent (no
# SANDBOX_USER grant); same surface as lockdown.
check_file /usr/local/sbin/ai-tools/ai-tools-relabel          root              root              750
# Lib dir: root-owned, group ai-tools, 750 (no world). The agent enters via group to read
# the prune list, but has no write, so it cannot alter the rules.
check_file /usr/local/lib/ai-tools                            root              "${SANDBOX_GROUP}" 750
# Secret-pattern matcher: read only by the root helpers, so 640 root:root -- no group/world
# surface. The agent (group ai-tools) cannot read it.
check_file /usr/local/lib/ai-tools/secret-patterns.lib.sh     root              root              640
# Prune-dir list: also sourced by session-hook.sh (runs as the agent), so 640 root:ai-tools
# -- agent reads via group, no world.
check_file /usr/local/lib/ai-tools/prune-dirs.lib.sh          root              "${SANDBOX_GROUP}" 640
# Logger library: 644 root:root -- world-readable, sourced by the root helpers, the hooks
# (run as ai-tools), and the CLI (run as the projects user, not in ai-tools).
check_file /usr/local/lib/ai-tools/log.lib.sh                 root              root              644
# Project-label library: 640 root:root -- read only by root principals (ai-tools-relabel and
# install-selinux.sh). No group/world surface; the unprivileged CLI inlines its read-only
# label check instead of sourcing it.
check_file /usr/local/lib/ai-tools/relabel.lib.sh             root              root              640
# Secret-pattern config: user-owned 600. ai-tools (not owner/group, cannot enter the 700
# .config/ai-tools dir) can neither read nor write it; root helpers read it.
check_file "${PROJECTS_HOME}/.config/ai-tools/secret-patterns" "${PROJECTS_USER}" "${PROJECTS_GROUP}" 600
check_file /etc/sudoers.d/ai-tools-claude                     root              root              440
check_file /etc/profile.d/path_dedup.sh                       root              root              644
# /opt/ai-tools/bin is locked: owned by the projects user (NOT ai-tools), 550, so ai-tools
# has group r-x but no write. The agent can execute nvm-update.sh and resolve the claude
# symlink, but cannot edit the updater or swap the symlink -- only root (via
# ai-tools-claude-symlink) writes here.
check_file /opt/ai-tools/bin                                  "${PROJECTS_USER}" "${SANDBOX_GROUP}" 550
# Control-plane files: owned by the projects user, group ai-tools. The agent (running as
# ai-tools) gets group read/exec but no write, so it cannot rewrite its own updater, hook,
# or hook config.
check_file /opt/ai-tools/bin/nvm-update.sh                    "${PROJECTS_USER}" "${SANDBOX_GROUP}" 550
check_file /opt/ai-tools/.claude/post-tool-hook.sh            "${PROJECTS_USER}" "${SANDBOX_GROUP}" 750
check_file /opt/ai-tools/.claude/session-hook.sh             "${PROJECTS_USER}" "${SANDBOX_GROUP}" 750
check_file /opt/ai-tools/.claude/settings.json               "${PROJECTS_USER}" "${SANDBOX_GROUP}" 640
# .claude must be install-user-owned (not ai-tools) with setgid+sticky (3770): ai-tools is a
# group-writer for its own state but cannot unlink/replace the install-user-owned control
# files above. Owned by ai-tools, or without the sticky bit, the agent could delete and
# recreate them.
check_file /opt/ai-tools/.claude                              "${PROJECTS_USER}" "${SANDBOX_GROUP}" 3770
check_file "${PROJECTS_HOME}/.local/bin/claude"               "${PROJECTS_USER}" "${PROJECTS_GROUP}" 750
check_file "${PROJECTS_HOME}/.local/bin/nvm-update.sh"        "${PROJECTS_USER}" "${PROJECTS_GROUP}" 750
check_file "${PROJECTS_HOME}/.config/systemd/user/nvm-update.service" \
                                                              "${PROJECTS_USER}" "${PROJECTS_GROUP}" 640
check_file "${PROJECTS_HOME}/.config/systemd/user/nvm-update.timer" \
                                                              "${PROJECTS_USER}" "${PROJECTS_GROUP}" 640

section "Sudoers syntax"
if visudo -c -f /etc/sudoers.d/ai-tools-claude > /dev/null 2>&1; then
    pass "/etc/sudoers.d/ai-tools-claude parses OK"
else
    fail "/etc/sudoers.d/ai-tools-claude has syntax errors"
fi

finish
