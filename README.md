# Agent Tools Restricted

[![CI](https://github.com/dag-node/tools-agent-tools-restricted/actions/workflows/ci.yml/badge.svg)](https://github.com/dag-node/tools-agent-tools-restricted/actions/workflows/ci.yml)
[![License: AGPL v3](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)
[![Platform: EL 9 | EL 10](https://img.shields.io/badge/platform-EL%209%20%7C%20EL%2010-blue.svg)](#requirements)

Run coding agents sandboxed — under their own locked-down system user.

Agent Tools Restricted runs an autonomous coding agent under a dedicated, unprivileged
service account (`SANDBOX_USER`, the account created as `ai-tools`) with a tightly scoped set
of privileges, and keeps its Node.js toolchain and CLI current automatically. **Claude Code is
the first supported agent**; the confinement, ownership-handback, and toolchain machinery are
agent-agnostic.

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

## Package install

Install from the signed DNF repository (recommended). One `.repo` file serves EL 9 and
EL 10 — `$releasever`/`$basearch` select the right tree — and `gpgcheck`/`repo_gpgcheck`
verify both the packages and the repo metadata against the dag-node org signing key:

```bash
sudo tee /etc/yum.repos.d/dagnode.repo >/dev/null <<'EOF'
[dagnode]
name=DagNode RPM Repository
baseurl=https://rpm.dagnode.com/el/$releasever/$basearch/
gpgkey=https://rpm.dagnode.com/RPM-GPG-KEY-dag-node
gpgcheck=1
repo_gpgcheck=1
enabled=1
metadata_expire=6h
EOF
sudo dnf install ai-tools          # the metapackage pulls the whole stack
```

Or install a release archive directly (offline / air-gapped). The zip bundles the four RPMs
(metapackage + `ai-tools-base`, `ai-tools-nodejs`, `claude-code-restricted`) plus the public
key; they extract flat and dnf orders them itself:

```bash
unzip ai-tools-el10-vX.Y.Z.zip                 # ai-tools-el9-... to match your platform
sudo rpm --import RPM-GPG-KEY-dag-node         # every release is signed; import once
rpm --checksig ./*.rpm                         # each line should end in: digests signatures OK
sudo dnf install ./*.rpm
```

Then finish setup — steps 1 and 2 here are independent of each other but both run before
step 3:

```bash
# 1. Install Node.js, nvm, and Claude Code (from npm) and enable the update timer (network).
sudo ai-tools-bootstrap

# 2. Enrol yourself as an operator: records you in /etc/ai-tools/operator.conf and grants
#    ai-ops membership (the sudo rules and ownership hand-back).
sudo ai-tools-admin operator add "$(id -un)"

# 3. Register a project and launch. `ai-tools --help` lists every command. Run inside a
#    project, `claude` (the wrapper) walks you through claiming it; the claim refuses system
#    paths and home roots.
ai-tools --project-create ~/myproject
cd ~/myproject && claude
```

**Upgrading — upgrade in place, never `dnf remove` first.** From the repo, `sudo dnf upgrade
'ai-tools*'`; from a downloaded archive, `sudo dnf install ./*.rpm` (a higher version upgrades
each subpackage). Removing the packages moves your edited `/etc/ai-tools/operator.conf` to
`operator.conf.rpmsave` and the fresh install writes an empty one, dropping your operator list
(re-add with `ai-tools-admin operator add`); an in-place upgrade keeps it via
`%config(noreplace)`. `dnf reinstall` needs the *same* version already installed and is not the
way to move between versions.

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
  runs only `claude-run` — a fixed-path sudo target, not a glob, which wraps the session in a
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
  world access stays closed. Applied at `ai-tools --project-claim`.
- **Operation logging** — the `sudo` helpers, the lifecycle hooks, the `ai-tools`
  CLI, and `install.sh` log through one library to **journald** (always, leveled and
  tagged: `journalctl -t ai-tools-chown`) and, for the root writers only, to
  root-only files under **`/var/log/ai-tools/`**.
- **Auto-updating** — a `systemd --user` timer in `${SANDBOX_USER}`'s own instance keeps
  Node and `@anthropic-ai/claude-code` current under `/opt/ai-tools`, and a root-side
  watcher relabels the new entrypoint for SELinux after each upgrade. Each update verifies the
  toolchain's npm registry signatures and fails closed on a tamper before activating it.

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
       ├─ resolve /opt/ai-tools/bin/claude    (one readlink hop; export as CLAUDE_EXEC)
       ├─ export CWD as CLAUDE_PROJECT_DIR    (validated project dir → unit WorkingDirectory)
       └─ exec sudo -u "${SANDBOX_USER}" -- /opt/ai-tools/bin/claude-run
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

- repoints the `/opt/ai-tools/bin/claude` symlink at the new versioned binary via the
  handback socket bridge (`SYMLINK` verb → `ai-tools-claude-symlink`). `bin` is locked
  `0551`, so the `${SANDBOX_USER}` updater cannot write it directly; the helper validates
  the versioned path and is the only writer of that dir.
- prunes old Node versions (any not referenced by a named alias) — **except** a version a
  live process still runs from. The prune scans `/proc/<pid>/exe` and defers such a
  version to the next cycle, so an update never deletes the toolchain out from under a
  running Claude session.

The `ai-tools-relabel.path` watcher sees the symlink repoint and runs
`ai-tools-relabel-entrypoint` (root) to restore `ai_tools_exec_t` on the new `claude.exe`,
so the SELinux domain transition keeps firing. Until the entrypoint is relabelled,
`claude-run` fail-closes (refuses to launch rather than run unconfined); `ai-tools
--relabel` is the manual fallback.

On launch the wrapper resolves the symlink one hop via `readlink`, exports it as
`CLAUDE_EXEC`, and `claude-run` re-validates it against the nvm versioned-binary pattern
before exec; the only sudoers rule dropping to `${SANDBOX_USER}` targets the fixed path
`/opt/ai-tools/bin/claude-run`, never the versioned binary. Why one hop, and what the
mode-700 package dir does and does not guarantee, is specified in
[launch](.claude/rules/launch.rule.md) and [updater](.claude/rules/updater.rule.md).

After an update, **new** Claude sessions resolve the repointed `bin/claude` symlink and use
the new Node version. A **running** session stays pinned to the version it launched with for
its whole lifetime by design.

## Operation logging

Two sinks — **journald** (all components) and **`/var/log/ai-tools/`** (root helpers
only, `700 root:root`). Query journald by component:

    sudo journalctl -t ai-tools-chown            # the ownership-restore helper
    sudo journalctl -t ai-tools-lockdown -p warning
    sudo journalctl -t ai-tools-hook             # the lifecycle hooks
    sudo journalctl -t ai-tools-handback         # the privilege bridge (one line per request)
    sudo journalctl -t ai-tools                  # the CLI (project/sandbox created, …)

The handback daemon keeps a per-request audit line — the peer PID, the verb, the path, and
the helper result — plus a `WARNING` for every rejected peer or malformed request, so each
privileged action is attributable at the socket layer. Root-only log files: `chown.log`,
`setgid.log`, `symlink.log`, `lockdown.log`, `handback.log`, `install.log`.

## SELinux

If AVC denials appear after install:

    ausearch -m avc -ts recent | audit2why

Common cause: directories or binaries under `/opt/ai-tools` carry a wrong
label after creation. Fix:

    sudo restorecon -Rv /opt/ai-tools

If `${SANDBOX_USER}`'s home needs a custom label:

    sudo semanage fcontext -a -t usr_t '/opt/ai-tools(/.*)?'
    sudo restorecon -Rv /opt/ai-tools

For the wrapper in `/usr/local/bin`:

    restorecon -v /usr/local/bin/claude

After editing the SELinux policy source, rebuild and reload with
`sudo selinux/install-selinux.sh rebuild`.

## Community

- **Bugs and feature requests** — [GitHub issues](https://github.com/dag-node/tools-agent-tools-restricted/issues);
  the templates ask for the environment details and journald excerpts that make a
  report actionable.
- **Security vulnerabilities** — never a public issue; see [`SECURITY.md`](SECURITY.md)
  for private reporting channels and what's in scope.
- **Contributing** — [`CONTRIBUTING.md`](CONTRIBUTING.md): development setup, the test
  categories, the lint baseline, and the branch/PR conventions.
- **Conduct** — [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) (Contributor Covenant 2.1).

## License

All source in this repository is published under the GNU Affero General
Public License v3.0 — free and open, with no gated tier. You may use, copy,
modify, and distribute it subject to that license's terms. The most
important one: if you run a modified version as a network service, you must
make your modified source available to that service's users. Full text:
[`LICENSE`](LICENSE), or <https://www.gnu.org/licenses/agpl-3.0.html>.

**Claude Code is separate.** This license covers only this repository's own
source — the sandboxing, install, and CLI machinery. `ai-tools-bootstrap`
installs Claude Code itself (`@anthropic-ai/claude-code`) fresh from npm at
your own bootstrap step; it is a separate proprietary Anthropic product
under its own license and terms, never vendored or redistributed by this
project. See [Anthropic's Claude Code](https://github.com/anthropics/claude-code)
for its own terms.

dag-node's commercial/enterprise offerings (fleet management, centralized
audit/policy reporting, SSO integration, support contracts) are built on top
of this open core rather than gating any part of it. See
[github.com/dag-node](https://github.com/dag-node) for those.
