# Delete a project

[Projects](index.md) · [Create](create.md) · [Claim](claim.md) ·
[Clone](clone.md) · [Push](push.md) · [List](list.md) · [Disable](disable.md) ·
[Enable](enable.md) · [Unclaim](unclaim.md) · **Remove** ·
[Lockdown](lockdown.md) · [Handback](handback.md) ·
[Permissions](permissions.md) — [all docs](../index.md)

How `ai-tools projects remove` unregisters a project and deletes its directory,
what authorizes it, what it checks first, and what a failure leaves behind.

```bash
ai-tools projects remove ~/src/oldproject
```

Does what an unclaim does **and deletes the directory**. There is no undo
and no trash location, so the command is deliberately hard to reach
by accident. To release a project and keep the files, use
`ai-tools projects unclaim` ([Unclaim](unclaim.md)).

## What authorizes it

An **exact** entry for the path in your allowlist, and only that: there is no
`--force`, since deleting a tree no entry registers is an unclaim plus an `rm`
you type yourself. A parked (`!`) entry counts, since it records a project
taken out of service and still yours, and adds one confirmation naming
that state. A directory enclosing claimed projects, a path *inside* a project,
an unregistered path, and a project that **contains** another claimed project
are each refused, the last because deleting it would take the nested one
with it and leave that project registered at a path that no longer exists.
The rules are
[ref-section-k3v7](../../.claude/rules/cli.rule.md#ref-section-k3v7).

## What it checks first

```text
WARNING: this tree cannot be fully deleted
    take ownership of the tree first, then re-run the removal:
      ai-tools projects handback --full ~/src/oldproject
```

Before anything changes, a read-only pass checks that you can delete every
directory in the tree, and refuses up front where you cannot, so a removal does
not stop partway and leave an unregistered fragment behind. The parent
directory is checked as well, since the last step unlinks the project from it;
where you cannot write the parent, the refusal names `projects unclaim`
instead, the parent never having been the project's to hand back. The pass also
reports unpushed commits and a repository with no upstream, and goes on, since
deleting a scratch repository on purpose is legitimate; uncommitted changes are
not counted, so check the working tree yourself before you confirm.

## It confirms twice

```text
Delete this project directory and everything in it? [y/N] (default: No):
```

Then the project's name, typed out. A run with no terminal answers neither,
so a delete needs an operator at the prompt — unless you pass `-y`,
which answers the confirmation and the typed name and is the only thing
that does: `AI_TOOLS_ASSUME_YES` does not answer a default-No question,
and the typed name has no default. With `-y` a `DIRECTORY` argument is
required, so an unattended removal cannot inherit the directory it happened
to start in.

## Registries first, the tree last

The label, the `safe.directory` entry and the allowlist entry go first,
and the tree is deleted last. A deletion that then fails leaves a tree that is
already unregistered and out of the agent's reach, which you remove by hand;
the reverse order would leave a half-deleted tree the agent still reaches.
The allowlist step is the one that has to complete: where the entry cannot be
removed, the command stops and prints the line to delete by hand.

## A sandbox clone

Pointed at a clone under the sandbox area, the command warns about any commit
not yet pushed, asks one default-No confirm, then deletes the clone
and unregisters it. The remote branch stays for others to merge. `-y` answers
that one confirm, on the same terms ([Clone](clone.md)).

## For another operator

`ai-tools projects remove --for svc-ci /srv/projects/api` deletes the tree
**as** that account, since only its owner can delete it, so the run needs
a `sudo` grant to act as that account; it is checked before anything is removed
([Service accounts](../operators/service-accounts.md)).

## Exit status

0 when the project is deleted; 1 when a step failed — a deletion that left
paths behind included, the project being already unregistered by then; 2
for a rejected command line (`-y` without a `DIRECTORY`); 3 when the path is
a protected system directory or a home root. `man ai-tools` has the full list.
