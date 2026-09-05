# SPDX-FileCopyrightText: 2026 Ondřej Nedomlel <tools@dagnode.com>
# SPDX-License-Identifier: MIT
Name:           ai-tools
# Single source of truth for the version: packaging/VERSION (the Makefile reads the same
# file), so a release bump touches one place. Parsing this spec requires _sourcedir to
# point at packaging/ -- the Makefile's rpm/srpm targets pass --define "_sourcedir ..."
# for that reason; a bare parse (rpmlint, IDE tooling) without it yields an empty Version.
Version:        %(cat %{_sourcedir}/VERSION)
# Plain "1" for a final vX.Y.Z release; the Makefile's RPM_RELEASE overrides it to a
# dev/snapshot string (e.g. "0.42.gitabcdef1") or an rc prerelease ("0.rc1"). The leading
# "0." on a dev Release is the Fedora pre-release convention: rpm's version comparison
# then always ranks a real release (Release starts at plain "1") above any dev snapshot
# that preceded it, and ranks newer dev snapshots above older ones as the counter climbs.
Release:        %{!?rpm_release:1}%{?rpm_release}%{?dist}
Summary:        Run Claude Code as a sandboxed system user (metapackage)

License:        AGPL-3.0-only
URL:            https://github.com/dag-node/tools-agent-tools-restricted
Source0:        %{name}-%{version}.tar.gz
Source1:        %{name}.sysusers
Source2:        VERSION

BuildArch:      noarch
BuildRequires:  systemd-rpm-macros
# Fedora only: the shipped SELinux .pp is compiled from source at build time rather than served
# from the committed EL-built prebuilt, because Fedora's refpolicy is a newer, moving target and
# an EL-built .pp may not load against it. EL keeps the committed prebuilt (no devel at build).
%if 0%{?fedora}
BuildRequires:  selinux-policy-devel
%endif

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
%global ai_libexecdir /usr/local/libexec/ai-tools
%global ai_bindir  /usr/local/bin
%global ai_mandir  /usr/local/share/man
%global ai_libdir  /usr/local/lib/ai-tools

# Metapackage: pulls the whole stack. ai-tools-base is the mandatory foundation; the
# ai-tools-agents and ai-tools-integration umbrellas are weak (Recommends), so a default
# dnf install pulls them while `--setopt=install_weak_deps=0` yields base alone. The real
# content is in the subpackages below.
Requires:       ai-tools-base = %{version}-%{release}
Recommends:     ai-tools-agents = %{version}-%{release}
Recommends:     ai-tools-integration = %{version}-%{release}

%description
Run Anthropic's Claude Code (and other npm-packaged AI tools) as a dedicated,
locked-down system user instead of your own login account. This metapackage
installs the full stack: the ai-tools-base sandbox account and ownership
machinery, the ai-tools-integration toolchain layer (nvm-managed Node and other
host-toolchain integrations), and the ai-tools-agents provider layer (Claude
Code). Both umbrellas are weakly pulled, so an install can drop either.

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
# Weak, not hard: without the policy the sandbox runs in a documented DAC-only mode rather than
# failing. ai_tools_confinement_verdict returns "ok" when the module is ABSENT (an intentional
# DAC-only deployment) and fails closed only when it is present-but-inactive, so dropping this
# subpackage degrades confinement without bricking a launch. Also a licence boundary: the policy
# is the one GPL payload in the stack (see its %%description), and a weak dep keeps it separable.
Recommends:     ai-tools-selinux = %{version}-%{release}

%description -n ai-tools-base
The provider-agnostic base layer: the ai-tools system account, the ai-ops
operators group, the ai-tools project-lifecycle CLI, the ai-tools-admin
operator-administration command, the ownership and secret-handling root helpers,
and the handback privilege-bridge socket. The SELinux confinement domain itself
ships in ai-tools-selinux, which this package weakly recommends. Other AI-tool
packages build on this layer.

# ─────────────────────────────────────────────────────────────────────────────
# The SELinux confinement policy, split out because it is the one payload in the stack the
# maintainer does not own: a compiled .pp embeds macro expansions from the SELinux reference
# policy (GPL-2.0-or-later), so it is conveyed under the GPL as its own package rather than
# relicensing the AGPL base around it. The scriptlets that load and unload the modules live
# here WITH the payload, which also removes any cross-subpackage ordering question.
#
# Scriptlet tools are named explicitly rather than via %%{?selinux_requires}: that macro bakes
# the BUILD host's selinux-policy version into a Requires (uninstallable on the older EL of a
# noarch build) and pulls policycoreutils-python-utils, which no scriptlet here uses. semodule and
# restorecon come from policycoreutils; getenforce from libselinux-utils.
%package -n ai-tools-selinux
Summary:        SELinux confinement policy for the ai-tools sandbox
License:        GPL-2.0-or-later
Requires:       ai-tools-base = %{version}-%{release}
Requires(post): policycoreutils
Requires(post): libselinux-utils
Requires(postun): policycoreutils

%description -n ai-tools-selinux
The SELinux targeted-policy module that confines a sandbox session in the
ai_tools_t domain, plus the prebuilt packages for the stable optional policy
groups. Built against the SELinux reference policy and therefore licensed
GPL-2.0-or-later, unlike the rest of the stack.

Without this package the sandbox runs in a documented DAC-only mode: ownership,
group ACLs, and the no-new-privileges launch confinement all still apply, but
the kernel-enforced type transition does not.

# ─────────────────────────────────────────────────────────────────────────────
# ai-tools-integration umbrella: the host-toolchain integration layers the sandboxed agent
# builds against (nvm-managed Node today; language/runtime integrations as
# ai-tools-integration-* siblings). A thin metapackage that weakly pulls its members, so an
# integration a host cannot use, or an operator does not want, drops without breaking the stack.
%package -n ai-tools-integration
Summary:        Umbrella for the ai-tools sandbox toolchain/runtime integrations (metapackage)
Recommends:     ai-tools-integration-nodejs = %{version}-%{release}
Recommends:     ai-tools-integration-dotnet = %{version}-%{release}

%description -n ai-tools-integration
Metapackage grouping the ai-tools-integration-* toolchain layers the sandboxed agent builds
against. Members are weakly pulled, so a host without a given toolchain, or an operator who
does not want it, installs the umbrella without that member.

# ─────────────────────────────────────────────────────────────────────────────
%package -n ai-tools-integration-nodejs
Summary:        nvm-managed Node toolchain and updater for the ai-tools sandbox
Requires:       ai-tools-base = %{version}-%{release}
Requires:       curl
Requires:       tar
Requires:       gzip
# This package carries what ai-tools-nodejs used to. The Provides/Obsoletes pair is what makes
# dnf treat that as a RENAME and hand the shared files over in one transaction. Without it a host
# on the old name cannot resolve `dnf update` at all: the installed ai-tools-nodejs pins
# `ai-tools-base = <its own version>`, the only upgrade candidate for the base is the new version,
# and no package obsoletes the old name to break the deadlock -- so the whole transaction fails and
# the operator is pushed into a manual erase that drops their operator.conf. The bound is the
# version the rename landed in, so a future package reusing the old name is never obsoleted.
Provides:       ai-tools-nodejs = %{version}-%{release}
Obsoletes:      ai-tools-nodejs < 0.7.0-1

%description -n ai-tools-integration-nodejs
Manages the sandbox account's private nvm-managed Node toolchain: the bootstrap
command that installs nvm/Node/the agent package, the scheduled version updater,
and the symlink-repoint and post-upgrade entrypoint-relabel helpers. Node itself
is nvm-managed under /opt/ai-tools, not an RPM dependency, so the agent can
self-update it within the SELinux policy.

# ─────────────────────────────────────────────────────────────────────────────
%package -n ai-tools-integration-dotnet
Summary:        .NET (dotnet) toolchain integration for the ai-tools sandbox
Requires:       ai-tools-base = %{version}-%{release}
# No dotnet RPM dependency: this integrates a HOST-managed dotnet, detected at runtime, and is
# inert on a host without one (the session-env fragment self-gates on /usr/bin/dotnet). It is
# weakly pulled by the ai-tools-integration umbrella, so a default install carries it harmlessly.

%description -n ai-tools-integration-dotnet
Integrates a host-managed .NET toolchain into a sandbox session: a session-env fragment that
exports DOTNET_ROOT and a sandbox-writable NuGet cache when the dotnet integration is enabled
(operator.conf AI_TOOLS_INTEGRATIONS), and the `dotnet` domain of ai-tools-admin to provision that
cache and shared global tools. The .NET SDK/runtime itself is the host's RPM-managed dotnet; this
package adds no runtime and is inert until enabled on a host that has dotnet installed.

# ─────────────────────────────────────────────────────────────────────────────
# ai-tools-agents umbrella: the AI coding agents that run confined in the sandbox. A thin
# metapackage that weakly pulls its members (Claude Code today; other providers as
# ai-tools-agents-* siblings on the same base and integration layers).
%package -n ai-tools-agents
Summary:        Umbrella for the sandboxed AI coding agents (metapackage)
Recommends:     ai-tools-agents-claude-code-restricted = %{version}-%{release}

%description -n ai-tools-agents
Metapackage grouping the ai-tools-agents-* provider layers -- the AI coding agents that run
confined in the sandbox. Members are weakly pulled, so an operator installs the umbrella and
drops any agent they do not use.

# ─────────────────────────────────────────────────────────────────────────────
%package -n ai-tools-agents-claude-code-restricted
Summary:        Claude Code launch wrapper, confinement shim, and hooks for the ai-tools sandbox
Requires:       ai-tools-integration-nodejs = %{version}-%{release}
# jq is a HARD runtime dependency of all three hooks this package ships, not a convenience: each
# parses its event JSON with it. Absent, every one of them takes its `|| exit 0` path silently --
# post-tool-hook stops handing agent-written files back (they stay sandbox-owned), session-hook
# stops reclaiming .git and stops the session-end sweep, and filter-hook stops filtering. The
# first two are ownership guarantees, so this is Requires rather than Recommends.
Requires:       jq
# gnupg2 provides gpgv, the verify-only half this uses to check the vendor's signed release
# manifest before trusting the checksum it publishes for this agent's entrypoint
# (entrypoint-verify.lib.sh). Absent it, the verification degrades to "unable to verify" and the
# entrypoint is never pinned -- so like jq this is Requires, not Recommends: the declaration in
# this package's manifest is what makes the check meaningful, and shipping the declaration without
# the verifier would leave every host silently unverified.
Requires:       gnupg2
# Renamed from claude-code-restricted; see the note on ai-tools-integration-nodejs for why the
# pair is required rather than cosmetic. This one also owns the launch wrapper and the hooks, so
# without the Obsoletes an install alongside the old name is a file conflict.
Provides:       claude-code-restricted = %{version}-%{release}
Obsoletes:      claude-code-restricted < 0.7.0-1

%description -n ai-tools-agents-claude-code-restricted
The Claude Code provider layer: the `claude` launch wrapper, the agent manifest
that tells the toolchain which npm package to provision and ai-tools-run which
executable may launch, its session-env fragment, and the Claude Code hooks that
drive ownership handback and secret quarantine. Confinement itself is the
base-owned ai-tools-run shim, so a sibling ai-tools-agents-* provider sits beside
this one on the same base and integration layers.

%prep
%autosetup

%build
# Substitute the constant sandbox-account tokens. The per-operator @PROJECTS_*@ tokens are
# intentionally left literal: they are resolved at runtime from /etc/ai-tools/operator.conf
# (written by ai-tools-admin), so every host ships identical files.
grep -rlZ -e '@SANDBOX_USER@' -e '@SANDBOX_GROUP@' src \
    | xargs -0 -r sed -i -e 's/@SANDBOX_USER@/ai-tools/g' -e 's/@SANDBOX_GROUP@/ai-tools/g'
# Stamp the package version into the CLI (`ai-tools --version`).
grep -rlZ '@AI_TOOLS_VERSION@' src \
    | xargs -0 -r sed -i 's/@AI_TOOLS_VERSION@/%{version}-%{release}/g'

%install
# The /opt control plane and the /var trees ship root:ai-tools and stay that way: root (not the
# agent) owns the locked control files while the agent reaches its state through group ai-tools.
# No step re-owns them to a person -- the operators drive the shared ai-tools account and reach
# the launcher through an o+x search bit, so the agent is never the owner of a locked dir.

# ── base: root helpers ───────────────────────────────────────────────────────
install -d -m 0750 %{buildroot}%{ai_libexecdir}
for h in ai-tools-chown ai-tools-setgid ai-tools-setfacl ai-tools-unclaim \
         ai-tools-lockdown ai-tools-relabel ai-tools-safedir ai-tools-reclaim \
         ai-tools-allowlist ai-tools-audit ai-tools-stop ai-tools-admin; do
    install -m 0750 src%{ai_libexecdir}/${h}.sh %{buildroot}%{ai_libexecdir}/${h}
done
install -m 0750 src%{ai_libexecdir}/ai-tools-handback.py %{buildroot}%{ai_libexecdir}/ai-tools-handback

# ai-tools-admin is typed by an administrator (documented as a bare command) and is the one
# base helper that is not daemon- or sudoers-invoked by fixed path, so it gets a symlink in
# %{_sbindir}: sudo resolves a bare command against the sudoers secure_path, which on stock
# EL is /sbin:/bin:/usr/sbin:/usr/bin and does NOT include /usr/local/sbin. The target keeps
# its canonical %{ai_libexecdir} path. Provisioning is a verb on it (`system bootstrap`) rather
# than a name of its own.
install -d -m 0755 %{buildroot}%{_sbindir}
ln -s %{ai_libexecdir}/ai-tools-admin %{buildroot}%{_sbindir}/ai-tools-admin

# ── base: CLI + handback client ──────────────────────────────────────────────
install -d -m 0755 %{buildroot}%{ai_bindir}
install -m 0755 src%{ai_bindir}/ai-tools.sh                 %{buildroot}%{ai_bindir}/ai-tools
install -m 0750 src%{ai_bindir}/ai-tools-handback-client.py %{buildroot}%{ai_bindir}/ai-tools-handback-client
# ai-tools(1) man page; the man1 dir is owned by the filesystem package, so only the page
# ships. brp-compress may gzip it (hence the %%files glob).
install -d -m 0755 %{buildroot}%{ai_mandir}/man1
install -m 0644 src%{ai_mandir}/man1/ai-tools.1             %{buildroot}%{ai_mandir}/man1/ai-tools.1
# ai-tools-admin(8): section 8 because every command it documents refuses a non-root caller.
install -d -m 0755 %{buildroot}%{ai_mandir}/man8
install -m 0644 src%{ai_mandir}/man8/ai-tools-admin.8       %{buildroot}%{ai_mandir}/man8/ai-tools-admin.8
# operator.conf(5): the host options and the shared KEY=value grammar they are written in.
install -d -m 0755 %{buildroot}%{ai_mandir}/man5
install -m 0644 src%{ai_mandir}/man5/operator.conf.5        %{buildroot}%{ai_mandir}/man5/operator.conf.5
# The CLI gets a %%{_sbindir} symlink for the OPPOSITE reason ai-tools-admin does: its
# mutating verbs must never run under sudo, and without the symlink `sudo ai-tools` dies with
# sudo's "command not found" (%%{ai_bindir} is not in secure_path) before the CLI's own
# refusal -- run as the projects user, drop the sudo -- can explain the right invocation.
# That only holds for a caller sudo will exec at all: an operator whose only grant is the
# %%ai-ops drop-in is refused by sudo first, and meets sudo's message rather than the CLI's.
# The symlink also carries the read-only reports, which the CLI now accepts as root.
ln -s %{ai_bindir}/ai-tools %{buildroot}%{_sbindir}/ai-tools

