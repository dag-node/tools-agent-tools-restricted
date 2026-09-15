# Agents

**Agents** · [Claude Code](claude-code.md) — [all docs](../index.md)

What an agent package adds to a host, how an operator turns one
on, and where one agent's own settings and environment variables are listed.

Claude Code is the first supported agent, and the machinery around it is not
specific to any agent: one shim confines every session, and an agent package
adds the pieces that differ — the command an operator types, a manifest
declaring what that agent is, and the environment its sessions get. Installing
a second agent package is therefore an install, rather than a change
to how sessions are confined.

Which agents a host offers is an operator's decision, written
in `AI_TOOLS_AGENTS` in `/etc/ai-tools/operator.conf`. The resolution is
fail-closed in a specific sense: a manifest, a directory, or a fragment
the sandbox account could have tampered with is ignored, and what a session
gets then is the default-enabled baseline rather than everything installed.
Because that file is root-owned, an agent whose package widens what a host
exposes stays off until an operator edits it.

[Claude Code](claude-code.md) catalogs one agent's surface: the settings
and environment variables that shape a session, what the sandbox sets for you,
and what an operator may add — a custom system prompt or a custom API endpoint
among them.
