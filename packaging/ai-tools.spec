Name:           ai-tools
Version:        0.1.0
Release:        1%{?dist}
Summary:        Run Claude Code as a sandboxed system user (metapackage)

License:        AGPL-3.0-or-later
URL:            https://github.com/dag-node/ai-tools
Source0:        %{name}-%{version}.tar.gz
Source1:        %{name}.sysusers

BuildArch:      noarch
BuildRequires:  systemd-rpm-macros

# Shell/Python scripts only: no ELF, so suppress the debuginfo subpackage and the
# binary build-root policy steps (ldconfig/strip) that do not apply to a noarch package.
%global debug_package %{nil}
%global __brp_ldconfig %{nil}
%global __brp_strip %{nil}
%global __brp_strip_static_archive %{nil}
%global __brp_strip_comment_note %{nil}

# Install paths are LITERAL /usr/local/* (not %%{_sbindir}/%%{_bindir}/%%{_libdir}): the
# sandbox hardcodes these exact paths in the SELinux file-contexts, the CLI's helper lookups,
# the hooks' handback-client path, and sudoers, so the package must place files there.
%global ai_sbindir /usr/local/sbin/ai-tools
%global ai_bindir  /usr/local/bin
%global ai_libdir  /usr/local/lib/ai-tools

# Metapackage: pulls the whole stack. The real content is in the subpackages below.
Requires:       ai-tools-base = %{version}-%{release}
Requires:       ai-tools-nodejs = %{version}-%{release}
Requires:       claude-code-restricted = %{version}-%{release}

%description
Run Anthropic's Claude Code (and other npm-packaged AI tools) as a dedicated,
locked-down system user instead of your own login account. This metapackage
installs the full stack: the ai-tools-base sandbox account and ownership
machinery, ai-tools-nodejs toolchain management, and the claude-code-restricted
provider layer.

# ─────────────────────────────────────────────────────────────────────────────
%package -n ai-tools-base
Summary:        Sandboxed-user umbrella for AI coding tools (account, CLI, ownership bridge)
Requires(pre):  shadow-utils
Requires(pre):  systemd
Requires:       systemd
Requires:       sudo
Requires:       acl
Requires:       python3
Requires:       coreutils
Requires:       policycoreutils

%description -n ai-tools-base
The provider-agnostic base layer: the ai-tools system account, the ai-ops
operators group, the ai-tools project-lifecycle CLI, the ai-tools-admin
operator-administration command, the ownership and secret-handling root helpers,
the handback privilege-bridge socket, and the base SELinux confinement domain.
Other AI-tool packages build on this layer.

# ─────────────────────────────────────────────────────────────────────────────
%package -n ai-tools-nodejs
Summary:        nvm-managed Node toolchain and updater for the ai-tools sandbox
Requires:       ai-tools-base = %{version}-%{release}
Requires:       curl
Requires:       tar
Requires:       gzip

%description -n ai-tools-nodejs
Manages the sandbox account's private nvm-managed Node toolchain: the bootstrap
command that installs nvm/Node/the agent package, the scheduled version updater,
and the symlink-repoint and post-upgrade entrypoint-relabel helpers. Node itself
is nvm-managed under /opt/ai-tools, not an RPM dependency, so the agent can
self-update it within the SELinux policy.

# ─────────────────────────────────────────────────────────────────────────────
%package -n claude-code-restricted
Summary:        Claude Code launch wrapper, confinement shim, and hooks for the ai-tools sandbox
Requires:       ai-tools-nodejs = %{version}-%{release}

%description -n claude-code-restricted
The Claude Code provider layer: the confinement service shim (claude-run) that
wraps each session in a transient systemd unit, the Claude Code hooks that drive
ownership handback and secret quarantine, and the session settings. A future
provider package would sit beside this one on the same base and nodejs layers.

%prep
%autosetup

%build
# Substitute the constant sandbox-account tokens. The per-operator @PROJECTS_*@ tokens are
# intentionally left literal: they are resolved at runtime from /etc/ai-tools/operator.conf
# (written by ai-tools-admin), so every host ships identical files.
grep -rlZ -e '@SANDBOX_USER@' -e '@SANDBOX_GROUP@' src \
    | xargs -0 -r sed -i -e 's/@SANDBOX_USER@/ai-tools/g' -e 's/@SANDBOX_GROUP@/ai-tools/g'

