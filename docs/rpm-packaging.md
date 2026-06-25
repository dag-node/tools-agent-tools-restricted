# RPM packaging

This note specifies the RPM packaging of the project: the package set, the
boundary each subpackage owns, the runtime operator-identity contract that lets
the helpers ship operator-agnostic, and the scriptlet behaviour. It is the
contract the spec file and the `src/` reorganization satisfy.

## Package set

One source package (`ai-tools`) builds three subpackages, layered by dependency:

```
ai-tools.spec  (one source RPM, BuildArch: noarch)
 ├─ ai-tools-base            the provider-agnostic umbrella
 ├─ ai-tools-nodejs          Requires: ai-tools-base = %{version}-%{release}
 └─ claude-code-restricted   Requires: ai-tools-nodejs = %{version}-%{release}
```

`ai-tools-base` carries the sandbox account, the project-management workflow, and
the ownership/secret machinery — everything independent of which AI tool runs in
the sandbox. `ai-tools-nodejs` adds nvm-managed Node and the auto-update timer.
`claude-code-restricted` is the Claude Code provider layer. A future provider
package (`ai-tools-<provider>`) is a sibling of `claude-code-restricted`,
depending on the same base and nodejs layers, so the base is shared rather than
duplicated.

Inter-subpackage `Requires` pin the exact `%{version}-%{release}`, so the three
move as a unit and a partial upgrade cannot mix layers.

## Boundaries

| Subpackage | Owns |
|---|---|
| `ai-tools-base` | the `ai-tools` user + group + linger; `/opt/ai-tools` home (and its default-deny `.gitignore` git guard) and `/var/opt/ai-tools` sandbox tree; `/etc/ai-tools/operator.conf`; `ai-tools` CLI (project lifecycle, `enroll`); ownership/secret helpers (`ai-tools-chown`, `-setgid`, `-setfacl`, `-unclaim`, `-lockdown`, `-relabel`); the handback socket, daemon, and client; `secret-patterns` template; `log.lib.sh`, `msg.lib.sh`, `relabel.lib.sh`, `prune-dirs.lib.sh`, `secret-patterns.lib.sh`; the base SELinux domain (`ai_tools_t` and the handback/helper types) |
| `ai-tools-nodejs` | nvm under `/opt/ai-tools/.nvm`; the per-sandbox-user Node-version auto-update service and timer; `ai-tools-bootstrap`; the symlink-repoint helper (`ai-tools-claude-symlink`) and the post-upgrade entrypoint relabel (`ai-tools-relabel-entrypoint`) |
| `claude-code-restricted` | the `claude` wrapper and `claude-run`; `/opt/ai-tools/bin/claude`; the `claude-run` sudoers rule; the Claude Code hooks (`post-tool-hook.sh`, `session-hook.sh`) and `settings.json`; the SELinux `ai_tools_exec_t` entrypoint file-context for `claude.exe` |

The handback daemon is a verb dispatcher over a helper table; the generic verbs
(`CHOWN`, `SETGID`, `SETFACL`) and the daemon live in the base, while the
node/provider-specific verb path (`SYMLINK`, repointing the provider binary)
lives in `ai-tools-nodejs`. The SELinux core domain confines whichever entrypoint
the sandbox user execs; the base ships the domain and helper types, and the
provider package supplies the `.fc` rule that labels its own entrypoint
`ai_tools_exec_t`, so a second provider relabels its binary into the same domain
without changing the base policy.

## Operator-identity contract

The sandbox account (`ai-tools`) is fixed and baked into paths, SELinux types,
and helper names. The **operator** — the human whose projects the sandbox works
on — is per-install and is resolved at runtime, not substituted into file
contents at build time.

`ai-tools-base` ships `/etc/ai-tools/operator.conf` as
`%config(noreplace)`, with the operator fields commented out:

```sh
# /etc/ai-tools/operator.conf — written by `ai-tools-enroll`.
# PROJECTS_USER=
# PROJECTS_HOME=
# PROJECTS_GROUP=
```

The root helpers source this file and resolve `PROJECTS_USER`, `PROJECTS_HOME`,
and `PROJECTS_GROUP` from it (the allowlist path remains overridable through the
existing `AI_TOOLS_ALLOWLIST` environment variable). When no operator is set, a
helper that restores ownership has no target and is a no-op, so an unenrolled
install is inert rather than misbehaving. This replaces the install-time
`@PROJECTS_USER@`/`@PROJECTS_HOME@`/`@PROJECTS_GROUP@` substitution; the
`@SANDBOX_USER@`/`@SANDBOX_GROUP@` tokens are constant and are substituted once at
build time in `%install`.

