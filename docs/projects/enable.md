# Enable a disabled project

[Projects](index.md) · [Create](create.md) · [Claim](claim.md) ·
[Clone](clone.md) · [Push](push.md) · [List](list.md) · [Disable](disable.md) ·
**Enable** · [Unclaim](unclaim.md) · [Remove](remove.md) ·
[Lockdown](lockdown.md) · [Handback](handback.md) ·
[Permissions](permissions.md) — [all docs](../index.md)

How `atr projects enable` turns back the `%` a disable wrote, why it refuses
an excluded path (`!`), and how a claim offers the same step on a disabled
entry.

```bash
atr projects enable ~/src/api
```

Turns the `%` that opens the project's line in your project registry back into
an `@`, so sessions may start there again. The tree's permissions did not
change while it was disabled, so the command does not grant any access that
was not already granted, does not run a secret scan, and does not prompt.
A project already enabled succeeds and says so; a path the registry does not
name is refused and pointed at `atr projects claim`, since registering
a project is a claim, and a claim scans for secrets first ([Claim](claim.md)).
A project nested inside another one is enabled on its own line like any other.

Enabling is not an access boundary, as disabling is not
([Disable](disable.md)): it decides where a session may start, and the agent's
access to the tree stays as the claim left it.

## A `!` line is not lifted

A `!` line is an excluded path wherever it sits, and not a disabled project,
and `projects enable` refuses it for that reason: lifting it would let
sessions start in that subtree and the walks act on it. No command writes or lifts such a line, so one in your file
was written by hand and is deleted by hand if that is what you mean. A `!` line
written before the upgrade to format 1.0 may be a project disabled then: change
it to `%` if it is one, and keep the `!` if the subtree is to stay excluded.
The reasoning is
[ref-section-v2n3](../../.claude/rules/cli.rule.md#ref-section-v2n3).

An excluded path stops sessions from starting in the subtree and the hand-back
from walking it; it does not take back access a claim already granted there,
and a session started in the enclosing project reads whatever the subtree's
permissions allow. No session start checks that. To keep the agent
out of the files themselves, make the subtree owner-only, which every claim
walk leaves alone ([Permissions](permissions.md)).

## Still blocked by another line

Where the project's own entry is clean but a `%` line on a directory enclosing
it, a `!` line, or a glob that matches it still blocks it, the command says
so and shows the line responsible, rather than reporting a project enabled
that no session can enter.

## From a claim

`atr projects claim` on a disabled project offers this same step behind
a default-No confirm, and claims the project with its line where it was
([Claim](claim.md)).

## For another operator

`atr projects enable --for svc-ci /srv/projects/api` edits that operator's
project registry ([Service accounts](../operators/service-accounts.md)).
The plain form does not run `sudo`; the `--for` form does.

## Exit status

0 when the project is enabled, or was already; 1 when the path is refused,
the path is excluded, or the line could not be written; 2 for a rejected
command line, a missing directory among them. `man ai-tools` has the full list.
