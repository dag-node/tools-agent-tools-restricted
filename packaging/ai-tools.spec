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

License:        AGPL-3.0-or-later
URL:            https://github.com/dag-node/tools-agent-tools-restricted
Source0:        %{name}-%{version}.tar.gz
Source1:        %{name}.sysusers
Source2:        VERSION

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

%description -n ai-tools-base
The provider-agnostic base layer: the ai-tools system account, the ai-ops
operators group, the ai-tools project-lifecycle CLI, the ai-tools-admin
operator-administration command, the ownership and secret-handling root helpers,
the handback privilege-bridge socket, and the base SELinux confinement domain.
Other AI-tool packages build on this layer.

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
# and nothing obsoletes the old name to break the deadlock -- so the whole transaction fails and
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
(operator.conf AI_TOOLS_INTEGRATIONS), and the ai-tools-dotnet helper to provision that cache and
shared global tools. The .NET SDK/runtime itself is the host's RPM-managed dotnet; this package
adds no runtime and is inert until enabled on a host that has dotnet installed.

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
# base helper that is not daemon- or sudoers-invoked by fixed path, so it gets a symlink in
# %{_sbindir}: sudo resolves a bare command against the sudoers secure_path, which on stock
# EL is /sbin:/bin:/usr/sbin:/usr/bin and does NOT include /usr/local/sbin. The target keeps
# its canonical %{ai_sbindir} path. ai-tools-bootstrap gets the same treatment in the
# ai-tools-integration-nodejs subpackage.
install -d -m 0755 %{buildroot}%{_sbindir}
ln -s %{ai_sbindir}/ai-tools-admin %{buildroot}%{_sbindir}/ai-tools-admin

# ── base: CLI + handback client ──────────────────────────────────────────────
install -d -m 0755 %{buildroot}%{ai_bindir}
install -m 0755 src%{ai_bindir}/ai-tools.sh                 %{buildroot}%{ai_bindir}/ai-tools
install -m 0750 src%{ai_bindir}/ai-tools-handback-client.py %{buildroot}%{ai_bindir}/ai-tools-handback-client
# ai-tools(1) man page; the man1 dir is owned by the filesystem package, so only the page
# ships. brp-compress may gzip it (hence the %%files glob).
install -d -m 0755 %{buildroot}%{ai_mandir}/man1
install -m 0644 src%{ai_mandir}/man1/ai-tools.1             %{buildroot}%{ai_mandir}/man1/ai-tools.1
# operator.conf(5): the host options and the shared KEY=value grammar they are written in.
install -d -m 0755 %{buildroot}%{ai_mandir}/man5
install -m 0644 src%{ai_mandir}/man5/operator.conf.5        %{buildroot}%{ai_mandir}/man5/operator.conf.5
# The CLI gets a %%{_sbindir} symlink for the OPPOSITE reason ai-tools-admin does: it must
# never run under sudo, and without the symlink `sudo ai-tools` dies with sudo's "command
# not found" (%%{ai_bindir} is not in secure_path) before the CLI's own refusal -- run as
# the projects user, drop the sudo -- can explain the right invocation.
ln -s %{ai_bindir}/ai-tools %{buildroot}%{_sbindir}/ai-tools

# ── base: shared libraries ───────────────────────────────────────────────────
# 0751: group SANDBOX_GROUP r-x for the agent; world-execute so an operator (not a
# SANDBOX_GROUP member under multi-operator) can traverse in to source the 644
# world-readable libs by path without listing the dir. The 640 files self-protect.
install -d -m 0751 %{buildroot}%{ai_libdir}
for l in log msg conf skip-dirs relabel secret-patterns operator control-plane safe-paths confinement npm-verify managed-assets providers selinux-groups filters; do
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
# Token-saving command-filter rule sets, keyed by name the same way: filters.d/<name>.rules. Base
# owns the directory and ships core.rules, the set every host gets; a package with commands of its
# own ships one beside it. An agent's filter hook reads them through filters.lib.sh.
install -d -m 0755 %{buildroot}%{ai_libdir}/filters.d
install -m 0644 src%{ai_libdir}/filters.d/core.rules %{buildroot}%{ai_libdir}/filters.d/core.rules
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

# ── base: sysusers ───────────────────────────────────────────────────────────
install -d -m 0755 %{buildroot}%{_sysusersdir}
install -m 0644 %{SOURCE1} %{buildroot}%{_sysusersdir}/ai-tools.conf