# ── base: shared libraries ───────────────────────────────────────────────────
# 0751: group SANDBOX_GROUP r-x for the agent; world-execute so an operator (not a
# SANDBOX_GROUP member under multi-operator) can traverse in to source the 644
# world-readable libs by path without listing the dir. The 640 files self-protect.
install -d -m 0751 %{buildroot}%{ai_libdir}
for l in log msg conf skip-dirs owner-only relabel secret-patterns operator control-plane safe-paths confinement npm-verify entrypoint-verify managed-assets providers selinux-groups filters services; do
    install -m 0644 src%{ai_libdir}/${l}.lib.sh %{buildroot}%{ai_libdir}/${l}.lib.sh
done
# Provider manifest + fragment directories (base owns the dirs; each member package ships its own
# files here): agents.d/<name>.conf and integrations.d/<name>.conf manifests, and
# session-env.d/<name>.env.sh fragments. providers.lib.sh reads the manifests to keep the
# toolchain and launch layers provider-agnostic; ai-tools-run sources the fragment of each enabled
# provider, agent and integration alike.
install -d -m 0755 %{buildroot}%{ai_libdir}/agents.d
install -d -m 0755 %{buildroot}%{ai_libdir}/integrations.d
install -d -m 0755 %{buildroot}%{ai_libdir}/session-env.d
# Contributed ai-tools-admin command domains, keyed by name the same way: admin-commands.d/<name>,
# an executable ai-tools-admin execs after checking that it and this directory are root-owned and
# not group- or other-writable. Base owns the directory and does not put a file in it; each
# provider package ships the domain named for itself.
install -d -m 0755 %{buildroot}%{ai_libdir}/admin-commands.d
# Token-saving command-filter rule sets, keyed by name the same way: filters.d/<name>.rules. Base
# owns the directory and ships core.rules, the set every host gets; a package with commands of its
# own ships one beside it. An agent's filter hook reads them through filters.lib.sh.
install -d -m 0755 %{buildroot}%{ai_libdir}/filters.d
install -m 0644 src%{ai_libdir}/filters.d/core.rules %{buildroot}%{ai_libdir}/filters.d/core.rules
# Pinned vendor release-signing keys, keyed by agent: keys/<agent>.asc. Base owns the directory
# and ships none -- the key that signs an agent's releases belongs to that agent's package, the
# same split as agents.d. entrypoint-verify.lib.sh verifies a release manifest against the key its
# manifest names, so the key is SHIPPED rather than fetched (a fetched key proves only that whoever
# served the manifest served the key).
install -d -m 0755 %{buildroot}%{ai_libdir}/keys
# The shared confinement shim. Base-owned and agent-agnostic: it resolves which agent may launch
# from the manifests above, so an ai-tools-agents-* package ships only its wrapper, manifest, and
# session-env fragment, and one sudoers grant serves every agent.
install -d -m 0755 %{buildroot}/opt/ai-tools/bin
install -m 0550 src/opt/ai-tools/bin/ai-tools-run.sh %{buildroot}/opt/ai-tools/bin/ai-tools-run
# PATH dedup fragment for operator shells; ai-tools-admin wires the source line into
# operator dotfiles, so no /etc/profile.d entry ships.
install -m 0644 src%{ai_libdir}/path-dedup.sh %{buildroot}%{ai_libdir}/path-dedup.sh

# ── base: handback systemd units ─────────────────────────────────────────────
install -d -m 0755 %{buildroot}%{_unitdir}
install -m 0644 src%{_unitdir}/ai-tools-handback.socket    %{buildroot}%{_unitdir}/
install -m 0644 src%{_unitdir}/ai-tools-handback@.service  %{buildroot}%{_unitdir}/
# Preset that enables the socket on install; without it the distro default leaves it disabled.
install -d -m 0755 %{buildroot}%{_presetdir}
install -m 0644 src%{_presetdir}/85-ai-tools.preset %{buildroot}%{_presetdir}/

# ── base: sysusers ───────────────────────────────────────────────────────────
install -d -m 0755 %{buildroot}%{_sysusersdir}
install -m 0644 %{SOURCE1} %{buildroot}%{_sysusersdir}/ai-tools.conf

# ── base: static %ai-ops sudoers drop-in (the @SANDBOX_*@ tokens are substituted in %build;
#    %ai-ops is literal, so the file is host-identical and ships unchanged). Packaged %config
#    (replace, not noreplace) so an upgrade always installs the shipped rule -- see %files. ──
install -d -m 0750 %{buildroot}%{_sysconfdir}/sudoers.d
install -m 0440 src%{_sysconfdir}/sudoers.d/ai-tools %{buildroot}%{_sysconfdir}/sudoers.d/ai-tools

# ── base: host-config template. The @PROJECTS_USER@ token stays literal at build (the
#    operator is a runtime identity), so stage the template with OPERATORS emptied;
#    `ai-tools-admin operators add` fills it in place. %config(noreplace) keeps the
#    operator's OPERATORS/SKIP_* edits across upgrades. ──
install -d -m 0755 %{buildroot}%{_sysconfdir}/ai-tools
sed 's/^OPERATORS=.*/OPERATORS=""/' src%{_sysconfdir}/ai-tools/operator.conf \
    > %{buildroot}%{_sysconfdir}/ai-tools/operator.conf
chmod 0644 %{buildroot}%{_sysconfdir}/ai-tools/operator.conf

# ── ai-tools-selinux: SELinux policy packages (prebuilt) ─────────────────────
# Staged here, shipped in the ai-tools-selinux subpackage (which also carries the load/unload
# scriptlets and the GPL licence text -- see its %%package block).
# The core (loaded on install) plus each STABLE optional group. Only stable groups ship
# prebuilt: they are toggled per host with `ai-tools-admin selinux groups enable <name>`,
# which semodule-loads the prebuilt .pp from this directory (no source tree or
# selinux-policy-devel needed). EXPERIMENTAL groups are NOT shipped -- they are compiled and
# verified from a source checkout on demand (install-selinux.sh enable-group + the avc loop);
# ai-tools-admin points the operator there rather than loading an unaudited module. Keep this
# list in step with the stable set in selinux-groups.lib.sh.
install -d -m 0755 %{buildroot}%{_datadir}/selinux/packages/ai-tools
# On Fedora, compile the .pp from the shipped .te/.fc/.if via the refpolicy Makefile (in the
# tarball for GPL compliance) so the module targets the host's own refpolicy version; on EL, serve
# the committed prebuilt. The .fc source -- carrying the /usr/local/libexec/ai-tools helper path --
# is the single source both consume, so the layout is identical on either build. The %{?dist} tag
# (.fc44 vs .el10) keeps a Fedora-built .pp from ever reaching an EL host or vice versa.
%if 0%{?fedora}
make -C selinux/policy ai_tools.pp ai_tools_tmpmap.pp
%endif
for pp in ai_tools ai_tools_tmpmap; do
    install -m 0644 selinux/policy/${pp}.pp \
        %{buildroot}%{_datadir}/selinux/packages/ai-tools/${pp}.pp
done

# ── base: sandbox project workflow tree + operation-log dir ──────────────────
install -d -m 2750 %{buildroot}/var/opt/ai-tools
install -d -m 2770 %{buildroot}/var/opt/ai-tools/sandbox-projects
install -d -m 0750 %{buildroot}/var/opt/ai-tools/state
# Verified entrypoint pins, one file per agent, written by ai-tools-relabel-agent as root and read
# by the launch shim as the sandbox account. Root-owned and NOT group-writable, like its parent:
# the whole value of a pin is that the account it constrains cannot write it.
install -d -m 0755 %{buildroot}/var/opt/ai-tools/state/entrypoint-pin.d
# What the last reconciliation could do about each agent's SELinux labels -- the labelling half's
# counterpart to the pin above, written by the same helper and read by `ai-tools --status`. Same
# ownership for the same reason: it reports on the sandbox account, which must not be able to
# rewrite it.
install -d -m 0755 %{buildroot}/var/opt/ai-tools/state/entrypoint-label.d
install -m 0640 src/var/opt/ai-tools/README.md %{buildroot}/var/opt/ai-tools/README.md
install -d -m 0700 %{buildroot}/var/log/ai-tools

# ── base: control-plane home root + bin (files added by nodejs/claude; the agent's own config
#    directory is staged in its section below). Staging modes are writable so files can be placed
#    here; the installed modes come from the file lists below. ──
install -d -m 0755 %{buildroot}/opt/ai-tools
install -d -m 0755 %{buildroot}/opt/ai-tools/bin
# The shared asset roots: agent-agnostic content the base owns, symlinked into each agent's own
# directories rather than copied per agent.
install -d -m 0750 %{buildroot}/opt/ai-tools/skills
install -d -m 0750 %{buildroot}/opt/ai-tools/subagents
# The integration state root: each ai-tools-integration-* package creates its own directory
# under it (integrations/<name>), and one static file-context rule covers them all.
install -d -m 0750 %{buildroot}/opt/ai-tools/integrations
# Default-deny git guard for the control-plane home: ai-tools-bootstrap captures the control
# plane in a root-private git repo, and this gitignore keeps secrets and churn out of it. The
# LIVE /opt/ai-tools/.gitignore is NOT rpm-owned -- neither it nor the host-derived .gitconfig
# is listed in %files, so an erase preserves both (operator state, like .nvm and the clones).
# The canonical guard ships read-only under %{_datadir} as the reseed source; %post copies it to
# /opt/ai-tools/.gitignore, and generates .gitconfig, only when the live file is absent.
install -d -m 0755 %{buildroot}%{_datadir}/ai-tools
install -m 0644 src%{_datadir}/ai-tools/gitignore %{buildroot}%{_datadir}/ai-tools/gitignore
# Shipped agents/skills: pristine copies under %{_datadir} are the reseed source (rpm-owned).
# They are in the CLAUDE CODE asset format, so the agent package owns them and seeds them into
# its own config directory; the base owns only the parent dir and the shared seeder library. The
# LIVE copies under that config dir are NOT rpm-owned (like .gitignore); %post seeds them when
# absent, so an erase/upgrade preserves an operator-updated copy. The interactive version update
# is offered by install.sh / ai-tools-bootstrap (managed-assets.lib.sh, the shared seeder).
cp -rT src%{_datadir}/ai-tools/subagents %{buildroot}%{_datadir}/ai-tools/subagents
cp -rT src%{_datadir}/ai-tools/skills %{buildroot}%{_datadir}/ai-tools/skills
find %{buildroot}%{_datadir}/ai-tools/subagents %{buildroot}%{_datadir}/ai-tools/skills -type d -exec chmod 0755 {} +
find %{buildroot}%{_datadir}/ai-tools/subagents %{buildroot}%{_datadir}/ai-tools/skills -type f -exec chmod 0644 {} +

# ── integration-nodejs: toolchain helpers + updater ──────────────────────────
for h in ai-tools-launcher-symlink ai-tools-relabel-agent ai-tools-bootstrap; do
    install -m 0750 src%{ai_libexecdir}/${h}.sh %{buildroot}%{ai_libexecdir}/${h}
done
# All three are reached at their %{ai_libexecdir} paths and do not get a %{_sbindir} symlink,
# because an administrator does not type any of them: provisioning is
# `sudo ai-tools-admin system bootstrap`, which execs the helper there.
install -m 0550 src/opt/ai-tools/bin/nvm-update.sh %{buildroot}/opt/ai-tools/bin/nvm-update.sh

# ── integration-nodejs: toolchain update units + post-upgrade relabel watcher ─
# The update service+timer run in the sandbox account's own systemd --user instance
# (%{_userunitdir}); the relabel .path watches the bin/claude symlink and triggers the
# root-side .service (restorecon to ai_tools_exec_t) after a Node bump.
install -d -m 0755 %{buildroot}%{_userunitdir}
install -m 0644 src%{_userunitdir}/nvm-update.service   %{buildroot}%{_userunitdir}/nvm-update.service
install -m 0644 src%{_userunitdir}/nvm-update.timer     %{buildroot}%{_userunitdir}/nvm-update.timer
install -m 0644 src%{_unitdir}/ai-tools-relabel.path    %{buildroot}%{_unitdir}/ai-tools-relabel.path
install -m 0644 src%{_unitdir}/ai-tools-relabel.service %{buildroot}%{_unitdir}/ai-tools-relabel.service

# ── integration-dotnet: session-env fragment + manifest + admin command ──────
# The .NET SDK/runtime is the host's; this ships only the sandbox-side glue. Every file drops into
# a base-owned directory: the env fragment (session-env.d), the manifest (integrations.d), and the
# command fragment carrying this package's `dotnet` domain of ai-tools-admin (admin-commands.d),
# whose basename is the domain token an administrator types.
install -m 0644 src%{ai_libdir}/session-env.d/dotnet.env.sh %{buildroot}%{ai_libdir}/session-env.d/dotnet.env.sh
install -m 0644 src%{ai_libdir}/integrations.d/dotnet.conf  %{buildroot}%{ai_libdir}/integrations.d/dotnet.conf
# Its command-filter rules (SDK verbosity), which are .NET knowledge and so ship with the .NET
# package rather than in the base's core.rules.
install -m 0644 src%{ai_libdir}/filters.d/dotnet.rules      %{buildroot}%{ai_libdir}/filters.d/dotnet.rules
install -m 0750 src%{ai_libdir}/admin-commands.d/dotnet.sh  %{buildroot}%{ai_libdir}/admin-commands.d/dotnet
# Ghost this helper's operation log alongside the base helpers' (the /var/log/ai-tools dir itself
# is base-owned), so it carries the package's context and is removed with the package.
touch %{buildroot}/var/log/ai-tools/dotnet.log

