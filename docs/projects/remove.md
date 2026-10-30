# Delete a project

[Projects](index.md) · [Create](create.md) · [Claim](claim.md) ·
[Clone](clone.md) · [Push](push.md) · [List](list.md) · [Disable](disable.md) ·
[Enable](enable.md) · [Unclaim](unclaim.md) · **Remove** ·
[Lockdown](lockdown.md) · [Handback](handback.md) ·
[Permissions](permissions.md) — [all docs](../index.md)

How `atr projects remove` unregisters a project and deletes its directory,
what authorizes it, what it checks first, and what a failure leaves behind.

```bash
atr projects remove ~/src/oldproject
```

Does what an unclaim does **and deletes the directory**. There is no undo
and no trash location, so the command is deliberately hard to reach
by accident. To release a project and keep the files, use
`atr projects unclaim` ([Unclaim](unclaim.md)).

The directory is always named, never taken from where you typed the command.
To delete the project you are in, name it:

```bash
atr projects remove .
```

## What authorizes it

An **exact** entry for the path in your project registry, an allow or a `%`
line, and only that: there is no `--force`, since deleting a tree no entry
registers is an unclaim plus an `rm` you type yourself. A parked (`%`) entry
counts, since it records a project taken out of service and still yours,
and adds one confirmation naming that state. A directory enclosing claimed
projects, a path *inside* a project, an unregistered path, and a project
that **contains** another claimed project are each refused, the last because
deleting it would take the nested one with it and leave that project registered
at a path that no longer exists. A carve-out (`!`) is refused too, since no
entry authorizes deleting it, and the carve-out lines under a project you
remove stay in the file, which `atr projects list` then reports as stale.
The rules are
[ref-section-k3v7](../../.claude/rules/cli.rule.md#ref-section-k3v7).

## What it checks first

```text
WARNING: this tree cannot be fully deleted
    take ownership of the tree first, then re-run the removal:
      atr projects handback --full ~/src/oldproject
```

Before anything changes, a read-only pass checks that you can delete every
directory in the tree, and refuses up front where you cannot, so a removal does
not stop partway and leave an unregistered fragment behind. The parent
directory is checked as well, since the last step unlinks the project from it;
where you cannot write the parent, the refusal names `projects unclaim`
instead, the parent never having been the project's to hand back. The command
does not read the repository, so unpushed commits and uncommitted changes are
not reported: check both yourself before you confirm.

## It confirms twice

```text
Delete this project directory and everything in it? [y/N] (default: No):
```

Then the project's name, typed out. A run with no terminal answers neither,
so a delete needs an operator at the prompt — unless you pass `-y`,
which answers the confirmation and the typed name and is the only thing
that does: `AI_TOOLS_ASSUME_YES` does not answer a default-No question,
and the typed name has no default.

## Registries first, the tree last

The label, the `safe.directory` entry and the registry entry go first,
and the tree is deleted last. A deletion that then fails leaves a tree that is
already unregistered and out of the agent's reach, which you remove by hand;
the reverse order would leave a half-deleted tree the agent still reaches.
The registry step is the one that has to complete: where the entry cannot be
removed, the command stops and prints the line to delete by hand.

While an agent session or the toolchain update runs, the label cannot be
reverted, and the command stops at that step with the tree and both entries
as they were. Let each session end (`/exit` inside it) and the update finish,
or end them all with `atr stop`, then run the removal again.

## A sandbox clone

Pointed at a clone under the sandbox area, the command asks one default-No
confirm, then deletes the clone and unregisters it. A commit not yet pushed
goes with it, and the command does not count them: run `atr projects push`
first to keep your work ([Push](push.md)). The remote branch stays for others
to merge. `-y` answers that one confirm, on the same terms ([Clone](clone.md)).

## For another operator

`atr projects remove --for svc-ci /srv/projects/api` deletes the tree **as**
that account, since only its owner can delete it, so the run needs a `sudo`
grant to act as that account; it is checked before anything is removed
([Service accounts](../operators/service-accounts.md)).

## Exit status

0 when the project is deleted; 1 when a step failed — a deletion that left
paths behind included, the project being already unregistered by then,
and a label step refused while a session runs, with the tree and its entries
left in place; 2 for a rejected command line (a missing `DIRECTORY`
among them); 3 when the path is a protected system directory or a home root.
`man ai-tools` has the full list.
