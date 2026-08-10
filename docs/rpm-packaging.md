# RPM packaging

This note specifies the RPM packaging of the project: the package set, the
boundary each subpackage owns, the runtime operator-identity contract that lets
the helpers ship operator-agnostic, and the scriptlet behaviour. It is the
contract the spec file and the `src/` reorganization satisfy.

## Package set

One source package (`ai-tools`) builds the whole set: the metapackage, the base foundation,
two umbrella metapackages (`ai-tools-agents`, `ai-tools-integration`), and their members,
layered by dependency:

```
ai-tools.spec  (one source RPM, BuildArch: noarch)
 ├─ ai-tools                    Requires: ai-tools-base; Recommends: both umbrellas
 ├─ ai-tools-base               the provider-agnostic foundation
 ├─ ai-tools-selinux            the confinement policy  (GPL-2.0-or-later; base Recommends it)
 ├─ ai-tools-integration        Recommends: ai-tools-integration-{nodejs,dotnet}
 │   ├─ ai-tools-integration-nodejs               Requires: ai-tools-base
 │   └─ ai-tools-integration-dotnet               Requires: ai-tools-base  (host dotnet; no dotnet RPM dep)
 └─ ai-tools-agents             Recommends: ai-tools-agents-claude-code-restricted
     └─ ai-tools-agents-claude-code-restricted    Requires: ai-tools-integration-nodejs
```

`ai-tools-base` carries the sandbox account, the project-management workflow, and
the ownership/secret machinery — everything independent of which AI tool runs in
the sandbox. `ai-tools-selinux` carries the confinement policy and the scriptlets that
load and unload it. It is separate for two reasons that coincide: a compiled policy
module embeds macro expansions from the SELinux reference policy, so it is
`GPL-2.0-or-later` while the rest of the stack is `AGPL-3.0-only`; and confinement is a
second boundary rather than the only one, so base only *recommends* it — dropping it
leaves the documented DAC-only posture rather than a broken install. The
`ai-tools-integration` umbrella groups the host-toolchain layers the
agent builds against: `ai-tools-integration-nodejs` adds nvm-managed Node and the
auto-update timer, `ai-tools-integration-dotnet` adds the session-env glue for a
host-managed .NET toolchain (inert without one), and further language/runtime
integrations join as `ai-tools-integration-*` siblings. The `ai-tools-agents` umbrella
groups the sandboxed agents:
`ai-tools-agents-claude-code-restricted` is the Claude Code provider layer, and other
providers join as `ai-tools-agents-*` siblings on the same base and integration layers,
so the base is shared rather than duplicated.

The `ai-tools` metapackage `Requires` the base (the mandatory foundation) and weakly
`Recommends` both umbrellas, each of which weakly `Recommends` its members — so a default
`dnf install ai-tools` pulls the whole stack while `--setopt=install_weak_deps=0` yields
base alone, and an operator can drop an umbrella or a single member. The umbrellas own no
files. The member→base and member→integration `Requires` pin the exact
`%{version}-%{release}`, so a member and the layers it hard-depends on move as a unit and a
partial upgrade cannot mix layers.

### Renaming a subpackage

A subpackage that takes over another's name and files carries both halves of the rpm rename
contract, so dnf performs the rename as part of an ordinary upgrade:

```
Provides:       <old-name> = %{version}-%{release}
Obsoletes:      <old-name> < <version the rename landed in>
```

Both are required, and the cost of omitting them is a **failed transaction**, not a cosmetic
gap. The old subpackage pins `Requires: ai-tools-base = <its own version>`; the only upgrade
candidate for the base is the new version; and with nothing obsoleting the old name, dnf can
neither keep nor replace it, so `dnf update` fails outright and the operator is pushed into a
manual erase that drops their `operator.conf`. Where the two packages also share a file path
(the `claude` wrapper, the hooks), the `Obsoletes` is additionally what lets rpm hand the file
over instead of reporting a conflict between the installed and the incoming package.

The `Obsoletes` bound is the version the rename landed in, never `%{version}`, so a future
package legitimately reusing the old name is not obsoleted by every later release.
`ai-tools-integration-nodejs` (from `ai-tools-nodejs`) and
`ai-tools-agents-claude-code-restricted` (from `claude-code-restricted`) both carry the pair.

## Installing and upgrading

The recommended install is the two commands in the README: the `dagnode-release` package brings
the signed repository definition and the org signing key, then `dnf install ai-tools` pulls the
stack. This section covers the cases that do not fit on the front page.