# ── base: static %ai-ops sudoers drop-in (the @SANDBOX_*@ tokens are substituted in %build;
#    %ai-ops is literal, so the file is host-identical and ships unchanged) ──
install -d -m 0750 %{buildroot}%{_sysconfdir}/sudoers.d
install -m 0440 src%{_sysconfdir}/sudoers.d/ai-tools %{buildroot}%{_sysconfdir}/sudoers.d/ai-tools

# ── base: host-config template. The @PROJECTS_USER@ token stays literal at build (the
#    operator is a runtime identity), so stage the template with OPERATORS emptied;
#    `ai-tools-admin operator add` fills it in place. %config(noreplace) keeps the
#    operator's OPERATORS/SKIP_* edits across upgrades. ──
install -d -m 0755 %{buildroot}%{_sysconfdir}/ai-tools
sed 's/^OPERATORS=.*/OPERATORS=""/' src%{_sysconfdir}/ai-tools/operator.conf \
    > %{buildroot}%{_sysconfdir}/ai-tools/operator.conf
chmod 0644 %{buildroot}%{_sysconfdir}/ai-tools/operator.conf

# ── base: SELinux policy packages (prebuilt) ─────────────────────────────────
# The core (loaded on install) plus each STABLE optional group. Only stable groups ship
# prebuilt: they are toggled per host with `ai-tools-admin selinux enable-group <name>`,
# which semodule-loads the prebuilt .pp from this directory (no source tree or
# selinux-policy-devel needed). EXPERIMENTAL groups are NOT shipped -- they are compiled and
# verified from a source checkout on demand (install-selinux.sh enable-group + the avc loop);
# ai-tools-admin points the operator there rather than loading an unaudited module. Keep this
# list in step with the stable set in selinux-groups.lib.sh.
install -d -m 0755 %{buildroot}%{_datadir}/selinux/packages/ai-tools
for pp in ai_tools ai_tools_tmpmap; do
    install -m 0644 selinux/policy/${pp}.pp \
        %{buildroot}%{_datadir}/selinux/packages/ai-tools/${pp}.pp
done

# ── base: sandbox project workflow tree + operation-log dir ──────────────────
install -d -m 2750 %{buildroot}/var/opt/ai-tools
install -d -m 2770 %{buildroot}/var/opt/ai-tools/sandbox-projects
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
    install -m 0750 src%{ai_sbindir}/${h}.sh %{buildroot}%{ai_sbindir}/${h}
done
# ai-tools-bootstrap is administrator-typed (documented as a bare command); symlinked in
# %{_sbindir} so `sudo ai-tools-bootstrap` resolves via secure_path, mirroring
# ai-tools-admin in the base subpackage.
ln -s %{ai_sbindir}/ai-tools-bootstrap %{buildroot}%{_sbindir}/ai-tools-bootstrap
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

