# Disable a project

[Projects](index.md) · [Create](create.md) · [Claim](claim.md) ·
[Clone](clone.md) · [Push](push.md) · [List](list.md) · **Disable** ·
[Enable](enable.md) · [Unclaim](unclaim.md) · [Remove](remove.md) ·
[Lockdown](lockdown.md) · [Handback](handback.md) ·
[Permissions](permissions.md) — [all docs](../index.md)

How `atr projects disable` stops sessions from starting in a claimed project,
what stays as it was while it is disabled, and what stops with it.

```bash
atr projects disable ~/src/api
```

Turns the `@` that opens the project's line in your project registry
into a `%`. The line keeps its end-of-line comment, and `projects enable` turns
the `%` back. Every command that changes the file rewrites all of it in one
order, which is in `man 5 ai-tools-project-registry`, so a file you edited
by hand takes that order at the first write, and after that a disable
and an enable leave it as it was.

```text
# ~/.config/ai-tools/project-registry
@ /home/you/src/api                     # payments, dev stage
  ->
% /home/you/src/api                     # payments, dev stage
```

## The kinds of line

| Line | What it means |
|---|---|
| `@ /home/you/src/api` | an enabled project: sessions may start there |
| `% /home/you/src/api` | a disabled project: no session starts there; the permissions and the label stay |
| `! /home/you/src/api/vendor` | an excluded path: no session starts in the subtree and the hand-back skips it, wherever the line sits; it does not take back access a claim already granted ([Enable](enable.md)) |

Each command reads the path's state before it acts, which is
how `projects claim` on a disabled project offers to enable it instead
of adding a second line ([Enable](enable.md)). Every state a path can be in is
in `man 5 ai-tools-project-registry`.

A project nested inside another one is disabled on its own line,
and the project enclosing it stays enabled. A project inside a disabled one is
not reachable while that line stands, whatever its own line says.

## What stays, and what stops

Disabling is a registry change and only that: the tree keeps its group, its
permissions and its label, so `projects enable` does not grant any access
that was not already granted, and neither command runs a secret scan
or prompts.

**Disabling is not an access boundary.** The agent's access to a claimed tree
is its group, its ACLs and its label, and a session started in any project you
claimed reaches every other project you claimed through them.
`projects unclaim`, once its hand-back has run, is what takes that access
off a tree ([Unclaim](unclaim.md)).

What stops with the launches is the handback: while the project is disabled,
files written under it are **not** restored to you, and `projects lockdown`,
`projects handback` and `projects unclaim` decline to act on it. A project
a session is still writing to therefore keeps that session's files owned
by the sandbox account until you enable it again. Stop the session first,
or enable the project afterwards and run `atr projects handback`
([Handback](handback.md)). Why every one of those stops together is
[ref-section-v2n3](../../.claude/rules/cli.rule.md#ref-section-v2n3).

## What it refuses

A path your project registry does not name is refused rather than disabled:
there is no entry to disable, and inventing one would register a project
without claiming it. A path inside a claimed project is refused, naming
that project, and so is an excluded path. A project already disabled succeeds
and says so.

## Launching in a disabled project

```text
claude: this project is disabled in your project registry: /home/you/src/api
claude: no session starts here until it is re-enabled -- its files, group and label are untouched
claude: re-enable it with:  atr projects enable /home/you/src/api
```

The launch refuses and names the way back.

## For another operator

`atr projects disable --for svc-ci /srv/projects/api` disables the entry
in that operator's project registry ([Service
accounts](../operators/service-accounts.md)). The plain form does not run
`sudo`; the `--for` form does, to read the other operator's registry.

## Exit status

0 when the project is disabled, or was already; 1 when the path is refused
or the line could not be written; 2 for a rejected command line, a missing
directory among them. `man ai-tools` has the full list.