A single config read is the only operator-dependent input to the helpers, so the
package files are identical on every host and `rpm -V` reports no helper as
modified after enrollment.

## Enrollment

`ai-tools-enroll [user]` (`/usr/local/sbin/ai-tools/ai-tools-enroll`, root, run via
`sudo`; defaults to `$SUDO_USER`) performs the per-operator setup that an RPM
scriptlet cannot, because it is specific to one human. It is a standalone root
helper rather than an `ai-tools` CLI verb, because the `ai-tools` CLI refuses to
run as root. It:

- writes `/etc/ai-tools/operator.conf` for the operator (`PROJECTS_USER/HOME/GROUP`);
- installs the `sudoers.d/ai-tools-claude` drop-in with the operator as principal,
  generated inline and validated with `visudo -cf` before activation;
- enables linger for the operator and `ai-tools`;
- seeds the operator's `~/.config/ai-tools/allowed-projects` (empty, with a header)
  when absent, leaving an existing allowlist untouched;
- re-owns the control plane (`/opt/ai-tools`, `bin`, `.claude`, the control files,
  `.gitconfig`, `.gitignore`, `.claude.json`) from the package's neutral `root:ai-tools`
  placeholder to the operator, tightening `/opt/ai-tools` to `drwxr-s---` and leaving the
  agent-owned subtrees (`.nvm`/`.cache`/`.local`/`.npm`) and `.git` untouched;
- captures the control plane's initial state in an operator-owned git repo (default-deny
  via the shipped `.gitignore`), with the repo metadata locked operator-private so the
  agent cannot read committed blobs;
- offers, interactively, to wire the host-wide PATH dedup into the operator's `~/.bashrc`
  and `~/.bash_profile` after their nvm init; a non-interactive run prints the line to add
  rather than editing the home.

`ai-tools-enroll` refuses to run until `ai-tools-bootstrap` has populated the toolchain
(it checks for `/opt/ai-tools/.nvm`): enrolling first would lock the home to the operator
before the sandbox account has created its `.nvm`/`.cache` subtrees, which it then could no
longer write. When the toolchain is absent it prints the ordered steps and exits without
changing anything.

`ai-tools-enroll` is idempotent and re-runnable: a second run reconciles
`operator.conf`, the sudoers principal, and linger to the named user, leaves a
seeded allowlist in place, reasserts control-plane ownership, skips the git capture
when `.git` already exists, and skips the PATH-dedup wiring when it is already present.
The re-own and git capture assume `ai-tools-bootstrap` has already run (the documented
order, and the order `%post` prints), so the agent-owned `.nvm`/`.cache` subtrees exist;
the home-claim in bootstrap is guarded to not steal ownership back on a later re-run.
Enabling the operator's `nvm-update` user timer and installing the `~/.local/bin` wrapper
are not yet part of it — those depend on the user-unit and wrapper shipping locations
settled with the spec, and remain in `install.sh` for the dev flow.

The `%post` of `ai-tools-base` does **not** enroll: enrollment is per-operator and the
control-plane re-own must follow `ai-tools-bootstrap`, neither of which a non-interactive
scriptlet can do. `%post` installs cleanly and unenrolled and prints the ordered
`sudo ai-tools-bootstrap` then `sudo ai-tools-enroll <user>` directives for the operator
to run.

## Bootstrap

`ai-tools-bootstrap [npm-package]` (`/usr/local/sbin/ai-tools/ai-tools-bootstrap`,
root, run via `sudo`; shipped by `ai-tools-nodejs`) creates the `ai-tools` system
account and its `/opt/ai-tools` home when absent, then installs nvm, Node, and the
agent's npm package under `/opt/ai-tools` as the sandbox account, and points
`/opt/ai-tools/bin/<launcher>` at the versioned binary. It defaults to the Claude
Code package and accepts an explicit package argument, so the same command serves
other providers; the launcher symlink is created only for a package whose launcher
is known.

