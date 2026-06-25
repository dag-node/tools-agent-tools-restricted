#!/usr/bin/env bash
# tests/integration/perms.sh
# Integration: the single source of truth for deployed-artifact ownership/permissions, plus
# sudoers syntax. Asserts EVERY installed file and directory matches the security model --
# root-owned helpers and handback bridge, the CLI, the locked /opt/ai-tools/bin and
# claude-run, the setgid sandbox/control-plane dirs, the setgid+sticky .claude,
# agent-readable-but-not-writable hooks/config, the root-only operation logs, and the
# projects-user-only allowlist/config -- and that the sudoers drop-in parses. Needs a
# completed install; run as root via sudo, or via `sudo ./install.sh check-perms`.

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
# SELinux entrypoint-relabel helper: 750 root:root -- run AS root via the third
# @PROJECTS_USER@ NOPASSWD rule (by the nvm-update timer and `ai-tools --relabel`), never by
# the agent. Fixed-path, no-arg target, so the root grant cannot be parameterized.
check_file /usr/local/sbin/ai-tools/ai-tools-relabel-entrypoint root            root              750
# Toolchain bootstrap + per-operator enrollment: 750 root:root -- run by the operator via sudo
# (and the RPM %post), never by the agent (no SANDBOX_USER grant).
check_file /usr/local/sbin/ai-tools/ai-tools-bootstrap        root              root              750
check_file /usr/local/sbin/ai-tools/ai-tools-enroll          root              root              750
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
# Operator-identity resolver: 644 root:root -- world-readable like log.lib.sh; sourced by the
# root helpers (ai_tools_handback_t) and the agent hooks (ai_tools_t) to read operator.conf.
check_file /usr/local/lib/ai-tools/operator.lib.sh           root              root              644
# Secret-pattern config: user-owned 600. ai-tools (not owner/group, cannot enter the 700
# .config/ai-tools dir) can neither read nor write it; root helpers read it.
check_file "${PROJECTS_HOME}/.config/ai-tools/secret-patterns" "${PROJECTS_USER}" "${PROJECTS_GROUP}" 600
check_file /etc/sudoers.d/ai-tools-claude                     root              root              440
# Operator identity: 644 root:root -- world-readable (agent hooks + root helpers read it),
# root-write-only (the agent cannot rewrite the identity root hands files back to).
check_file /etc/ai-tools/operator.conf                        root              root              644
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

# Handback bridge. The helper dir is 750 root:root (no world bit -- non-root users cannot
# list the helper names). The daemon is root-only-executable; the agent never exec's it, it
# connects via the socket. The client is group-executable so SANDBOX_USER (a SANDBOX_GROUP
# member) runs it from the hooks/updater, but no world bit (no arbitrary user reaches the
# bridge). The units are read by systemd as root.
check_file /usr/local/sbin/ai-tools                           root root 750
check_file /usr/local/sbin/ai-tools/ai-tools-handback         root root 750
check_file /usr/local/bin/ai-tools-handback-client            root "${SANDBOX_GROUP}" 750
check_file /usr/lib/systemd/system/ai-tools-handback.socket   root root 644
check_file /usr/lib/systemd/system/ai-tools-handback@.service root root 644
# Project CLI: 755 root:root -- runs AS the projects user (its guard refuses root and the
# sandbox account); root-owned so the agent cannot rewrite it, world-exec is harmless since
# it edits only user-writable registries.
check_file /usr/local/bin/ai-tools                            root root 755
# Message formatter: 644 root:root -- world-readable like log.lib.sh; sourced by the operator
# wrapper/CLI, the agent's hooks, and claude-run, so every principal must read it. No secrets.
check_file /usr/local/lib/ai-tools/msg.lib.sh                 root root 644
# Sandbox area: PROJECTS_USER:SANDBOX_GROUP. Outer dir 2750 (setgid, no world); inner
# sandbox-projects 2770 (setgid so clones are born group SANDBOX_GROUP, group-writable so the
# agent works in the clones). README 640.
check_file /var/opt/ai-tools                                  "${PROJECTS_USER}" "${SANDBOX_GROUP}" 2750
check_file /var/opt/ai-tools/sandbox-projects                 "${PROJECTS_USER}" "${SANDBOX_GROUP}" 2770
check_file /var/opt/ai-tools/README.md                        "${PROJECTS_USER}" "${SANDBOX_GROUP}" 640
# /opt/ai-tools root: 2750 PROJECTS_USER:SANDBOX_GROUP -- setgid propagates group SANDBOX_GROUP
# to new files; group r-x only, so the agent cannot create or delete here. claude-run mirrors
# nvm-update.sh (550, group r-x, no write). .gitconfig 640: agent reads safe.directory, owner edits.
# .gitignore 640: a default-deny guard if the operator versions the control plane (agent reads, never writes).
check_file /opt/ai-tools                                      "${PROJECTS_USER}" "${SANDBOX_GROUP}" 2750
check_file /opt/ai-tools/bin/claude-run                       "${PROJECTS_USER}" "${SANDBOX_GROUP}" 550
check_file /opt/ai-tools/.gitconfig                           "${PROJECTS_USER}" "${SANDBOX_GROUP}" 640
check_file /opt/ai-tools/.gitignore                           "${PROJECTS_USER}" "${SANDBOX_GROUP}" 640
# Operation logs: dir 700 root:root, each file 600 root:root -- the root helpers append here;
# ai-tools (neither owner nor able to traverse the 700 dir) can neither read nor tamper with
# the trail, so secret filenames recorded by ai-tools-chown stay out of agent reach.
check_file /var/log/ai-tools              root root 700
check_file /var/log/ai-tools/chown.log    root root 600
check_file /var/log/ai-tools/setgid.log   root root 600
check_file /var/log/ai-tools/symlink.log  root root 600
check_file /var/log/ai-tools/lockdown.log root root 600
check_file /var/log/ai-tools/relabel.log  root root 600
check_file /var/log/ai-tools/install.log  root root 600
# Projects-user config dir 700 + allowlist 600: ai-tools (not owner, not in PROJECTS_GROUP,
# cannot traverse the 700 dir) can neither read nor modify the approved-projects list even if
# it had a looser mode; the root helpers read it on the user's behalf.
check_file "${PROJECTS_HOME}/.config/ai-tools"                 "${PROJECTS_USER}" "${PROJECTS_GROUP}" 700
check_file "${PROJECTS_HOME}/.config/ai-tools/allowed-projects" "${PROJECTS_USER}" "${PROJECTS_GROUP}" 600

section "Sudoers syntax"
if visudo -c -f /etc/sudoers.d/ai-tools-claude > /dev/null 2>&1; then
    pass "/etc/sudoers.d/ai-tools-claude parses OK"
else
    fail "/etc/sudoers.d/ai-tools-claude has syntax errors"
fi

finish
