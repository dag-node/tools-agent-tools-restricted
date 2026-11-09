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

An **exact** entry for the path in your project registry, an `@` or a `%` line,
and only that: there is no `--force`, since deleting a tree no entry registers
is an unclaim plus an `rm` you type yourself. A disabled (`%`) entry counts,
since it records a project taken out of service and still yours, and adds one
confirmation naming that state. A directory enclosing claimed projects, a path
*inside* a project, an unregistered path, and a project that **contains**
another claimed project are each refused, the last because deleting it would
take the nested one with it and leave that project registered at a path that no
longer exists. An excluded path (`!`) is refused too, since no entry authorizes
deleting it, and the excluded lines under a project you remove stay
in the file, which `atr projects list` then reports as stale. A sandbox clone
is authorized by where it is, who owns it and its shape ([A sandbox
clone](#a-sandbox-clone)). The rules are
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
so a delete needs an operator at the prompt, or `-y`, the only thing
that answers both (`man ai-tools`).

## Registries first, the tree last

The label and the registry entry go first, then the `safe.directory` entry,
and the tree is deleted last. A deletion that then fails leaves a tree
whose own registry entry is gone and no longer authorizes a launch there.
Where the project is nested in an enabled project and no disabled or excluded
line covers it, that project's entry still authorizes a launch there,
and the warning names it. A session already running keeps its access until it
ends, and the files left keep their group grant, since the command does not
hand them back before deleting them. The warning says whether the label step
completed; where it did not, the relabel command printed with the failure still
applies to the tree. Remove what is left by hand: the command prints
the `rm -rf` to run, and under `--for` the account to run it as. The registry
step is the one that has to complete: where the entry cannot be removed,
the command stops and prints the line to delete by hand.

The label is reverted whether or not an agent session runs. A file
with a second name outside the project, a hardlink, keeps its current type,
and the deletion removes only its name in the tree. Where the revert did not
complete, the command reads the tree's hardlinked files before it deletes
the tree, then says how many it held and prints, for the first 20,
the `sudo find … -ls` that lists one file's other names. The relabel command
a failed revert prints drops the rules the step left; after the deletion it
does not reach those other names, which the `find` lines list. On a host
with no label to apply the step reads `not applicable`.

## A sandbox clone

Pointed at a clone under the sandbox area, the command removes it when it is
a directory directly inside that area, owned by you or by the operator you act
for, holding a `.git` directory with a `HEAD` file, and asks the same two
questions ([It confirms twice](#it-confirms-twice)). It does not run git
to check, so a directory of that shape is removed on your confirm whether
`atr projects clone` made it or not. It then takes the order [Registries first,
the tree last](#registries-first-the-tree-last) states, the clone's own lines
going with it; a clone no line names is reported as having had no entry
when its deletion fails. A commit not yet pushed and an uncommitted change go
with it, and the command does not count them: run `atr projects push` first
to keep your work ([Push](push.md)). Work already pushed stays on its remote.
A project `atr projects create` made in the sandbox area is removed the same
way. `-y` answers both questions, on the same terms ([Clone](clone.md)).

## For another operator

`atr projects remove --for svc-ci /srv/projects/api` deletes the tree **as**
that account, since only its owner can delete it, so the run needs a `sudo`
grant to act as that account; it is checked before anything is removed
([Service accounts](../operators/service-accounts.md)). A project created
in the sandbox area for that account is removed the same way:

```bash
atr projects remove --for svc-ci /var/opt/ai-tools/sandbox-projects/api
```

## Exit status

0 when the project is deleted; 1 when a step failed — a deletion that left
paths behind included, the project being already unregistered by then,
and a label step refused while a process of the sandbox account is live,
with the tree and its entries left in place; 2 for a rejected command line (a
missing `DIRECTORY` among them); 3 when the path is a protected system
directory or a home root. `man ai-tools` has the full list.