Bootstrap claims `/opt/ai-tools` for the sandbox account only while it is still unowned
by an operator (a fresh dir, the RPM placeholder, or already `ai-tools`), so nvm/npm can
populate it; it pre-creates the agent's writable state dirs (`.cache`, beside the nvm
tree), seeds an empty `~/.claude.json` (`{}`) so the agent has a writable state file once
the home is locked, and adds the PATH-dedup guard to the account's `~/.bash_profile`. After
`ai-tools-enroll` re-owns the home to the operator (`drwxr-s---`), a bootstrap re-run
leaves that ownership intact — Node updates land inside the agent-owned `.nvm` subtree,
which stays writable.

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

- `%pre` creates the `ai-tools` user and group via `systemd-sysusers` from a
  shipped `sysusers.d` snippet (system account, home `/opt/ai-tools`, shell
  `/sbin/nologin`, locked password), so the account exists before any file is
  owned by it. `Requires(pre): shadow-utils`.
- `%post` enables linger for `ai-tools`; runs `%systemd_post
  ai-tools-handback.socket`; opportunistically enrolls `$SUDO_USER` (above); and,
  when SELinux is not `Disabled`, installs the prebuilt core policy module and
  relabels (below).
- `%preun` runs `%systemd_preun ai-tools-handback.socket`.
- `%postun` runs `%systemd_postun_with_restart ai-tools-handback.socket`, and on
  final erase (`$1 == 0`) removes the SELinux core module and re-applies default
  contexts.

`ai-tools-nodejs`: `%post`/`%preun`/`%postun` manage the `nvm-update` units with
the systemd macros against `%{_userunitdir}` (`/usr/lib/systemd/user/`), where the
user units ship system-wide; per-user enablement is done by `ai-tools-enroll`.

`claude-code-restricted`: `%post` applies the entrypoint file-context and, when
SELinux is enabled, relabels `/opt/ai-tools/bin`; no service of its own.

The user systemd units move from the operator's `~/.config/systemd/user/` to
`%{_userunitdir}`, so RPM owns them and a single shipped copy serves every
operator.

## SELinux

The core policy module ships prebuilt (`ai_tools.pp`) under
`%{_datadir}/selinux/packages/`, so a normal install needs no policy toolchain.
`ai-tools-base` `%post` installs the **core module only** and applies file
contexts when `getenforce` is not `Disabled`, and is a no-op otherwise; it does
not prompt for or load the optional policy groups. The optional groups
(`systemd`, `pkgmgmt`, `netadmin`, `podman`) remain available through
`ai-tools-selinux enable-group <name>` for an operator who hits a boundary, and
are not installed by the package.

`%postun` removes the module on final erase only. Per-project `semanage fcontext`
rules are created by project registration, not by the package, so an erase that
keeps registered projects leaves their labels in place.

## Preservation on erase

Erasing the packages keeps everything that is operator state or runtime data
rather than packaged files:

- the `ai-tools` user and group, so a reinstall or upgrade never orphans
  `ai-tools`-owned files;
- `/opt/ai-tools/.nvm` (nvm and Node) and `/var/opt/ai-tools` (sandbox clones),
  which are unpackaged runtime data;
- each operator's `~/.config/ai-tools/{allowed-projects,secret-patterns}`, which
  the package never owns — `ai-tools-enroll` seeds them and they survive erase
  untouched.

`operator.conf` is `%config(noreplace)`, so operator edits survive an upgrade and
the file is removed only on final erase.

## Tests

The test suite is not run by any scriptlet: integration and boundary tests need a
deployed, enrolled system with a live user session, and scriptlets must stay fast,
non-interactive, and free of runtime-state dependencies. The hermetic unit subset
MAY run in the spec `%check` at build time; the full suite (`tests/run.sh`) and
`ai-tools check-perms` remain available on demand after install.

## Build

`make dist` produces the `%{name}-%{version}.tar.gz` source tarball consumed by
`Source0`; `%prep` is `%autosetup`. The build compiles nothing (`BuildArch:
noarch`); `%install` lays out the `src/` tree into the buildroot and substitutes
the constant `@SANDBOX_*@` tokens. The prebuilt `ai_tools.pp` is shipped as a
build artifact checked into the source tarball, so the build needs no
`selinux-policy-devel`.

Runtime dependencies: `ai-tools-base` requires `systemd`, `sudo`, `acl`,
`python3`, `coreutils`, and `policycoreutils` (for `restorecon`/`semodule`);
`ai-tools-nodejs` adds `curl`, `tar`, and `gzip` for bootstrap. Node is not an RPM
dependency — it is nvm-managed under `/opt/ai-tools` so the agent can self-update
it within the policy the SELinux module enforces.
</content>
</invoke>
