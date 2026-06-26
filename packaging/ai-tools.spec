Name:           ai-tools
Version:        0.1.0
Release:        1%{?dist}
Summary:        Run Claude Code as a sandboxed system user (metapackage)

License:        MIT
URL:            https://github.com/example/ai-tools
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
The provider-agnostic base layer: the ai-tools system account, the ai-tools
project-lifecycle CLI, the per-operator enrollment command, the ownership and
secret-handling root helpers, the handback privilege-bridge socket, and the base
SELinux confinement domain. Other AI-tool packages build on this layer.

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
# (written by ai-tools-enroll), so every host ships identical files.
grep -rlZ -e '@SANDBOX_USER@' -e '@SANDBOX_GROUP@' src \
    | xargs -0 -r sed -i -e 's/@SANDBOX_USER@/ai-tools/g' -e 's/@SANDBOX_GROUP@/ai-tools/g'

%install
# Operator-owned paths (the /opt control plane, /var trees) ship root:ai-tools as a SAFE
# neutral default: root (not the agent) owns them and the agent reaches its state via group
# ai-tools, exactly as under the operator-owned model. ai-tools-enroll personalizes ownership
# to the operator. The agent is never the owner of a locked dir, so it cannot tamper with it.

# ── base: root helpers ───────────────────────────────────────────────────────
install -d -m 0750 %{buildroot}%{ai_sbindir}
for h in ai-tools-chown ai-tools-setgid ai-tools-setfacl ai-tools-unclaim \
         ai-tools-lockdown ai-tools-relabel ai-tools-enroll; do
    install -m 0750 src%{ai_sbindir}/${h}.sh %{buildroot}%{ai_sbindir}/${h}
done
install -m 0750 src%{ai_sbindir}/ai-tools-handback.py %{buildroot}%{ai_sbindir}/ai-tools-handback

# ── base: CLI + handback client ──────────────────────────────────────────────
install -d -m 0755 %{buildroot}%{ai_bindir}
install -m 0755 src%{ai_bindir}/ai-tools.sh                 %{buildroot}%{ai_bindir}/ai-tools
install -m 0750 src%{ai_bindir}/ai-tools-handback-client.py %{buildroot}%{ai_bindir}/ai-tools-handback-client

# ── base: shared libraries ───────────────────────────────────────────────────
install -d -m 0750 %{buildroot}%{ai_libdir}
for l in log msg prune-dirs relabel secret-patterns operator control-plane; do
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
# Default-deny git guard for the control-plane home, in case the operator versions it (see
# the file header). Ships neutral; ai-tools-enroll re-owns it to the operator with .gitconfig.
install -m 0640 src/opt/ai-tools/gitignore %{buildroot}/opt/ai-tools/.gitignore

# ── nodejs: toolchain helpers + updater ──────────────────────────────────────
for h in ai-tools-claude-symlink ai-tools-relabel-entrypoint ai-tools-bootstrap; do
    install -m 0750 src%{ai_sbindir}/${h}.sh %{buildroot}%{ai_sbindir}/${h}
done
install -m 0550 src/opt/ai-tools/bin/nvm-update.sh %{buildroot}/opt/ai-tools/bin/nvm-update.sh

# ── claude: confinement shim + hooks + settings ──────────────────────────────
install -m 0550 src/opt/ai-tools/bin/claude-run.sh         %{buildroot}/opt/ai-tools/bin/claude-run
install -m 0750 src/opt/ai-tools/.claude/post-tool-hook.sh %{buildroot}/opt/ai-tools/.claude/post-tool-hook.sh
install -m 0750 src/opt/ai-tools/.claude/session-hook.sh   %{buildroot}/opt/ai-tools/.claude/session-hook.sh
install -m 0640 src/opt/ai-tools/.claude/settings.json     %{buildroot}/opt/ai-tools/.claude/settings.json

