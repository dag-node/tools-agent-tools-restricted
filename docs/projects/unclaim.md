# Unclaim a project

[Projects](index.md) · [Create](create.md) · [Claim](claim.md) ·
[Clone](clone.md) · [Push](push.md) · [List](list.md) · [Disable](disable.md) ·
[Enable](enable.md) · **Unclaim** · [Remove](remove.md) ·
[Lockdown](lockdown.md) · [Handback](handback.md) ·
[Permissions](permissions.md) — [all docs](../index.md)

How `ai-tools projects unclaim` takes the agent's access off a tree and drops
its registration while the files stay, and what its flags change.

```bash
ai-tools projects unclaim ~/src/api
```

Drops the project from your allowlist and from git's `safe.directory` list,
reverts its label, and — behind its own confirm, default Yes — hands the tree
back to your group with the agent's write access removed. The directory stays
on disk. Dropping the entry is what stops sessions: none starts there
afterwards, and the ownership handback stops with it.

## It normalizes; it does not restore

The group owner of every path moves from the agent's group to yours (or
to the group `--group` names), every extended ACL entry is cleared — the ones
that predated the claim included — group write and the setgid bit
on directories go, and the label reverts. The pre-claim permissions are not
recorded, so back up first; the claim and the forced unclaim each say
so before asking. World access the claim removed does not come back,
and an owner-only path is untouched at both ends ([Permissions](permissions.md)
has what each path ends at). New files then take their mode from the creating
account's umask again, which the claim's default ACL had been overriding (the
[permissions cheatsheet](../linux-permissions-cheatsheet.txt) covers a default
ACL replacing the umask). What comes off, and why the group owner is the route
that has to close, is
[ref-section-m5n5](../../.claude/rules/cli.rule.md#ref-section-m5n5).

## What you point at decides what happens

| What you pointed at | What happens |
|---|---|
| a claimed project | unclaimed |
| a directory with claimed projects nested under it | they are listed, one confirm covers all, each is unclaimed outermost-first |
| a path *inside* a claimed project | refused, naming the nearest claimed parent and the command that works |
| a path the allowlist does not cover, without any agent permissions on it | refused: no part of this tree was claimed |
| a path the allowlist does not cover, still carrying agent permissions | reported, and `--force` offered |

The outcomes are
[ref-table-d9g9](../../.claude/rules/cli.rule.md#ref-table-d9g9).

A **parked** project is asked about first: the hand-back cannot run while
the `!` line stands, so the command offers to lift it. Declining does not abort
— the entry is still dropped, or parked under `--keep-entry` —
and the hand-back is reported as not run, with the `projects enable`
and `projects handback --full` pair that completes it, and a non-zero exit.

## Keeping your place across a release

```bash
ai-tools projects unclaim --keep-entry ~/src/api   # files handed back; the line stays, parked
# ... release ...
ai-tools projects claim ~/src/api                  # offers to re-enable it, in place
```

A common rhythm is to unclaim before a production release, so the tree carries
ordinary permissions, then claim again for the next development stage. A plain
unclaim deletes the line, so the later claim appends a new one at the end
of the file; `--keep-entry` parks it instead, as `projects disable` would,
and the claim then offers to re-enable it where it was ([Enable](enable.md)).
`--keep-entry` is refused with `--force`, which reaches a tree with no line
to keep, and for a project nested inside another claimed one, for the reason
`projects disable` gives ([Disable](disable.md)).

## A copy that was not unclaimed

```bash
ai-tools projects unclaim --force --dry-run /backup/staging/proj   # list, change nothing
ai-tools projects unclaim --force /backup/staging/proj             # apply
```

Copy or move a claimed project (`cp -a`, `rsync -a`, `mv`, `tar -p`)
and the copy carries the agent's group, ACL entries and setgid bits with it,
while no allowlist entry names it, so the normal unclaim refuses. `--force`
handles exactly that tree: a path is touched only while it still carries
the agent's ownership, group or ACL entry, so on a directory that was never
claimed it leaves every path as it found it, which is what makes a mistyped
path harmless. What it does to a path it accepts is identical to a normal
unclaim, the label included where the directory still carries one.
On a registered project `--force` is refused outright.

`--force` does not relax any other gate. A system directory or a home root is
still refused; a file belonging to anyone else is still skipped; a hardlinked
file is still refused, since a second name for it reaches from outside the tree
— a locally cloned `.git` hits this in bulk, and the count is reported
with the `find` line that lists them; secret-named and `!`-excluded paths are
still skipped.

Two flags pair with it. `--full` extends the walk into the heavy trees
the claim skips (`node_modules`, `.venv`, caches), where the agent's ownership
survives a copy as it does elsewhere; the pass reports what it finds there
and confirms before including it, and without the flag those paths are reported
and left alone. `--dry-run` lists every path that would change, with ownership
and mode, and applies none of them; it pairs with `--force` only, since
a registered project's unclaim previews itself.

## When `--force` does not recognise the tree

Where you have already changed the group ownership or the ACL entries by hand,
`--force` does not recognise the path and leaves it untouched. The reversal is
then the same steps, performed by you:

```bash
setfacl -R -b path                       # strip access + default ACLs
chgrp -R "$(id -gn)" path                # restore your primary group
chmod -R g-w path                        # drop group write
find path -type d -exec chmod g-s {} +   # clear the setgid bit on directories only
restorecon -RF path                      # restore the SELinux label for the location
```

For a single file omit the `-R` flags and the `find` line. `restorecon` needs
`sudo` when the object is not owned by you. Verify the result with:

```bash
getfacl -e path
ls -ldZ path
```

Why each bit those commands touch behaves as it does is in the [permissions
cheatsheet](../linux-permissions-cheatsheet.txt): its sections on `chgrp`,
on setgid for a directory and for a file (which is why the `find` line stays
on directories), and on the default ACL that replaces the umask.

## Scripting an unclaim

```bash
ai-tools projects unclaim --force -y --group builders /backup/staging/proj
```

Normalizing a copy before a backup or a deployment is the case that runs
without a terminal. `-y` pre-answers the confirm, and only that: it does not
answer the hand-back question or the skip-listed one. `--group` names
the target group outright. Give `--group` in any unclaim, forced or not:
without it the command asks whether to hand back and whose group to use,
and a run with no terminal takes the invoking user's group.

## An unclaim that could not hand the files back says so

The hand-back is the step that takes the agent's access off the *files*;
the registry steps stop a session from launching there and leave the tree as it
was. When the hand-back did not run — a declined password round, or a parked
project whose `!` you kept — the command reports it, names
the `projects enable` and `projects handback --full` pair, and exits non-zero;
it does not print a clean `unclaimed`. What each verb does after a root step
fails is [ref-table-b9q6](../../.claude/rules/cli.rule.md#ref-table-b9q6).

## For another operator

`ai-tools projects unclaim --for svc-ci /srv/projects/api` reverses a claim
made for that operator ([Service accounts](../operators/service-accounts.md)).
It cannot be combined with `--force`: that mode reaches a tree no allowlist
names, so the command has no entry to read an owner from and binds the walk
to you.

## Exit status

0 when the project is unclaimed; 1 when a step failed, or the hand-back did not
run; 2 for a rejected command line (`--keep-entry` with `--force`, `--yes`
with `--dry-run`); 3 when the path is a protected system directory or a home
root. `man ai-tools` has the full list.
