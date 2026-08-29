# Agent Tools Restricted

[![CI](https://github.com/dag-node/tools-agent-tools-restricted/actions/workflows/ci.yml/badge.svg)](https://github.com/dag-node/tools-agent-tools-restricted/actions/workflows/ci.yml)
[![License: AGPL v3](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)
[![Platform: EL 9 | EL 10](https://img.shields.io/badge/platform-EL%209%20%7C%20EL%2010-blue.svg)](#requirements)

**Confine coding agents to a locked-down system account — so they never inherit your keys, sudo rights, or secrets.**

Agent Tools Restricted runs autonomous coding agents under a dedicated, unprivileged system user (`ai-tools`) with tightly scoped privileges, SELinux confinement, ownership hand-back, and automatic toolchain updates. The agent never runs as you. Claude Code is the first supported agent; the confinement, ownership-handback, and toolchain machinery are deliberately agent-agnostic.

> **Fun fact.** This project is written inside its own sandbox. The agent that edits these
> files runs as `ai-tools` under the confinement described here — its writes come back to the
> author through the ownership handback, and when a Node upgrade leaves an entrypoint
> mislabelled it refuses to launch the very session that would fix it. Several of the sharper
> edges below were found that way rather than reasoned about.

**Contents**: [Requirements](#requirements) · [Package install](#package-install) · [Why](#why) ·
[Identities and naming](#identities-and-naming) ·
[Architecture at a glance](#architecture-at-a-glance) · [From source](#from-source) ·
[Upgrade behaviour](#upgrade-behaviour) · [Operation logging](#operation-logging) ·
[SELinux](#selinux) · [Community](#community) · [License](#license)

## Requirements

- **Enterprise Linux 9 or 10** — RHEL and its rebuilds (Rocky, AlmaLinux, Oracle
  Linux/UEK). Other distributions are untested; the design assumes systemd, sudo,
  and EL filesystem conventions.
- **systemd** (system instance plus user instances with lingering) and **POSIX ACL**
  support on the filesystem holding your projects.
- **SELinux targeted policy, enforcing** — recommended; the session is confined in
  `ai_tools_t`. With SELinux disabled the system runs in a documented DAC-only
  posture.
- **Network access once** for `ai-tools-bootstrap` (fetches nvm, Node, and the agent
  npm package); day-to-day operation and updates run from a systemd timer.
- Optional: **podman** to run the container test harness (`packaging/README.md`).

> [!WARNING]
> **Pre-1.0 and fast moving.** Ahead of 1.0, interfaces, package layout, CLI verbs, and on-disk
> paths may still change. The stack has run stably since its first release and follows
> [Semantic Versioning](https://semver.org/)—patch releases are compatible fixes, minor bumps may
> break (always noted in the release notes), and upgrades migrate automatically. Review the notes
> before a minor upgrade.

## Package install

Import the org signing key, then install the dag-node release package and the stack. The release
package is signed by the org key, so `dnf` verifies its signature at install time — importing the
key first satisfies that check, since the package that would otherwise install the key has not run
yet. The release package brings the signed DNF repository definition and the key with it
([source](https://github.com/dag-node/rpm-dagnode-release)); the last command pulls the stack. One
repository serves EL 9 and EL 10, and both the packages and the repository metadata are
signature-verified. Verify the key fingerprint out of band before importing — see the
[repository README](https://github.com/dag-node/rpm/blob/main/README.md#signing-key).

```bash
# Import the org signing key (verify its fingerprint out of band first — see the README above)
sudo rpm --import \
  https://rpm.dagnode.com/RPM-GPG-KEY-dag-node

# Install the release package (repo definition + key), then the stack
sudo dnf install \
  https://rpm.dagnode.com/dagnode-release-latest.noarch.rpm
sudo dnf install ai-tools ai-tools-selinux   # the whole stack + SELinux confinement
```

`ai-tools` is a metapackage that pulls the full stack (agents, integrations, toolchain).
`ai-tools-selinux` — the SELinux confinement policy — is only *recommended*, so it is named
explicitly to guarantee confinement on every host, including minimal images that install
without weak dependencies. Drop it only for a deliberate DAC-only deployment.

Then finish setup — steps 1 and 2 here are independent of each other but both run before
step 3:

```bash
# 1. Install Node.js, nvm, and Claude Code (from npm) and enable the update timer (network).
sudo ai-tools-bootstrap

# 2. Enrol yourself as an operator: records you in /etc/ai-tools/operator.conf and grants
#    ai-ops membership (the sudo rules and ownership hand-back).
sudo ai-tools-admin operator add "$(id -un)"

# 3. Claim an existing project and launch. `claude` inside an unclaimed project walks you
#    through claiming it; the claim refuses system paths and home roots. `ai-tools --help`
#    lists every command.
cd ~/path/to/your/project     # an existing directory you want the agent to work in
claude                        # first run here: the wrapper offers to claim it, then launches
```

To claim without launching — or to script it — use `ai-tools --project-claim <path>`,
which claims an existing directory in place.

### Upgrading

Upgrade in place with ordinary DNF — never `dnf remove` first:

```bash
sudo dnf upgrade --refresh 'ai-tools*'
```

`--refresh` forces a metadata refresh: root's DNF cache is separate from your user's and can
predate a just-published release, so a plain `dnf upgrade` may report "Nothing to do" on a
stale cache even when `dnf list` (a newer cache) already shows the new version. This moves
every **installed** ai-tools package to the new version, and a host running `dnf-automatic`
does the same unattended once its cache refreshes on schedule. What it does **not** do is add a package you don't
already have: DNF never pulls a new weak dependency onto an existing install. So a host first
installed before 0.10.0 — when the SELinux policy split into its own `ai-tools-selinux`
package — keeps upgrading *without* confinement until you add it once:

```bash
rpm -q ai-tools-selinux || sudo dnf install ai-tools-selinux
```

Installing offline from a release archive, and exactly what an upgrade preserves, are in
[docs/rpm-packaging.md](docs/rpm-packaging.md#installing-and-upgrading). The
[Upgrade behaviour](#upgrade-behaviour) section below is about the Node/Claude **toolchain**
auto-update, a separate mechanism from these DNF package upgrades.

`claude` resolves to the system wrapper `/usr/local/bin/claude`, which runs as you,
checks your `ai-ops` membership and the project allowlist, then drops to `${SANDBOX_USER}`
via `sudo` and wraps the session in a confined `systemd --user` service. Launched in an
unclaimed project it prompts you to claim it first; the claim and every elevated helper
refuse system directories and home roots (the
[safe-paths backstop](.claude/rules/safe-paths.rule.md)). [From source](#from-source)
is the manual equivalent of the package install plus `ai-tools-bootstrap`.

## Why

A coding agent like Claude Code reads, writes, and runs commands autonomously. Run as
your own user it inherits everything you can touch — SSH keys, browser profiles,
every project, your full sudo rights. And what it reads does not stay local: an agent
sends file contents to a third-party model service as a matter of course, so a secret
the agent can open is a secret you may already have disclosed. Repositories onboarding
agentic tools carry a particular blind spot here: credentials committed years ago and
since "removed" survive in git history — invisible in the working tree, one
`git show` away for anything that can read `.git`.

This project restricts the agent's scope on the host instead of trusting it: a
dedicated UID with a tightly scoped set of privileges, per-project consent for what it
may touch, and shallow clones plus secret lockdown to keep history and credentials out
of what it can ever send:

- **Separate identity** — `${SANDBOX_USER}` is a system account with no login shell
  and no password. Claude executes under that UID via `sudo`, not as you.
- **Launches only in approved projects** — a wrapper refuses to start Claude
  unless the working directory is listed in `~/.config/ai-tools/allowed-projects`
  (with `!` exclusions to carve out subdirectories or secrets).
- **Minimal sudo surface** — `${SANDBOX_USER}` has **no** sudo rights. Root operations
  (ownership handback, setgid normalisation, symlink repoint) go through a dedicated
  socket daemon (`ai-tools-handback`) that verifies the caller's identity with a kernel
  credential the caller cannot forge. The one `%ai-ops` rule that drops to `${SANDBOX_USER}`
  runs only `ai-tools-run` — a fixed-path sudo target, not a glob, which wraps the session in a
  confined systemd `--user --pty` service. Nothing else. See the
  [handback bridge](.claude/rules/handback-bridge.rule.md).
- **Ownership hand-back** — files Claude writes are chowned back to
  `${PROJECTS_USER}:${SANDBOX_GROUP}` (group-readable, world-closed) inside approved paths only, along
  with any directories Claude created on the way (world bits stripped, group
  `rwx` kept; only dirs the agent itself made are touched).
- **Secrets stay out of reach** — a secret-named file Claude writes (`.env`, `*.key`,
  `*.pem`, SSH keys, `kubeconfig`, …) is instead chowned to
  `${PROJECTS_USER}:${PROJECTS_GROUP} 600`, removing `${SANDBOX_USER}`'s read access entirely; a `NOTICE`
  lands in the session and the operation log. `ai-tools --lockdown` applies the same over an
  existing tree. See [secret handling](.claude/rules/secret-handling.rule.md).
- **Git history stays behind** — `ai-tools --sandbox-create` hands the agent a shallow
  clone (`--depth=1`) of a dedicated branch, so credentials buried in past commits are
  never on disk within its reach, and secret-named files in the tip commit are locked
  down before the clone is opened to the agent at all. An in-place claim keeps `.git`
  access an explicit opt-in prompt. See
  [docs/project-lifecycle.md](docs/project-lifecycle.md).
- **Collaborative access** — a POSIX default ACL on each approved tree makes you and
  Claude co-writers without `${PROJECTS_USER}` joining `${SANDBOX_GROUP}`:
  `g:${SANDBOX_GROUP}:rwX` grants Claude access to your files and
  `user:${PROJECTS_USER}:rwX` grants you access to Claude's, both umask-independent;
  world access stays closed. Applied at `ai-tools --project-claim`, which skips owner-only
  paths (`600`/`700`) so a private file or directory is never opened to the agent — see
  [docs/project-lifecycle.md](docs/project-lifecycle.md).
- **Shared skills, one copy** — the documentation and engineering-judgment skills the project
  ships live once in `/opt/ai-tools/skills`; each agent's config directory holds a symlink per
  skill, so a skill is authored and updated in one place however many agents read it, and an
  agent-specific skill is simply a real directory that the linker never displaces. See
  `/usr/share/ai-tools/skills/README.md`.
- **Operation logging** — the `sudo` helpers, the lifecycle hooks, the `ai-tools`
  CLI, and `install.sh` log through one library to **journald** (always, leveled and
  tagged: `journalctl -t ai-tools-chown _UID=0`) and, for the root writers only, to
  root-only files under **`/var/log/ai-tools/`**.
- **A working stop** — `ai-tools --stop` terminates every agent session on the host and
  everything it spawned, with no password to answer, so an unattended detector can reach it too. (To finish a session you are done with, use `/exit` inside it, which lets
  it run its own ownership handback.) Sessions are found and killed by **cgroup**, so a child that
  called `setsid(2)` or double-forked goes with them, and success means verified gone from the
  kernel's view rather than from systemd's. It takes no path and no authorization input, and
  exempts no cgroup — a stop path the session can put itself outside of is not a stop path — so the
  sandbox account's own user manager is terminated too and restarted afterwards. The session takes
  no part in any of it: the account it runs as can neither invoke, read nor alter the helper. What
  each outcome means and what a stop cannot undo are in
  [docs/session-stop.md](docs/session-stop.md).
- **Auto-updating** — a `systemd --user` timer in `${SANDBOX_USER}`'s own instance keeps
  Node and `@anthropic-ai/claude-code` current under `/opt/ai-tools`, and a root-side
  watcher relabels the new entrypoint for SELinux after each upgrade. Each update verifies the
  toolchain's npm registry signatures and fails closed on a tamper before activating it.

One property ties those together, and it is the one to check when reviewing this project:
**every input that decides what a session gets is read through the same trust predicate, and
every way it can fail gives the agent *less*.** A config it cannot read, a manifest someone made
writable, an entrypoint whose SELinux label will not verify, a toolchain whose npm signatures do
not check out — each one costs a capability and is reported; none of them grants one. So there is
no state the agent can arrange that improves its own position, only states that shut it down.

Each of those refusals is tested from both ends: once that the refusal fires, and once — running
*as* the sandbox account — that the agent cannot create the state the refusal exists to catch
(`tests/unit/providers.sh` and `tests/boundary/providers.sh` are the worked pair).

> **On the boundary.** The allowlist gates where Claude *launches* and which
> files get ownership restored — it is not a kernel-enforced read boundary. The CWD is
> canonicalized before it is checked, so a symlink cannot slip a path past it. Once running
> as `${SANDBOX_USER}`, ordinary Unix permissions plus the `ai_tools_t` SELinux type govern
> access; that is what actually isolates the agent from other users' files. A per-session
> `bubblewrap` mount namespace to make the allowlist a true access boundary is proposed but
> not yet implemented.

The enforced isolation boundary is DAC plus the `ai_tools_t` SELinux type. A few things are
**out of scope by design**, not oversights: all operators share one `${SANDBOX_USER}` account
(sessions are not kernel-isolated from each other), and `ai-ops` operators are trusted — the
model defends the host from the *agent*, not from an operator. The full trust model, the
non-goals, and the deferred hardening (per-operator isolation, registry-key pinning) are
in [`CLAUDE.md`](CLAUDE.md#boundaries-and-non-goals).

The agent binary itself is verified against the checksum its vendor **signed**, using a key shipped
in the package rather than downloaded, and the verified value is pinned where the sandbox account
cannot write it — so a binary modified after installation refuses to launch. It needs no per-release
maintenance and no network at launch; what it checks, what each failure means, and how it behaves on
an air-gapped host are in
[docs/entrypoint-verification.md](docs/entrypoint-verification.md).

## Identities and naming

Three identities recur throughout this README, the scripts, and the templates.
They are referred to by fixed names so each reference is unambiguous; the full
spec is in [`docs/naming-conventions.md`](docs/naming-conventions.md).

| Identity | Variable / token | Default | Meaning |
|---|---|---|---|
| Projects user | `PROJECTS_USER` / `@PROJECTS_USER@` | your login (`$SUDO_USER`) | the account that owns the projects, installs the sandbox, and launches `claude` |
| …its group | `PROJECTS_GROUP` / `@PROJECTS_GROUP@` | your primary group | the projects user's private group |
| …its home | `PROJECTS_HOME` / `@PROJECTS_HOME@` | `$HOME` | the projects user's home directory |
| Sandbox user | `SANDBOX_USER` / `@SANDBOX_USER@` | `ai-tools` | the unprivileged service account Claude Code runs as |
| …its group | `SANDBOX_GROUP` / `@SANDBOX_GROUP@` | `ai-tools` | the sandbox user's group |

The package and `install.sh` resolve these automatically — you never type them. The
`@…@` token form is what the shipped templates carry; the RPM `%prep` and `install.sh`
substitute it to `ai-tools` at build/deploy time, and the RPM creates the account from a
`sysusers.d` entry (`u ai-tools …`) with no prompt, so the name is **not** an install-time
choice today. `SANDBOX_USER`/`SANDBOX_GROUP` name the account (`ai-tools`); the literal
`ai-tools` is also kept in paths (`/opt/ai-tools`), SELinux types (`ai_tools_t`), the `ai-tools`
CLI, and helper names (`ai-tools-chown`) — those are fixed and do not track the account name.

Setting the variables by hand matters only on the manual from-source path — the export
block and every step that uses it are in
[docs/install-from-source.md](docs/install-from-source.md).

## Architecture at a glance

```
you type `claude`
  └─ /usr/local/bin/claude                    (wrapper, runs as the invoking operator)
       ├─ caller ∈ ai-ops group?              refuse a non-operator with a framed message
       ├─ CWD ∈ allowed-projects?             refuse if not, or if !-excluded
       ├─ resolve /opt/ai-tools/bin/claude    (one readlink hop; export as AI_TOOLS_AGENT_EXEC)
       ├─ export CWD as AI_TOOLS_PROJECT_DIR    (validated project dir → unit WorkingDirectory)
       └─ exec sudo -u "${SANDBOX_USER}" -- /opt/ai-tools/bin/ai-tools-run
            │                                  (DROPS privilege to the unprivileged sandbox
            │                                   account — the wrapper never runs as root)
            └─ systemd transient service      (--pty; RestrictNamespaces=yes, UMask=0007,
                                               WorkingDirectory=project, NODE_COMPILE_CACHE pinned)
                 └─ claude runs as ${SANDBOX_USER} in ai_tools_t (SELinux)
                      └─ on Write/Edit → PostToolUse hook (or Stop/SessionStart sweep)
                           └─ ai-tools-handback-client CHOWN <file>   (socket, no sudo)
                                └─ ai-tools-handback daemon            (root; authenticated caller)
                                     └─ ai-tools-chown <file>          (allowlist-checked)
                                          └─ chown ${PROJECTS_USER}:${SANDBOX_GROUP}, strip world bits
```

The privilege model and every guard above are specified in
[`CLAUDE.md`](CLAUDE.md) (trust chain and invariants) and the per-component
[`.claude/rules/`](.claude/rules/).

## From source

    git clone https://github.com/dag-node/tools-agent-tools-restricted.git
    cd tools-agent-tools-restricted
    # steps 1-3: PATH fragment, the ai-tools account, nvm + Node + claude
    sudo ./install.sh install                   # step 4: helpers, units, sudoers, CLI
    sudo ai-tools-admin operator add <user>     # enrol yourself as an operator

`install.sh` stops unless the sandbox account and `/opt/ai-tools/bin` already exist —
steps 1–3 create them (once the package is deployed, `sudo ai-tools-bootstrap` does both
in one idempotent command). The four steps, the full source→deploy file map, and
`sudo ./install.sh uninstall` are in
[docs/install-from-source.md](docs/install-from-source.md); registering projects is the
same as the package path — see
[docs/project-lifecycle.md](docs/project-lifecycle.md).

## Upgrade behaviour

`nvm-update.timer` fires daily in `${SANDBOX_USER}`'s `--user` instance and runs
`/opt/ai-tools/bin/nvm-update.sh`, which resolves the latest LTS in the `NVM_NODE_MAJOR`
series, installs it under `/opt/ai-tools/.nvm`, refreshes the global tools, prunes, and:

- repoints each enabled agent's `/opt/ai-tools/bin/<launcher>` symlink at the new versioned
  binary via the handback socket bridge (`SYMLINK` verb → `ai-tools-launcher-symlink`). `bin`
  is locked `0551`, so the `${SANDBOX_USER}` updater cannot write it directly; the helper
  validates the versioned path, accepts only a launcher an enabled agent manifest claims, and
  is the only writer of that dir.
- prunes old Node versions (any not referenced by a named alias) — **except** a version a
  live process still runs from. The prune scans `/proc/<pid>/exe` and defers such a
  version to the next cycle, so an update never deletes the toolchain out from under a
  running Claude session.

The `ai-tools-relabel.path` watcher sees the repoint (it watches the `bin` directory, so one
watch covers every agent) and runs `ai-tools-relabel-agent` (root) to restore
`ai_tools_exec_t` on each enabled agent's new entrypoint, so the SELinux domain transition keeps
firing. Until the entrypoint is relabelled,
`ai-tools-run` fail-closes (refuses to launch rather than run unconfined); `ai-tools
--relabel` is the manual fallback.

On launch the wrapper resolves the symlink one hop via `readlink`, exports it as
`AI_TOOLS_AGENT_EXEC`, and `ai-tools-run` re-validates it against the nvm versioned-binary pattern
before exec; the only sudoers rule dropping to `${SANDBOX_USER}` targets the fixed path
`/opt/ai-tools/bin/ai-tools-run`, never the versioned binary. Why one hop, and what the
mode-700 package dir does and does not guarantee, is specified in
[launch](.claude/rules/launch.rule.md) and [updater](.claude/rules/updater.rule.md).

After an update, **new** Claude sessions resolve the repointed `bin/claude` symlink and use
the new Node version. A **running** session stays pinned to the version it launched with for
its whole lifetime by design.

## Operation logging

Start here — one command answers "has anything gone wrong lately?":

    sudo ai-tools --audit                      # findings in the last 7 days
    sudo ai-tools --audit --since '2 days ago' # any window date(1) understands

It reads the trails below and reports what refused, was rejected, was stranded, or was
flagged — a breached secret, a rejected socket peer, a helper timeout, a refused launch. It
exits non-zero when anything is reported, so it works from cron or a login banner without
parsing its output. Findings from the root-only files and refusals from the session's own
journald tag are reported **separately**, because only the first is a trail the agent cannot
write.

Every tool call a session makes is recorded too, one line each:

    sudo journalctl -t ai-tools-hook _UID="$(id -u ai-tools)"   # what the agent ran and wrote
    sudo journalctl -t ai-tools-hook -o json _UID="$(id -u ai-tools)" | jq  # structured fields

A `Bash` record carries the command's leading two words and its argument count — never the
command line, which through a here-doc would carry file contents. The same facts are also
emitted as native journald fields (`AI_TOOLS_TOOL`, `AI_TOOLS_CMD`, `AI_TOOLS_ARGC`,
`AI_TOOLS_PATH`), so a journal ingester can select on them without re-parsing the message.

Two sinks — **journald** (all components) and **`/var/log/ai-tools/`** (root helpers
only, `700 root:root`). Query journald by component **and by the writer's uid**:

    sudo journalctl -t ai-tools-chown _UID=0                  # the ownership-restore helper
    sudo journalctl -t ai-tools-lockdown _UID=0 -p warning    # the secret lockdown
    sudo journalctl -t ai-tools-handback _UID=0               # the privilege bridge (one line per request)
    sudo journalctl -t ai-tools-run _UID="$(id -u ai-tools)"  # session launches
    sudo journalctl -t ai-tools _UID="$(id -u)"               # the CLI (project/sandbox created, …)

The uid matters because a syslog tag is chosen by whoever writes the line, and the sandbox
account can write to `/dev/log` — so a session could emit a line under a root helper's tag.
`_UID` is stamped by journald from the sender's kernel credentials and cannot be forged, so
pairing it with the tag is what makes a line attributable.

`ai-tools-hook` is the one tag no filter separates: the lifecycle hooks run **as** the agent, so
it is that tag's legitimate writer. Read those lines as the session's own account, and reconcile
them against the root-written trail — `/var/log/ai-tools/` is `700 root:root`, so the agent can
neither read nor append to it.

The handback daemon keeps a per-request audit line — the peer PID, the verb, the path, and
the helper result — plus a `WARNING` for every rejected peer or malformed request, so each
privileged action is attributable at the socket layer. Root-only log files: `chown.log`,
`setgid.log`, `setfacl.log`, `unclaim.log`, `safedir.log`, `allowlist.log`, `symlink.log`,
`lockdown.log`, `relabel.log`, `dotnet.log`, `handback.log`, `install.log`.

## SELinux

The optional confinement layer puts the session in its own domain, `ai_tools_t`, on top of the
file permissions that already isolate it. It ships **prebuilt and enforcing**, so a normal
install loads it without a policy toolchain, and it is a second boundary rather than the only
one — a host without it is still confined by DAC.

The one thing an operator meets in practice is a **stale label after a Node upgrade**. A freshly
installed agent binary is born with the default type, so its exec fires no domain transition —
and rather than run the session unconfined, `ai-tools-run` **refuses to launch** and says so. The
post-upgrade watcher normally relabels it for you; when it has not, the fix is one command:

```bash
ai-tools --relabel        # relabels every enabled agent's entrypoint and config directory
```

Two things worth knowing before reaching for `restorecon` yourself: the agent entrypoints and
each agent's config directory are labelled from rules the **agent's own manifest** declares, so
`ai-tools --relabel` (or `sudo selinux/install-selinux.sh relabel`) applies them in the right
order, and a bare recursive `restorecon` over `/opt/ai-tools` can leave a hardlinked entrypoint
mislabelled — which the launch will then refuse. To inspect a denial:

```bash
sudo ausearch -m avc -ts recent | audit2why
```

Policy layout, the optional policy groups, and the bring-up loop:
[`selinux/README.md`](selinux/README.md). What the domain guarantees and where it stops:
[confinement](.claude/rules/confinement.rule.md).

## Community

- **Bugs and feature requests** — [GitHub Issues](https://github.com/dag-node/tools-agent-tools-restricted/issues).
  The templates ask for the environment details and journald excerpts that make a report actionable.
- **Security vulnerabilities** — never a public issue. See [`SECURITY.md`](SECURITY.md) for
  private reporting channels and what is in scope.
- **Contributing** — [`CONTRIBUTING.md`](CONTRIBUTING.md): development setup, test categories,
  the lint baseline, branch and PR conventions, and the Contributor License Agreement.
- **Code of Conduct** — [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) (Contributor Covenant 2.1).

## License

Licensed under the **GNU Affero General Public License v3.0 only** (`AGPL-3.0-only`).
See [`LICENSE`](LICENSE) for the full text. Releases through 0.9.x were published as
`AGPL-3.0-or-later`; from 0.10.0 the project is `AGPL-3.0-only`.

**Claude Code is separate.** This license covers this repository's own source — the
sandboxing, install, and CLI machinery. `ai-tools-bootstrap` installs Claude Code
(`@anthropic-ai/claude-code`) from npm at your own bootstrap step; it is a separate
Anthropic product under its own terms, never vendored or redistributed here.
See [Anthropic's Claude Code](https://github.com/anthropics/claude-code).

The SELinux policy modules under [`selinux/policy/`](selinux/policy) are `GPL-2.0-or-later`,
because they are built against the SELinux reference policy, and ship as their own
`ai-tools-selinux` subpackage. Everything else under `selinux/` — the installer and the
denial-analysis tooling — is `AGPL-3.0-only` like the rest of the project. Each file states
which applies in an `SPDX-License-Identifier` header; `REUSE.toml` covers the rest.

Contributions require a Contributor License Agreement, handled by
[CLA Assistant](https://cla-assistant.io/) when you open a pull request.
See [`CONTRIBUTING.md`](CONTRIBUTING.md).