# ── integration-dotnet: session-env fragment + manifest + provisioning helper ─
# The .NET SDK/runtime is the host's; this ships only the sandbox-side glue. The env fragment
# (session-env.d) and manifest (integrations.d) drop into the base-owned dirs; the ai-tools-dotnet
# helper is administrator-typed, so it gets a %{_sbindir} symlink like ai-tools-bootstrap/-admin.
install -m 0644 src%{ai_libdir}/session-env.d/dotnet.env.sh %{buildroot}%{ai_libdir}/session-env.d/dotnet.env.sh
install -m 0644 src%{ai_libdir}/integrations.d/dotnet.conf  %{buildroot}%{ai_libdir}/integrations.d/dotnet.conf
# Its command-filter rules (SDK verbosity), which are .NET knowledge and so ship with the .NET
# package rather than in the base's core.rules.
install -m 0644 src%{ai_libdir}/filters.d/dotnet.rules      %{buildroot}%{ai_libdir}/filters.d/dotnet.rules
install -m 0750 src%{ai_sbindir}/ai-tools-dotnet.sh         %{buildroot}%{ai_sbindir}/ai-tools-dotnet
ln -s %{ai_sbindir}/ai-tools-dotnet %{buildroot}%{_sbindir}/ai-tools-dotnet
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
# Its session env (config dir, compile cache, in-session updater), sourced by ai-tools-run last
# so the agent's own pins are authoritative over an integration's.
install -m 0644 src%{ai_libdir}/session-env.d/claude-code.env.sh %{buildroot}%{ai_libdir}/session-env.d/claude-code.env.sh

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
# only -- the stable optional groups ship prebuilt alongside it but stay OFF, toggled per host
# with `ai-tools-admin selinux enable-group <name>` (experimental groups are not shipped).
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
# Re-assert the setgid bit on the sandbox tree. EL10's rpm (4.19+) drops the setgid from these
# %attr(2750/2770) directories on install -- owner and group apply, the setgid is lost -- which
# breaks the SANDBOX_GROUP inheritance the collaborative-ownership model depends on (clones and
# agent-created files must be born group ai-tools). Setting it here guarantees the documented mode
# regardless of how rpm honored the %attr; idempotent, and a no-op where rpm kept it (EL9).
chmod 2750 /var/opt/ai-tools 2>/dev/null || :
chmod 2770 /var/opt/ai-tools/sandbox-projects 2>/dev/null || :
# Control-plane git guard + identity for the repo ai-tools-bootstrap captures (the RPM
# counterpart of install.sh's do_install .gitignore/.gitconfig steps). Neither file is
# rpm-owned, so an erase preserves them; %post reseeds each ONLY when absent (install.sh's
# keep_existing semantics), so a fresh install or upgrade self-heals a missing guard while an
# existing -- possibly operator-customised -- file is never clobbered. This runs on every
# transition, not fresh-install only, so a file lost to an earlier package's config handling is
# restored. No operator is bound yet at %post time (that is `ai-tools-admin operator add`, run
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
# directories it reads. Non-interactive, so an existing managed asset is kept and only an absent
# one is seeded.
for kind in skills subagents; do
    [ -d %{_datadir}/ai-tools/${kind} ] && command -v bash >/dev/null 2>&1 || continue
    bash -c ". /usr/local/lib/ai-tools/msg.lib.sh; . /usr/local/lib/ai-tools/managed-assets.lib.sh; ai_tools_seed_managed_assets %{_datadir}/ai-tools /opt/ai-tools ai-tools ${kind}; ai_tools_link_asset_readme %{_datadir}/ai-tools/${kind}/README.md /opt/ai-tools/${kind} ai-tools" >/dev/null 2>&1 || :
done
# Operator binding + toolchain are per-operator / network steps a scriptlet must not do; direct
# the operator to them. ai-tools-bootstrap installs the Node toolchain; ai-tools-admin operator
# add binds an operator (OPERATORS list + ai-ops membership + linger + allowlist seed).
cat <<'EOF'
ai-tools-base installed. To finish setup:
  sudo ai-tools-bootstrap                      # install nvm + Node + Claude Code (network)
  sudo ai-tools-admin operator add <your-user> # bind an operator (ai-ops, OPERATORS, linger)
EOF
# operator.conf is %config(noreplace): an edited file is kept and this version's copy is parked as
# .rpmnew. rpm's own warning names that file but not what to do with it, and ignoring it costs
# silently -- an option this version adds simply never appears on the host.
if [ -f /etc/ai-tools/operator.conf.rpmnew ]; then
    echo "  sudo ai-tools-admin postupgrade              # operator.conf.rpmnew is waiting"
fi

%preun -n ai-tools-base
%systemd_preun ai-tools-handback.socket

%postun -n ai-tools-base
%systemd_postun_with_restart ai-tools-handback.socket
# On final erase only, unload the SELinux modules: the core plus any optional group a host
# loaded with `ai-tools-admin selinux enable-group` (its .pp is erased with the package, but the
# compiled module persists in the policy store until removed). Intentionally preserved (not
# rpm-owned): the ai-tools account, /opt/ai-tools/.nvm, the control-plane .gitignore/.gitconfig,
# /var/opt/ai-tools clones, and each operator's ~/.config/ai-tools.
if [ "$1" -eq 0 ] && command -v semodule >/dev/null 2>&1; then
    mods=$(semodule -l 2>/dev/null | grep -E '^ai_tools(_|$)' || :)
    [ -n "${mods}" ] && semodule -n $(printf ' -r %s' ${mods}) >/dev/null 2>&1 || :
fi

%post -n ai-tools-integration-nodejs
# Enable the root-side relabel watcher (system unit). The nvm-update.timer is a --user unit
# enabled in the sandbox account's own instance by ai-tools-bootstrap, which is where that
# instance is brought up with linger -- a scriptlet cannot reliably reach it.
%systemd_post ai-tools-relabel.path