%install
# The /opt control plane and the /var trees ship root:ai-tools and stay that way: root (not the
# agent) owns the locked control files while the agent reaches its state through group ai-tools.
# Nothing re-owns them to a person -- the operators drive the shared ai-tools account and reach
# the launcher through an o+x search bit, so the agent is never the owner of a locked dir.

# ── base: root helpers ───────────────────────────────────────────────────────
install -d -m 0750 %{buildroot}%{ai_sbindir}
for h in ai-tools-chown ai-tools-setgid ai-tools-setfacl ai-tools-unclaim \
         ai-tools-lockdown ai-tools-relabel ai-tools-safedir ai-tools-reclaim \
         ai-tools-admin; do
    install -m 0750 src%{ai_sbindir}/${h}.sh %{buildroot}%{ai_sbindir}/${h}
done
install -m 0750 src%{ai_sbindir}/ai-tools-handback.py %{buildroot}%{ai_sbindir}/ai-tools-handback

# ai-tools-admin is typed by an administrator (documented as a bare command) and is the one
# base helper that is not daemon- or sudoers-invoked by fixed path, so it goes on root's PATH
# via a symlink in /usr/local/sbin (in root's secure_path). The target keeps its canonical
# %{ai_sbindir} path. ai-tools-bootstrap gets the same treatment in the nodejs subpackage.
ln -s ai-tools/ai-tools-admin %{buildroot}/usr/local/sbin/ai-tools-admin

# ── base: CLI + handback client ──────────────────────────────────────────────
install -d -m 0755 %{buildroot}%{ai_bindir}
install -m 0755 src%{ai_bindir}/ai-tools.sh                 %{buildroot}%{ai_bindir}/ai-tools
install -m 0750 src%{ai_bindir}/ai-tools-handback-client.py %{buildroot}%{ai_bindir}/ai-tools-handback-client

# ── base: shared libraries ───────────────────────────────────────────────────
# 0751: group SANDBOX_GROUP r-x for the agent; world-execute so an operator (not a
# SANDBOX_GROUP member under multi-operator) can traverse in to source the 644
# world-readable libs by path without listing the dir. The 640 files self-protect.
install -d -m 0751 %{buildroot}%{ai_libdir}
for l in log msg skip-dirs relabel secret-patterns operator control-plane safe-paths; do
    install -m 0644 src%{ai_libdir}/${l}.lib.sh %{buildroot}%{ai_libdir}/${l}.lib.sh
done

# ── base: handback systemd units ─────────────────────────────────────────────
install -d -m 0755 %{buildroot}%{_unitdir}
install -m 0644 src%{_unitdir}/ai-tools-handback.socket    %{buildroot}%{_unitdir}/
install -m 0644 src%{_unitdir}/ai-tools-handback@.service  %{buildroot}%{_unitdir}/

# ── base: profile.d PATH dedup + sysusers ────────────────────────────────────
install -d -m 0755 %{buildroot}%{_sysconfdir}/profile.d
install -m 0644 src%{_sysconfdir}/profile.d/path_dedup.sh %{buildroot}%{_sysconfdir}/profile.d/path_dedup.sh
install -d -m 0755 %{buildroot}%{_sysusersdir}
install -m 0644 %{SOURCE1} %{buildroot}%{_sysusersdir}/ai-tools.conf

# ── base: static %ai-ops sudoers drop-in (the @SANDBOX_*@ tokens are substituted in %build;
#    %ai-ops is literal, so the file is host-identical and ships unchanged) ──
install -d -m 0750 %{buildroot}%{_sysconfdir}/sudoers.d
install -m 0440 src%{_sysconfdir}/sudoers.d/ai-tools-claude %{buildroot}%{_sysconfdir}/sudoers.d/ai-tools-claude

# ── base: host-config template. The @PROJECTS_USER@ token stays literal at build (the
#    operator is a runtime identity), so stage the template with OPERATORS emptied;
#    `ai-tools-admin operator add` fills it in place. %config(noreplace) keeps the
#    operator's OPERATORS/SKIP_* edits across upgrades. ──
install -d -m 0755 %{buildroot}%{_sysconfdir}/ai-tools
sed 's/^OPERATORS=.*/OPERATORS=""/' src%{_sysconfdir}/ai-tools/operator.conf \
    > %{buildroot}%{_sysconfdir}/ai-tools/operator.conf
chmod 0644 %{buildroot}%{_sysconfdir}/ai-tools/operator.conf

# ── base: SELinux core policy module (prebuilt) ──────────────────────────────
install -d -m 0755 %{buildroot}%{_datadir}/selinux/packages/ai-tools
install -m 0644 selinux/policy/ai_tools.pp %{buildroot}%{_datadir}/selinux/packages/ai-tools/ai_tools.pp

