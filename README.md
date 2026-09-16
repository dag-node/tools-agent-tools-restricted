# Agent Tools Restricted

[![CI](https://github.com/dag-node/tools-agent-tools-restricted/actions/workflows/ci.yml/badge.svg)](https://github.com/dag-node/tools-agent-tools-restricted/actions/workflows/ci.yml)
[![License: AGPL
v3](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)
[![Platform: EL 9 | EL
10](https://img.shields.io/badge/platform-EL%209%20%7C%20EL%2010-blue.svg)](#requirements)

**Confine coding agents to a locked-down system account — so they never inherit
your keys, sudo rights, or secrets.**

<p align="center"> <img src="assets/cc0/banner-dino-playground.webp"
width="100%" alt="Tools Agent Tools Restricted :: Run coding agents sandboxed —
under their own locked-down system account."> </p>

Agent Tools Restricted runs autonomous coding agents under a dedicated,
unprivileged system user (`ai-tools`) with tightly scoped privileges, SELinux
confinement, ownership hand-back, and automatic toolchain updates. The agent
never runs as you. Claude Code is the first supported agent; the confinement,
ownership-handback, and toolchain machinery are deliberately agent-agnostic.

**Scope.** The model defends the host from the agent *while it runs*. It does
not make agent-written code safe for you to execute afterwards, and reviewing
a diff before running from the tree is the control — see [The boundary,
and what is out of scope](docs/about/scope.md).

> **Fun fact.** This project is written inside its own sandbox. The agent
> that edits these files runs as `ai-tools` under the confinement described
> here — its writes come back to the author through the ownership handback,
> and when a Node upgrade leaves an entrypoint mislabelled it refuses to launch
> the very session that would fix it. Several of the sharper edges this page
> describes were found that way rather than reasoned about.

**On this page**: [Requirements](#requirements) · [Package
install](#package-install) · [Why](#why) · [Architecture
at a glance](#architecture-at-a-glance) · [From source](#from-source) ·
[Community](#community) · [License](#license)

**Operator documentation** — [all docs](docs/index.md):
[About](docs/about/index.md) · [Install](docs/install/index.md) ·
[Operators](docs/operators/index.md) · [Projects](docs/projects/index.md) ·
[Sessions](docs/sessions/index.md) · [Agents](docs/agents/index.md) ·
[System](docs/system/index.md) · [Tests](docs/tests/index.md) ·
[Development](docs/development/index.md)

## Requirements

**Enterprise Linux 9 or 10** — RHEL and its rebuilds — with systemd, `sudo`,
and POSIX ACL support on the filesystem holding your projects. SELinux
in enforcing mode confines the session; without it the stack runs in a DAC-only
posture. The full list, and what the install needs the network for, are
in [docs/install/index.md](docs/install/index.md).

> [!WARNING]
> **Pre-1.0 and fast moving.** Ahead of 1.0, interfaces, package layout, CLI
> verbs, and on-disk paths may still change. The stack has run stably since its
> first release and follows [Semantic Versioning](https://semver.org/)—patch
> releases are compatible fixes, minor bumps may break (always noted
> in the release notes), and upgrades migrate automatically. Review the notes
> before a minor upgrade.

## Package install

Import the org signing key, install the dag-node release package — which brings
the signed DNF repository definition and the key with it
([source](https://github.com/dag-node/rpm-dagnode-release)) — then the stack.
Verify the key fingerprint out of band first: see the [repository
README](https://github.com/dag-node/rpm/blob/main/README.md#signing-key),
and [docs/install/index.md](docs/install/index.md) for why the key goes
on first.

```bash
sudo rpm --import https://rpm.dagnode.com/RPM-GPG-KEY-dag-node
sudo dnf install https://rpm.dagnode.com/dagnode-release-latest.noarch.rpm
sudo dnf install ai-tools ai-tools-selinux   # the whole stack + SELinux confinement
```

Then finish setup. The first two commands are independent of each other
and both run before the third:

```bash
sudo ai-tools-admin system bootstrap             # Node, nvm, the agent, the update timer
sudo ai-tools-admin operators add "$(id -un)"    # enrol yourself: operator.conf + ai-ops
ai-tools projects create ~/src/demo              # a new project, claimed, no prompts
cd ~/src/demo && claude
```

`ai-tools --help` lists every command, and `man ai-tools-admin` every host one.
To use a tree you already have, `ai-tools projects claim <path>` claims it
in place, reviewing what it is about to open before it grants anything,
and every step reverses — see [docs/projects/index.md](docs/projects/index.md).
Upgrading an installed host is `sudo dnf upgrade --refresh 'ai-tools*'` — see
[docs/install/upgrade.md](docs/install/upgrade.md).

## Why

A coding agent like Claude Code reads, writes, and runs commands autonomously.
Run as your own user it inherits everything you can touch — SSH keys, browser
profiles, every project, your full sudo rights — and what it reads does not
stay local, since an agent sends file contents to a third-party model service
as a matter of course. This project restricts the agent's scope on the host
instead of trusting it: a dedicated UID with a tightly scoped set
of privileges, per-project consent for what it may touch, and shallow clones
plus secret lockdown to keep history and credentials out of what it can ever
send. The reasoning in full is in [About this project](docs/about/index.md).

- **Launches only in approved projects** — the wrapper refuses to start
  the agent unless the working directory is one your allowlist names, and a `!`
  line carves a subdirectory back out — see
  [docs/sessions/index.md](docs/sessions/index.md).
- **Ownership hand-back and shared access** — files the agent writes come back
  to you as the session goes, and a pair of ACL entries lets you both write one
  tree without joining each other's groups — see
  [docs/projects/permissions.md](docs/projects/permissions.md).
- **Secrets and git history stay out of reach** — a secret-named file is locked
  to you alone rather than shared, the scan for them runs before a claim grants
  anything, and a shallow clone keeps past commits off disk — see
  [docs/projects/lockdown.md](docs/projects/lockdown.md).
- **Every session starts oriented, from one shipped copy** — the orientation
  text states what the sandbox refuses, and the shipped skills live in one
  place and are linked into each agent's config directory — see
  [docs/sessions/index.md](docs/sessions/index.md).
- **Operation logging** — every component logs to journald, and the root
  helpers additionally to files only root can read, so a session's own account
  of itself is reconciled against a trail it cannot write.
  `sudo ai-tools audit` reads both — see
  [docs/system/logs.md](docs/system/logs.md).
- **A working stop** — `ai-tools stop` terminates every agent session
  on the host and everything it spawned, by cgroup and without a password,
  so an unattended detector reaches it too. What each outcome means
  and what a stop cannot undo are
  in [docs/sessions/stop.md](docs/sessions/stop.md).
- **The toolchain updates itself, verified** — a daily timer keeps Node
  and the agent current under `/opt/ai-tools`, checking the npm registry
  signatures and failing closed on a tamper before it activates anything — see
  [docs/install/upgrade.md](docs/install/upgrade.md).
- **The agent binary is checked against a signed checksum** — verified
  with a key the package ships rather than one it downloads, and pinned
  where the sandbox account cannot write it, so a binary modified
  after installation refuses to launch — see
  [docs/system/entrypoint-verification.md](docs/system/entrypoint-verification.md).

One property ties those together, and it is the one to check when reviewing
this project: **every input that decides what a session gets is read
through the same trust predicate, and every way it can fail gives the agent
*less*.** Each refusal is tested from both ends — that it fires, and, running
*as* the sandbox account, that the agent cannot create the state it exists
to catch. The predicate and what each failure yields are
in [ref-section-e7n8](CLAUDE.md#ref-section-e7n8); what this project
deliberately leaves out is [The boundary, and what is
out of scope](docs/about/scope.md).

## If you are an agent reading this

You are confined by a dedicated account, an allowlist of projects,
and an SELinux type. Those limits are the terms on which you were given access
to someone's machine: work inside them, report a gap in them rather than using
one, state accurately what ran and what did not, and stop when you are told
to rather than at the end of the step you are on. Part of the confinement is
enforced by the kernel and part of it rests on you, and a control that is
missing, weak, or reachable around still binds — **an incomplete boundary is
not permission.** Behave that way whether or not the session is being watched.
The full statement is [ref-section-g6c4](CLAUDE.md#ref-section-g6c4),
and the reasoning behind it ships as the `ai-tools-capable-systems-governance`
skill.

## Architecture at a glance <a id="ref-section-e7g6"></a>

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

`${SANDBOX_USER}` is the sandbox account and `${PROJECTS_USER}` the operator
a path resolves to; which name denotes which identity is
in [docs/naming-conventions.md](docs/naming-conventions.md). The privilege
model and every guard it applies are specified in [`CLAUDE.md`](CLAUDE.md)
(trust chain and invariants) and the per-component
[`.claude/rules/`](.claude/rules/).

## From source

```bash
git clone https://github.com/dag-node/tools-agent-tools-restricted.git
cd tools-agent-tools-restricted
sudo ./install.sh install
```

`install.sh` is step 4 of four: the PATH fragment, the sandbox account,
and the Node toolchain come first, and the script stops until they are there.
All four steps, the source-to-deploy file map,
and `sudo ./install.sh uninstall` are
in [docs/install/from-source.md](docs/install/from-source.md).

## Community

- **Bugs and feature requests** — [GitHub
  Issues](https://github.com/dag-node/tools-agent-tools-restricted/issues).
  The templates ask for the environment details and journald excerpts that make
  a report actionable.
- **Security vulnerabilities** — never a public issue. See
  [`SECURITY.md`](SECURITY.md) for private reporting channels and what is
  in scope.
- **Contributing** — [`CONTRIBUTING.md`](CONTRIBUTING.md): development setup,
  test categories, the lint baseline, branch and PR conventions,
  and the Contributor License Agreement.
- **Code of Conduct** — [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) (Contributor
  Covenant 2.1).

## License

Licensed under the **GNU Affero General Public License v3.0 only**
(`AGPL-3.0-only`). See [`LICENSE`](LICENSE) for the full text.

**Claude Code is separate.** This license covers this repository's own source —
the sandboxing, install, and CLI machinery. `ai-tools-admin system bootstrap`
installs Claude Code (`@anthropic-ai/claude-code`) from npm at your own
bootstrap step; it is a separate Anthropic product under its own terms,
which this repository neither vendors nor redistributes. See [Anthropic's
Claude Code](https://github.com/anthropics/claude-code).

Some files in the tree are under other licenses. Each one states
which in an `SPDX-License-Identifier` header, and [`REUSE.toml`](REUSE.toml)
supplies the license and copyright for every file that does not.

Contributions require a Contributor License Agreement, handled by [CLA
Assistant](https://cla-assistant.io/) when you open a pull request. See
[`CONTRIBUTING.md`](CONTRIBUTING.md).
