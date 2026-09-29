# Enable a parked project

[Projects](index.md) · [Create](create.md) · [Claim](claim.md) ·
[Clone](clone.md) · [Push](push.md) · [List](list.md) · [Disable](disable.md) ·
**Enable** · [Unclaim](unclaim.md) · [Remove](remove.md) ·
[Lockdown](lockdown.md) · [Handback](handback.md) ·
[Permissions](permissions.md) — [all docs](../index.md)

How `ai-tools projects enable` lifts the `!` a disable wrote, which `!` line it
refuses to lift, and how a claim offers the same step on a parked entry.

```bash
ai-tools projects enable ~/src/api
```

Deletes the `!` from the project's line in your allowlist, in place,
so sessions may start there again. The tree's permissions did not change while
it was parked, so the command does not grant any access that was not already
granted, does not run a secret scan, and does not prompt. A project already
enabled succeeds and says so; a path the allowlist does not name is refused
and pointed at `ai-tools projects claim`, since registering a project is
a claim, and a claim scans for secrets first ([Claim](claim.md)).

## A `!` line inside a claimed project is not lifted

An exclusion **inside** a claimed project is a carve-out — a subtree you
withheld from the agent — and not a parked project, and `projects enable`
refuses it for that reason: lifting it would hand that subtree over. No verb
writes such a line (`projects disable` refuses the nested case,
[Disable](disable.md)), so one in your file was written by hand and is deleted
by hand if that is what you mean. The reasoning is
[ref-section-v2n3](../../.claude/rules/cli.rule.md#ref-section-v2n3).

## Still parked by another line

Where the project's own entry is clean but a `!` line on a directory enclosing
it, or a glob that matches it, still parks it, the command says so and shows
the line responsible, rather than reporting a project enabled that no session
can enter.

## From a claim, and after a release

`ai-tools projects claim` on a parked project offers this same re-enable behind
a default-No confirm, and claims the project with its line where it was
([Claim](claim.md)). That is the second half of the release rhythm
`ai-tools projects unclaim --keep-entry` starts: hand a tree back with clean
permissions before a release, and claim it again for the next stage without
the project losing its place in the file ([Unclaim](unclaim.md)).

## For another operator

`ai-tools projects enable --for svc-ci /srv/projects/api` edits that operator's
allowlist ([Service accounts](../operators/service-accounts.md)). The plain
form does not run `sudo`; the `--for` form does.

## Exit status

0 when the project is enabled, or was already; 1 when the path is not named,
the line is a carve-out, or the line could not be written; 2 for a rejected
command line. `man ai-tools` has the full list.