# ── agents-claude: launch wrapper + hooks + settings ─────────────────────────
# This agent's payload lives at src/opt/ai-tools/agents/claude-code/ -- named for its MANIFEST,
# not for the .claude directory it installs into, because that destination is manifest data
# (config_dir). A second agent adds a sibling directory named for its own manifest.
# The wrapper ships root:root 0755 in /usr/local/bin (Tier 1 in path-dedup.sh, wired into
# operator dotfiles by ai-tools-admin, so it shadows the nvm-managed claude on every
# operator's PATH); it runs as the invoking operator, gates on ai-ops membership, then drops
# to the sandbox account via sudo.
install -m 0755 src%{ai_bindir}/claude.sh                  %{buildroot}%{ai_bindir}/claude
# This agent's config directory, the one its manifest declares (config_dir=.claude).
install -d -m 0770 %{buildroot}/opt/ai-tools/.claude
install -m 0750 src/opt/ai-tools/agents/claude-code/post-tool-hook.sh %{buildroot}/opt/ai-tools/.claude/post-tool-hook.sh
install -m 0750 src/opt/ai-tools/agents/claude-code/session-hook.sh   %{buildroot}/opt/ai-tools/.claude/session-hook.sh
install -m 0750 src/opt/ai-tools/agents/claude-code/filter-hook.sh    %{buildroot}/opt/ai-tools/.claude/filter-hook.sh
install -m 0640 src/opt/ai-tools/agents/claude-code/settings.json     %{buildroot}/opt/ai-tools/.claude/settings.json
# The claude-code agent manifest: providers.lib.sh reads it so the toolchain layer installs the
# Claude npm package and symlinks the claude launcher without hardcoding either (the agents.d
# directory itself is owned by ai-tools-base).
install -m 0644 src%{ai_libdir}/agents.d/claude-code.conf  %{buildroot}%{ai_libdir}/agents.d/claude-code.conf
# The pinned Anthropic release-signing key (published at downloads.claude.ai/keys/claude-code.asc).
# Plain rpm-owned data, NOT %%config: the pin must change only when a signed package installs a new
# one, never by an edit on the host. Its fingerprint is declared in the manifest above and asserted
# against gpgv's output, so this file alone does not decide what may sign a release.
install -m 0644 src%{ai_libdir}/keys/claude-code.asc %{buildroot}%{ai_libdir}/keys/claude-code.asc
# Its session env (config dir, compile cache, in-session updater), sourced by ai-tools-run last
# so the agent's own pins are authoritative over an integration's.
install -m 0644 src%{ai_libdir}/session-env.d/claude-code.env.sh %{buildroot}%{ai_libdir}/session-env.d/claude-code.env.sh
# Claude Code-specific resolvers (the base owns the lib directory; the agent ships these into it):
# the custom system prompt (claude.sh, wrapper-side) and the custom API endpoint (the fragment
# above, sandbox-side). Both split their pure logic out for unit testing.
install -m 0644 src%{ai_libdir}/claude-prompt.lib.sh   %{buildroot}%{ai_libdir}/claude-prompt.lib.sh
install -m 0644 src%{ai_libdir}/claude-endpoint.lib.sh %{buildroot}%{ai_libdir}/claude-endpoint.lib.sh
# The empty default custom system prompt and the endpoints directory with its inert endpoint
# template; the operator edits each in place, both %config(noreplace) so those edits survive an
# upgrade. Both files are 0640 root:ai-tools: the sandbox account reads them (the fragment reads the
# endpoint, and claude.sh hands the prompt path to the confined binary) while neither is world-
# readable -- the endpoint holds a bearer token, and a custom prompt may be proprietary. The dirs
# stay 0755 so claude.sh can stat the prompt file as the operator.
install -d -m 0755 %{buildroot}%{_sysconfdir}/ai-tools/prompts
install -m 0640 src%{_sysconfdir}/ai-tools/prompts/claude-system-prompt.md \
    %{buildroot}%{_sysconfdir}/ai-tools/prompts/claude-system-prompt.md
install -d -m 0755 %{buildroot}%{_sysconfdir}/ai-tools/endpoints
install -m 0640 src%{_sysconfdir}/ai-tools/endpoints/custom-claude-endpoint.conf \
    %{buildroot}%{_sysconfdir}/ai-tools/endpoints/custom-claude-endpoint.conf

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
# Enables the socket on first install per 85-ai-tools.preset (no-op on upgrade, so a later
# operator disable survives). Only enables; posttrans starts it.
%systemd_post ai-tools-handback.socket
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
    # Traverse only on the state dir: operators read the stamps inside (whose own group is
    # ai-ops), never write there. What the mode buys is scope, not integrity -- a stamp's CONTENT
    # is written by the sandbox account and trusted accordingly (see services.lib.sh).
    setfacl -m g:ai-ops:r-x /var/opt/ai-tools/state || :
fi
# Re-assert the setgid bit on the sandbox tree -- rpm 4.19+ drops it from these %attr(2xxx) %dir
# entries on install. Done in %post AND %posttrans because which one survives is rpm-dependent
# (some rpm re-applies %attr after %post); both are idempotent no-ops on a host that kept the bit.
# NB the container-image (OCI) layer preserves these two writes inconsistently across distros, so
# the rpm-selftest RE-ASSERTS setgid at runtime (container-selftest.sh) -- this pair is for real
# hosts, which have no image layer.
chmod 2750 /var/opt/ai-tools 2>/dev/null || :
chmod 2770 /var/opt/ai-tools/sandbox-projects 2>/dev/null || :
# Control-plane git guard + identity for the repo ai-tools-bootstrap captures (the RPM
# counterpart of install.sh's do_install .gitignore/.gitconfig steps). Neither file is
# rpm-owned, so an erase preserves them; %post reseeds each ONLY when absent (install.sh's
# keep_existing semantics), so a fresh install or upgrade self-heals a missing guard while an
# existing -- possibly operator-customised -- file is never clobbered. This runs on every
# transition, not fresh-install only, so a file lost to an earlier package's config handling is
# restored. No operator is bound yet at %post time (that is `ai-tools-admin operators add`, run
# after this), so the .gitconfig email uses the hostname -f fallback.
if [ ! -f /opt/ai-tools/.gitignore ]; then
    install -m 0640 -o root -g ai-tools \
        %{_datadir}/ai-tools/gitignore /opt/ai-tools/.gitignore
fi
if [ ! -f /opt/ai-tools/.gitconfig ]; then
    domain="$(hostname -f 2>/dev/null || hostname)"
    printf '[user]\n\tname = ai-tools\n\temail = ai-tools@%s\n\n[core]\n\tfileMode = true\n\tautocrlf = input\n\n[init]\n\tdefaultBranch = main\n\n[pull]\n\trebase = false\n' \
        "${domain}" > /opt/ai-tools/.gitconfig
    chown root:ai-tools /opt/ai-tools/.gitconfig
    chmod 0644 /opt/ai-tools/.gitconfig
fi
# Relabel the reseeded files: the -R restorecon above ran before this block created them, so
# label them explicitly (no-op when SELinux is off or they already carry the right context).
if command -v restorecon >/dev/null 2>&1; then
    restorecon /opt/ai-tools/.gitignore /opt/ai-tools/.gitconfig >/dev/null 2>&1 || :
fi
# Seed each ai-tools-managed SHARED kind into its own root, reusing the seeder under an explicit
# bash (the lib is bash; a %post scriptlet runs under /bin/sh). Skills and subagent definitions
# are agent-agnostic, so they are seeded once here and each agent package symlinks them into the
# directories it reads. A newer shipped version replaces the live copy, then withdrawn assets are
# moved to /opt/ai-tools/retired: the live roots are not rpm-owned, so an upgrade leaves an asset
# this package no longer ships in place until this runs.
# AI_TOOLS_ASSUME_YES answers the update confirm here rather than letting it fall through to its
# default. The outcome is the same either way -- the default IS yes, and a scriptlet has no tty to
# answer with -- but the prompt is written to /dev/tty, which succeeds when dnf runs on a terminal,
# so without this the operator is shown a question that no one can answer and that is then decided
# without them. Pre-answering skips drawing it, and the decision audits as `assume-yes` rather than
# `default`, which is what actually happened. It cannot widen anything: the variable fast-tracks a
# question whose default is already yes and never flips a default-NO one (see msg.lib.sh).
# conf.lib.sh comes first -- it owns the dated-sidecar stamp both of those steps preserve through.
# stdout is kept so `dnf upgrade` reports what changed; a host that never sees these lines cannot
# tell that a shipped asset moved.
for kind in skills subagents; do
    [ -d %{_datadir}/ai-tools/${kind} ] && command -v bash >/dev/null 2>&1 || continue
    AI_TOOLS_ASSUME_YES=1 bash -c ". /usr/local/lib/ai-tools/msg.lib.sh; . /usr/local/lib/ai-tools/conf.lib.sh; . /usr/local/lib/ai-tools/managed-assets.lib.sh; ai_tools_seed_managed_assets %{_datadir}/ai-tools /opt/ai-tools ai-tools ${kind}; ai_tools_remove_retired_assets /opt/ai-tools ${kind}; ai_tools_link_asset_readme %{_datadir}/ai-tools/${kind}/README.md /opt/ai-tools/${kind} ai-tools" 2>/dev/null || :
done
# Direct the operator to the per-operator / network steps a scriptlet must not take itself.
# Each is gated on the state it would create rather than on install-vs-upgrade, so an upgrade
# names only what this host still owes, a step undone since an earlier run included. An operator
# is two facts -- ai-ops membership and a name in OPERATORS (cli.rule.md) -- so either one
# missing asks for `operators add`, which writes both. OPERATORS ships holding the literal
# @PROJECTS_USER@ token, which the name-character class excludes. A gate that cannot read its
# input prints its hint.
_at_toolchain=1
_at_operator=1
_at_merge=0
if [ -d /opt/ai-tools/.nvm ]; then
    _at_toolchain=0
fi
if [ -n "$(getent group ai-ops 2>/dev/null | cut -d: -f4)" ] \
   && grep -Eq '^[[:space:]]*OPERATORS[[:space:]]*=[[:space:]]*"?[A-Za-z0-9_]' \
        /etc/ai-tools/operator.conf 2>/dev/null; then
    _at_operator=0
fi
# operator.conf is config(noreplace), so an edited file is kept and this version's copy parked as
# .rpmnew. Ignoring it costs silently: an option this version adds never reaches the host.
if [ -f /etc/ai-tools/operator.conf.rpmnew ]; then
    _at_merge=1
fi
if [ "${_at_toolchain}${_at_operator}${_at_merge}" != "000" ]; then
    echo "ai-tools-base: steps this host still needs:"
    if [ "${_at_toolchain}" = 1 ]; then
        echo "  sudo ai-tools-admin system bootstrap          # install nvm + Node + Claude Code (network)"
    fi
    if [ "${_at_operator}" = 1 ]; then
        echo "  sudo ai-tools-admin operators add <your-user> # bind an operator (ai-ops, OPERATORS, linger)"
    fi
    if [ "${_at_merge}" = 1 ]; then
        echo "  sudo ai-tools-admin system post-upgrade       # operator.conf.rpmnew is waiting"
    fi
fi

%preun -n ai-tools-base
%systemd_preun ai-tools-handback.socket

%postun -n ai-tools-base
%systemd_postun_with_restart ai-tools-handback.socket
# Intentionally preserved on erase (not rpm-owned): the ai-tools account, /opt/ai-tools/.nvm, the
# control-plane .gitignore/.gitconfig, /var/opt/ai-tools clones, and each operator's
# ~/.config/ai-tools. The SELinux module unload lives with the policy payload, in
# %postun -n ai-tools-selinux.

%posttrans -n ai-tools-base
# Start the socket so the handback is live without a reboot (posttrans runs after the systemd
# daemon-reload file trigger). Idempotent; guarded so a systemd-less build/image fails soft.
systemctl start ai-tools-handback.socket 2>/dev/null || :

# Re-assert setgid after all file ops (some rpm re-applies %attr after %post, dropping it). Paired
# with the %post copy; both idempotent. See the %post comment for the container-image caveat.
chmod 2750 /var/opt/ai-tools 2>/dev/null || :
chmod 2770 /var/opt/ai-tools/sandbox-projects 2>/dev/null || :

# Helper-layout migration (0.10.0): the root helper tree moved
# /usr/local/sbin/ai-tools -> /usr/local/libexec/ai-tools so ONE layout serves EL and the
# Fedora bin/sbin merge. rpm's own file handling completes the move (old helpers leave %files
# and are deleted; the sudoers drop-in is now plain %config, replaced on an unmodified host).
# This scriptlet is the fail-safe for a host that reaches 0.10.0 while STILL on the old
# noreplace sudoers file (its new-path copy parked inert as .rpmnew), plus a guarded sweep of an
# empty old helper dir. Every step fails closed: it only ever rewrites a validated file or
# removes an already-empty rpm-orphaned dir, and never touches operator config.
_su=/etc/sudoers.d/ai-tools
_old=/usr/local/sbin/ai-tools
_new=/usr/local/libexec/ai-tools
# Rewrite a lingering old-path relabel-agent rule to the new path, but only through a
# visudo-validated temp file swapped in atomically; on any validation failure leave the working
# file untouched and report, so a malformed rewrite can never disable or widen the guardrail.
if command -v visudo >/dev/null 2>&1 && [ -f "${_su}" ] && grep -q "${_old}/" "${_su}" 2>/dev/null; then
    if visudo -cf "${_su}" >/dev/null 2>&1; then
        _tmp="${_su}.rpmmig.$$"    # dotted suffix: sudo ignores it even if a failure strands it
        if sed "s#${_old}/#${_new}/#g" "${_su}" > "${_tmp}" 2>/dev/null \
           && visudo -cf "${_tmp}" >/dev/null 2>&1; then
            chmod 0440 "${_tmp}" 2>/dev/null || :
            chown root:root "${_tmp}" 2>/dev/null || :
            mv -f "${_tmp}" "${_su}"    # atomic same-dir rename
            command -v restorecon >/dev/null 2>&1 && restorecon "${_su}" >/dev/null 2>&1 || :
            echo "ai-tools: migrated the sudoers relabel-agent rule to ${_new} (helper layout moved)."
        else
            rm -f "${_tmp}" 2>/dev/null || :
            echo "ai-tools: WARNING could not migrate ${_su} to the new helper path; edit it with visudo and point the relabel-agent rule at ${_new}." >&2
        fi
    else
        echo "ai-tools: WARNING ${_su} does not validate; not migrating the helper path automatically. Run visudo -cf ${_su}." >&2
    fi
fi
# Remove the old helper directory only if it is a real, empty directory (rpm deletes the old
# helper files as they leave %files, but the %dir may linger on a partial state). Never a symlink
# (a Fedora host where /usr/local/sbin -> /usr/local/bin) and never recursive/forced.
if [ -d "${_old}" ] && [ ! -L "${_old}" ]; then
    rmdir "${_old}" 2>/dev/null || :
fi

