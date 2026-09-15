# Sessions

**Sessions** · [Stop](stop.md) — [all docs](../index.md)

Starting an agent session inside a claimed project, what the session reaches
while it runs, and how to end one that is already running.

A session starts by running the agent's own command inside a project you
claimed — `claude` for Claude Code. What you type is the agent's name;
what runs is a chain of checks, each of which refuses the launch and says
so: you are in the operators group, the directory you are in is one of your
claimed projects, the executable is the one the vendor signed ([Entrypoint
verification](../system/entrypoint-verification.md)), and the confinement
the host expects is in place.

What starts then runs as the sandbox account rather than as you, in its own
transient systemd unit, confined to the `ai_tools_t` SELinux type
where the policy is installed. The project is its working directory, its
environment is an allowlist rather than your shell's, and the files it writes
come back to you ([Projects](../projects/index.md)).

Two things are set up for every session without you doing anything. **One
orientation file serves every agent**: a single shipped file is linked
into each agent's config directory under the name that agent reads, and a real
file of your own at that path wins and is reported rather than replaced.
**Command output is narrowed before the agent sees it**, by root-owned rule
sets an operator selects with `AI_TOOLS_FILTERS`; narrowing what a command
prints does not widen what it may do, because the agent's own permission
pipeline runs again on the rewritten command.

[Stop](stop.md) ends sessions that are already running — every one on the host,
in a single command.
