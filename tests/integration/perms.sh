#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/integration/perms.sh
# Integration: the single source of truth for deployed-artifact ownership/permissions, plus
# sudoers syntax. Asserts EVERY installed file and directory matches the security model --
# root-owned helpers and handback bridge, the CLI, the locked /opt/ai-tools/bin and
# ai-tools-run, the setgid sandbox/control-plane dirs, the setgid+sticky .claude,
# agent-readable-but-not-writable hooks/config, the root-only operation logs, and the
# projects-user-only allowlist/config -- and that the sudoers drop-in parses. Needs a
# completed install; run as root via sudo, or via `sudo ./install.sh check-perms`.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

section "File permissions"
check_file /usr/local/libexec/ai-tools/ai-tools-chown            root              root              750
check_file /usr/local/libexec/ai-tools/ai-tools-setgid           root              root              750
check_file /usr/local/libexec/ai-tools/ai-tools-setfacl          root              root              750
check_file /usr/local/libexec/ai-tools/ai-tools-unclaim          root              root              750
check_file /usr/local/libexec/ai-tools/ai-tools-safedir          root              root              750
check_file /usr/local/libexec/ai-tools/ai-tools-reclaim          root              root              750
check_file /usr/local/libexec/ai-tools/ai-tools-allowlist        root              root              750
check_file /usr/local/libexec/ai-tools/ai-tools-audit            root              root              750
check_file /usr/local/libexec/ai-tools/ai-tools-stop             root              root              750
check_file /usr/local/libexec/ai-tools/ai-tools-launcher-symlink root              root              750
check_file /usr/local/libexec/ai-tools/ai-tools-lockdown         root              root              750
# SELinux project-label helper: 750 root:root -- user-run via sudo, never by the agent (no
# SANDBOX_USER grant); same surface as lockdown.
check_file /usr/local/libexec/ai-tools/ai-tools-relabel          root              root              750
# SELinux agent-relabel helper: 750 root:root -- run AS root automatically by the
# ai-tools-relabel.path watcher and on demand by `sudo ai-tools-admin system entrypoints relabel`,
# never by the agent. It carries no NOPASSWD rule: the admin command reaches it through the host's
# own general sudo grant, so the %ai-ops drop-in holds the session lifecycle alone.
check_file /usr/local/libexec/ai-tools/ai-tools-relabel-agent    root              root              750
# Toolchain bootstrap + operator administration: 750 root:root. ai-tools-admin runs as root via
# sudo; the provisioning helper is exec'd by its `system bootstrap` command at this fixed path.
# Neither is reachable by the agent (no SANDBOX_USER grant, and /usr/local/libexec/ai-tools is
# 750 root:root).
check_file /usr/local/libexec/ai-tools/ai-tools-bootstrap        root              root              750
check_file /usr/local/libexec/ai-tools/ai-tools-admin           root              root              750
# The sudo-PATH symlink in /usr/sbin, for the one command an administrator types (sudoers
# secure_path on stock EL excludes /usr/local/sbin, so `sudo ai-tools-admin` resolves here).
# check_file lstat()s the link itself (777 is a symlink's fixed mode); -e inside it also catches
# a dangling link. Nothing else has one: the provisioning helper and every contributed command
# are reached as verbs of this one.
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
# Managed-asset seeder: 644 root:root. Sourced by install.sh + ai-tools-bootstrap to seed the
# ai-tools-* agents/skills; world-readable, no secrets.
check_file /usr/local/lib/ai-tools/managed-assets.lib.sh     root              root              644
# Protected-paths backstop: 644 root:root. Sourced by the wrapper, the CLI, and the root
# helpers to refuse a system directory as a target; world-readable, no secrets.
check_file /usr/local/lib/ai-tools/safe-paths.lib.sh         root              root              644
check_file /usr/local/lib/ai-tools/confinement.lib.sh        root              root              644
check_file /usr/local/lib/ai-tools/npm-verify.lib.sh         root              root              644
check_file /usr/local/lib/ai-tools/entrypoint-verify.lib.sh  root              root              644
check_file /usr/local/lib/ai-tools/keys/claude-code.asc      root              root              644
# Shared KEY=value grammar + the trust predicate: 644 root:root -- world-readable, sourced by
# operator.lib.sh, skip-dirs.lib.sh and providers.lib.sh; does not carry secrets.
check_file /usr/local/lib/ai-tools/conf.lib.sh               root              root              644
# Provider/agent resolver: 644 root:root -- world-readable, sourced by ai-tools-bootstrap and
# nvm-update (both run as the sandbox account) to read the agent manifests; does not carry secrets.
check_file /usr/local/lib/ai-tools/providers.lib.sh          root              root              644
# Optional SELinux policy-group registry: 644 root:root -- world-readable, sourced by
# ai-tools-admin and selinux/install-selinux.sh (both root); read-only data, does not carry secrets.
check_file /usr/local/lib/ai-tools/selinux-groups.lib.sh     root              root              644
# Command-filter engine: 644 root:root -- world-readable, sourced by an agent's filter hook, which
# runs AS the agent on every Bash call; read-only data plus pure logic, does not carry secrets.
check_file /usr/local/lib/ai-tools/filters.lib.sh            root              root              644
# Service-health registry: 644 root:root -- world-readable, sourced by the operator launch wrapper
# and the CLI (--status); read-only data, no secrets.
check_file /usr/local/lib/ai-tools/services.lib.sh           root              root              644
# The three provider directories, owned by ai-tools-base (each member package drops only its own
# files into them). 0755 root:root is SECURITY-LOAD-BEARING, not housekeeping: these decide which
# agents get provisioned and what env a session gets, and a group- or other-writable directory
# would let a non-root writer unlink and replace a root-owned manifest or fragment inside it. The
# resolver and ai-tools-run both refuse a directory that fails exactly this check, so an assertion
# here is the deployed-state half of that guarantee (see providers.rule.md).
check_file /usr/local/lib/ai-tools/agents.d                  root              root              755
check_file /usr/local/lib/ai-tools/integrations.d            root              root              755
check_file /usr/local/lib/ai-tools/session-env.d              root              root              755
# The contributed-command directory takes that same reasoning at the highest privilege here:
# ai-tools-admin execs what it finds inside AS ROOT, so a non-root writer would be choosing a root
# command. Root-owned with no group or other write is what the dispatch's trust check requires;
# world-READ is what lets `ai-tools-admin --help`, answered ahead of its own root check, list this
# host's domains for any caller.
check_file /usr/local/lib/ai-tools/admin-commands.d          root              root              755
# The command-filter rule-set directory carries the same reasoning one step further out: its files
# decide what every command in a session becomes, so a non-root writer here could reshape the
# commands the agent runs and the transcript the operator reads. Base owns the directory and
# core.rules; a package with commands of its own drops a rule set beside them.
check_file /usr/local/lib/ai-tools/filters.d                 root              root              755
check_file /usr/local/lib/ai-tools/filters.d/core.rules      root              root              644
# Agent manifest, shipped by ai-tools-agents-claude-code-restricted (not base): 644 root:root,
# parsed data naming the Claude npm package + launcher.
check_file /usr/local/lib/ai-tools/agents.d/claude-code.conf root              root              644
# dotnet integration data (shipped by ai-tools-integration-dotnet, not base): 644 root:root -- the
# manifest providers.lib.sh reads and the session-env fragment ai-tools-run sources when enabled.
check_file /usr/local/lib/ai-tools/integrations.d/dotnet.conf   root            root              644
check_file /usr/local/lib/ai-tools/session-env.d/dotnet.env.sh  root            root              644
# The `dotnet` domain of ai-tools-admin, contributed by the same package: 750 root:root like every
# other root-executed helper, so the agent can neither read nor run it, and root-owned so the
# dispatch's trust check admits it.
check_file /usr/local/lib/ai-tools/admin-commands.d/dotnet      root            root              750
check_file /usr/local/lib/ai-tools/filters.d/dotnet.rules       root            root              644
# The claude-code agent's own session-env fragment, shipped by its agent package. ai-tools-run
# sources it last, so these pins outrank an integration's -- and 644 root:root is what makes it
# trusted enough to source at all.
check_file /usr/local/lib/ai-tools/session-env.d/claude-code.env.sh root         root              644
# The claude-code agent's Claude-specific resolvers: the custom system prompt (wrapper-side) and the
# custom API endpoint (fragment-side). 644 root:root -- sourced by claude.sh / the fragment, so
# root-owned and non-group-writable is what makes them trusted enough to source. No secrets.
check_file /usr/local/lib/ai-tools/claude-prompt.lib.sh      root              root              644
check_file /usr/local/lib/ai-tools/claude-endpoint.lib.sh    root              root              644
# Secret-pattern config: user-owned 600. ai-tools (not owner/group, cannot enter the 700
# .config/ai-tools dir) can neither read nor write it; root helpers read it. Optional: it is a
# per-operator OVERRIDE -- the shared classifier falls back to its built-in defaults when the file
# is absent (secret-patterns.lib.sh), so install.sh seeds it but a fresh RPM enrolment need not.
check_file_optional "${PROJECTS_HOME}/.config/ai-tools/secret-patterns" "${PROJECTS_USER}" "${PROJECTS_GROUP}" 600
check_file /etc/sudoers.d/ai-tools                     root              root              440
# Operator identity: 644 root:root -- world-readable (agent hooks + root helpers read it),
# root-write-only (the agent cannot rewrite the identity root hands files back to).
check_file /etc/ai-tools/operator.conf                        root              root              644
# Custom system prompt: an empty, editable default under a dedicated dir. 640 root:ai-tools -- the
# sandbox account reads it (via etc_t + the group) and the operator edits it with sudo, but a custom
# prompt is not world-readable (it may carry proprietary instructions). claude.sh only stat()s it as
# the operator, so no operator read is needed; the dir stays 755 so that stat can traverse it.
check_file /etc/ai-tools/prompts                              root              root              755
check_file /etc/ai-tools/prompts/claude-system-prompt.md      root              "${SANDBOX_GROUP}" 640
# Custom API endpoint: the endpoint file may hold a bearer token, so unlike operator.conf it is
# 640 root:ai-tools -- readable by root and the sandbox account (which needs the token) but NOT
# world, and NOT by the operator (not in ai-tools). Its directory is a plain 755 root:root.
check_file /etc/ai-tools/endpoints                            root              root              755
check_file /etc/ai-tools/endpoints/custom-claude-endpoint.conf root             "${SANDBOX_GROUP}" 640
# PATH dedup fragment: 644 root:root -- world-readable, sourced by the operator shells
# ai-tools-admin wires (never installed into /etc/profile.d; unwired accounts keep their
# stock PATH).
check_file /usr/local/lib/ai-tools/path-dedup.sh              root              root              644
# /opt/ai-tools/bin is locked: root:ai-tools 0551, so ai-tools has group r-x but no write. The
# agent can execute nvm-update.sh and resolve the claude symlink, but cannot edit the updater or
# swap the symlink -- only root (via ai-tools-launcher-symlink) writes here. The o+x search bit
# lets an operator readlink bin/<launcher>.
check_file /opt/ai-tools/bin                                  root              "${SANDBOX_GROUP}" 551
# Control-plane files: root:ai-tools. The agent (running as ai-tools) gets group read/exec but
# no write, so it cannot rewrite its own updater, hook, or hook config.
check_file /opt/ai-tools/bin/nvm-update.sh                    root              "${SANDBOX_GROUP}" 550
check_file /opt/ai-tools/.claude/post-tool-hook.sh            root              "${SANDBOX_GROUP}" 750
check_file /opt/ai-tools/.claude/session-hook.sh             root              "${SANDBOX_GROUP}" 750
check_file /opt/ai-tools/.claude/filter-hook.sh              root              "${SANDBOX_GROUP}" 750
check_file /opt/ai-tools/.claude/settings.json               root              "${SANDBOX_GROUP}" 640
# EVERY agent's config directory is root-owned with setgid+sticky (CP_AGENT_CONFIG_MODE, 3770):
# ai-tools is a group-writer for its own state but cannot unlink/replace the root-owned control
# files above. Owned by ai-tools, or without the sticky bit, the agent could delete and recreate
# them. The set of directories comes from the manifests (control-plane.lib.sh), so a second agent
# is covered here without editing this list; a host with none skips and says so.
# The SHARED asset roots: base-owned, agent-readable, NOT agent-writable. Every agent symlinks
# into them, so a writable root here would let one session rewrite the instructions -- or the
# delegate definitions -- every agent and every future session reads.
check_file /opt/ai-tools/skills                               root              "${SANDBOX_GROUP}" 750
check_file /opt/ai-tools/subagents                            root              "${SANDBOX_GROUP}" 750
_cp_lib=/usr/local/lib/ai-tools/control-plane.lib.sh
# shellcheck source=/dev/null
if source "${_cp_lib}" 2>/dev/null && declare -F ai_tools_agent_config_dirs >/dev/null 2>&1; then
    _cfg_found=0
    while IFS=$'\t' read -r _agent _cfg; do
        [[ -n "${_cfg}" ]] || continue
        _cfg_found=1
        check_file "${_cfg}" root "${SANDBOX_GROUP}" "${CP_AGENT_CONFIG_MODE}"
    done < <(ai_tools_agent_config_dirs)
    (( _cfg_found )) || skip "agent config directory modes" "no enabled agent declares a config_dir"
    # Each agent's asset directories carry SYMLINKS into the shared roots, not copies -- that is
    # what keeps an asset authored in one place. Assert a shipped asset of each kind arrived that
    # way, so a regression to per-agent copies (silently forking the content) fails here. The
    # pairs are <manifest field>:<shared root>:<a shipped asset name>.
    for _spec in "skills_dir:/opt/ai-tools/skills:ai-tools-technical-docs" \
                 "subagents_dir:/opt/ai-tools/subagents:ai-tools-reference-architect.md"; do
        _field="${_spec%%:*}"; _rest="${_spec#*:}"; _root="${_rest%%:*}"; _asset="${_rest#*:}"
        _marker=""
        while IFS=$'\t' read -r _agent _dir; do
            [[ -d "${_dir}" ]] || { skip "${_dir}" "not deployed on this host"; continue; }
            _link="${_dir}/${_asset}"
            _marker="${_link}"; [[ -d "${_link}" ]] && _marker="${_link}/SKILL.md"
            if [[ ! -e "${_link}" ]]; then
                skip "${_link}" "shipped asset not seeded on this host"
            elif [[ -L "${_link}" && "$(readlink "${_link}")" == "${_root}"/* ]]; then
                pass "${_link} is a symlink into ${_root}"
            elif ! grep -qE '^x-ai-tools-managed:[[:space:]]*true' "${_marker}" 2>/dev/null; then
                # A real entry that is NOT ai-tools-managed is the operator's own override, which
                # the linker is contracted to leave alone -- the feature, not a regression.
                skip "${_link}" "an operator override sits here (not ai-tools-managed)"
            else
                fail "${_link} is a managed COPY, not a symlink into ${_root} -- the shared asset forks per agent. An identical copy is converted on the next install/bootstrap; one that differs is kept, so reconcile or remove it"
            fi
        done < <(ai_tools_agent_asset_dirs "${_field}")
    done
else
    skip "agent config directory modes" "${_cp_lib} does not resolve the agents' config dirs"
fi
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
check_file /usr/local/libexec/ai-tools                           root root 750
check_file /usr/local/libexec/ai-tools/ai-tools-handback         root root 750
check_file /usr/local/bin/ai-tools-handback-client            root "${SANDBOX_GROUP}" 750
check_file /usr/lib/systemd/system/ai-tools-handback.socket   root root 644
check_file /usr/lib/systemd/system/ai-tools-handback@.service root root 644
# The preset that enables the socket on install (see systemd.sh for its enablement check).
check_file /usr/lib/systemd/system-preset/85-ai-tools.preset  root root 644
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
# ai-tools(1) man page: the RPM's brp-compress gzips it, the from-source install does not,
# so check whichever form is deployed.
if [[ -e /usr/local/share/man/man1/ai-tools.1.gz ]]; then
    check_file /usr/local/share/man/man1/ai-tools.1.gz        root root 644
else
    check_file /usr/local/share/man/man1/ai-tools.1           root root 644
fi
if [[ -e /usr/local/share/man/man5/operator.conf.5.gz ]]; then
    check_file /usr/local/share/man/man5/operator.conf.5.gz   root root 644
else
    check_file /usr/local/share/man/man5/operator.conf.5      root root 644
fi
if [[ -e /usr/local/share/man/man8/ai-tools-admin.8.gz ]]; then
    check_file /usr/local/share/man/man8/ai-tools-admin.8.gz  root root 644
else
    check_file /usr/local/share/man/man8/ai-tools-admin.8     root root 644
fi
# Launch wrapper: 755 root:root -- system-wide on every operator's PATH (path-dedup.sh ranks
# /usr/local/bin above the nvm shims, so it shadows nvm's claude). Runs as the invoking
# operator, gates on ai-ops membership, then drops to the sandbox account via sudo; root-owned
# so the agent cannot rewrite it.
check_file /usr/local/bin/claude                              root root 755
# Message formatter: 644 root:root -- world-readable like log.lib.sh; sourced by the operator
# wrapper/CLI, the agent's hooks, and ai-tools-run, so every principal must read it. No secrets.
check_file /usr/local/lib/ai-tools/msg.lib.sh                 root root 644
# Sandbox area: root:SANDBOX_GROUP. Outer dir 2750 (setgid, no world); inner sandbox-projects
# 2770 (setgid so clones are born group SANDBOX_GROUP, group-writable so the agent works in the
# clones). README 640.
check_file /var/opt/ai-tools                                  root              "${SANDBOX_GROUP}" 2750
check_file /var/opt/ai-tools/sandbox-projects                 root              "${SANDBOX_GROUP}" 2770
check_file /var/opt/ai-tools/README.md                        root              "${SANDBOX_GROUP}" 640
# Last-run state the sandbox account publishes for `ai-tools --status` to read (its --user units
# are not queryable from the operator's session). The mode is what bounds the surface a
# sandbox-written stamp adds, so both halves are asserted: the directory 0750 root:SANDBOX_GROUP --
# root-owned and NOT group-writable, so the account has traverse only and can neither add, unlink,
# rename, nor symlink-swap anything here (no setgid: the bit inherited from the 2750 parent must be
# stripped symbolically, since neither `install -d -m` nor a numeric chmod clears it) -- and each
# stamp 0640 SANDBOX_USER:ai-ops, the one inode the account rewrites in place, group-readable to
# operators and closed to everyone else. The stamp ships with the nodejs integration, so a
# base-only install legitimately lacks it.
check_file /var/opt/ai-tools/state                            root              "${SANDBOX_GROUP}" 750
check_file_optional /var/opt/ai-tools/state/nvm-update.status "${SANDBOX_USER}" ai-ops            640
# The entrypoint pins. root:root and not group-writable, unlike the stamp beside them: a stamp
# reports and does not gate a launch, while a pin is what the launch compares the agent binary against, so
# the account it constrains must not be able to write it.
check_file /var/opt/ai-tools/state/entrypoint-pin.d           root              root              755
check_file /var/opt/ai-tools/state/entrypoint-label.d         root              root              755
# Sandbox-area operator ACL: ai-ops reaches the area without SANDBOX_GROUP membership -- traverse
# on the outer dir, rwX + default on sandbox-projects. The agent (not in ai-ops) does not gain access.
if ! command -v getfacl >/dev/null 2>&1; then
    skip "sandbox-area ai-ops ACL" "getfacl not available"
elif getfacl -p /var/opt/ai-tools 2>/dev/null | grep -qE '^group:ai-ops:r-x' \
     && getfacl -p /var/opt/ai-tools/sandbox-projects 2>/dev/null | grep -qE '^group:ai-ops:rwx' \
     && getfacl -p /var/opt/ai-tools/sandbox-projects 2>/dev/null | grep -qE '^default:group:ai-ops:rwx' \
     && getfacl -p /var/opt/ai-tools/state 2>/dev/null | grep -qE '^group:ai-ops:r-x'; then
    pass "sandbox area carries the ai-ops operator ACL (traverse + rwX + default + state read)"
else
    fail "sandbox-area ai-ops ACL missing: $(getfacl -p /var/opt/ai-tools/sandbox-projects 2>/dev/null | grep ai-ops | tr '\n' ' ')"
fi
# /opt/ai-tools root: 2751 root:SANDBOX_GROUP -- setgid propagates group SANDBOX_GROUP to new
# files; group r-x and the o+x search bit, so the agent reads through the group and an operator
# traverses to the launcher, but neither creates or deletes here. ai-tools-run is the base-owned
# confinement shim and mirrors nvm-update.sh (550, group r-x, no write): the sandbox account
# executes it, cannot modify it, and cannot replace it through the 0551 bin directory. .gitconfig 644: world-readable so the agent reads safe.directory and
# the operator/wrapper read it without SANDBOX_GROUP membership; only root writes (via
# ai-tools-safedir). .gitignore 640: a default-deny guard for a git repo versioning the control plane.
check_file /opt/ai-tools                                      root              "${SANDBOX_GROUP}" 2751
check_file /opt/ai-tools/bin/ai-tools-run                       root              "${SANDBOX_GROUP}" 550
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
check_file_optional /var/log/ai-tools/handback.log root root 600
check_file_optional /var/log/ai-tools/install.log  root root 600
check_file_optional /var/log/ai-tools/dotnet.log   root root 600
# Projects-user config dir 700 + allowlist 600: ai-tools (not owner, not in PROJECTS_GROUP,
# cannot traverse the 700 dir) can neither read nor modify the approved-projects list even if
# it had a looser mode; the root helpers read it on the user's behalf.
check_file "${PROJECTS_HOME}/.config/ai-tools"                 "${PROJECTS_USER}" "${PROJECTS_GROUP}" 700
check_file "${PROJECTS_HOME}/.config/ai-tools/allowed-projects" "${PROJECTS_USER}" "${PROJECTS_GROUP}" 600

section "Sudoers syntax"
if visudo -c -f /etc/sudoers.d/ai-tools > /dev/null 2>&1; then
    pass "/etc/sudoers.d/ai-tools parses OK"
else
    fail "/etc/sudoers.d/ai-tools has syntax errors"
fi

# env_keep surface: ai-tools-run re-validates AI_TOOLS_AGENT_EXEC/AI_TOOLS_PROJECT_DIR (ai-tools-run.sh test),
# which is the real defense, but the drop-in's per-command env_keep should pass through ONLY
# those two -- a widened list would smuggle attacker-influenced env into the launch path. Pin it:
# every env_keep in the file names exactly AI_TOOLS_AGENT_EXEC and AI_TOOLS_PROJECT_DIR, and no other name.
if [[ -r /etc/sudoers.d/ai-tools ]]; then
    ek_extra="$(grep -oE 'env_keep[[:space:]]*\+?=[[:space:]]*"[^"]*"' /etc/sudoers.d/ai-tools \
        | grep -oE '"[^"]*"' | tr -d '"' | tr ' ' '\n' \
        | grep -vE '^[[:space:]]*$' | grep -vxE 'AI_TOOLS_AGENT_EXEC|AI_TOOLS_PROJECT_DIR' || true)"
    if [[ -z "${ek_extra}" ]]; then
        pass "sudoers env_keep passes only AI_TOOLS_AGENT_EXEC + AI_TOOLS_PROJECT_DIR"
    else
        fail "sudoers env_keep names unexpected variable(s): ${ek_extra//$'\n'/ } -- widened launch env surface"
    fi

    # The root rule must be pinned to its helper's ZERO-ARGUMENT form. The trailing "" is what keeps
    # it a grant to run one program one way: sudoers(5) reads a command listed with no arguments at
    # all as permitting ANY, so a dropped "" silently turns a narrow root rule into `--force`
    # without a password. tests/unit/helper-path.sh pins the same line in the SOURCE; this asserts
    # what the install actually deployed.
    if grep -qE "^%ai-ops[[:space:]]+.*NOPASSWD:[[:space:]]*/usr/local/libexec/ai-tools/ai-tools-stop[[:space:]]+\"\"[[:space:]]*$" \
            /etc/sudoers.d/ai-tools; then
        pass "sudoers grants ai-tools-stop in its zero-argument form only"
    else
        fail "sudoers rule for ai-tools-stop is missing or not pinned to the zero-argument form"
    fi

    # And the drop-in holds the session lifecycle ALONE. The entrypoint relabel is an
    # ai-tools-admin command reached through the host's own general sudo grant, so a %ai-ops rule
    # naming its helper would hand every operator a passwordless root command the model no longer
    # accounts for.
    if grep -qE "^%ai-ops.*ai-tools-relabel-agent" /etc/sudoers.d/ai-tools; then
        fail "sudoers grants %ai-ops a rule for ai-tools-relabel-agent -- the drop-in holds the session lifecycle only"
    else
        pass "sudoers grants %ai-ops no rule for ai-tools-relabel-agent"
    fi
fi

finish
