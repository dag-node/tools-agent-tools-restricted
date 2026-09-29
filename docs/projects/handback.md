# Take agent-written files back

[Projects](index.md) · [Create](create.md) · [Claim](claim.md) ·
[Clone](clone.md) · [Push](push.md) · [List](list.md) · [Disable](disable.md) ·
[Enable](enable.md) · [Unclaim](unclaim.md) · [Remove](remove.md) ·
[Lockdown](lockdown.md) · **Handback** · [Permissions](permissions.md) — [all
docs](../index.md)

How `ai-tools projects handback` returns ownership of what the agent wrote
to you without unclaiming, when to run it, and what `--full` adds.

```bash
ai-tools projects handback ~/src/api
```

Walks the project and hands every file the agent still owns back to you,
with the same checks the handback that runs by itself applies
([Permissions](permissions.md)): a file you wrote is not touched,
and a secret-named file comes back yours alone. The project stays claimed
and the agent keeps its access; only the owner of those files moves. It runs
through `sudo`.

## When to run it

The handback that runs as the session goes returns files per tool call
and per turn, so a project that ended cleanly has little left for this command.
It catches the rest: the files a session that was killed left behind,
and the `.git` tree, which the per-session passes skip. `--full` adds the heavy
trees those passes skip too (`node_modules`, `.venv`, caches). Run it
before a backup that does not preserve ACLs, so plain ownership carries your
access into the copy, and after `ai-tools stop`, which names it for each
project it ended a session in ([Stopping a running
session](../sessions/stop.md)).

It is not the opposite of a claim: `projects unclaim` takes the agent's access
off a tree ([Unclaim](unclaim.md)); this command changes who owns files inside
a tree the agent keeps working in ([Project lifecycle](index.md)).

## What it refuses

A path outside every claimed project is refused before the `sudo` prompt,
so the command does not run as a silent no-op. A disabled project is declined
for the reason on [Disable](disable.md): enable it, then run the handback.

## For another operator

`ai-tools projects handback --for svc-ci /srv/projects/api` returns the files
to that operator ([Service accounts](../operators/service-accounts.md)).

## Exit status

0 when the pass ran, whether or not it found a file to hand back; 1 when it
failed; 2 for a rejected command line; 3 when the path is a protected system
directory or a home root. `man ai-tools` has the full list.
