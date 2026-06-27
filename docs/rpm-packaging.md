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
| `ai-tools-base` | the `ai-tools` user and the `ai-ops` operators group; `/opt/ai-tools` home (and its default-deny `.gitignore` git guard) and `/var/opt/ai-tools` sandbox tree; the static `%ai-ops` sudoers drop-in; the `ai-tools` CLI (project lifecycle); `ai-tools-admin` (operator administration); ownership/secret helpers (`ai-tools-chown`, `-setgid`, `-setfacl`, `-unclaim`, `-lockdown`, `-relabel`); the handback socket, daemon, and client; `secret-patterns` template; `log.lib.sh`, `msg.lib.sh`, `relabel.lib.sh`, `prune-dirs.lib.sh`, `secret-patterns.lib.sh`, `operator.lib.sh`, `control-plane.lib.sh`; the base SELinux domain (`ai_tools_t` and the handback/helper types) |
| `ai-tools-nodejs` | nvm under `/opt/ai-tools/.nvm`; the per-sandbox-user Node-version auto-update service and timer; `ai-tools-bootstrap`; the symlink-repoint helper (`ai-tools-claude-symlink`) and the post-upgrade entrypoint relabel (`ai-tools-relabel-entrypoint`) |
| `claude-code-restricted` | the `claude` wrapper and `claude-run`; `/opt/ai-tools/bin/claude`; the Claude Code hooks (`post-tool-hook.sh`, `session-hook.sh`) and `settings.json`; the SELinux `ai_tools_exec_t` entrypoint file-context for `claude.exe` |

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

`ai-tools-admin operator add|remove|list` (`/usr/local/sbin/ai-tools/ai-tools-admin`,
root, run via `sudo`) manages the operators -- the login users (a human or a rootless
service account) that drive the sandbox through the shared `ai-tools` account. It is a
root helper rather than an `ai-tools` CLI verb, because it edits host config (the
`OPERATORS` list, the `ai-ops` group, the sandbox account's linger) while the CLI is unprivileged and refuses
to run as root.

`add [user]` (default `$SUDO_USER`) is accumulating and idempotent:

- appends the name to `OPERATORS` in `/etc/ai-tools/operator.conf`;
- adds the user to the `ai-ops` group, which the static `sudoers.d/ai-tools-claude`
  drop-in and the launch wrapper gate on;
- seeds the user's `~/.config/ai-tools/allowed-projects` (empty, with a header) when
  absent, leaving an existing allowlist untouched;
- ensures the `ai-tools` account's linger (its `--user` instance runs the toolchain timer
  and each `claude-run` session); an operator runs `claude` from its own login and needs none;
- offers, interactively, to wire the host-wide PATH dedup into the user's `~/.bashrc`
  and `~/.bash_profile` after their nvm init; a non-interactive run prints the line to add.

`remove <user>` drops the name from `OPERATORS` and the `ai-ops` group, leaving the user's
own allowlist and config in place. `list` prints the current operators. `add` refuses to make
the sandbox account or root an operator, and `claude-run` refuses to launch if the sandbox
account is ever in `ai-ops`.

The static `sudoers.d/ai-tools-claude` drop-in (a `%ai-ops` group rule) and the `ai-ops` group
ship with the package, so adding an operator is a membership change, not a sudoers edit.

The `%post` of `ai-tools-base` does **not** bind an operator: it is per-operator, which a
non-interactive scriptlet cannot do. `%post` installs cleanly and unenrolled and prints the
ordered `sudo ai-tools-bootstrap` then `sudo ai-tools-admin operator add <user>` directives.

## Bootstrap

`ai-tools-bootstrap [npm-package]` (`/usr/local/sbin/ai-tools/ai-tools-bootstrap`,
root, run via `sudo`; shipped by `ai-tools-nodejs`) creates the `ai-tools` system
account and its `/opt/ai-tools` home when absent, then installs nvm, Node, and the
agent's npm package under `/opt/ai-tools` as the sandbox account, and points
`/opt/ai-tools/bin/<launcher>` at the versioned binary. It defaults to the Claude
Code package and accepts an explicit package argument, so the same command serves
other providers; the launcher symlink is created only for a package whose launcher
is known.

The home root stays `root:ai-tools 2751`, which the agent (group `ai-tools`) cannot write,
so bootstrap pre-creates the agent-owned subtrees it must populate — `.nvm`, `.cache`,
`.npm`, `.local`, each `ai-tools:ai-tools 0750` — as root, then runs nvm/Node/npm as the
sandbox account, writing only within them (`PROFILE=/dev/null` keeps nvm's installer off the
root-owned home profile). It seeds an empty `~/.claude.json` (`{}`, `root:ai-tools 0460`) as
root so the agent has a group-writable state file on first run, and creates the launcher
symlink under the locked `bin` as root. A re-run reuses an existing toolchain; Node updates
land inside the agent-owned `.nvm` subtree.

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
- `%post` runs `%systemd_post ai-tools-handback.socket`; when SELinux is not
  `Disabled`, installs the prebuilt core policy module and relabels (below); and
  prints the ordered `ai-tools-bootstrap` then `ai-tools-admin operator add`
  directives. It does not bind an operator or provision the toolchain and its update
  timer — those belong to `ai-tools-admin operator add` and `ai-tools-bootstrap`.
- `%preun` runs `%systemd_preun ai-tools-handback.socket`.
- `%postun` runs `%systemd_postun_with_restart ai-tools-handback.socket`, and on
  final erase (`$1 == 0`) removes the SELinux core module and re-applies default
  contexts.

`ai-tools-nodejs`: `%post`/`%preun`/`%postun` manage the system `ai-tools-relabel.path`
watcher with the systemd macros. The `nvm-update` service and timer ship in
`%{_userunitdir}` (`/usr/lib/systemd/user/`); `ai-tools-bootstrap` enables the timer in
`ai-tools`'s own `--user` instance once it has provisioned the toolchain.

`claude-code-restricted`: `%post` applies the entrypoint file-context and, when
SELinux is enabled, relabels `/opt/ai-tools/bin`; no service of its own.

The `nvm-update` user units ship in `%{_userunitdir}`, so RPM owns them and one shipped
copy serves the `ai-tools` instance that runs the timer.

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
  the package never owns — `ai-tools-admin operator add` seeds the allowlist and they
  survive erase untouched.

`operator.conf` is written at runtime by `ai-tools-admin`, not packaged, so an
upgrade never touches it and an erase leaves it in place — the host's operators
persist across a reinstall.

## Tests

The test suite is not run by any scriptlet: integration and boundary tests need a
deployed system with at least one operator and a live user session, and scriptlets must stay fast,
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