%post -n ai-tools-selinux
# Load the core module into the RUNNING policy and apply contexts. Core only -- the stable
# optional groups ship prebuilt alongside it but stay OFF, toggled per host with
# `ai-tools-admin selinux groups enable <name>` (experimental groups are not shipped).
#
# `semodule -i` loads into the RUNNING policy, not just the module store: the entrypoint is
# labelled by the restorecon below only once the module's types exist in the kernel, and
# ai-tools-run's preflight refuses to launch (`mislabel`) while it is unlabelled. The default
# module priority puts this in the same slot selinux/install-selinux.sh and `ai-tools-admin
# selinux groups enable` address, so one host holds one copy of each module and a package upgrade
# always supersedes what it replaces.
#
# After relabelling the daemon binary, refresh an already-active handback socket (an upgrade): the
# listener bound on tmpfs /run/ai-tools keeps its stale context and its handler runs
# unconfined_service_t, so ai_tools_t's connectto is denied and every hook handback silently no-ops.
# daemon-reexec + socket restart re-derive the listener context from the now-correct binary label.
# Guarded on is-active, so a fresh install (base %posttrans starts it later, already correct) no-ops.
# Same sequence as install-selinux.sh _relabel_runtime; rationale in confinement.rule.md.
#
# A failed load is REPORTED rather than swallowed: every type the entrypoint and the project
# labels name comes from this module, so a load that did not happen surfaces later as a relabel
# that cannot register its rules and a launch that fail-closes, with no message naming this as the
# cause. The transaction still completes -- the remedy is a re-run, not a rollback.
if [ "$(getenforce 2>/dev/null)" != "Disabled" ] && command -v semodule >/dev/null 2>&1; then
    _semodule_error=$(semodule -i %{_datadir}/selinux/packages/ai-tools/ai_tools.pp 2>&1) || {
        echo "ai-tools-selinux: WARNING could not load the ai_tools policy module: ${_semodule_error}" >&2
        echo "ai-tools-selinux: sessions run unconfined until it loads; re-run: sudo semodule -i %{_datadir}/selinux/packages/ai-tools/ai_tools.pp" >&2
    }
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -R %{ai_libexecdir} %{ai_libdir} /opt/ai-tools /var/log/ai-tools >/dev/null 2>&1 || :
    fi
    if command -v systemctl >/dev/null 2>&1 \
       && systemctl is-active --quiet ai-tools-handback.socket 2>/dev/null; then
        systemctl daemon-reexec >/dev/null 2>&1 || :
        systemctl restart ai-tools-handback.socket >/dev/null 2>&1 || :
        command -v restorecon >/dev/null 2>&1 && restorecon -R /run/ai-tools >/dev/null 2>&1 || :
    fi
fi

%postun -n ai-tools-selinux
# On final erase only, unload every loaded ai_tools module -- the core, any stable optional group
# enabled with `ai-tools-admin selinux groups enable`, and any EXPERIMENTAL group compiled from a
# source checkout. Enumerated rather than named: a .pp is erased with the package, but the
# compiled module persists in the policy store until removed, and a module built from source was
# never in the rpm database at all. Leaving one loaded would keep a domain alive for files the
# package no longer owns.
if [ "$1" -eq 0 ] && command -v semodule >/dev/null 2>&1; then
    mods=$(semodule -l 2>/dev/null | grep -E '^ai_tools(_|$)' || :)
    [ -n "${mods}" ] && semodule $(printf ' -r %s' ${mods}) >/dev/null 2>&1 || :
fi

%post -n ai-tools-integration-nodejs
# Enable the root-side relabel watcher (system unit). The nvm-update.timer is a --user unit
# enabled in the sandbox account's own instance by ai-tools-bootstrap, which is where that
# instance is brought up with linger -- a scriptlet cannot reliably reach it.
%systemd_post ai-tools-relabel.path
# Create the updater's last-run stamp (%ghost, so rpm owns the path without shipping content). The
# state directory is root-owned and not group-writable on purpose, so nvm-update.sh can only
# REWRITE this inode, never create it -- which is exactly what keeps the surface to one file. Owned
# by the sandbox account (the writer) with group ai-ops (the readers). Idempotent; an existing
# stamp keeps its content, and a %ghost path is not removed on upgrade.
if [ -d /var/opt/ai-tools/state ]; then
    [ -e /var/opt/ai-tools/state/nvm-update.status ] \
        || : > /var/opt/ai-tools/state/nvm-update.status
    chown ai-tools:ai-ops /var/opt/ai-tools/state/nvm-update.status 2>/dev/null || :
    chmod 0640 /var/opt/ai-tools/state/nvm-update.status 2>/dev/null || :
fi

%preun -n ai-tools-integration-nodejs
%systemd_preun ai-tools-relabel.path

%postun -n ai-tools-integration-nodejs
%systemd_postun_with_restart ai-tools-relabel.path

%posttrans -n ai-tools-integration-nodejs
# Start the relabel watcher so it is live without a reboot -- the twin of ai-tools-base's
# posttrans starting the handback socket. The nodejs post scriptlet only ENABLES the unit
# (applies the preset); a .path unit must be started to begin watching, and until it does a Node
# auto-upgrade that repoints the launcher goes unwatched and the next launch fail-closes on a
# bin_t entrypoint. posttrans runs after the systemd daemon-reload file trigger, so the unit is
# known. Idempotent; guarded so a systemd-less build/image fails soft.
# (No macro names in this comment: rpm expands macros inside scriptlet comments too.)
systemctl start ai-tools-relabel.path 2>/dev/null || :

%post -n ai-tools-integration-dotnet
# Create + SELinux-label the sandbox-side dotnet dirs (writable NuGet cache, read-only shared
# tools) the session-env fragment relies on. Offline + idempotent; the command recognizes a host
# with no enforcing ai-tools policy and skips labelling there rather than failing. Not the network
# tool install -- that stays the operator's `sudo ai-tools-admin dotnet tools install`.
#
# The command fragment is exec'd at its own path rather than through ai-tools-admin: this package
# ships it, so its presence is what the guard tests, and the dispatch would add a discovery step
# to reach a file already known here.
#
# The failure is NOT swallowed: a half-provisioned integration that looks installed surfaces later
# as an opaque denial inside a confined session. The command logs the cause (journald +
# /var/log/ai-tools/dotnet.log) and the scriptlet reports the remedy and exits non-zero, so rpm
# records a scriptlet failure against this package alone -- the transaction still completes, which
# is what a weakly-pulled optional integration should do to the rest of the stack.
if [ -x %{ai_libdir}/admin-commands.d/dotnet ]; then
    %{ai_libdir}/admin-commands.d/dotnet bootstrap >/dev/null || {
        echo "ai-tools-integration-dotnet: provisioning failed; see 'journalctl -t ai-tools-dotnet'" >&2
        echo "ai-tools-integration-dotnet: fix the cause and re-run: sudo ai-tools-admin dotnet bootstrap" >&2
        exit 1
    }
fi

%post -n ai-tools-agents-claude-code-restricted
# Register this agent's SELinux entrypoint file-context and label whatever it matches. The base
# policy is agent-agnostic (see selinux/policy/ai_tools.fc): the pattern comes from this package's
# own manifest, and the helper maps it to the base's ai_tools_exec_t as a local rule, so a
# session's domain transition fires. Offline and idempotent; it no-ops when SELinux or the
# ai_tools module is inactive, and when the toolchain is not provisioned yet (a fresh install --
# ai-tools-bootstrap relabels the entrypoint it installs).
#
# Not swallowed: an entrypoint that stays mislabelled means ai-tools-run refuses every launch, so
# the scriptlet reports the remedy and exits non-zero rather than leaving that to be discovered
# at the first `claude`.
# PIN_REUSE: this scriptlet must finish quickly and must succeed offline, and a package upgrade
# usually leaves the npm-installed entrypoint untouched. It therefore answers from the existing pin
# when the version, the declared verification inputs (this package ships the signing key, so a key
# change invalidates them) and the entrypoint's bytes are all unchanged; anything else re-fetches
# and re-verifies.
if [ -x %{ai_libexecdir}/ai-tools-relabel-agent ]; then
    AI_TOOLS_ENTRYPOINT_PIN_REUSE=1 %{ai_libexecdir}/ai-tools-relabel-agent >/dev/null || {
        echo "ai-tools-agents-claude-code-restricted: entrypoint labelling failed; see 'journalctl -t ai-tools-relabel-agent'" >&2
        echo "ai-tools-agents-claude-code-restricted: fix the cause and re-run: sudo ai-tools-admin system entrypoints relabel" >&2
        exit 1
    }
fi
# Link the shared assets (seeded by ai-tools-base) into the directories THIS agent reads them
# from: skills into skills/, subagent definitions into agents/ -- the name Claude Code uses for
# what this project calls a subagent. One symlink per asset, so an asset is authored and updated
# in one place however many agents read it. Reuses the base's seeder lib under an explicit bash
# (the lib is bash; a %post scriptlet runs under /bin/sh). Best-effort and idempotent; a real
# directory already there is never displaced.
for kind in skills:skills subagents:agents; do
    shared="/opt/ai-tools/${kind%%:*}"
    dest="/opt/ai-tools/.claude/${kind#*:}"
    readme="%{_datadir}/ai-tools/${kind%%:*}/README.md"
    [ -d "${shared}" ] && command -v bash >/dev/null 2>&1 || continue
    bash -c ". /usr/local/lib/ai-tools/msg.lib.sh; . /usr/local/lib/ai-tools/managed-assets.lib.sh; ai_tools_link_shared_assets ${shared} ${dest} ai-tools ${readme}" >/dev/null 2>&1 || :
done
# settings.json is %config(noreplace), so a host that tuned its permission rules keeps them and rpm
# parks this version's copy as .rpmnew. Choosing between the two is the operator's call, made
# through `ai-tools-admin system post-upgrade` -- a scriptlet does not edit a config file. Say so here,
# because leaving it costs silently: a hook this version ships installs its body and its data, and
# no event invokes it until its DECLARATION reaches settings.json.
if [ -f /opt/ai-tools/.claude/settings.json.rpmnew ]; then
    echo "ai-tools: settings.json.rpmnew is waiting -- this version's hook declarations are not in"
    echo "  your settings.json yet, so the hooks they declare never run. Merge them with:"
    echo "    sudo ai-tools-admin system post-upgrade"
fi

%preun -n ai-tools-agents-claude-code-restricted
# On final erase, drop the entrypoint file-context rule this package registered and restore
# default labels on what it matched -- the type it names belongs to ai-tools-base, which the host
# may erase next, and a local rule naming an undefined type breaks later relabels. Runs in %preun,
# not %postun, because the pattern is read from this package's manifest, which is still on disk
# here.
if [ "$1" -eq 0 ] && [ -x %{ai_libexecdir}/ai-tools-relabel-agent ]; then
    %{ai_libexecdir}/ai-tools-relabel-agent --remove claude-code >/dev/null 2>&1 || :
fi

# ─────────────────────────────────────────────────────────────────────────────
# File lists
# ─────────────────────────────────────────────────────────────────────────────
%files
%doc docs/rpm-packaging.md docs/project-lifecycle.md docs/entrypoint-verification.md
%doc docs/session-stop.md README.md

%files -n ai-tools-selinux
%license LICENSES/GPL-2.0-or-later.txt
%dir %{_datadir}/selinux/packages/ai-tools
%{_datadir}/selinux/packages/ai-tools/ai_tools.pp
%{_datadir}/selinux/packages/ai-tools/ai_tools_tmpmap.pp

%files -n ai-tools-base
%license LICENSE
%dir %attr(0750, root, root) %{ai_libexecdir}
%attr(0750, root, root) %{ai_libexecdir}/ai-tools-chown
%attr(0750, root, root) %{ai_libexecdir}/ai-tools-setgid
%attr(0750, root, root) %{ai_libexecdir}/ai-tools-setfacl
%attr(0750, root, root) %{ai_libexecdir}/ai-tools-unclaim
%attr(0750, root, root) %{ai_libexecdir}/ai-tools-lockdown
%attr(0750, root, root) %{ai_libexecdir}/ai-tools-relabel
%attr(0750, root, root) %{ai_libexecdir}/ai-tools-safedir
%attr(0750, root, root) %{ai_libexecdir}/ai-tools-reclaim
%attr(0750, root, root) %{ai_libexecdir}/ai-tools-allowlist
%attr(0750, root, root) %{ai_libexecdir}/ai-tools-audit
%attr(0750, root, root) %{ai_libexecdir}/ai-tools-stop
%attr(0750, root, root) %{ai_libexecdir}/ai-tools-admin
%{_sbindir}/ai-tools-admin
%attr(0750, root, root) %{ai_libexecdir}/ai-tools-handback
%attr(0755, root, root) %{ai_bindir}/ai-tools
%{_sbindir}/ai-tools
%attr(0644, root, root) %{ai_mandir}/man1/ai-tools.1*
%attr(0644, root, root) %{ai_mandir}/man5/operator.conf.5*
%attr(0644, root, root) %{ai_mandir}/man8/ai-tools-admin.8*
%attr(0750, root, ai-tools) %{ai_bindir}/ai-tools-handback-client
%dir %attr(0751, root, ai-tools) %{ai_libdir}
%attr(0644, root, root) %{ai_libdir}/log.lib.sh
%attr(0644, root, root) %{ai_libdir}/msg.lib.sh
%attr(0644, root, root) %{ai_libdir}/skip-dirs.lib.sh
%attr(0644, root, root) %{ai_libdir}/owner-only.lib.sh
%attr(0640, root, root) %{ai_libdir}/relabel.lib.sh
%attr(0640, root, root) %{ai_libdir}/secret-patterns.lib.sh
%attr(0644, root, root) %{ai_libdir}/operator.lib.sh
%attr(0644, root, root) %{ai_libdir}/control-plane.lib.sh
%attr(0644, root, root) %{ai_libdir}/managed-assets.lib.sh
%attr(0644, root, root) %{ai_libdir}/safe-paths.lib.sh
%attr(0644, root, root) %{ai_libdir}/confinement.lib.sh
%attr(0644, root, root) %{ai_libdir}/npm-verify.lib.sh
%attr(0644, root, root) %{ai_libdir}/entrypoint-verify.lib.sh
%attr(0644, root, root) %{ai_libdir}/conf.lib.sh
%attr(0644, root, root) %{ai_libdir}/providers.lib.sh
%attr(0644, root, root) %{ai_libdir}/selinux-groups.lib.sh
%attr(0644, root, root) %{ai_libdir}/filters.lib.sh
%attr(0644, root, root) %{ai_libdir}/services.lib.sh
%dir %attr(0755, root, root) %{ai_libdir}/keys
%dir %attr(0755, root, root) %{ai_libdir}/agents.d
%dir %attr(0755, root, root) %{ai_libdir}/integrations.d
%dir %attr(0755, root, root) %{ai_libdir}/session-env.d
%dir %attr(0755, root, root) %{ai_libdir}/admin-commands.d
%dir %attr(0755, root, root) %{ai_libdir}/filters.d
%attr(0644, root, root) %{ai_libdir}/filters.d/core.rules
%attr(0550, root, ai-tools) /opt/ai-tools/bin/ai-tools-run
%attr(0644, root, root) %{ai_libdir}/path-dedup.sh
%{_unitdir}/ai-tools-handback.socket
%{_unitdir}/ai-tools-handback@.service
%{_presetdir}/85-ai-tools.preset
# Plain %config (replace on upgrade), NOT noreplace: the file is host-identical by
# construction (@SANDBOX_*@ substituted to the constant ai-tools at %build, %ai-ops literal),
# so it does not hold operator config to preserve. Replace guarantees the guardrail -- including
# the sudoers path of the root relabel-agent rule -- always matches the shipped version instead
# of drifting under noreplace: on the unmodified host rpm sees on-disk == prior-packaged and
# replaces silently; on a hand-edited host it parks the old file as .rpmsave (ignored by sudo,
# which skips dotted names), so no stale-path rule ever stays active. %posttrans is the fail-safe
# for a host that upgraded while still on the old noreplace file.
%config %attr(0440, root, root) %{_sysconfdir}/sudoers.d/ai-tools
%dir %attr(0755, root, root) %{_sysconfdir}/ai-tools
%config(noreplace) %attr(0644, root, root) %{_sysconfdir}/ai-tools/operator.conf
%{_sysusersdir}/ai-tools.conf
%dir %attr(2750, root, ai-tools) /var/opt/ai-tools
%dir %attr(2770, root, ai-tools) /var/opt/ai-tools/sandbox-projects
%attr(0640, root, ai-tools) /var/opt/ai-tools/README.md
# Operator-readable state written BY the sandbox account: the last-run stamps of the units that
# live in that account's own systemd --user manager, which `ai-tools --status` cannot query from
# the operator's session (services.lib.sh reads them). root owns the directory and it is NOT
# group-writable -- the account gets traverse only, so it cannot add, unlink, rename, or
# symlink-swap anything here. Each stamp is created by the owning package's %post and rewritten in
# place by its writer, which confines the added surface to that one file's contents. Readers reach
# it through the g:ai-ops:r-x ACL %post applies (%files cannot express an ACL).
%dir %attr(0750, root, ai-tools) /var/opt/ai-tools/state
%dir %attr(0755, root, root) /var/opt/ai-tools/state/entrypoint-pin.d
%dir %attr(0755, root, root) /var/opt/ai-tools/state/entrypoint-label.d
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
# Shared asset roots: one place for each kind of agent-agnostic content; every agent's config
# directory carries symlinks into them (control-plane.lib.sh CP_SHARED_SKILLS /
# CP_SHARED_SUBAGENTS). The seeded assets inside are NOT rpm-owned, like the other control-plane
# content, so an erase preserves operator updates.
%dir %attr(0750, root, ai-tools) /opt/ai-tools/skills
%dir %attr(0750, root, ai-tools) /opt/ai-tools/subagents
# The integration state root (see the .fc rule): base owns it, each integration package owns its
# own directory inside it, and the state within is runtime data -- not rpm-owned, so an erase
# leaves a restore cache alone.
%dir %attr(0750, root, ai-tools) /opt/ai-tools/integrations
# Pristine reseed sources (rpm-owned) for both shared kinds.
%{_datadir}/ai-tools/skills
%{_datadir}/ai-tools/subagents
# /opt/ai-tools/.gitignore and .gitconfig are deliberately NOT listed here: rpm-owning them
# would delete them on erase. They are scriptlet-managed (%post reseed-if-missing) so an erase
# preserves the operator's copies. The canonical .gitignore reseed source ships read-only here.
%dir %{_datadir}/ai-tools
%{_datadir}/ai-tools/gitignore

