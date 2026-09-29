# Disable a project

[Projects](index.md) · [Create](create.md) · [Claim](claim.md) ·
[Clone](clone.md) · [Push](push.md) · [List](list.md) · **Disable** ·
[Enable](enable.md) · [Unclaim](unclaim.md) · [Remove](remove.md) ·
[Lockdown](lockdown.md) · [Handback](handback.md) ·
[Permissions](permissions.md) — [all docs](../index.md)

How `ai-tools projects disable` parks a claimed project so no session starts
there, what stays in place while it is parked, and what stops with it.

```bash
ai-tools projects disable ~/src/api
```

Prefixes the project's line in your allowlist with `!`, in place: the entry
keeps its position and its end-of-line comment, so an allowlist you maintain
as an ordered, documented file comes back exactly as it was when you enable
the project again. It is the same edit you would make by hand.

```text
# projects
  /home/you/src/api   # payments, dev stage   ->   !/home/you/src/api   # payments, dev stage
  /home/you/src/web                                /home/you/src/web
```

## The three states of an entry

| State | Your allowlist says | What it means |
|---|---|---|
| listed | an allow line names the path | sessions may start there |
| disabled | a `!` line names it | no session starts there; the permissions and the label stay |
| absent | neither | not a project |

A `!` line outranks an allow line for the same path, so a project is `disabled`
while one names it, whatever else the file says. Each verb reads the state
before it acts, which is how `projects claim` on a parked project offers
to re-enable it instead of adding a duplicate line ([Enable](enable.md)).
The states are
[ref-table-d7q3](../../.claude/rules/cli.rule.md#ref-table-d7q3).

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
or re-enable the project afterwards and run `ai-tools projects handback`
([Handback](handback.md)). Why every one of those stops together is
[ref-section-v2n3](../../.claude/rules/cli.rule.md#ref-section-v2n3).

## What it refuses

A path your allowlist does not name is refused rather than parked: there is no
entry to disable, and inventing one would register a project without claiming
it. A project already disabled succeeds and says so.

A project nested inside another claimed project is refused too. The `!` line it
would write reads the same as a carve-out — a subtree you withheld
from the enclosing project — and the file has no field that tells a carve-out
from a parked project afterwards, so a later `projects enable` would be
guessing on an edit that widens what the agent reaches. The refusal names
the two ways to the intended effect: unclaim the nested project, or park
the one enclosing it. Editing the line by hand is unaffected.

## Launching in a parked project

```text
claude: this project is disabled in your approved projects list: /home/you/src/api
claude: re-enable it with:  ai-tools projects enable
```

The launch refuses and names the way back.

## For another operator

`ai-tools projects disable --for svc-ci /srv/projects/api` parks the entry
in that operator's allowlist ([Service
accounts](../operators/service-accounts.md)). The plain form does not run
`sudo`; the `--for` form does, to read the other allowlist.

## Exit status

0 when the project is parked, or was already; 1 when the path is not named, is
nested inside another claimed project, or the line could not be written; 2
for a rejected command line. `man ai-tools` has the full list.
