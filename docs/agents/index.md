# Agents

**Agents** · [Claude Code](claude-code.md) · [Codex](codex.md) · [Setting
names](setting-names.md) — [all docs](../index.md)

What an agent package adds to a host, how an operator turns one
on, and where one agent's own settings and environment variables are listed.

## Enable an agent

```bash
sudo ai-tools-admin system bootstrap                 # asks which agent, and writes the line
sudo ai-tools-admin system bootstrap --agents <name> # claude-code | codex - the unattended form
sudo sed -i 's/^#\?AI_TOOLS_REQUIRE_SELINUX=.*/AI_TOOLS_REQUIRE_SELINUX=yes/' /etc/ai-tools/operator.conf
sudo sed -i 's/^#\?AI_TOOLS_REQUIRE_ENTRYPOINT_VERIFY=.*/AI_TOOLS_REQUIRE_ENTRYPOINT_VERIFY=yes/' /etc/ai-tools/operator.conf
```

`AI_TOOLS_AGENTS` in `/etc/ai-tools/operator.conf` names the agents this host
runs, and no agent is on until it is named there. An installed agent package
puts its files on the host and stays off; the first bootstrap asks which one
installed agent to enable, writes its name on that line, installs the agent's
npm package into the sandbox toolchain, and the nightly update keeps it
current. A run with no terminal, or one answered with none, provisions Node
alone and says which line to set; `--agents <name>` makes the choice without
asking. The file is root-owned, so which agents run is decided with `sudo`
and from nowhere else: a session cannot add one, and an agent package
that widens what the host exposes stays off until you name it.
`ai-tools providers` lists what is installed and which of it is enabled.

A second agent is a deliberate step, taken by hand: add its name to the line
and re-run the bootstrap. Every agent named there runs as the one sandbox
account and reads what the others store, a login or a token and the session
history among them, and a session of one can start another's binary inside
itself. Read [Scope](../about/scope.md) before naming a second agent;
the bootstrap says the same once, on a line naming more than one.

The third and fourth lines are optional and recommended.
With `AI_TOOLS_REQUIRE_SELINUX=yes` a session starts only where SELinux is
enforcing and the confinement policy is loaded, so a host whose policy drifted
refuses the launch rather than running the session unconfined;
with `AI_TOOLS_REQUIRE_ENTRYPOINT_VERIFY=yes` an agent binary that no reconcile
has pinned does not start. Each turns a state the launch would otherwise accept
into a refusal that names its fix; see [SELinux
confinement](../system/selinux.md)
and [Strictness](../system/entrypoint-verification.md#strictness).

Enabling installs and maintains an agent; it does not run one. A session starts
when an operator types the agent's command in a claimed project,
and that command reaches the sandbox wrapper only where the operator's `PATH`
ranks `/usr/local/bin` ahead of their own tools — the ordering
`ai-tools-admin operators add` wires into their shell
([ref-section-y2t3](../install/from-source.md#ref-section-y2t3)).
`ai-tools status` reports a shell where another copy of the command would win.

Every agent runs the same way once it is on. One shim confines every session,
and an agent package adds only what differs: the command you type, a manifest
saying what that agent is, and the environment its sessions get. Adding
an agent is an install, not a change to how sessions are confined. How the host
decides what it trusts among those files is
in [providers](../../.claude/rules/providers.rule.md).

## One agent's own page

[Claude Code](claude-code.md) catalogs one agent's surface: the settings
and environment variables that shape a session, what the sandbox sets for you,
and what an operator may add — a custom system prompt or a custom API endpoint
among them.

[Codex](codex.md) is the second agent package. The page states the command
that turns it on, the device-code login a session needs, the two files
under `/etc/codex` an operator may edit, and what a Codex session does not get.

[Setting names](setting-names.md) decodes the six settings across both agents
whose names read as the opposite of what they do — `danger-full-access`,
which is the setting that keeps this host's confinement closed,
and `approval: never`, which says who the agent asks rather than what it
permits, among them. Read it before deciding a banner line is
a misconfiguration.