%files -n ai-tools-integration
# Umbrella metapackage: no files of its own; weakly pulls the ai-tools-integration-* members.

%files -n ai-tools-integration-nodejs
%attr(0750, root, root) %{ai_libexecdir}/ai-tools-launcher-symlink
%attr(0750, root, root) %{ai_libexecdir}/ai-tools-relabel-agent
%attr(0750, root, root) %{ai_libexecdir}/ai-tools-bootstrap
%attr(0550, root, ai-tools) /opt/ai-tools/bin/nvm-update.sh
# The updater's last-run stamp: rewritten by nvm-update.sh on every exit, read by
# `ai-tools --status` (the base's state directory above owns the placement). Owned by the sandbox
# account so it may rewrite the contents, group ai-ops so operators read it without joining the
# sandbox group, and no world bits. %ghost with %post creating it: the content is runtime evidence,
# but the inode must exist for the account to write it -- the directory is not group-writable.
%ghost %attr(0640, ai-tools, ai-ops) /var/opt/ai-tools/state/nvm-update.status
%{_userunitdir}/nvm-update.service
%{_userunitdir}/nvm-update.timer
%{_unitdir}/ai-tools-relabel.path
%{_unitdir}/ai-tools-relabel.service

%files -n ai-tools-integration-dotnet
%attr(0644, root, root) %{ai_libdir}/session-env.d/dotnet.env.sh
%attr(0644, root, root) %{ai_libdir}/integrations.d/dotnet.conf
%attr(0644, root, root) %{ai_libdir}/filters.d/dotnet.rules
%attr(0750, root, root) %{ai_libdir}/admin-commands.d/dotnet
%ghost %attr(0600, root, root) /var/log/ai-tools/dotnet.log

%files -n ai-tools-agents
# Umbrella metapackage: no files of its own; weakly pulls the ai-tools-agents-* members.

%files -n ai-tools-agents-claude-code-restricted
# This agent owns its own control-plane directory -- the base owns the home root and bin, and
# pins the mode every agent's config dir carries (control-plane.lib.sh CP_AGENT_CONFIG_MODE), so
# a second agent ships its own directory instead of sharing this one. Setgid+sticky: the agent is
# a group-writer for its session state but cannot unlink the root-owned files below.
%dir %attr(3770, root, ai-tools) /opt/ai-tools/.claude
%attr(0644, root, root) %{ai_libdir}/agents.d/claude-code.conf
%attr(0644, root, root) %{ai_libdir}/keys/claude-code.asc
%attr(0644, root, root) %{ai_libdir}/session-env.d/claude-code.env.sh
%attr(0644, root, root) %{ai_libdir}/claude-prompt.lib.sh
%attr(0644, root, root) %{ai_libdir}/claude-endpoint.lib.sh
%attr(0755, root, root) %{ai_bindir}/claude
# Custom system prompt: an inert, editable default under a dedicated /etc/ai-tools/prompts. The
# custom API endpoint: a dedicated /etc/ai-tools/endpoints holding the endpoint file, which is
# 0640 root:ai-tools because it may carry a bearer token (not world-readable, unlike operator.conf).
%dir %attr(0755, root, root) %{_sysconfdir}/ai-tools/prompts
%config(noreplace) %attr(0640, root, ai-tools) %{_sysconfdir}/ai-tools/prompts/claude-system-prompt.md
%dir %attr(0755, root, root) %{_sysconfdir}/ai-tools/endpoints
%config(noreplace) %attr(0640, root, ai-tools) %{_sysconfdir}/ai-tools/endpoints/custom-claude-endpoint.conf
%attr(0750, root, ai-tools) /opt/ai-tools/.claude/post-tool-hook.sh
%attr(0750, root, ai-tools) /opt/ai-tools/.claude/session-hook.sh
%attr(0750, root, ai-tools) /opt/ai-tools/.claude/filter-hook.sh
%config(noreplace) %attr(0640, root, ai-tools) /opt/ai-tools/.claude/settings.json

%changelog
* Sat Sep 05 2026 dagnode <tools@dagnode.com> - 0.15.0-1
- CHANGED: The ai-tools-admin commands are spelled as a resource grammar, so the names an
  administrator types are 'operators add <user>', 'operators remove <user>', 'operators'
  (which lists them), 'selinux groups', 'selinux groups enable <name>', 'selinux groups
  disable <name>', and 'system post-upgrade'. The old spellings -- operator add, selinux
  list-groups, selinux enable-group, selinux disable-group, postupgrade -- are gone and are
  not aliased. Update any script, cron job or runbook that calls them. What each command does
  is unchanged.
- CHANGED: The entrypoint reconcile is now 'sudo ai-tools-admin system entrypoints relabel'.
  'ai-tools --relabel' is gone and is not aliased; running it prints the new command and exits 2.
  Update any script, cron job or runbook that calls it. What the command does is unchanged: it
  verifies each agent binary against the checksum its vendor signed, pins the result, then
  restores the SELinux label. The command moved because it runs as root, and root commands live on
  ai-tools-admin.
- CHANGED: Provisioning is now 'sudo ai-tools-admin system bootstrap'. The standalone
  'ai-tools-bootstrap' command is gone and is not aliased, and its /usr/sbin symlink goes with it.
  Update any script, kickstart or runbook that calls it -- the %post banner and the install
  output already print the new spelling. What the command does is unchanged, including the
  AI_TOOLS_NVM_VERSION and AI_TOOLS_NODE_MAJOR settings it reads and its re-run after enabling
  another agent. A host installed from source keeps the old /usr/sbin/ai-tools-bootstrap symlink
  until it is removed by hand; an RPM upgrade removes it.
- CHANGED: The dotnet integration is administered through 'sudo ai-tools-admin dotnet <verb>':
  'dotnet bootstrap' (was 'ai-tools-dotnet setup'), 'dotnet tools install <pkg...>' (was
  'install-tools'), and 'dotnet status'. The standalone 'ai-tools-dotnet' command is gone and is
  not aliased, and its /usr/sbin symlink goes with it, so ai-tools and ai-tools-admin are the only
  two commands this stack puts on your PATH. Update any script or runbook that calls it. What each
  command does is unchanged, including the journal tag and log file it writes
  ('journalctl -t ai-tools-dotnet', /var/log/ai-tools/dotnet.log). A host installed from source
  keeps the old /usr/sbin/ai-tools-dotnet symlink and the helper it points at until both are
  removed by hand; an RPM upgrade removes them.
- NEW: An installed provider package can add its own command domain to ai-tools-admin, which is
  how 'dotnet' arrives above. 'ai-tools-admin --help' lists the domains this host has, each with a
  line describing it, and every domain answers its own --help. Installing a package is what makes
  its commands exist -- enabling the provider in operator.conf is a separate question, and still
  decides what a session gets.
- NEW: A contributed command is checked before it runs, and every check refuses rather than
  guesses. It and its directory must be root-owned and writable by neither group nor other, and one
  file failing that refuses every contributed command on the host: only root may write there, so a
  file that is not root's alone is one something else can rewrite between runs. A packaged command
  installs in the correct state, so the remedy is to reinstall the package owning it ('rpm -qf'
  names it) and find out how the file changed -- not to re-permission it in place. Each command
  must also declare the domain it is installed as, the least ai-tools-admin interface version it
  needs, and the verbs it answers; one claiming a name ai-tools-admin already uses is refused
  rather than merged. Writing an integration of your own: the declaration is three comment lines,
  documented in .claude/rules/providers.rule.md, and a floor of 1.0 stays valid for every
  ai-tools-admin that implements 1.x.
- NEW: 'sudo ai-tools-admin system bootstrap --scope full' provisions the toolchain and then runs
  the setup of every integration enabled in operator.conf, so a host that also runs .NET is
  provisioned in one command. A bare 'system bootstrap' is unchanged and still does the minimum
  that works: the toolchain and the enabled agents.
- CHANGED: The %ai-ops sudoers drop-in is down to two rules, the session lifecycle: launch a
  session, and stop every session. The passwordless rule for the relabel helper is removed, so an
  operator who holds no general sudo grant can launch and stop sessions and cannot run the
  reconcile by hand. Nothing else changes for them: the post-upgrade relabel still runs on its own
  through the root-side watcher and the agent package's install scriptlet.
- NEW: 'ai-tools-admin --help' and '-h' print the command summary, and '--version' prints the
  installed version. The tool previously answered a wrong command with a one-line error and had
  no way to show its surface at all. Both answer any caller rather than only root, so reading
  what the tool does needs no sudo.
- NEW: ai-tools-admin(8) documents every command, its arguments, the exit codes and the files
  each one touches, with worked examples, 'system entrypoints relabel' among them.
  'man ai-tools-admin'.
- CHANGED: A rejected command line exits 2 rather than 1, so an unattended caller can tell a
  command nobody can type correctly from an operation that ran and failed. Exit 0 and exit 1
  keep their meanings.
- NEW: 'sudo ai-tools-admin status' reports the same host 'ai-tools --status' does, and completes
  the three readings an operator cannot make and sees as '?': the sandbox account's own systemd
  --user units, read live; each agent's entrypoint pin, which lives in a directory only root can
  enter; and the SELinux type each agent path carries. That last one is what no other command
  gives -- 'ai-tools --status' reports what the last relabel achieved, which may be hours old,
  while this reports the label on the file now, so a label that has drifted since is visible
  without running the reconcile. It is read-only and relabels nothing, takes no argument, and
  exits non-zero when something needs attention, so it runs from a monitor or a cron job without
  parsing its output.
- CHANGED: 'sudo ai-tools --status' now resolves the sandbox account's systemd --user units live
  instead of reporting them from their last-run stamp, so root sees the same verdicts either way.
  Run as yourself the command is unchanged. A live reading only ever adds an answer: a unit that
  is stopped or failed is reported as such outright, while one that is running is still checked
  against its last-run stamp, so a timer that is loaded but has stopped firing still reports
  STALE rather than OK.

* Mon Aug 31 2026 dagnode <tools@dagnode.com> - 0.14.0-1
- NEW: 'ai-tools --project-create <path>' creates a project: one directory, an empty git
  repository, a README.md naming it, then the ordinary claim on the result. It was an alias for
  --project-claim, which refuses a path that does not exist, so the one thing its name promised was
  the one thing it could not do. It asks nothing it can answer for itself -- no proceed
  confirmation, no secret scan and no git-history question over a tree it just created -- which
  leaves the traverse grant as the only prompt, and it takes no -y because there is nothing to
  pre-answer. A path that already exists and a parent that does not are each refused, naming the
  command that applies.
- NEW: 'ai-tools --project-remove [path]' releases a project AND deletes its directory.
  It was an alias for --project-unclaim, so the verb named after removal removed nothing;
  --project-unclaim stays the non-destructive reversal. An exact allowlist entry is the only thing
  that authorizes a deletion -- an ancestor, a path inside a project, an unregistered path, and an
  entry containing another claimed project are each refused -- and there is no --force. It confirms
  twice, a default-NO prompt and a typed project name with no default at all, so nothing is deleted
  without a terminal; only this verb's own -y pre-answers them, and -y requires an explicit path so
  an unattended run cannot delete the directory it started in.
- FIX: --project-create now produces a project the agent can actually read on a host whose umask is
  077. The directory, the README and .git were born owner-only, which the claim that follows
  honours as a deliberate seal and skips -- so the verb registered a project whose README the agent
  cannot read, having just reported that it was normalizing it. It sets group-readable modes
  instead of inheriting them, and says what it set rather than asking.
- FIX: --project-remove checks that it can unlink the project from its PARENT directory before it
  deletes anything. On a parent the operator cannot write, the deletion previously removed every
  file, failed on the top directory, and left an empty husk whose registry entries had already been
  dropped -- exactly the outcome the pre-flight exists to prevent.
- FIX: --project-remove refuses when the project's allowlist entry cannot be dropped, and names the
  line to delete by hand. That entry is the agent's launch gate, so deleting the tree past a failed
  de-registration stranded the one entry the teardown order exists to remove.
- NEW: 'ai-tools --project-disable [path]' parks a claimed project and '--project-enable [path]'
  brings it back. Parking takes a project out of service without unclaiming it: no session starts
  there and the ownership handback stops restoring files written under it, while group ownership,
  ACLs, setgid and the SELinux label are untouched -- so re-enabling grants nothing that was not
  already granted. The line is edited in place, so an allowed-projects you keep as an ordered,
  commented document comes back byte-identical after a park and a restore. --project-disable
  refuses a project nested inside another, since that line would be indistinguishable from a
  carve-out withholding a subtree, and --project-enable refuses a carve-out for the same reason.
- NEW: 'ai-tools --project-unclaim --keep-entry' hands the files back with clean permissions and
  leaves the project's line parked in place. It serves the release cycle: seal a tree before a
  release, then claim it again for the next stage without its entry moving to the end of the file.
- CHANGE: The CLI reads the parked state. A '!'-prefixed line is a workflow that predates any verb
  for it and the CLI could not see one, so a parked project was indistinguishable from a project
  never claimed: a claim appended a duplicate under an exclusion that still won and reported
  success, while --project-unclaim, --project-remove, --lockdown and --reclaim refused it as "not a
  claimed project". Entry state is now reported apart from effective reachability, since a project
  whose own line is clean can still be parked by an ancestor or a glob.