# ── base: ghost the operation logs so the package owns them with the right context ──
for f in chown setgid setfacl symlink lockdown relabel handback install enroll; do
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
# Enrollment + toolchain are per-operator / network steps a scriptlet must not do; direct the
# operator to them. ai-tools-enroll binds an operator (operator.conf + sudoers + linger);
# ai-tools-bootstrap installs the Node toolchain.
cat <<'EOF'
ai-tools-base installed. To finish setup:
  sudo ai-tools-bootstrap                 # install nvm + Node + Claude Code (network)
  sudo ai-tools-enroll <your-user>        # bind the operator (sudoers, operator.conf, linger)
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

%posttrans -n ai-tools-base
# Unpacking re-applies the packaged root:ai-tools owner/modes to the control plane on every
# upgrade; restore the enrolled operator's ownership from operator.conf. No-op when unenrolled.
# In %posttrans so all subpackages' files are on disk before the re-own walks the tree.
if [ -x %{ai_sbindir}/ai-tools-enroll ]; then
    %{ai_sbindir}/ai-tools-enroll --reassert || :
fi

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
%attr(0750, root, root) %{ai_sbindir}/ai-tools-enroll
%attr(0750, root, root) %{ai_sbindir}/ai-tools-handback
%attr(0755, root, root) %{ai_bindir}/ai-tools
%attr(0750, root, ai-tools) %{ai_bindir}/ai-tools-handback-client
%dir %attr(0750, root, ai-tools) %{ai_libdir}
%attr(0644, root, root) %{ai_libdir}/log.lib.sh
%attr(0644, root, root) %{ai_libdir}/msg.lib.sh
%attr(0640, root, ai-tools) %{ai_libdir}/prune-dirs.lib.sh
%attr(0640, root, root) %{ai_libdir}/relabel.lib.sh
%attr(0640, root, root) %{ai_libdir}/secret-patterns.lib.sh
%attr(0644, root, root) %{ai_libdir}/operator.lib.sh
%attr(0644, root, root) %{ai_libdir}/control-plane.lib.sh
%{_unitdir}/ai-tools-handback.socket
%{_unitdir}/ai-tools-handback@.service
%attr(0644, root, root) %{_sysconfdir}/profile.d/path_dedup.sh
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
%ghost %attr(0600, root, root) /var/log/ai-tools/enroll.log
# Control-plane root and dirs ship root:ai-tools (neutral placeholder -- the package has no
# operator at build time). ai-tools-bootstrap populates the tree as the sandbox account, then
# ai-tools-enroll re-owns this set to the operator and tightens /opt/ai-tools to drwxr-s---.
%dir %attr(2750, root, ai-tools) /opt/ai-tools
%dir %attr(0550, root, ai-tools) /opt/ai-tools/bin
%dir %attr(3770, root, ai-tools) /opt/ai-tools/.claude
%config(noreplace) %attr(0640, root, ai-tools) /opt/ai-tools/.gitignore

%files -n ai-tools-nodejs
%attr(0750, root, root) %{ai_sbindir}/ai-tools-claude-symlink
%attr(0750, root, root) %{ai_sbindir}/ai-tools-relabel-entrypoint
%attr(0750, root, root) %{ai_sbindir}/ai-tools-bootstrap
%attr(0550, root, ai-tools) /opt/ai-tools/bin/nvm-update.sh

%files -n claude-code-restricted
%attr(0550, root, ai-tools) /opt/ai-tools/bin/claude-run
%attr(0750, root, ai-tools) /opt/ai-tools/.claude/post-tool-hook.sh
%attr(0750, root, ai-tools) /opt/ai-tools/.claude/session-hook.sh
%attr(0640, root, ai-tools) /opt/ai-tools/.claude/settings.json

%changelog
* Thu Jun 25 2026 Packager <packager@example.com> - 0.1.0-1
- Initial RPM packaging: ai-tools-base / ai-tools-nodejs / claude-code-restricted
  subpackages from one source, sysusers account creation, SELinux core module load,
  handback socket, and the bootstrap/enroll commands.