# ── base: sandbox project workflow tree + operation-log dir ──────────────────
install -d -m 2750 %{buildroot}/var/opt/ai-tools
install -d -m 2770 %{buildroot}/var/opt/ai-tools/sandbox-projects
install -m 0640 src/var/opt/ai-tools/README.md %{buildroot}/var/opt/ai-tools/README.md
install -d -m 0700 %{buildroot}/var/log/ai-tools

# ── base: control-plane home root + dirs (files added by nodejs/claude). Staging modes are
#    writable so files can be placed here; the installed modes come from the file lists below. ──
install -d -m 0755 %{buildroot}/opt/ai-tools
install -d -m 0755 %{buildroot}/opt/ai-tools/bin
install -d -m 0770 %{buildroot}/opt/ai-tools/.claude
# Default-deny git guard for the control-plane home: ai-tools-bootstrap captures the control
# plane in a root-private git repo, and this gitignore keeps secrets and churn out of it.
install -m 0640 src/opt/ai-tools/gitignore %{buildroot}/opt/ai-tools/.gitignore

# ── nodejs: toolchain helpers + updater ──────────────────────────────────────
for h in ai-tools-claude-symlink ai-tools-relabel-entrypoint ai-tools-bootstrap; do
    install -m 0750 src%{ai_sbindir}/${h}.sh %{buildroot}%{ai_sbindir}/${h}
done
# ai-tools-bootstrap is administrator-typed (documented as a bare command); put it on root's
# PATH via /usr/local/sbin, mirroring ai-tools-admin in the base subpackage.
ln -s ai-tools/ai-tools-bootstrap %{buildroot}/usr/local/sbin/ai-tools-bootstrap
install -m 0550 src/opt/ai-tools/bin/nvm-update.sh %{buildroot}/opt/ai-tools/bin/nvm-update.sh

# ── nodejs: toolchain update units + post-upgrade relabel watcher ─────────────
# The update service+timer run in the sandbox account's own systemd --user instance
# (%{_userunitdir}); the relabel .path watches the bin/claude symlink and triggers the
# root-side .service (restorecon to ai_tools_exec_t) after a Node bump.
install -d -m 0755 %{buildroot}%{_userunitdir}
install -m 0644 src%{_userunitdir}/nvm-update.service   %{buildroot}%{_userunitdir}/nvm-update.service
install -m 0644 src%{_userunitdir}/nvm-update.timer     %{buildroot}%{_userunitdir}/nvm-update.timer
install -m 0644 src%{_unitdir}/ai-tools-relabel.path    %{buildroot}%{_unitdir}/ai-tools-relabel.path
install -m 0644 src%{_unitdir}/ai-tools-relabel.service %{buildroot}%{_unitdir}/ai-tools-relabel.service

# ── claude: launch wrapper + confinement shim + hooks + settings ──────────────
# The wrapper ships root:root 0755 in /usr/local/bin (Tier 1 in path_dedup.sh, so it shadows
# the nvm-managed claude on every operator's PATH); it runs as the invoking operator, gates on
# ai-ops membership, then drops to the sandbox account via sudo.
install -m 0755 src%{ai_bindir}/claude.sh                  %{buildroot}%{ai_bindir}/claude
install -m 0550 src/opt/ai-tools/bin/claude-run.sh         %{buildroot}/opt/ai-tools/bin/claude-run
install -m 0750 src/opt/ai-tools/.claude/post-tool-hook.sh %{buildroot}/opt/ai-tools/.claude/post-tool-hook.sh
install -m 0750 src/opt/ai-tools/.claude/session-hook.sh   %{buildroot}/opt/ai-tools/.claude/session-hook.sh
install -m 0640 src/opt/ai-tools/.claude/settings.json     %{buildroot}/opt/ai-tools/.claude/settings.json

# ── base: ghost the operation logs so the package owns them with the right context ──
for f in chown setgid setfacl symlink lockdown relabel handback install; do
    touch %{buildroot}/var/log/ai-tools/${f}.log
done

# ─────────────────────────────────────────────────────────────────────────────
# Scriptlets
# ─────────────────────────────────────────────────────────────────────────────
%pre -n ai-tools-base
# Create the ai-tools system account before any file owned by it is unpacked.
%sysusers_create_compat %{SOURCE1}

