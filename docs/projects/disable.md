# Disable a project

[Projects](index.md) · [Create](create.md) · [Claim](claim.md) ·
[Clone](clone.md) · [Push](push.md) · [List](list.md) · **Disable** ·
[Enable](enable.md) · [Unclaim](unclaim.md) · [Remove](remove.md) ·
[Lockdown](lockdown.md) · [Handback](handback.md) ·
[Permissions](permissions.md) — [all docs](../index.md)

How `atr projects disable` parks a claimed project so no session starts there,
what stays in place while it is parked, and what stops with it.

```bash
atr projects disable ~/src/api
```

Writes a `%` in front of the project's line in your project registry, in place:
the entry keeps its position and its end-of-line comment, so a registry you
maintain as an ordered, documented file comes back exactly as it was when you
enable the project again. It is the same edit you would make by hand.

```text
# ~/.config/ai-tools/project-registry
  /home/you/src/api   # payments, dev stage   ->   %/home/you/src/api   # payments, dev stage
  /home/you/src/web                                /home/you/src/web
```

## The kinds of line

| Line | What it means |
|---|---|
| `/home/you/src/api` | a project: sessions may start there |
| `%/home/you/src/api` | a parked project: no session starts there; the permissions and the label stay |
| `!/home/you/src/api/vendor` | a carve-out: the agent is withheld from the subtree, wherever the line sits |

Each command reads the path's state before it acts, which is
how `projects claim` on a parked project offers to re-enable it instead
of adding a duplicate line ([Enable](enable.md)). Every state a path can be
in is in `man 5 ai-tools-project-registry`.

A project nested inside another one is parked on its own line, and the project
enclosing it stays enabled. A project inside a parked one is not reachable
while the park stands, whatever its own line says.

## What stays, and what stops

Disabling is a registry change and only that: the tree keeps its group, its
permissions and its label, so `projects enable` does not grant any access
that was not already granted, and neither command runs a secret scan
or prompts.

What stops with the launches is the handback: while the project is disabled,
files written under it are **not** restored to you, and `projects lockdown`,
`projects handback` and `projects unclaim` decline to act on it. A project
a session is still writing to therefore keeps that session's files owned
by the sandbox account until you re-enable it. Stop the session first,
or re-enable the project afterwards and run `atr projects handback`
([Handback](handback.md)). Why every one of those stops together is
[ref-section-v2n3](../../.claude/rules/cli.rule.md#ref-section-v2n3).

## What it refuses

A path your project registry does not name is refused rather than parked: there
is no entry to disable, and inventing one would register a project without
claiming it. A path inside a claimed project is refused, naming that project,
and so is a carve-out. A project already disabled succeeds and says so.

## Launching in a parked project

```text
claude: this project is disabled in your project registry: /home/you/src/api
claude: no session starts here until it is re-enabled -- its files, group and label are untouched
claude: re-enable it with:  atr projects enable /home/you/src/api
```

The launch refuses and names the way back.

## For another operator

`atr projects disable --for svc-ci /srv/projects/api` parks the entry
in that operator's project registry ([Service
accounts](../operators/service-accounts.md)). The plain form does not run
`sudo`; the `--for` form does, to read the other operator's registry.

## Exit status

0 when the project is parked, or was already; 1 when the path is refused
or the line could not be written; 2 for a rejected command line, a missing
directory among them. `man ai-tools` has the full list.