%preun -n ai-tools-integration-nodejs
%systemd_preun ai-tools-relabel.path

%postun -n ai-tools-integration-nodejs
%systemd_postun_with_restart ai-tools-relabel.path

%post -n ai-tools-integration-dotnet
# Create + SELinux-label the sandbox-side dotnet dirs (writable NuGet cache, read-only shared
# tools) the session-env fragment relies on. Offline + idempotent; the helper recognizes a host
# with no enforcing ai-tools policy and skips labelling there rather than failing. Not the network
# tool install -- that stays the operator's `sudo ai-tools-dotnet install-tools`.
#
# The failure is NOT swallowed: a half-provisioned integration that looks installed surfaces later
# as an opaque denial inside a confined session. The helper logs the cause (journald +
# /var/log/ai-tools/dotnet.log) and the scriptlet reports the remedy and exits non-zero, so rpm
# records a scriptlet failure against this package alone -- the transaction still completes, which
# is what a weakly-pulled optional integration should do to the rest of the stack.
if [ -x %{ai_sbindir}/ai-tools-dotnet ]; then
    %{ai_sbindir}/ai-tools-dotnet setup >/dev/null || {
        echo "ai-tools-integration-dotnet: provisioning failed; see 'journalctl -t ai-tools-dotnet'" >&2
        echo "ai-tools-integration-dotnet: fix the cause and re-run: sudo ai-tools-dotnet setup" >&2
        exit 1
    }
fi

