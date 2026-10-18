# About this project

**About** · [Scope](scope.md) — [all docs](../index.md)

Why a coding agent gets a locked-down account of its own, what that separates
it from, and where the boundary this project draws sits.

An agent started from your shell holds everything your account holds: your SSH
keys, your browser profiles, every project on the host, and your sudo rights.
What it reads does not stay local either — an agent sends file contents
to a third-party model service as a matter of course, so a secret it can open
is a secret you may already have disclosed. A repository onboarding an agent
carries one blind spot in particular: credentials committed years ago and since
removed survive in git history, invisible in the working tree and one
`git show` away for anything that can read `.git`.

`ai-tools` restricts what the agent reaches on the host instead of trusting it.
It gives the agent a different account — `ai-tools`, with no login shell and no
password — and lets it work on the projects you claim for it. What separates
your account from the sandbox account is ordinary filesystem permissions plus
an SELinux type: the boundary the kernel already enforces between any two
users.

**The agent runs under its own identity, from its own toolchain.**
`sudo ai-tools-admin system bootstrap` installs Node and the agent's npm
package into `/opt/ai-tools`, which the sandbox account owns and whose mode
grants no other account entry, so your own login cannot traverse it. You reach
the coding agent through its wrapper at `/usr/local/bin/{coding-agent-name}`,
`/usr/local/bin/claude` for Claude Code, which runs as you, checks what it has
to check, and then drops to the sandbox account. A coding agent **you**
installed answers to the same name, so what `{coding-agent-name}` resolves
to on your `PATH` is the one thing to get right — `ai-tools status` reads
which binary your shell runs, and the ordering this project installs for it is
[ref-section-y2t3](../install/from-source.md#ref-section-y2t3).

**The sandbox account does not hold a sudo rule of its own.** The two rules
the stack installs belong to the operators group: one starts a session,
the other stops every session on the host. The root operations the agent's own
session needs — handing a written file back to you, normalizing a setgid bit,
repointing the launcher symlink after a toolchain update — go through a socket
daemon that verifies the caller's uid with a kernel credential the caller
cannot forge, so none of them is a command the agent can aim somewhere else.

<a id="ref-diagram-z9p7"></a>**The system overview**

<picture> <source media="(prefers-color-scheme: dark)"
srcset="../static/diagrams/system-overview-dark.svg"> <source
media="(prefers-color-scheme: light)"
srcset="../static/diagrams/system-overview-light.svg"> <img alt="System
overview: your shell runs the coding-agent wrapper
/usr/local/bin/{coding-agent-name} as you; it checks ai-ops membership
and other gates, then calls a sudo rule of the operators group
in /etc/sudoers.d/ai-tools, which holds two, to launch a session and to stop
every session. ~/.config/ai-tools holds your allowlist, maintained
with the ai-tools projects CLI, and your secret-patterns file, which you edit
and the root helpers read to lock secret-named files away. The ai-tools CLI
runs as you, claims projects, keeps your allowlist and reports status,
and takes its root steps through sudo; ai-tools-admin runs as root alone,
enrols operators and provisions the toolchain and the SELinux policy. The rule
starts ai-tools-run as the sandbox account ai-tools, which has no login shell,
password or sudo rule. ai-tools-run checks the entrypoint pin and starts
a restricted transient systemd service in ai_tools_t, where the coding agent's
versioned file from .nvm reads and writes the claimed project. After each tool
call and turn, coding-agent hooks ask the root handback daemon, which checks
the caller's uid by kernel credential, to hand written files back: owned
by you, reached by the coding agent through group bits, with world access
removed. Secret-named files such as .env, *.key and *.pem are locked to you
at mode 600 before a claim grants anything, owner-only paths stay closed,
and the coding agent reaches the files you write through the ACL grant a claim
writes. Prompts and file contents go to the model service. nvm-update.timer,
running as ai-tools, installs Node and each coding agent's package from npm
once their signatures verify; a root watcher verifies, pins and labels the new
entrypoint; root helpers log to /var/log/ai-tools, which root alone reads."
src="../static/diagrams/system-overview-light.svg"> </picture>

Three more properties follow, and each has a page that says what you do
about it:

- A session starts only inside a project you claimed, and refuses a system
  directory or a whole home as the target ([Sessions](../sessions/index.md)).
- Files the agent writes come back to you, without you running anything
  ([Permissions](../projects/permissions.md)).
- Secret-named files are locked away before a claim grants the agent anything,
  a claim asks before exposing git history, and a sandbox clone keeps history
  out of reach altogether ([Lockdown](../projects/lockdown.md)).

One property ties those together, and it is the one to check when reviewing
this project: **every input that decides what a session gets is read
through the same trust predicate, and every way that predicate can fail gives
the agent *less*.** A config it cannot read, a manifest someone made writable,
an entrypoint whose SELinux label does not verify, a toolchain whose npm
signatures do not check out — each one costs a capability and is reported,
and none of them grants one. So there is no state the agent can arrange
that improves its own position, only states that shut it down. Which decision
each predicate governs, and what each failure yields, are
in [ref-section-e7n8](../../CLAUDE.md#ref-section-e7n8).

Each of those refusals is tested from both ends: once that the refusal fires,
and once — running *as* the sandbox account — that the agent cannot create
the state the refusal exists to catch.

Where that boundary stops, and the three things this project deliberately does
not defend against, are on [Scope](scope.md).
