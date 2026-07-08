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
check_file /usr/local/sbin/ai-tools/ai-tools-safedir          root              root              750
check_file /usr/local/sbin/ai-tools/ai-tools-reclaim          root              root              750
check_file /usr/local/sbin/ai-tools/ai-tools-claude-symlink   root              root              750
check_file /usr/local/sbin/ai-tools/ai-tools-lockdown         root              root              750
# SELinux project-label helper: 750 root:root -- user-run via sudo, never by the agent (no
# SANDBOX_USER grant); same surface as lockdown.
check_file /usr/local/sbin/ai-tools/ai-tools-relabel          root              root              750
# SELinux entrypoint-relabel helper: 750 root:root -- run AS root automatically by the
# ai-tools-relabel.path watcher and on demand by `ai-tools --relabel` (the %ai-ops NOPASSWD
# rule), never by the agent. Fixed-path, no-arg target, so the root grant cannot be parameterized.
check_file /usr/local/sbin/ai-tools/ai-tools-relabel-entrypoint root            root              750
# Toolchain bootstrap + operator administration: 750 root:root -- run by the operator via sudo,
# never by the agent (no SANDBOX_USER grant, and /usr/local/sbin/ai-tools is 750 root:root).
check_file /usr/local/sbin/ai-tools/ai-tools-bootstrap        root              root              750
check_file /usr/local/sbin/ai-tools/ai-tools-admin           root              root              750
# Their sudo-PATH symlinks in /usr/sbin (sudoers secure_path on stock EL excludes
# /usr/local/sbin, so `sudo ai-tools-bootstrap` resolves here). check_file lstat()s the
# link itself (777 is a symlink's fixed mode); -e inside it also catches a dangling link.
check_file /usr/sbin/ai-tools-bootstrap                       root              root              777
check_file /usr/sbin/ai-tools-admin                           root              root              777
# Lib dir: root-owned, group ai-tools, 0751. The agent enters via group to read the skip
# list; world-execute lets an operator (not a SANDBOX_GROUP member) traverse in to source the
# 644 world-readable libs by path without listing the dir. No write but root.
check_file /usr/local/lib/ai-tools                            root              "${SANDBOX_GROUP}" 751
# Secret-pattern matcher: read only by the root helpers, so 640 root:root -- no group/world
# surface. The agent (group ai-tools) cannot read it.
check_file /usr/local/lib/ai-tools/secret-patterns.lib.sh     root              root              640
# Skip-dir list/selector: 644 root:root -- world-readable, sourced by the root helpers,
# session-hook.sh (runs as the agent), and the CLI's claim drift scan (runs as the
# projects user, not in ai-tools). Carries no secrets: the names are documented.
check_file /usr/local/lib/ai-tools/skip-dirs.lib.sh           root              root              644
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
# Control-plane boundary-mode constants: 644 root:root. Sourced by install.sh as the single
# source for the /opt/ai-tools home/dir modes the spec %files also declares.
check_file /usr/local/lib/ai-tools/control-plane.lib.sh      root              root              644
# Protected-paths backstop: 644 root:root. Sourced by the wrapper, the CLI, and the root
# helpers to refuse a system directory as a target; world-readable, no secrets.
check_file /usr/local/lib/ai-tools/safe-paths.lib.sh         root              root              644
# Secret-pattern config: user-owned 600. ai-tools (not owner/group, cannot enter the 700
# .config/ai-tools dir) can neither read nor write it; root helpers read it. Optional: it is a
# per-operator OVERRIDE -- the shared classifier falls back to its built-in defaults when the file
# is absent (secret-patterns.lib.sh), so install.sh seeds it but a fresh RPM enrolment need not.
check_file_optional "${PROJECTS_HOME}/.config/ai-tools/secret-patterns" "${PROJECTS_USER}" "${PROJECTS_GROUP}" 600
check_file /etc/sudoers.d/ai-tools-claude                     root              root              440
# Operator identity: 644 root:root -- world-readable (agent hooks + root helpers read it),
# root-write-only (the agent cannot rewrite the identity root hands files back to).
check_file /etc/ai-tools/operator.conf                        root              root              644
# PATH dedup fragment: 644 root:root -- world-readable, sourced by the operator shells
# ai-tools-admin wires (never installed into /etc/profile.d; unwired accounts keep their
# stock PATH).
check_file /usr/local/lib/ai-tools/path-dedup.sh              root              root              644
# /opt/ai-tools/bin is locked: root:ai-tools 0551, so ai-tools has group r-x but no write. The
# agent can execute nvm-update.sh and resolve the claude symlink, but cannot edit the updater or
# swap the symlink -- only root (via ai-tools-claude-symlink) writes here. The o+x search bit
# lets an operator readlink bin/claude.
check_file /opt/ai-tools/bin                                  root              "${SANDBOX_GROUP}" 551
# Control-plane files: root:ai-tools. The agent (running as ai-tools) gets group read/exec but
# no write, so it cannot rewrite its own updater, hook, or hook config.
check_file /opt/ai-tools/bin/nvm-update.sh                    root              "${SANDBOX_GROUP}" 550
check_file /opt/ai-tools/.claude/post-tool-hook.sh            root              "${SANDBOX_GROUP}" 750
check_file /opt/ai-tools/.claude/session-hook.sh             root              "${SANDBOX_GROUP}" 750
check_file /opt/ai-tools/.claude/settings.json               root              "${SANDBOX_GROUP}" 640
# .claude is root-owned with setgid+sticky (3770): ai-tools is a group-writer for its own state
# but cannot unlink/replace the root-owned control files above. Owned by ai-tools, or without
# the sticky bit, the agent could delete and recreate them.
check_file /opt/ai-tools/.claude                              root              "${SANDBOX_GROUP}" 3770
# The agent's XDG config for its --user manager: root-owned root:ai-tools 2750 (setgid inherited
# from the control-plane home), so the manager reads its units through the group but the agent
# cannot add a --user unit. An agent-writable wants dir would let a confined session register a
# unit the account's unconfined manager runs.
check_file /opt/ai-tools/.config/systemd/user                 root              "${SANDBOX_GROUP}" 2750
check_file /opt/ai-tools/.config/systemd/user/timers.target.wants \
                                                              root              "${SANDBOX_GROUP}" 2750

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
# Toolchain update units (sandbox account's --user instance) + post-upgrade relabel watcher.
# 644 root:root -- systemd reads them as root; no world write.
check_file /usr/lib/systemd/user/nvm-update.service           root root 644
check_file /usr/lib/systemd/user/nvm-update.timer             root root 644
check_file /usr/lib/systemd/system/ai-tools-relabel.path      root root 644
check_file /usr/lib/systemd/system/ai-tools-relabel.service   root root 644
# Project CLI: 755 root:root -- runs AS the projects user (its guard refuses root and the
# sandbox account); root-owned so the agent cannot rewrite it, world-exec is harmless since
# it edits only user-writable registries.
check_file /usr/local/bin/ai-tools                            root root 755
# Launch wrapper: 755 root:root -- system-wide on every operator's PATH (path-dedup.sh ranks
# /usr/local/bin above the nvm shims, so it shadows nvm's claude). Runs as the invoking
# operator, gates on ai-ops membership, then drops to the sandbox account via sudo; root-owned
# so the agent cannot rewrite it.
check_file /usr/local/bin/claude                              root root 755
# Message formatter: 644 root:root -- world-readable like log.lib.sh; sourced by the operator
# wrapper/CLI, the agent's hooks, and claude-run, so every principal must read it. No secrets.
check_file /usr/local/lib/ai-tools/msg.lib.sh                 root root 644
# Sandbox area: root:SANDBOX_GROUP. Outer dir 2750 (setgid, no world); inner sandbox-projects
# 2770 (setgid so clones are born group SANDBOX_GROUP, group-writable so the agent works in the
# clones). README 640.
check_file /var/opt/ai-tools                                  root              "${SANDBOX_GROUP}" 2750
check_file /var/opt/ai-tools/sandbox-projects                 root              "${SANDBOX_GROUP}" 2770
check_file /var/opt/ai-tools/README.md                        root              "${SANDBOX_GROUP}" 640
# Sandbox-area operator ACL: ai-ops reaches the area without SANDBOX_GROUP membership -- traverse
# on the outer dir, rwX + default on sandbox-projects. The agent (not in ai-ops) gains nothing.
if ! command -v getfacl >/dev/null 2>&1; then
    skip "sandbox-area ai-ops ACL" "getfacl not available"