- FIX: A launch refused in a parked project names --project-enable. Both a parked project and a
  subtree an operator withheld from an enclosing project were refused as "excluded by '!' rule",
  which left the operator to work out which of the two they had -- and the screen they reached next
  offered to claim a project that was already claimed. One is now one command, the other an edit.
- FIX: './install.sh install' asks before de-registering its own checkout when that allowlist entry
  carries a comment. It matched only a line spelled exactly as the install directory, so a
  commented entry read as absent, the operator was never asked, and the entry stayed.
- FIX: A claim no longer closes with a success mark over root steps that did not apply. With a
  mistyped password all four -- group, setgid, ACLs, label -- could fail, each printing its own
  warning, and the claim still reported "claimed" over a project the agent cannot enter. It now
  reports what is still pending and exits non-zero. The first failure also asks once, default NO,
  whether to attempt the remaining steps, instead of costing three password prompts per step on a
  host where sudo caches no credential.
- FIX: --project-unclaim reports when the filesystem hand-back did not run, and exits non-zero.
  That step is what revokes the agent's access to the FILES; everything else the verb does is
  registry work, so an unclaim that under-applied told the operator access was removed while the
  tree stayed group-owned by the sandbox account. --sandbox-create no longer reports "sandbox
  ready" when git safe.directory could not be added, and --project-remove keeps its check mark for
  the deleted tree but names the cleanup that did not run.
- FIX: A claim over a tree the resolved operator does not own is refused before its first registry
  write, naming the chown that makes it claimable. 'mkdir ~/proj && ai-tools --project-claim --for
  svc ~/proj' is the common way to reach that state: every inode failed the helpers' owner guard,
  so the claim applied its registries and its label, granted nothing, and finished with a check
  mark over a project that account cannot enter.
- FIX: The setgid and ACL walks report how many paths they skipped because a third party owns them,
  with the project root stated in its own words -- every directory below an unreachable root
  inherits nothing, so that case is the outcome of the whole claim rather than one skipped path.
- FIX: Claiming a project for a secondary operator, and every 'ai-tools --project-claim --for
  <operator>', now applies the SELinux label. The label step read a single operator's
  allowlist -- the primary's -- and refused a path absent from it, so on an enforcing host the
  claim finished registered, git-trusted and ACL'd but unlabelled, which is a project the agent
  cannot work in. It was reported ("1 step(s) that grant the agent access did not apply") rather
  than silent, but it could not succeed. The label's authorization now comes from whichever
  operator's registry holds the project.
- FIX: 'ai-tools --project-claim --for <operator>' sets git's core.filemode as that operator. It
  ran git as the invoking user, so the claim either reported the target's tree as "not a git work
  tree" or was refused the write into a .git/config that account owns.
- FIX: A project directly under your home -- /home/<you>/<project> -- is reachable again. Vetting
  an ancestor for the traverse grant reused the rule written for whole-tree targets, which refuses
  every home root, so such a project was reported permanently unreachable with a sandbox clone the
  only route in. Granting search permission on one directory is now its own rule: your own home
  root is allowed, while every system directory, /home itself and any other account's home root
  stay refused. Under --for the grant applies as the target operator, so a claim made for someone
  else can set it on ancestors that belong to them instead of warning on each one.
- FIX: The checks that ask whether an SELinux policy module is loaded could report a loaded module
  as ABSENT, at random, and more often the more modules a host has. That silently cost an entrypoint
  relabel its file-context registration and the dotnet integration its label step. Five probes
  carried the fault; all five are fixed, and the same shape was costing the container test suite
  red runs on a man-page check that had nothing wrong with it.
- CHANGE: An unattended entrypoint reconciliation answers from the pin already on disk when the
  installed version, the binary's bytes and every verification input are unchanged. A single dnf
  upgrade could otherwise re-fetch and re-verify the vendor's signed manifest several times, which
  on an air-gapped host meant two connection timeouts per agent per run to leave the pin exactly as
  it was. 'ai-tools --relabel' still re-verifies the signature every time, which is what an operator
  runs it for; a pin recording no digest is never reused.
- FIX: A package upgrade reports honestly what it did with the shipped skills and agents. The four
  withdrawn documentation skills were reported "up to date" and retired seconds later in the same
  transaction, "seeded (vN)" carried the previous asset's version rather than the new one, and the
  update question was drawn on dnf's terminal where nothing could answer it. No host ends an
  upgrade in a different state; what an operator is shown while it happens is now correct.
- CHANGE: The first-run screen an agent shows in a directory it cannot work in states each choice
  once, leads with the action rather than the refusal, and says which option does not start a
  session there. It has no default: an unattended or piped run cancels, and the cancel path prints
  both commands plainly below the frame where they can be copied.
- CHANGE: 'ai-tools --help' is orientation -- the verbs grouped by what they are for, one line
  each, the three flags that cross verbs, and a pointer to ai-tools(1). The man page is now the one
  reference for options and gains full entries and examples for --project-create and
  --project-remove, which it had documented as aliases, and the runas grant a --for create or
  remove needs.
- FIX: 'ai-tools --help' and 'ai-tools --version' run on a host whose install never finished. The
  provisioning gate refused them, so --help answered with a refusal naming ai-tools-bootstrap --
  the only place the command could still be found.
- CHANGE: The project lifecycle guide follows the lifecycle: choose a model, create or claim, work,
  clone, park, release, delete, act for another operator, then the permission reference. Each
  section opens with a runnable command, and the guide now covers --for, the parked state and
  --keep-entry. It also separates --reclaim from unclaiming -- bringing a project back after an
  unclaim is --project-claim run again, not --reclaim -- and states which routes into the tree a
  release actually closes, in the order that matters. The README leads with the --project-create
  one-liner and keeps --project-claim beside it.
- Upgrading from 0.13.x needs no action beyond dnf.

* Sat Aug 29 2026 dagnode <tools@dagnode.com> - 0.13.0-1
- CHANGE: "Operator" now names exactly two facts -- membership of ai-ops and a name in OPERATORS,
  both written by 'ai-tools-admin operator add'. A general sudo grant is a THIRD, independent axis
  this project never writes, records, or infers: the host's own sudoers decides it. An account
  holding only the two is a first-class operator -- it launches sessions and has projects claimed
  for it with --for -- rather than a half-configured one. The requirement that follows is now
  stated: a host needs at least one operator holding a general grant, or nothing can be claimed on
  it by any principal, root included. Nothing changes on an existing host; what changes is that a
  refusal now says which of the three you are missing.
- NEW: A verb whose root helper you hold no sudo grant for is refused BEFORE sudo asks for a
  password. sudo authenticates before it decides whether a rule matches, so a restricted operator
  was made to authenticate and then turned away, for a decision that was knowable without asking.
  The refusal names the command that does work -- for most verbs the same command with
  '--for <you>', run by an operator who holds a grant. It reports rather than decides: an answer it
  cannot read falls through to sudo, so nobody loses a command they do hold the grant for.
- NEW: Root may run the commands that write no operator-owned state -- --audit, --status, --list,
  --providers and --stop. --audit needs root by construction (its trail is 700 root:root) and was
  unreachable from both sides on a host whose only operator holds no general grant. Every command
  that writes a registry still refuses root, since a registry owned by root names an operator whose
  own launch gate cannot read it.
- NEW: 'ai-tools --stop' runs with no password in its bare form, so a service that detects a session
  which must end immediately can escalate to a full stop with nobody present. A control unattended
  monitoring cannot exercise is unavailable during exactly the incidents it exists for. The grant is
  pinned to that bare form: --force (which drops the grace period, and the current turn's unsaved
  work with it) and --dry-run still prompt. It now also works on a host that is unprovisioned or
  that enables an agent other than Claude Code -- a stop must not depend on what it is stopping.
- FIX: 'sudo ai-tools --stop', the form 0.12.0 documented, was refused on every host: --stop sat in
  the set of verbs the CLI refuses root for, though it writes no operator state. Run it as yourself
  -- 'ai-tools --stop' -- and root may now run it too.
- NEW: 'install.sh --operator <account>' names the account to enrol instead of silently adopting
  SUDO_USER, and an interactive install asks. Root, the sandbox account, an unknown name and a name
  with no home are each refused by one rule whichever route the name arrived by, so an unattended
  from-source install can enrol an account other than SUDO_USER.
- NEW: 'sudo ai-tools-admin operator add <name>' reports which of the two operator shapes it just
  created, by asking sudo about the enrolled account directly. Group membership cannot imply a
  sudoers rule, so asking is the only way to know -- and the administrator learns at the moment of
  the decision whether that account can claim projects or needs another operator to claim for it.
- CHANGE: A shipped skill or agent is now UPDATED by default on upgrade. It was only ever replaced
  when an operator answered yes at a prompt, and a package scriptlet has no terminal, so every dnf
  upgrade silently took the keep default with its output discarded -- a host stayed on whatever
  version it first seeded and was never told. Assets seeded before this need ONE interactive
  './install.sh install' or 'sudo ai-tools-bootstrap' to move; after that, upgrades deliver new
  versions on their own. A withdrawn asset is moved to /opt/ai-tools/retired rather than deleted.
- CHANGE: The four documentation skills (reference, usage, doc comments, changelogs) are replaced by
  one writing standard, ai-tools-technical-docs, which also covers commit messages, man pages, and
  error and log output. The four are removed from the live skills root on upgrade and kept under
  /opt/ai-tools/retired; a skill of your own under one of those names is left alone.
- NEW: 'ai-tools --status' reports the LABELLING half of the entrypoint reconciliation beside the
  verification half. An upgrade whose relabel failed previously reported a healthy host -- the
  watcher OK and a fresh green VERIFIED line, both true, with the failure between them writing no
  record at all. ai-tools-relabel.service is reported too, judged by its last run rather than by
  is-active, which a healthy oneshot service always fails.
- FIX: An upgrade could leave the entrypoint and config-directory SELinux rules unregistered. The
  agent package's %post and the relabel watcher the same transaction triggers ran at once, and
  semanage reports an error to whichever process finds the policy store held rather than waiting,
  so both runs failed on a store neither had broken. They now take a shared lock, and a refusal
  carries semanage's own reason instead of naming none -- a held store and a type the loaded policy
  does not define need different remedies.
- FIX: A policy module that failed to load during install left no trace at the point it happened,
  surfacing much later as a relabel that cannot register its rules and a launch that fail-closes.
  The scriptlet now prints semodule's message and the command that repeats it.
- FIX: A refusal that suggested a claim command could name a directory nobody typed. It scanned the
  arguments for one that exists and fell back to the current directory, so a mistyped project path
  produced a plausible-looking claim of whatever repository you were standing in -- observed live.
  A path you named now passes through as typed.
- FIX: 'ai-tools-admin operator add' read a sudo that failed for its own reasons -- an unreachable
  sudoers backend, a host that refuses -l -- as proof the account holds no grant, sending an
  administrator to a --for workflow they did not need. It now reports "undetermined" unless a
  second probe confirms sudo is answering at all.
- FIX: ai-tools(1) documents the exit codes it returns, including the three specific to --stop, and
  both man pages follow the shipped man-page guideline (ENVIRONMENT, EXAMPLES, and the lifecycle
  guide cited at the path the package installs it to).
- Upgrading from 0.12.x needs no action beyond dnf, with one exception: shipped skills and agents
  seeded before this release move on the next INTERACTIVE './install.sh install' or
  'sudo ai-tools-bootstrap', not on the dnf upgrade itself.

* Mon Aug 24 2026 dagnode <tools@dagnode.com> - 0.12.0-1
- NEW: 'sudo ai-tools --stop' ends every agent session running on this host, and everything it
  spawned. Until now every control changed only what the NEXT launch gets -- unclaiming a project,
  disabling a provider, revoking an operator -- and "stop what it is doing, now" meant hunting for
  units in an account you cannot reach. Sessions are found by their cgroup, so a child that
  double-forked or called setsid is still ended; each gets ten seconds to exit before it is killed.
  Preview with --dry-run, skip the confirmation with -y, skip the grace period with --force. It
  reports what it ended, and because a killed session cannot run its own hand-back it names the
  --reclaim for each project it interrupted. Use /exit inside a session you are simply finished
  with. Details in /usr/share/doc/ai-tools/session-stop.md.
- NEW: The agent binary is checked against the checksum its vendor SIGNED, and the verified value
  is pinned where the sandbox account cannot write it -- so a binary altered after installation
  refuses to launch. npm's integrity hash covers what was delivered, not what is on disk weeks
  later, and 'npm install -g' does not reinstall an unchanged version, so such a change would
  otherwise persist across every session and operator. The signing key ships in the package rather
  than being fetched, and the pin is written automatically by the watcher that already relabels
  entrypoints: nothing to maintain per release. Requires gnupg2 (gpgv).
- NEW: 'ai-tools --status' shows that verification per agent: VERIFIED with the pinned version and
  how long ago, or unverified. It is the only window an operator has onto it, the entrypoint itself
  living in a toolchain they cannot read. Unverified counts against the exit status only where
  verification is required, so an air-gapped host does not alarm.
- NEW: AI_TOOLS_REQUIRE_ENTRYPOINT_VERIFY=yes in operator.conf refuses to launch an entrypoint
  carrying no verified checksum, and keeps the updater from activating a release it could not
  verify -- for hosts that should never run an unattested agent. A checksum MISMATCH always refuses
  regardless of this key. Off by default. See docs/entrypoint-verification.md.
- NEW: 'ai-tools --relabel' now reconciles the whole entrypoint -- verify, pin, then label -- so it
  is also how to pin one on a DAC-only host, or on a host the watcher was offline for. An
  unreachable vendor is not an error; only a mismatch fails the command.
- NEW: 'sudo ai-tools --audit [--since <when>]' reads back what has refused, been rejected, been
  stranded or been flagged. These detections were already being recorded and nothing read them,
  each landing in a root-only file or a journald tag someone had to think to query. It exits
  non-zero when anything is reported, so it runs from cron or a login banner without parsing its
  output. Launch refusals are reported separately, since those lines come from the sandbox account
  itself and are for reconciling against the root-only trail rather than relying on alone. Window
  defaults to 7 days; a --since date(1) cannot parse is refused rather than read as "everything".
- NEW: Every tool call a session makes is recorded where the agent can append but neither edit nor
  delete -- 'journalctl -t ai-tools-hook _UID="$(id -u ai-tools)"', or '-o json' for structured
  fields. The session's own transcript is agent-owned, so after an incident there was nothing
  independent to reconcile it against; now there is a record of what ran and what was written. Each
  record is bounded on purpose: for a shell command, its first two words and word count, never the
  command line -- a here-doc body or a credential in an argument never reaches the journal.
- NEW: 'ai-tools --for <operator>' claims projects on behalf of another enrolled operator, so a
  passwordless service account that runs an agent can be given work. The entry lands in that
  account's registry, which is what makes the project theirs: files the agent writes are handed
  back to them, the per-project ACL grants them, and their next launch finds the project claimed
  instead of prompting for a password it cannot supply. You claim once, with your own password, and
  the account never meets a sudo prompt. Accepted on --project-claim/-create,
  --project-unclaim/-remove, --lockdown, --reclaim and --list; refused elsewhere rather than
  quietly ignored. Enrol the target first with 'sudo ai-tools-admin operator add <name>'.