**Offline / air-gapped, from a release archive.** The zip bundles every RPM of the release — the
`ai-tools` metapackage, `ai-tools-base`, and the `ai-tools-agents` / `ai-tools-integration`
umbrellas with their members — plus the public key. They extract flat and dnf orders them itself:

```bash
unzip ai-tools-el10-vX.Y.Z.zip                 # ai-tools-el9-... to match your platform
sudo rpm --import RPM-GPG-KEY-dag-node         # every release is signed; import once
rpm --checksig ./*.rpm                         # each line should end in: digests signatures OK
sudo dnf install ./*.rpm
```

**Upgrade in place; never `dnf remove` first.** From the repository, `sudo dnf upgrade
'ai-tools*'`; from a downloaded archive, `sudo dnf install ./*.rpm` (a higher version upgrades
each subpackage). A subpackage that has been renamed carries `Obsoletes` for its old name, so dnf
performs the rename inside the same transaction and nothing has to be removed by hand.

Removing the packages moves an edited `/etc/ai-tools/operator.conf` to `operator.conf.rpmsave`
and a fresh install writes an empty one, dropping the operator list (re-add with
`ai-tools-admin operator add`); an in-place upgrade keeps it via `%config(noreplace)`. What else
survives an erase is in [Preservation on erase](#preservation-on-erase). `dnf reinstall` requires
the *same* version already installed and is not the way to move between versions.

## Boundaries

| Subpackage | Owns |
|---|---|
| `ai-tools-base` | the `ai-tools` user and the `ai-ops` operators group; `/opt/ai-tools` home ROOT and `bin` (plus its default-deny `.gitignore` git guard and `.gitconfig` identity, both `%post`-seeded-if-missing and not rpm-owned, so an erase preserves them); the mode and label contract every agent's config directory carries, but no such directory itself; the shared skills root `/opt/ai-tools/skills` and the pristine skill copies (skills are agent-agnostic, so every agent symlinks into this one place) and `/var/opt/ai-tools` sandbox tree; the static `%ai-ops` sudoers drop-in; the `ai-tools` CLI (project lifecycle); `ai-tools-admin` (operator administration); ownership/secret helpers (`ai-tools-chown`, `-setgid`, `-setfacl`, `-unclaim`, `-lockdown`, `-relabel`); the handback socket, daemon, and client; `secret-patterns` template; `log.lib.sh`, `msg.lib.sh`, `relabel.lib.sh`, `skip-dirs.lib.sh`, `safe-paths.lib.sh`, `secret-patterns.lib.sh`, `operator.lib.sh`, `control-plane.lib.sh`, `conf.lib.sh`, `providers.lib.sh`; the agent-agnostic confinement shim `/opt/ai-tools/bin/ai-tools-run` and the `%ai-ops` sudoers grant that reaches it; the `agents.d`, `integrations.d`, and `session-env.d` provider directories (base owns the dirs at `0755 root:root`; each member package drops only its own manifest or fragment into them) |
| `ai-tools-selinux` | the prebuilt SELinux policy packages in `/usr/share/selinux/packages/ai-tools/` — the core `ai_tools.pp` (the `ai_tools_t` domain and the handback/helper types) plus each STABLE optional group; the `%post`/`%postun` scriptlets that load the core and unload every loaded `ai_tools*` module on erase; the GPL licence text |
| `ai-tools-integration-nodejs` | nvm under `/opt/ai-tools/.nvm`; the per-sandbox-user Node-version auto-update service and timer; `ai-tools-bootstrap`; the symlink-repoint helper (`ai-tools-launcher-symlink`) and the post-upgrade entrypoint relabel (`ai-tools-relabel-agent`) |
| `ai-tools-integration-dotnet` | the dotnet session-env fragment (`session-env.d/dotnet.env.sh`) and manifest (`integrations.d/dotnet.conf`); the `ai-tools-dotnet` provisioning helper (writable NuGet cache + read-only shared tools under its own `/opt/ai-tools/integrations/dotnet` state root, covered by the base's single fcontext rule for that tree). No .NET runtime — the host's dotnet is used |
| `ai-tools-agents-claude-code-restricted` | the `claude` launch wrapper; `/opt/ai-tools/bin/claude`; the Claude Code hooks (`post-tool-hook.sh`, `session-hook.sh`) and `settings.json`; its agent manifest (`agents.d/claude-code.conf`, naming the npm package, launcher, display name, handback capability, config directory, and the SELinux entrypoint file-context for `claude.exe`); its own config directory `/opt/ai-tools/.claude`, the shipped Claude-format agents seeded into it, and its session-env fragment (`session-env.d/claude-code.env.sh`); the scriptlets that register that file-context on install and drop it on erase. Confinement itself is base-owned, so this package ships no shim and needs no sudoers rule of its own |

The handback daemon is a verb dispatcher over a helper table; the generic verbs
(`CHOWN`, `SETGID`, `SETFACL`) and the daemon live in the base, while the
node/provider-specific verb path (`SYMLINK`, repointing the provider binary)
lives in `ai-tools-integration-nodejs`. The SELinux core domain confines whichever entrypoint
the sandbox user execs; the base ships the domain and helper types (including
`ai_tools_exec_t`) but no entrypoint rule, and the provider package declares the file-context
for its own entrypoint in its manifest, which `ai-tools-relabel-agent` registers as a local
rule on install and drops on erase. A second provider therefore labels its binary into the same
domain without changing the base policy.

## Operator-identity contract

The sandbox account (`ai-tools`) is fixed and baked into paths, SELinux types,
and helper names. The **operators** — the login users (a human plus rootless
service accounts) whose projects the sandbox works on — are per-host and resolved
at runtime, not substituted into file contents at build time.

`/etc/ai-tools/operator.conf` is not a packaged file: `ai-tools-admin` creates
`/etc/ai-tools/` and writes it at runtime, holding the operators list:

```sh
# /etc/ai-tools/operator.conf — managed by `ai-tools-admin`.
OPERATORS="alice bob svc-ci"
```

Because rpm does not own the file, an upgrade or reinstall never rewrites or
removes it, so the operators persist untouched across the package lifecycle.

The root helpers and the agent hooks parse this list (each operator's home and
primary group are derived from the name via `getent`/`id`), so the package files
carry no per-operator value. When the list is empty, a helper that restores
ownership has no target and is a no-op, so an unenrolled install is inert rather
than misbehaving. This replaces the install-time
`@PROJECTS_USER@`/`@PROJECTS_HOME@`/`@PROJECTS_GROUP@` substitution; the
`@SANDBOX_USER@`/`@SANDBOX_GROUP@` tokens are constant and are substituted once at
build time in `%install`.

A single config read is the only operator-dependent input to the helpers, so the
package files are identical on every host and `rpm -V` reports no helper as
modified after an operator is added.

## Operator administration

`ai-tools-admin operator add|remove|list` (`/usr/local/libexec/ai-tools/ai-tools-admin`,
root, run via `sudo`) manages the operators -- the login users (a human or a rootless
service account) that drive the sandbox through the shared `ai-tools` account. It is a
root helper rather than an `ai-tools` CLI verb, because it edits host config (the
`OPERATORS` list, the `ai-ops` group, the sandbox account's linger) while the CLI is unprivileged and refuses
to run as root.

`add [user]` (default `$SUDO_USER`) is accumulating and idempotent:

- appends the name to `OPERATORS` in `/etc/ai-tools/operator.conf`;
- adds the user to the `ai-ops` group, which the static `sudoers.d/ai-tools`
  drop-in and the launch wrapper gate on;
- seeds the user's `~/.config/ai-tools/allowed-projects` (empty, with a header) when
  absent, leaving an existing allowlist untouched;
- ensures the `ai-tools` account's linger (its `--user` instance runs the toolchain timer
  and each `ai-tools-run` session); an operator runs `claude` from its own login and needs none;
- offers, interactively, to wire the host-wide PATH dedup into the user's `~/.bashrc`
  and `~/.bash_profile` after their nvm init; a non-interactive run prints the line to add.

`remove <user>` drops the name from `OPERATORS` and the `ai-ops` group, leaving the user's
own allowlist and config in place. `list` prints the current operators. `add` refuses to make
the sandbox account or root an operator, and `ai-tools-run` refuses to launch if the sandbox
account is ever in `ai-ops`.

The static `sudoers.d/ai-tools` drop-in (a `%ai-ops` group rule) and the `ai-ops` group
ship with the package, so adding an operator is a membership change, not a sudoers edit.

The `%post` of `ai-tools-base` does **not** bind an operator: it is per-operator, which a
non-interactive scriptlet cannot do. `%post` installs cleanly and unenrolled and prints the
ordered `sudo ai-tools-bootstrap` then `sudo ai-tools-admin operator add <user>` directives.

## Bootstrap

`ai-tools-bootstrap` (`/usr/local/libexec/ai-tools/ai-tools-bootstrap`, root, run via
`sudo`; shipped by `ai-tools-integration-nodejs`) creates the `ai-tools` system account
and its `/opt/ai-tools` home when absent, then installs nvm, Node, and each **enabled**
agent's npm package under `/opt/ai-tools` as the sandbox account, and points
`/opt/ai-tools/bin/<launcher>` at each versioned binary. It takes no arguments and names
no agent: the enabled set, each agent's npm package, and its launcher come from the
manifests under `/usr/local/lib/ai-tools/agents.d` gated by `operator.conf`
`AI_TOOLS_AGENTS` (see the [providers](../.claude/rules/providers.rule.md) rule). With no
manifests deployed it provisions Node alone, and a re-run picks up agents installed since.

The home root stays `root:ai-tools 2751`, which the agent (group `ai-tools`) cannot write,
so bootstrap pre-creates the agent-owned subtrees it must populate — `.nvm`, `.cache`,
`.npm`, `.local`, each `ai-tools:ai-tools 0750` — as root, then runs nvm/Node/npm as the
sandbox account, writing only within them (`PROFILE=/dev/null` keeps nvm's installer off the
root-owned home profile). It creates the launcher symlink under the locked `bin` as root;
agent runtime state needs no seeding — `ai-tools-run` pins `CLAUDE_CONFIG_DIR` to the
group-writable `.claude`, where claude creates its own state files (`.claude.json`
included). A re-run reuses an existing toolchain; Node updates land inside the agent-owned
`.nvm` subtree.

The nvm release is resolved at run time — its latest GitHub release by default, so
the command does not carry a version that rots — overridable with
`AI_TOOLS_NVM_VERSION` and falling back to a pinned default when the GitHub API is
unreachable. The resolved tag is constrained to `vMAJOR.MINOR.PATCH` before it
reaches the download URL.

Bootstrap fetches from the network (`nvm` from GitHub, packages from npm), so it
is a command run once after install, never an RPM scriptlet: scriptlets are
non-interactive, must succeed offline and inside build chroots, and must be
reproducible. `%post` prints the `sudo ai-tools-bootstrap` directive; the
nvm-update timer maintains the tree from then on.

## Scriptlets

`ai-tools-base`:

- `%pre` creates the `ai-tools` sandbox user (system account, home `/opt/ai-tools`,
  shell `/sbin/nologin`, locked password) and the `ai-ops` operators group via
  `systemd-sysusers` from a shipped `sysusers.d` snippet, so both exist before any
  file owned by them is unpacked. `Requires(pre): shadow-utils`. The `ai-ops` group
  ships empty; operators are added to it per host.
- `%post` runs `%systemd_post ai-tools-handback.socket`, applies the shared-area ACLs, and
  prints the ordered `ai-tools-bootstrap` then `ai-tools-admin operator add`
  directives. Loading the SELinux policy is NOT base's job — that scriptlet lives with the
  payload in `ai-tools-selinux`. It does not bind an operator or provision the toolchain and its update
  timer — those belong to `ai-tools-admin operator add` and `ai-tools-bootstrap`.
- `%preun` runs `%systemd_preun ai-tools-handback.socket`.
- `%postun` runs `%systemd_postun_with_restart ai-tools-handback.socket`.

`ai-tools-selinux`: `%post` loads the prebuilt core module into the running policy with plain
`semodule -i` and relabels the install paths. `%postun`, on final erase (`$1 == 0`), unloads
every loaded `ai_tools*` module — enumerated, not named, so a stable group enabled with
`ai-tools-admin` and an experimental group compiled from a source checkout are both caught.
Neither scriptlet passes `--noreload`: the store and the running kernel policy must not
diverge, or an install leaves the entrypoint unlabelled and an erase leaves the domain live.

`ai-tools-integration-nodejs`: `%post`/`%preun`/`%postun` manage the system `ai-tools-relabel.path`
watcher with the systemd macros. The `nvm-update` service and timer ship in
`%{_userunitdir}` (`/usr/lib/systemd/user/`); `ai-tools-bootstrap` enables the timer in
`ai-tools`'s own `--user` instance once it has provisioned the toolchain.

`ai-tools-agents-claude-code-restricted`: `%post` applies the entrypoint file-context and, when
SELinux is enabled, relabels `/opt/ai-tools/bin`; no service of its own.

The `nvm-update` user units ship in `%{_userunitdir}`, so RPM owns them and one shipped
copy serves the `ai-tools` instance that runs the timer.

## SELinux

The core policy module and the **stable** optional groups ship prebuilt (`ai_tools.pp` and
each stable `ai_tools_<group>.pp`, currently `ai_tools_tmpmap.pp`) under
`%{_datadir}/selinux/packages/ai-tools/`, so a normal install and enabling a stable group
both need no policy toolchain. `ai-tools-selinux` `%post` loads the **core module only** and
applies file contexts when `getenforce` is not `Disabled`, and is a no-op otherwise. The
stable groups are shipped but stay **off**, toggled per host by an operator who hits a
boundary:

```bash
sudo ai-tools-admin selinux list-groups
sudo ai-tools-admin selinux enable-group tmpmap
```

That helper `semodule`-loads the prebuilt `.pp` from the package directory. The
**experimental** groups (`systemd`, `pkgmgmt`, `netadmin`, `podman`, `apphost`, `netcore`) are
unaudited drafts and
are **not** packaged: `ai-tools-admin` refuses them and directs the operator to compile and
verify one from a source checkout first (`install-selinux.sh enable-group` + the `avc/`
loop). The shipped set is single-sourced with the stable set in `selinux-groups.lib.sh` and
must be kept in step across the spec, `install.sh`, `.gitignore`, and `packaging/Makefile`.
`%postun` on final erase unloads the core **and** any group a host left loaded (the `.pp` is
erased with the package, but the compiled module persists in the store otherwise).
Per-project `semanage fcontext` rules are created by project registration, not by the
package, so an erase that keeps registered projects leaves their labels in place.

## Preservation on erase

Erasing the packages keeps everything that is operator state or runtime data
rather than packaged files:

- the `ai-tools` user and group, so a reinstall or upgrade never orphans
  `ai-tools`-owned files;
- `/opt/ai-tools/.nvm` (nvm and Node) and `/var/opt/ai-tools` (sandbox clones),
  which are unpackaged runtime data;
- each operator's `~/.config/ai-tools/{allowed-projects,secret-patterns}`, which
  the package never owns — `ai-tools-admin operator add` seeds the allowlist and they
  survive erase untouched.

`operator.conf` ships as `%config(noreplace)` with an empty `OPERATORS=""` baseline and is
edited in place by `ai-tools-admin operator add|remove`. `%config(noreplace)` keeps the
edited copy across an **upgrade** (`dnf upgrade`, or `dnf install ./*.rpm` of a higher
version), so the host's operators persist. An **erase** is different: rpm saves the modified
config as `operator.conf.rpmsave` and removes the tracked file, so a remove-then-install
cycle drops the operator list — the fresh install lays down the empty baseline. Upgrade in
place rather than `dnf remove` + install; if a `.rpmsave` was left behind, re-add operators
with `ai-tools-admin operator add` (see the README "Upgrading" note).

## Tests

The test suite is not run by any scriptlet: integration and boundary tests need a
deployed system with at least one operator and a live user session, and scriptlets must stay fast,
non-interactive, and free of runtime-state dependencies. The hermetic unit subset
MAY run in the spec `%check` at build time; the full suite (`tests/run.sh`) and
`ai-tools check-perms` remain available on demand after install.

## Platform scope

The package targets Enterprise Linux (RHEL/Rocky/Alma and UEK R8) with the **targeted**
SELinux policy — where the `ai_tools_t` domain is written and compiled. The `rpm-selftest`
container runs on Rocky with SELinux absent, so a green run validates the RPM, the DAC layer, and
the admin→operator→agent workflow, but **not** the SELinux confinement (`integration/selinux.sh`
skips when the module is not loaded); enforcement is verified only on a real enforcing EL host.
Non-EL SELinux is not a target: an SELinux-enabled Ubuntu host defaults to AppArmor and, when
SELinux is used at all, runs a different base policy the prebuilt `.pp` will not load against, so
the confinement would silently not apply; installation is RPM/`dnf`-native regardless.

## Build

`make dist` produces the `%{name}-%{version}.tar.gz` source tarball consumed by
`Source0`; `%prep` is `%autosetup`. The build compiles nothing (`BuildArch:
noarch`); `%install` lays out the `src/` tree into the buildroot and substitutes
the constant `@SANDBOX_*@` tokens. The prebuilt `ai_tools.pp` is shipped as a
build artifact checked into the source tarball, so the build needs no
`selinux-policy-devel`.

`packaging/VERSION` is the single source of truth for `Version:` — the spec reads
it directly (`%(cat %{_sourcedir}/VERSION)`, also shipped as `Source2` so a
rebuild from the SRPM alone still resolves it) and the Makefile reads the same
file, so a release bump touches one place. `Release:` defaults to plain `1`
(a final `vX.Y.Z` release); `make rpm`/`rpmtest-rockyN`/`rpmbase-elN` accept
`RPM_RELEASE=<override>` — CI passes `0.<run>.git<sha>` for dev builds and
`0.rcN` for `vX.Y.Z-rc.N` prerelease tags. The leading `0.` is the Fedora
pre-release convention, so rpm's version comparison ranks any snapshot or RC
below the final release that follows it, and a host that installed an RC
upgrades cleanly to the final via ordinary `dnf`.

Runtime dependencies: `ai-tools-base` requires `systemd`, `sudo`, `acl`,
`python3`, `coreutils`, and `policycoreutils`, and weakly recommends `ai-tools-selinux`
(which itself pulls `policycoreutils` for `semodule`/`restorecon` and `libselinux-utils` for
`getenforce` at scriptlet time);
`ai-tools-integration-nodejs` adds `curl`, `tar`, and `gzip` for bootstrap. Node is not an RPM
dependency — it is nvm-managed under `/opt/ai-tools` so the agent can self-update
it within the policy the SELinux module enforces.

## Signing and distribution

The `release` job signs each built RPM with the dag-node org GPG key and publishes it to the
signed DNF repository at `https://rpm.dagnode.com/` (the "served from a signed repo" install
path the README leads with). Two properties shape the design:

- **Each project signs its own RPMs, in the matching-EL build container.**
  `packaging/sign-rpms.sh` runs inside `ai-tools-rpmbase:elN` (not on the Ubuntu runner), so
  the `rpm`/`gnupg` toolchain that signs matches the one that built — no header-signature or
  macro mismatch. It imports the key from a step-scoped secret into a throwaway `GNUPGHOME`,
  signs with a fully specified non-interactive `%__gpg_sign_cmd` (loopback pinentry,
  passphrase from a 0600 file, never argv), then verifies every signature against a throwaway
  rpmdb. Verification requires `rpmkeys -Kv` to print a cryptographic signature line that
  validates — not merely a zero exit, which `--checksig` also returns for an *unsigned*
  package, so a silent `rpmsign` no-op cannot ship. Build provenance stays with the project;
  the packages are immutable once signed. **Signing is mandatory.** The release job requires
  `GPG_SIGNING_KEY`, `GPG_SIGNING_PASSPHRASE`, and `RPM_REPO_DISPATCH_TOKEN`, and before
  building or publishing anything it runs `sign-rpms.sh --selftest` in each matching-EL
  container — signing and verifying a throwaway RPM — so a wrong passphrase or a no-op signing
  toolchain fails the job while nothing is public. A release never publishes an unsigned
  package.
- **A central repo owns metadata and hosting.** The signed RPMs and the public key attach to
  the GitHub Release (loose + per-EL zip), then the job notifies the dedicated `dag-node/rpm`
  repository via `repository_dispatch`. That repo — not this project — runs the single publish
  pipeline (`createrepo_c`, `repomd.xml` signing, GitHub Pages deploy at `rpm.dagnode.com`),
  serialized so concurrent project releases never race the metadata.

Prerelease tags (`vX.Y.Z-rc.N`) run the same sign-and-verify path but publish only a GitHub
**prerelease** and skip the `dag-node/rpm` notify — the central repo serves final tags only. A
`workflow_dispatch` run rehearses the identical path with every publish step skipped, leaving
the signed output as a workflow artifact. The process is [`branching-and-release.md`](branching-and-release.md).

The signing key and org secrets (`GPG_SIGNING_KEY`, `GPG_SIGNING_PASSPHRASE`,
`RPM_REPO_DISPATCH_TOKEN`) are in the org playbook `GPG-HINTS.md`; the central repository's
architecture, layout, and DNS/Pages setup are in `RPM-REPO-HINTS.md` — kept out of this
project so its docs stay scoped to the package build.