%post -n ai-tools-base
%systemd_post ai-tools-handback.socket
# Load the prebuilt SELinux core module and apply contexts when SELinux is enabled. Core
# only -- the optional policy groups stay available via the SELinux tooling, not installed.
if [ "$(getenforce 2>/dev/null)" != "Disabled" ] && command -v semodule >/dev/null 2>&1; then
    semodule -n -i %{_datadir}/selinux/packages/ai-tools/ai_tools.pp >/dev/null 2>&1 || :
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -R %{ai_sbindir} %{ai_libdir} /opt/ai-tools /var/log/ai-tools >/dev/null 2>&1 || :
    fi
fi
# Grant the ai-ops operators group access to the shared sandbox area through a group ACL, so
# operators create and work in clones (ai-tools --sandbox-create) without joining the ai-tools
# group: traverse on the outer dir, rwX on sandbox-projects (a default ACL so clones inherit the
# operator access), and read on the doc. One grant covers every operator and outlives a leave of
# the ai-tools group. This is the shared-area counterpart to ai-tools-setfacl's per-project
# user:<operator> grant; %files cannot express an ACL, so it is applied here. ai-ops exists from
# %pre (sysusers); the directories exist from this package's %files.
if command -v setfacl >/dev/null 2>&1; then
    setfacl -m g:ai-ops:r-x /var/opt/ai-tools || :
    setfacl -m g:ai-ops:rwx /var/opt/ai-tools/sandbox-projects || :
    setfacl -d -m g:ai-ops:rwX /var/opt/ai-tools/sandbox-projects || :
    setfacl -m g:ai-ops:r-- /var/opt/ai-tools/README.md || :
fi
# Operator binding + toolchain are per-operator / network steps a scriptlet must not do; direct
# the operator to them. ai-tools-bootstrap installs the Node toolchain; ai-tools-admin operator
# add binds an operator (OPERATORS list + ai-ops membership + linger + allowlist seed).
cat <<'EOF'
ai-tools-base installed. To finish setup:
  sudo ai-tools-bootstrap                      # install nvm + Node + Claude Code (network)
  sudo ai-tools-admin operator add <your-user> # bind an operator (ai-ops, OPERATORS, linger)
EOF

%preun -n ai-tools-base
%systemd_preun ai-tools-handback.socket

%postun -n ai-tools-base
%systemd_postun_with_restart ai-tools-handback.socket
# On final erase only, unload the SELinux module. The ai-tools account, /opt/ai-tools/.nvm,
# /var/opt/ai-tools clones, and each operator's ~/.config/ai-tools are intentionally preserved.
if [ "$1" -eq 0 ] && command -v semodule >/dev/null 2>&1; then
    semodule -n -r ai_tools >/dev/null 2>&1 || :
fi

%post -n ai-tools-nodejs
# Enable the root-side relabel watcher (system unit). The nvm-update.timer is a --user unit
# enabled in the sandbox account's own instance by ai-tools-bootstrap, which is where that
# instance is brought up with linger -- a scriptlet cannot reliably reach it.
%systemd_post ai-tools-relabel.path

%preun -n ai-tools-nodejs
%systemd_preun ai-tools-relabel.path

%postun -n ai-tools-nodejs
%systemd_postun_with_restart ai-tools-relabel.path

# ─────────────────────────────────────────────────────────────────────────────
# File lists
# ─────────────────────────────────────────────────────────────────────────────
%files
%doc docs/rpm-packaging.md README.md