%post -n ai-tools-agents-claude-code-restricted
# Register this agent's SELinux entrypoint file-context and label whatever it matches. The base
# policy names no agent (see selinux/policy/ai_tools.fc): the pattern comes from this package's
# own manifest, and the helper maps it to the base's ai_tools_exec_t as a local rule, so a
# session's domain transition fires. Offline and idempotent; it no-ops when SELinux or the
# ai_tools module is inactive, and when the toolchain is not provisioned yet (a fresh install --
# ai-tools-bootstrap relabels the entrypoint it installs).
#
# Not swallowed: an entrypoint that stays mislabelled means ai-tools-run refuses every launch, so
# the scriptlet reports the remedy and exits non-zero rather than leaving that to be discovered
# at the first `claude`.
if [ -x %{ai_sbindir}/ai-tools-relabel-agent ]; then
    %{ai_sbindir}/ai-tools-relabel-agent >/dev/null || {
        echo "ai-tools-agents-claude-code-restricted: entrypoint labelling failed; see 'journalctl -t ai-tools-relabel-agent'" >&2
        echo "ai-tools-agents-claude-code-restricted: fix the cause and re-run: sudo ai-tools --relabel" >&2
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
# through `ai-tools-admin postupgrade` -- a scriptlet does not edit a config file. Say so here,
# because leaving it costs silently: a hook this version ships installs its body and its data, and
# nothing invokes it until its DECLARATION reaches settings.json.
if [ -f /opt/ai-tools/.claude/settings.json.rpmnew ]; then
    echo "ai-tools: settings.json.rpmnew is waiting -- this version's hook declarations are not in"
    echo "  your settings.json yet, so the hooks they declare never run. Merge them with:"
    echo "    sudo ai-tools-admin postupgrade"
fi

%preun -n ai-tools-agents-claude-code-restricted
# On final erase, drop the entrypoint file-context rule this package registered and restore
# default labels on what it matched -- the type it names belongs to ai-tools-base, which the host
# may erase next, and a local rule naming an undefined type breaks later relabels. Runs in %preun,
# not %postun, because the pattern is read from this package's manifest, which is still on disk
# here.
if [ "$1" -eq 0 ] && [ -x %{ai_sbindir}/ai-tools-relabel-agent ]; then
    %{ai_sbindir}/ai-tools-relabel-agent --remove claude-code >/dev/null 2>&1 || :
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
%attr(0750, root, root) %{ai_sbindir}/ai-tools-safedir
%attr(0750, root, root) %{ai_sbindir}/ai-tools-reclaim
%attr(0750, root, root) %{ai_sbindir}/ai-tools-admin
%{_sbindir}/ai-tools-admin
%attr(0750, root, root) %{ai_sbindir}/ai-tools-handback
%attr(0755, root, root) %{ai_bindir}/ai-tools
%{_sbindir}/ai-tools
%attr(0644, root, root) %{ai_mandir}/man1/ai-tools.1*
%attr(0644, root, root) %{ai_mandir}/man5/operator.conf.5*
%attr(0750, root, ai-tools) %{ai_bindir}/ai-tools-handback-client
%dir %attr(0751, root, ai-tools) %{ai_libdir}
%attr(0644, root, root) %{ai_libdir}/log.lib.sh
%attr(0644, root, root) %{ai_libdir}/msg.lib.sh
%attr(0644, root, root) %{ai_libdir}/skip-dirs.lib.sh
%attr(0640, root, root) %{ai_libdir}/relabel.lib.sh
%attr(0640, root, root) %{ai_libdir}/secret-patterns.lib.sh
%attr(0644, root, root) %{ai_libdir}/operator.lib.sh
%attr(0644, root, root) %{ai_libdir}/control-plane.lib.sh
%attr(0644, root, root) %{ai_libdir}/managed-assets.lib.sh
%attr(0644, root, root) %{ai_libdir}/safe-paths.lib.sh
%attr(0644, root, root) %{ai_libdir}/confinement.lib.sh
%attr(0644, root, root) %{ai_libdir}/npm-verify.lib.sh
%attr(0644, root, root) %{ai_libdir}/conf.lib.sh
%attr(0644, root, root) %{ai_libdir}/providers.lib.sh
%attr(0644, root, root) %{ai_libdir}/selinux-groups.lib.sh
%attr(0644, root, root) %{ai_libdir}/filters.lib.sh
%dir %attr(0755, root, root) %{ai_libdir}/agents.d
%dir %attr(0755, root, root) %{ai_libdir}/integrations.d
%dir %attr(0755, root, root) %{ai_libdir}/session-env.d
%dir %attr(0755, root, root) %{ai_libdir}/filters.d
%attr(0644, root, root) %{ai_libdir}/filters.d/core.rules
%attr(0550, root, ai-tools) /opt/ai-tools/bin/ai-tools-run
%attr(0644, root, root) %{ai_libdir}/path-dedup.sh
%{_unitdir}/ai-tools-handback.socket
%{_unitdir}/ai-tools-handback@.service
%config(noreplace) %attr(0440, root, root) %{_sysconfdir}/sudoers.d/ai-tools
%dir %attr(0755, root, root) %{_sysconfdir}/ai-tools
%config(noreplace) %attr(0644, root, root) %{_sysconfdir}/ai-tools/operator.conf
%{_sysusersdir}/ai-tools.conf
%dir %{_datadir}/selinux/packages/ai-tools
%{_datadir}/selinux/packages/ai-tools/ai_tools.pp
%{_datadir}/selinux/packages/ai-tools/ai_tools_tmpmap.pp
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
%attr(0750, root, root) %{ai_sbindir}/ai-tools-launcher-symlink
%attr(0750, root, root) %{ai_sbindir}/ai-tools-relabel-agent
%attr(0750, root, root) %{ai_sbindir}/ai-tools-bootstrap
%{_sbindir}/ai-tools-bootstrap
%attr(0550, root, ai-tools) /opt/ai-tools/bin/nvm-update.sh
%{_userunitdir}/nvm-update.service
%{_userunitdir}/nvm-update.timer
%{_unitdir}/ai-tools-relabel.path
%{_unitdir}/ai-tools-relabel.service

%files -n ai-tools-integration-dotnet
%attr(0644, root, root) %{ai_libdir}/session-env.d/dotnet.env.sh
%attr(0644, root, root) %{ai_libdir}/integrations.d/dotnet.conf
%attr(0644, root, root) %{ai_libdir}/filters.d/dotnet.rules
%attr(0750, root, root) %{ai_sbindir}/ai-tools-dotnet
%{_sbindir}/ai-tools-dotnet
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
%attr(0644, root, root) %{ai_libdir}/session-env.d/claude-code.env.sh
%attr(0755, root, root) %{ai_bindir}/claude
%attr(0750, root, ai-tools) /opt/ai-tools/.claude/post-tool-hook.sh
%attr(0750, root, ai-tools) /opt/ai-tools/.claude/session-hook.sh
%attr(0750, root, ai-tools) /opt/ai-tools/.claude/filter-hook.sh
%config(noreplace) %attr(0640, root, ai-tools) /opt/ai-tools/.claude/settings.json

%changelog
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
- For .NET workloads on an enforcing host, enable the two optional groups they need: tmpmap for
  restore/build and apphost to run an executable or host project; both stay off by default.

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