elif getfacl -p /var/opt/ai-tools 2>/dev/null | grep -qE '^group:ai-ops:r-x' \
     && getfacl -p /var/opt/ai-tools/sandbox-projects 2>/dev/null | grep -qE '^group:ai-ops:rwx' \
     && getfacl -p /var/opt/ai-tools/sandbox-projects 2>/dev/null | grep -qE '^default:group:ai-ops:rwx'; then
    pass "sandbox area carries the ai-ops operator ACL (traverse + rwX + default)"
else
    fail "sandbox-area ai-ops ACL missing: $(getfacl -p /var/opt/ai-tools/sandbox-projects 2>/dev/null | grep ai-ops | tr '\n' ' ')"
fi
# /opt/ai-tools root: 2751 root:SANDBOX_GROUP -- setgid propagates group SANDBOX_GROUP to new
# files; group r-x and the o+x search bit, so the agent reads through the group and an operator
# traverses to the launcher, but neither creates or deletes here. claude-run mirrors nvm-update.sh
# (550, group r-x, no write). .gitconfig 644: world-readable so the agent reads safe.directory and
# the operator/wrapper read it without SANDBOX_GROUP membership; only root writes (via
# ai-tools-safedir). .gitignore 640: a default-deny guard for a git repo versioning the control plane.
check_file /opt/ai-tools                                      root              "${SANDBOX_GROUP}" 2751
check_file /opt/ai-tools/bin/claude-run                       root              "${SANDBOX_GROUP}" 550
check_file /opt/ai-tools/.gitconfig                           root              "${SANDBOX_GROUP}" 644
check_file /opt/ai-tools/.gitignore                           root              "${SANDBOX_GROUP}" 640
# Operation logs: dir 700 root:root, each file 600 root:root -- the root helpers append here;
# ai-tools (neither owner nor able to traverse the 700 dir) can neither read nor tamper with
# the trail, so secret filenames recorded by ai-tools-chown stay out of agent reach. The log
# FILES are %ghost (created on first write of their op), so each is optional: a fresh install has
# only the logs whose op has run (relabel.log waits for a relabel; install.log is install.sh-only).
check_file /var/log/ai-tools              root root 700
check_file_optional /var/log/ai-tools/chown.log    root root 600
check_file_optional /var/log/ai-tools/setgid.log   root root 600
check_file_optional /var/log/ai-tools/symlink.log  root root 600
check_file_optional /var/log/ai-tools/lockdown.log root root 600
check_file_optional /var/log/ai-tools/relabel.log  root root 600
check_file_optional /var/log/ai-tools/install.log  root root 600
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

# env_keep surface: claude-run re-validates CLAUDE_EXEC/CLAUDE_PROJECT_DIR (claude-run.sh test),
# which is the real defense, but the drop-in's per-command env_keep should pass through ONLY
# those two -- a widened list would smuggle attacker-influenced env into the launch path. Pin it:
# every env_keep in the file names exactly CLAUDE_EXEC and CLAUDE_PROJECT_DIR, nothing else.
if [[ -r /etc/sudoers.d/ai-tools-claude ]]; then
    ek_extra="$(grep -oE 'env_keep[[:space:]]*\+?=[[:space:]]*"[^"]*"' /etc/sudoers.d/ai-tools-claude \
        | grep -oE '"[^"]*"' | tr -d '"' | tr ' ' '\n' \
        | grep -vE '^[[:space:]]*$' | grep -vxE 'CLAUDE_EXEC|CLAUDE_PROJECT_DIR' || true)"
    if [[ -z "${ek_extra}" ]]; then
        pass "sudoers env_keep passes only CLAUDE_EXEC + CLAUDE_PROJECT_DIR"
    else
        fail "sudoers env_keep names unexpected variable(s): ${ek_extra//$'\n'/ } -- widened launch env surface"
    fi
fi

finish