%files -n ai-tools-base
%dir %attr(0750, root, root) %{ai_sbindir}
%attr(0750, root, root) %{ai_sbindir}/ai-tools-chown
%attr(0750, root, root) %{ai_sbindir}/ai-tools-setgid
%attr(0750, root, root) %{ai_sbindir}/ai-tools-setfacl
%attr(0750, root, root) %{ai_sbindir}/ai-tools-unclaim
%attr(0750, root, root) %{ai_sbindir}/ai-tools-lockdown
%attr(0750, root, root) %{ai_sbindir}/ai-tools-relabel
%attr(0750, root, root) %{ai_sbindir}/ai-tools-safedir
%attr(0750, root, root) %{ai_sbindir}/ai-tools-reclaim
%attr(0750, root, root) %{ai_sbindir}/ai-tools-admin
/usr/local/sbin/ai-tools-admin
%attr(0750, root, root) %{ai_sbindir}/ai-tools-handback
%attr(0755, root, root) %{ai_bindir}/ai-tools
%attr(0750, root, ai-tools) %{ai_bindir}/ai-tools-handback-client
%dir %attr(0751, root, ai-tools) %{ai_libdir}
%attr(0644, root, root) %{ai_libdir}/log.lib.sh
%attr(0644, root, root) %{ai_libdir}/msg.lib.sh
%attr(0644, root, root) %{ai_libdir}/skip-dirs.lib.sh
%attr(0640, root, root) %{ai_libdir}/relabel.lib.sh
%attr(0640, root, root) %{ai_libdir}/secret-patterns.lib.sh
%attr(0644, root, root) %{ai_libdir}/operator.lib.sh
%attr(0644, root, root) %{ai_libdir}/control-plane.lib.sh
%attr(0644, root, root) %{ai_libdir}/safe-paths.lib.sh
%{_unitdir}/ai-tools-handback.socket
%{_unitdir}/ai-tools-handback@.service
%attr(0644, root, root) %{_sysconfdir}/profile.d/path_dedup.sh
%config(noreplace) %attr(0440, root, root) %{_sysconfdir}/sudoers.d/ai-tools-claude
%dir %attr(0755, root, root) %{_sysconfdir}/ai-tools
%config(noreplace) %attr(0644, root, root) %{_sysconfdir}/ai-tools/operator.conf
%{_sysusersdir}/ai-tools.conf
%dir %{_datadir}/selinux/packages/ai-tools
%{_datadir}/selinux/packages/ai-tools/ai_tools.pp
%dir %attr(2750, root, ai-tools) /var/opt/ai-tools
%dir %attr(2770, root, ai-tools) /var/opt/ai-tools/sandbox-projects
%attr(0640, root, ai-tools) /var/opt/ai-tools/README.md
%dir %attr(0700, root, root) /var/log/ai-tools
%ghost %attr(0600, root, root) /var/log/ai-tools/chown.log
%ghost %attr(0600, root, root) /var/log/ai-tools/setgid.log
%ghost %attr(0600, root, root) /var/log/ai-tools/setfacl.log
%ghost %attr(0600, root, root) /var/log/ai-tools/symlink.log
%ghost %attr(0600, root, root) /var/log/ai-tools/lockdown.log
%ghost %attr(0600, root, root) /var/log/ai-tools/relabel.log
%ghost %attr(0600, root, root) /var/log/ai-tools/handback.log
%ghost %attr(0600, root, root) /var/log/ai-tools/install.log
# Control-plane root and dirs are owned root:ai-tools: root owns the locked control files, the
# agent reaches its state through group ai-tools, and the o+x search bits on the home and bin let
# an operator readlink the launcher without reading anything deeper. ai-tools-bootstrap populates
# the agent's own subtrees (.nvm/.cache/...) under the home as the sandbox account.
%dir %attr(2751, root, ai-tools) /opt/ai-tools
%dir %attr(0551, root, ai-tools) /opt/ai-tools/bin
%dir %attr(3770, root, ai-tools) /opt/ai-tools/.claude
%config(noreplace) %attr(0640, root, ai-tools) /opt/ai-tools/.gitignore

%files -n ai-tools-nodejs
%attr(0750, root, root) %{ai_sbindir}/ai-tools-claude-symlink
%attr(0750, root, root) %{ai_sbindir}/ai-tools-relabel-entrypoint
%attr(0750, root, root) %{ai_sbindir}/ai-tools-bootstrap
/usr/local/sbin/ai-tools-bootstrap
%attr(0550, root, ai-tools) /opt/ai-tools/bin/nvm-update.sh
%{_userunitdir}/nvm-update.service
%{_userunitdir}/nvm-update.timer
%{_unitdir}/ai-tools-relabel.path
%{_unitdir}/ai-tools-relabel.service

%files -n claude-code-restricted
%attr(0755, root, root) %{ai_bindir}/claude
%attr(0550, root, ai-tools) /opt/ai-tools/bin/claude-run
%attr(0750, root, ai-tools) /opt/ai-tools/.claude/post-tool-hook.sh
%attr(0750, root, ai-tools) /opt/ai-tools/.claude/session-hook.sh
%attr(0640, root, ai-tools) /opt/ai-tools/.claude/settings.json

%changelog
* Thu Jun 25 2026 dagnode <tools@dagnode.com> - 0.1.0-1
- Initial RPM packaging: ai-tools-base / ai-tools-nodejs / claude-code-restricted
  subpackages from one source, sysusers account + ai-ops group creation, SELinux core
  module load, handback socket, and the bootstrap/admin commands.