- NEW: Sandboxed agents now carry a shared standard for building and operating systems that act
  with autonomy -- what constrains a system, what watches it, and what a human does when a
  threshold is crossed -- which also binds the agent's own conduct in the sandbox. Seeded with the
  other shipped skills; nothing to configure.
- FIX: On a DAC-only host, launch verified one path and started another: it checked the resolved
  entrypoint but handed systemd the launcher symlink, leaving the preflight as a window in which
  that link could be repointed. It now resolves once, uses that single path for both, and re-checks
  it immediately before starting. SELinux hosts were never exposed to this.
- FIX: 'ai-tools --relabel' could report success while every launch stayed refused, exiting 0 with
  "entrypoint is not installed" for an agent that was in fact installed elsewhere than its package
  declares. That case now exits non-zero and names the real cause, and "not installed" is reported
  only when the agent genuinely is not provisioned.
- FIX: A fresh install left the entrypoint relabel watcher enabled but not started, so
  'ai-tools --status' showed it DOWN until a reboot -- and a Node auto-upgrade in that window left
  the next launch refusing on an unlabelled entrypoint. It is started at install.
- FIX: A fresh toolchain bootstrap no longer emits "warning: adding embedded git repository: .nvm".

* Tue Aug 18 2026 dagnode <tools@dagnode.com> - 0.11.1-1
- FIX: A toolchain update that could not reach the npm registry failed with an empty journal and
  left ai-tools --status reporting FAILED until the next day's window. It now says what it could
  not reach, reads SKIPPED instead (nothing changed; STALE after 48 hours if it persists), and
  retries every 30 minutes for up to 6 hours. The daily window moved to 07:55 local time, and it
  and the tracked Node LTS series are overridable with 'systemctl --user -M ai-tools@.host edit'.

* Tue Aug 18 2026 dagnode <tools@dagnode.com> - 0.11.0-1
- NEW: ai-tools --status is a single health report for the pieces a session depends on: the
  ownership-handback socket, the post-upgrade relabel watcher, and the sandbox account's toolchain
  updater and its timer. Each reads OK, STALE, DOWN, FAILED or not-installed, with what breaks
  while it is down and the exact command that fixes it. It also names the active Node version, and
  exits non-zero when anything is broken, so it can be run from cron or a monitor without parsing
  its output. A unit this host cannot query is not counted as a fault.
- NEW: The report covers the toolchain updater even though it runs in the sandbox account's own
  systemd user instance, which your session cannot query. Until now a repeatedly failing update was
  invisible and the toolchain simply stopped advancing; each run's time and exit code are now
  recorded where the report can read them, and a successful run older than 48 hours reads STALE
  rather than OK -- an update that stops being triggered leaves Node and the agent packages quietly
  falling behind while every recorded run stays green. Anything reported broken prints the commands
  to read its journal and restart it, which differ from the usual ones because the unit belongs to
  that account's user instance.
- NEW: Launching a session runs the same health check first and warns when a service it depends on
  is down, instead of letting the failure surface later as a confusing symptom.
- NEW: ai-tools --sandbox-create is scriptable: --from, --branch, --dir and -y give every input a
  flag and a default, with the prompts kept as the interactive fallback, and the confirm previews
  the exact git commands. The branch may be any valid git ref and now defaults to
  sandbox/<name-of-source> (previously ai-tools/sandbox-<owner>/<leaf>); the name is convention
  only -- nothing parses it -- so no behaviour depends on the change.
- NEW: ai-tools --project-unclaim --force releases a copy of a claimed project -- one moved or
  copied elsewhere that still carries the ai-tools group and ACLs but that no allowlist names. It
  changes only paths that still carry ai-tools access; --dry-run, --full and --group support
  scripted use.
- NEW: ai-tools --lockdown also seals the paths you sealed by mode rather than by name, so a file
  or directory made owner-only after the claim is cleaned up without waiting for the next one.
  --dry-run previews that pass as well, naming each path and what would come off it.
- NEW: ai-tools --project-claim reports, in its Review block, a sealed directory whose setgid bit
  belongs to a third group -- the one piece of residue a claim leaves, since it cannot tell a
  deliberate choice from a leftover -- with the chmod g-s that clears it.
- NEW: ai-tools --list flags more kinds of inconsistent allowlist entry under Suggested cleanup,
  each with a copy-paste fix: a glob written in an allow line (globs work only in '!' exclusion
  lines, so a glob allow entry silently matches nothing), a stale '!' exclusion whose path no
  longer exists, and a git safe.directory entry that no allowlist line lists. The report stays
  read-only.
- NEW: AI_TOOLS_REQUIRE_SELINUX=yes in operator.conf lets an operator require SELinux confinement:
  a session then refuses to launch on a host where the ai-tools policy is not enforcing, instead of
  falling back to DAC-only. Off by default, so intentional DAC-only hosts are unaffected.
- CHANGE: ai-tools --project-unclaim now leaves a hardlinked file alone, in both modes. Changing it
  would change every other name for the same inode, including names outside the project -- which is
  what a locally cloned repo has, since git hardlinks .git/objects to the repo it was cloned from.
  Those files keep the group they have, so the agent is not off them: the count is reported at the
  end of the run, with the find command that lists them, and you decide.
- FIX: Claiming a project no longer opens files and directories you had made owner-only (0600,
  0700) to the agent. The setgid pass regrouped every directory you owned -- at claim and again on
  every session start -- while the ACL pass skipped them; both now honour the seal, and the claim
  reports how many paths it skipped. Re-claim an existing project to repair directories already
  regrouped.
- FIX: Sealing a path now removes the sandbox residue behind the mode. A path created inside a
  claimed tree inherits the group, the setgid bit and the project ACL at create time, and a later
  chmod only masks them -- so widening the mode once re-activated the lot. The claim walk, the
  lockdown and the ownership handback all strip it now, removing only what the sandbox put there
  and leaving your mode bits, ownership and other ACL entries alone.
- FIX: A locked secret is owned <you>:<you>, not <you>:ai-tools. The proactive lockdown and the
  on-write quarantine gave the same secret two different owners, and the sandbox group would have
  re-exposed it the moment its mode was widened.
- FIX: A session could silently run unconfined on a host that did have the SELinux policy loaded.
  The pre-launch confinement probe read module presence from the root-only policy store, which the
  sandbox account cannot read, so it always saw "absent" and on one path launched DAC-only. It now
  derives module presence from the world-readable file contexts, so a loaded policy is detected and
  an installed-but-unverifiable confinement fails the launch closed rather than open.
- FIX: A sandbox clone gets the project SELinux label it needs. Clones under
  /var/opt/ai-tools/sandbox-projects were left unlabelled because EL and Fedora alias /var/opt to
  /opt before matching file contexts, so the clone-area rule was never reached -- and a launch
  refused with "SELinux label still missing" right after the claim had reported success. Labelling
  now also verifies the type it applied, so a mislabel surfaces at claim or relabel time instead of
  at the next launch.
- FIX: The project and sandbox verbs check their target before changing anything. --project-unclaim
  refuses a directory that is neither a claimed project nor an ancestor of claimed ones, refuses a
  protected system directory up front, and hands ownership back before dropping the allowlist entry
  -- previously it could drop the entry first and leave the tree in the agent's group, releasing
  nothing. --sandbox-remove and the per-project verbs likewise refuse a target that is not a
  recognized sandbox clone or claimed project, so a mistyped path cannot delete or re-permission
  the wrong tree.
- FIX: ai-tools --list is reliable on a hand-edited allowlist. An entry written with an end-of-line
  comment or quotes, or reached through a symlink, is now recognized everywhere the CLI reads the
  list -- such an entry was invisible to several checks, so claiming it appended a duplicate line,
  unclaiming it reported "not listed" and left the agent's access behind, and launching after an
  in-place claim could fail with "the claim did not complete." A stale or protected entry no longer
  aborts the listing either, which used to hide every entry after it along with the Suggested
  cleanup and Maintenance sections.
- FIX: The post-upgrade relabel watcher (ai-tools-relabel.path) is enabled on install, so the agent
  entrypoint is re-labelled automatically after a Node toolchain upgrade. Without it a launch after
  an upgrade could fail closed on a mislabelled binary until you ran ai-tools --relabel by hand.
- FIX: Upgrading the ai-tools-selinux policy refreshes the running handback socket's SELinux label,
  so ownership hand-back keeps working immediately after the upgrade instead of silently doing
  nothing until the next reboot.
- FIX: The toolchain updater could abort silently, leaving nvm-update.service failed with an empty
  journal and Node and the agent packages frozen at their installed versions: its logging ran as a
  bare pipeline that killed the run it was reporting, before the line explaining why was written.
  Logging can no longer fail the run, and the message reaches the unit's journal first.
- FIX: Reports read as intended: sudo ai-tools-admin selinux list-groups prints a clean sectioned
  report of the optional policy groups and their load state; a short list of flagged paths is
  printed once, whole, rather than sampled, counted and offered for re-listing (four paths took
  seven lines and a question); and several --status and --providers hints now name commands that
  work as printed.
- DOCS: The README gives explicit install and upgrade commands, a working first-launch walkthrough,
  and a pre-1.0 stability notice, and the project-lifecycle documentation spells out what a claim
  and an unclaim each do to a project's permissions.
- Upgrading from 0.10.x needs no action beyond dnf. If you had sealed directories (0700) inside a
  project claimed by an earlier release, re-claim it once -- ai-tools --project-claim <project> --
  to return them to your own group.

* Thu Aug 13 2026 dagnode <tools@dagnode.com> - 0.10.1-1
- FIX: The package now enables the ownership-handback socket (ai-tools-handback.socket) on install,
  via a shipped systemd preset. Without it a package install left the socket at the distribution
  default (disabled): every ownership hand-back then failed silently, so files the agent wrote
  stayed owned by the sandbox account and git reported "dubious ownership" on the project. The
  preset applies on initial install only, so a later systemctl disable survives upgrades -- and, by
  the same rule, upgrading a host that never had the socket enabled does not turn it on. If a host
  is already affected, run once: sudo systemctl enable --now ai-tools-handback.socket, then
  ai-tools --reclaim <project>.
- FIX: A down handback socket is now reported instead of failing silently. The launch warns (naming
  the fix) and proceeds -- the socket restores ownership but is not a confinement boundary -- while
  the session sweeps and ai-tools --reclaim count only confirmed hand-backs and, when the socket is
  down, report the stranded work rather than a reassuring count of calls that changed nothing.
- DOCS: The claim, unclaim, and reclaim entries in ai-tools --help and the man page now spell out
  what each does and how they differ: claim grants the agent access to a project, unclaim releases
  it (revoking that access and returning the tree to your group), and reclaim takes ownership back
  while the project stays claimed.

* Mon Aug 10 2026 dagnode <tools@dagnode.com> - 0.10.0-1
- CHANGE: The root helper programs moved from /usr/local/sbin/ai-tools to
  /usr/local/libexec/ai-tools, so one install layout works on both EL and Fedora (Fedora merges
  /usr/local/sbin into /usr/local/bin, which collided the helper directory with the ai-tools CLI;
  /usr/local/libexec is untouched by that merge). The sudoers grant is re-pointed automatically on
  upgrade with no manual step and the old directory is removed; your operator configuration is
  untouched. If an upgrade prints a notice, run sudo ai-tools --relabel.
- NEW: The RPMs now install on Fedora (42+). The EL9/EL10 packages previously refused the
  transaction there because of the bin/sbin merge the layout change above resolves; a native Fedora
  build also compiles the SELinux policy against Fedora's own reference policy. EL9/EL10 remain the
  gated, released targets; Fedora is smoke-tested per commit.
- LICENSE: The project license identifier is now AGPL-3.0-only. Releases through 0.9.x were
  published as AGPL-3.0-or-later, and everyone who received them keeps the "or later" option on
  those versions; this narrowing applies from 0.10.0 forward. No change to what the license permits
  you to do with the code.
- NEW: The SELinux confinement policy now ships as its own subpackage, ai-tools-selinux, licensed
  GPL-2.0-or-later. A compiled policy module embeds macro expansions from the GPL SELinux reference
  policy, so it is conveyed under the GPL as its own package rather than inside the AGPL base. A
  default install still pulls it (base recommends it); installing without it leaves the sandbox in
  the documented DAC-only mode.
- NEW: Set a custom system prompt for sandboxed sessions by placing it at
  /etc/ai-tools/prompts/claude-system-prompt.md (root-owned). When the file is configured the
  launch fails closed rather than silently dropping it.
- NEW: Route sandboxed sessions at a custom, Anthropic-compatible API endpoint via
  /etc/ai-tools/endpoints/custom-claude-endpoint.conf (root-owned: a base URL plus the name of the
  auth-token variable). It fails closed when configured but unusable, so a session never falls back
  to the default endpoint unnoticed.
- NEW: Add CLAUDE_CODE_MAX_OUTPUT_TOKENS to the default session configuration.
- FIX: The SELinux module now reaches the running kernel policy on install and leaves it on erase.
  Both scriptlets passed semodule --noreload, which commits to the module store without loading, so
  a fresh install could leave the agent entrypoint unlabelled (the launch preflight then refuses
  with mislabel until a reload) and dnf remove could leave the ai_tools domain live after the files
  were gone.
- FIX: The source tarball and SRPM no longer pick up policy modules built locally from source; a
  filesystem wildcard was sweeping an experimental group compiled on the build host into the
  published source artifact.
- FIX: The source package now carries the SELinux policy sources alongside the compiled modules, so
  a GPL binary is conveyed with its corresponding source (GPLv2 s.3) on every channel, including the
  offline release archive.
- Upgrading from 0.9.x needs no action beyond dnf: the helper-path migration and the sudoers
  re-point are automatic. If a host prints a relabel notice, run sudo ai-tools --relabel.

* Wed Aug 05 2026 dagnode <tools@dagnode.com> - 0.9.1-1
- FIX: Strip the stray group-execute bit Claude Code's file writes leave on data files. The
  ownership handback and unclaim now clamp the group class off the owner-execute bit, so a data
  file hands back group rw (not rwx) while a real script keeps group r-x -- and the spurious bit no
  longer becomes a real group-execute when a project tree is archived (tar/zip) and extracted
  without ACLs.
- FIX: Refuse an operator command (--project-*/--sandbox-*/--lockdown/--reclaim/--relabel) up
  front when the invoking user is not in OPERATORS in operator.conf, pointing at sudo
  ai-tools-admin operator add <user>, instead of running through registry writes and confirm
  prompts only to fail in a root helper and roll back. --help/--version/--list/--providers stay
  open to any user.

* Sun Aug 02 2026 dagnode <tools@dagnode.com> - 0.9.0-1
- NEW: Save tokens by default -- command filters narrow what a tool prints, over the root-owned
  rule sets in filters.d and operator.conf AI_TOOLS_FILTERS (an empty value disables).
  Access-neutral: the permission rules are re-evaluated on the rewritten command.
