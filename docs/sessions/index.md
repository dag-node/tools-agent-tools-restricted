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

**A session launches only in a project you approved.** The wrapper refuses
to start the agent unless the working directory is listed
in `~/.config/ai-tools/allowed-projects` — your own file, written by a claim —
and a `!`-prefixed line carves a subdirectory back out of one that is listed.
The directory is resolved to its real target before it is matched, so a symlink
does not get a path past the check, and a system directory or a whole home root
is refused whatever the file says ([Scope](../about/scope.md)).

What starts then runs as the sandbox account rather than as you, in its own
transient systemd unit, confined to the `ai_tools_t` SELinux type
where the policy is installed. The project is its working directory, its
environment is an allowlist rather than your shell's, and the files it writes
come back to you ([Projects](../projects/index.md)).

Three things are set up for every session without you doing anything.

**Every session starts oriented.** One shipped file states what the sandbox
refuses — which commands, why a `chmod` on a handed-back file fails,
which paths do not list — and is linked into each agent's config directory
under the filename that agent reads as user-scope instructions. So a session
working in any project knows its boundaries instead of finding them one failed
command at a time. The file is root-owned, and a real file of your own
at that path wins and is reported rather than replaced.

**The shipped skills exist in one copy.** The documentation
and engineering-judgment skills this project ships live once
under `/opt/ai-tools`; each agent's config directory holds a symlink per skill,
so a skill is authored and updated in one place however many agents read it.
A skill of your own, or one specific to a single agent, is a real directory
there and the linker keeps it in place. The operator guide for them ships
beside them, at `/usr/share/ai-tools/skills/README.md`.

**Command output is narrowed before the agent sees it**, by root-owned rule
sets an operator selects with `AI_TOOLS_FILTERS`; narrowing what a command
prints does not widen what it may do, because the agent's own permission
pipeline runs again on the rewritten command.

## Orientation is memory; a system prompt is a separate channel

The orientation text arrives as **user-scope instructions** — the agent's own
memory layer, loaded beside each project's own memory file — so a project's
instructions sit alongside it rather than under it.

An agent that supports a custom **system prompt** takes one through a second,
independent channel, and Claude Code is the agent that does today. An operator
points `CLAUDE_SYSTEM_PROMPT_FILE` in `/etc/ai-tools/operator.conf`
at a root-owned file under `/etc/ai-tools/prompts/` — the one directory
a confined session is granted read on — and `CLAUDE_SYSTEM_PROMPT_MODE` decides
how it lands: `append` (the default) layers the file after the agent's own
system prompt, keeping its built-in tool-use and safety guidance, while
`replace` drops that default, so the file has to restate whatever of it still
applies. Replacing sets the request's system field alone; the tool definitions
and the memory files ride in other fields and stay.

A host that configures neither key launches unchanged. A key that is set
but cannot be honoured — a missing file, one outside the prompts directory, one
that is not plain text, or an unknown mode — **refuses the launch** rather than
starting a session without the prompt an operator asked for. Both keys,
with their defaults, are in `man 5 operator.conf`; how each is resolved
and what it is checked against are
in [agent-claude-code](../../.claude/rules/agent-claude-code.rule.md).

[Stop](stop.md) ends sessions that are already running — every one on the host,
in a single command.