- NEW: Apply the command filters on both Bash hook events
- NEW: Quiet the dotnet SDK through its own command-filter rule set
- NEW: Keep host-tuned permission rules across an upgrade -- settings.json ships
  %config(noreplace), so rpm keeps the file you edited and parks this version's copy as
  settings.json.rpmnew (earlier releases overwrote it and kept no copy)
- NEW: Reconcile the .rpmnew copies an upgrade leaves with sudo ai-tools-admin postupgrade. It
  merges shipped hook declarations into settings.json after listing exactly what it will add and
  confirming, writing a dated .bak first. operator.conf and the sudoers grant are reported, never
  written -- a file of commented option blocks has no merge worth learning to predict. The install
  output points here whenever a .rpmnew is waiting
- NEW: Merge shipped hook declarations into a kept settings.json, so a new version's hook no
  longer installs with nothing to invoke it (inline on a from-source install, through postupgrade
  on RPM)
- NEW: Report the options a kept KEY=value config has not seen (inline on a from-source install,
  through postupgrade against operator.conf.rpmnew on RPM)
- NEW: Add the shared config backup and baseline-copy layer to the from-source installer --
  dated .bak and .shipped sidecars, never overwritten
- NEW: Read allowed-projects with the shared config grammar (conf.lib.sh): end-of-line comments
  and quoted paths, one parser for the wrapper, the CLI, and the handback helper
- NEW: Add operator.conf(5)
- NEW: Optional SELinux policy group apphost lets the sandbox build and run .NET executable and
  host projects -- console apps, ASP.NET Core and worker services, xunit.v3 tests, single-file
  publishes. A class library, or in-process MSTest (Microsoft.Testing.Platform), does not need it.
  It complements tmpmap (restore and build); enable both for a full build-and-run workflow. Off by
  default:  sudo selinux/install-selinux.sh enable-group apphost
- NEW: Optional SELinux policy group netcore covers the rest of a .NET workflow under enforcing --
  dotnet test (its diagnostic socket and, for an out-of-process xUnit/VSTest host, the loopback TCP
  connection to it), multi-node MSBuild (lets you drop the -m:1 workaround), and running a binary
  you built from the project tree. Off by default:  sudo selinux/install-selinux.sh enable-group
  netcore
- FIX: Parse the labelling report so the unconfined-entrypoint guard can fire -- an entrypoint
  that failed to take ai_tools_exec_t ran sessions UNCONFINED while the install reported success.
  Check an enforcing host after upgrading:  ps -eo label,cmd | grep '[c]laude'  (expect
  ai_tools_t)
- FIX: Require jq, which every Claude Code hook depends on -- without it the ownership handback
  and the .git reclaim silently stopped
- FIX: Drive the sandbox user manager over the machine transport -- the toolchain auto-update
  timer never started, failing with "Connection refused"
- FIX: Repair project labels on re-install instead of reconverting (relabel.lib.sh), so a
  re-install no longer rewrites every file of every registered project
- FIX: Group the install output by the work it reports
- FIX: Stop the "failed to set default file creation context" SELinux warnings that cluttered
  command output under enforcing -- most visibly through dotnet build and NuGet restore
- FIX: A second build of the same solution no longer fails on the previous project's locked
  output (dotnet/msbuild#6461)
- FIX: Re-apply SELinux labels once per install, and repair them even when the SELinux step is
  declined on a host that already has the module loaded (e.g. after a Node upgrade)
- FIX: Clearer optional-group install prompt -- each group is tagged stable or experimental, the
  explanation precedes the skip question, an already-loaded group is reported (and can be
  recompiled from source rather than offered for re-enable), and the summary lists every loaded
  group
- Upgrading from 0.8.1 needs no action beyond dnf. Command filtering arrives ON for a host whose
  operator.conf predates AI_TOOLS_FILTERS; set AI_TOOLS_FILTERS="" to opt out.
- For .NET workloads on an enforcing host, enable the optional groups they need: tmpmap
  (restore/build), apphost (build an executable or host project), and netcore (test and run); all
  stay off by default.

* Wed Jul 29 2026 dagnode <tools@dagnode.com> - 0.8.1-1
- Fixed the SELinux-enforcing limitation carried in 0.8.0: the sandbox domain held no map
  permission on its own /tmp files, so dotnet restore/build -- and git or SQLite run in a /tmp
  working tree -- failed with EACCES on the mmap. A new optional SELinux policy group, tmpmap,
  grants exactly that one permission (ai_tools_tmp_t:file map); it is mmap-at-all and NOT
  executable mapping (/tmp stays noexec), so it cannot run code from /tmp. With it enabled the SDK
  restores and builds normally. On an enforcing host: sudo ai-tools-admin selinux enable-group
  tmpmap.
- The STABLE optional SELinux policy groups now ship prebuilt (currently tmpmap) and are managed
  on any installed host with a new ai-tools-admin selinux subcommand -- list-groups, enable-group
  <name>, disable-group <name> -- which loads the shipped .pp via semodule, needing no source
  checkout or selinux-policy-devel. The group set is single-sourced, so this helper and the
  source-tree install-selinux.sh never disagree on which groups exist.
- The experimental groups (systemd, pkgmgmt, netadmin, podman) are unaudited drafts and are NOT
  shipped prebuilt; they must be compiled and verified from a source checkout first
  (install-selinux.sh enable-group + the avc bring-up loop). ai-tools-admin enable-group of an
  experimental group refuses and points at that workflow rather than loading an unaudited module.
- ai-tools --providers now reports the SELinux confinement layer where SELinux is active -- the
  core module and any loaded optional group -- and, when the dotnet integration is enabled under
  enforcing but tmpmap is not loaded, names the enable command instead of letting the build fail
  with an opaque EACCES.
- Upgrading from 0.8.0 needs no action beyond dnf. A DAC-only host is unchanged; on an enforcing
  host, dotnet builds now require enabling the tmpmap group once, as above.

* Tue Jul 28 2026 dagnode <tools@dagnode.com> - 0.8.0-1
- The stack is multi-agent: nothing in ai-tools-base names an agent. Which agents exist, what
  each provisions, where it keeps its config directory, which binary the SELinux domain
  transition keys on, which side converges file ownership, and where it reads skills and
  subagents all come from per-package manifests under /usr/local/lib/ai-tools/agents.d. A second
  agent package ships a wrapper, a manifest, and a session-env fragment -- no sudoers rule, no
  policy change, no edit to the base.
- Confinement is one agent-agnostic shim, /opt/ai-tools/bin/ai-tools-run. It accepts an
  executable only at a semver version directory in the sandbox toolchain whose launcher an
  enabled manifest claims, then wraps the session in the same confined transient unit as before.
- operator.conf AI_TOOLS_AGENTS and AI_TOOLS_INTEGRATIONS choose what a host runs: a key present
  is an exact allowlist, absent means every installed provider its own package marked
  default_enable=yes. Every enabled provider contributes session environment and PATH through a
  root-owned session-env.d/<name>.env.sh fragment, integrations first and the agent last.
- The gating is fail-closed and tamper-refusing throughout: each input is honored only while it
  is root-owned and writable by neither group nor other, and every failure resolves to LESS
  access -- the default-enabled baseline, never "enable all" -- and is reported.
- Skills and subagent definitions live in one place each, /opt/ai-tools/skills and
  /opt/ai-tools/subagents, and every agent's directories hold a symlink per asset. An asset is
  authored and updated once however many agents read it, while an agent-specific one is a real
  file the linker never displaces. Adding one: /usr/share/ai-tools/skills/README.md.
- Each integration keeps its sandbox-side state under /opt/ai-tools/integrations/<name>, covered
  by a single base-owned SELinux rule, so an integration package carries no file-context rules
  of its own and adds no directory to the sandbox home.
- ai-tools-integration-dotnet integrates a host-managed .NET toolchain (no runtime packaged, no
  dotnet RPM dependency, inert without one): DOTNET_ROOT, a sandbox-writable NuGet cache, and the
  admin-provisioned shared tools on PATH. Provision with sudo ai-tools-dotnet setup /
  install-tools. Pulled as a dnf weak dependency, so it installs by default and removes cleanly.
  Known limitation on an SELinux-enforcing host: the SDK cannot restore or build, because NuGet
  mmaps a shared-memory file under /tmp and the sandbox domain holds no map permission on its own
  tmp files. Running a prebuilt assembly works, as does a DAC-only host; the policy grant is
  planned for 0.8.1.
- New command: ai-tools --providers reports the installed agents and integrations, which of them
  a session gets, and why -- including any input refused as untrusted.
- Upgrading from 0.7.0 needs no action beyond dnf, but five things moved. dnf handles the first;
  the rest are stale copies worth deleting once:
    /etc/sudoers.d/ai-tools-claude   is now /etc/sudoers.d/ai-tools (removed on upgrade)
    ai-tools-claude-symlink          is now ai-tools-launcher-symlink
    ai-tools-relabel-entrypoint      is now ai-tools-relabel-agent
    /opt/ai-tools/.nuget, .dotnet    dotnet state now lives under integrations/dotnet
    .claude/{skills,agents}          shipped copies now live in the shared roots; an unchanged
                                     per-agent copy is converted to a symlink on the next
                                     install or bootstrap, one you edited is kept and reported
  A hand-written agent manifest must spell the npm key npm_package, not npm_pkg.

* Sun Jul 26 2026 dagnode <tools@dagnode.com> - 0.7.0-1
- Reorganized the package tree under two umbrellas: the Claude Code provider is now
  ai-tools-agents-claude-code-restricted (under the ai-tools-agents umbrella) and the
  nvm-managed Node toolchain is now ai-tools-integration-nodejs (under ai-tools-integration).
  The ai-tools metapackage weakly Recommends both umbrellas, so an install can drop either.
  No functional change to the sandbox, confinement, CLI, or bootstrap.
- The renamed packages carry Provides/Obsoletes for their old names, so dnf performs the rename
  as an ordinary upgrade and no package has to be removed by hand.

* Sun Jul 19 2026 dagnode <tools@dagnode.com> - 0.6.4-1
- Secret lockdown now precedes every access-widening step: a re-claim that only adds the
  group ACL, .git normalization, or the SELinux label scans first, and --sandbox-create
  clones privately (umask 077), locks tip-commit secrets, and only then opens and
  registers the clone -- declining leaves it private and unregistered, resumable by
  re-running on the clone path.
- Reworked the --project-claim / --sandbox-create dialogs into self-contained blocks:
  each decision shows its own headline, details, and result, warnings frame at 50
  columns vs 80 for section headlines, and the sudo-password notices are gone.
- Fixed the normalize-.git prompt re-asking on every re-claim of an already-normalized
  tree, and the drift listing's empty mode column (both an IFS parsing bug).
- Fixed first claims flagging the entire tree as "interior permission drift"; the
  report now appears only on re-claims, where it is actionable.
- Added an ai-tools(1) man page (man ai-tools), kept in sync with ai-tools --help by
  the test suite.
- New operator guide docs/project-lifecycle.md (claim vs sandbox decision, what each
  prompt grants, recovery paths); README slimmed to a front page that links out.

* Sat Jul 18 2026 dagnode <tools@dagnode.com> - 0.6.3-1
- Release RPMs are reliably GPG-signed: the signing step runs directly, past the build
  image's init entrypoint, and asserts a signed-package line, so every published package
  carries a verified signature. Install with gpgcheck after importing RPM-GPG-KEY-dag-node.
- Hardened the release pipeline: the GPG signing secret stays out of the build
  container's environment -- passed over stdin, forwarded through sudo to podman -- and
  the signing scratch tree is wiped on exit. No change to the installed packages.

* Fri Jul 17 2026 dagnode <tools@dagnode.com> - 0.6.2-1
- Fixed: release RPMs are correctly GPG-signed on EL10. The 0.6.0 and 0.6.1 el10
  packages shipped unsigned -- rpm's sign command ran gpg with a stray argument and
  signed nothing. Reinstall with gpgcheck after importing RPM-GPG-KEY-dag-node.
- Signing is now mandatory: the release proves the whole key/passphrase/sign/verify
  chain on a throwaway package before building or publishing, so a broken signing
  toolchain fails the release instead of shipping unsigned packages.

* Fri Jul 17 2026 dagnode <tools@dagnode.com> - 0.6.1-1
- Maintenance re-release of 0.6.0 to complete the signed rpm.dagnode.com
  publish; no changes to the installed packages.
    
* Fri Jul 17 2026 dagnode <tools@dagnode.com> - 0.6.0-1
- Release RPMs are now GPG-signed and published to the signed DNF repo at
  rpm.dagnode.com; install with gpgcheck/repo_gpgcheck instead of --nogpgcheck
  (import the key: rpm --import https://rpm.dagnode.com/RPM-GPG-KEY-dag-node).
- Ship curated agents and skills into the sandboxed agent's global config, seeded
  and kept current on install and upgrade.
- Ship a reference host-wide managed-settings.json for the sandboxed agent.
- Provisioning no longer triggers an immediate catch-up toolchain update, so the
  first launch after install/bootstrap is not raced into a mislabel refusal.
- The launch banner surfaces the session unit name with a journalctl hint.
- Harden CI: GitHub Actions are pinned to commit SHAs.

* Wed Jul 15 2026 dagnode <tools@dagnode.com> - 0.5.0-1
- Ship a reference-architect agent and the documentation and engineering-principles
  skills into the sandbox account, provisioned into every project the agent works in.
  They are ai-tools- namespaced and versioned; installing or updating never overwrites
  an agent or skill you authored yourself.
- Surface the per-session systemd unit and a journalctl hint when a session launches.
- Add a reference host-wide managed-settings.json.
- Fixed: the Claude launcher symlink repoint is idempotent, so a no-op update no longer
  churns the SELinux relabel.
- Fixed: skipping the SELinux step during install keeps an already-installed module
  instead of removing it.

* Mon Jul 13 2026 dagnode <tools@dagnode.com> - 0.4.0-1
- Sessions now default to confirm-before-acting: the shipped settings.json sets
  "disableAutoMode": "disable", which removes "auto" from the Shift+Tab cycle and rejects
  --permission-mode auto. Auto mode (autonomous agentic actions, on by default since Claude
  Code 2.1.207) is therefore off for sandbox sessions. Operators who relied on it re-enable
  it per project via that project's .claude/settings.json.
  Note the option name is a double-negative trap: the key is disableAutoMode and its
  activating value is also "disable", so the guard is engaged by "disable"-ing a
  "disable"-named key. The two negatives do not cancel — they compound to auto mode being
  off — and the name gives the reader no cue to that; a positive spelling (autoMode: "off")
  would read plainly. We set the vendor key as-is because it is the only knob Claude Code
  exposes for this.
- Privacy default: settings.json sets CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1, opting
  sessions out of telemetry, error reporting, the /feedback upload, and the quality survey
  in one variable. Essential Anthropic API traffic is unaffected. New reference:
  docs/claude-options.md catalogs the Claude Code options an operator may layer per project.

* Thu Jun 25 2026 dagnode <tools@dagnode.com> - 0.1.0-1
- Initial RPM packaging: ai-tools-base / ai-tools-nodejs / claude-code-restricted
  subpackages from one source, sysusers account + ai-ops group creation, SELinux core
  module load, handback socket, and the bootstrap/admin commands.
