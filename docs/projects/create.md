# Create a new project

[Projects](index.md) · **Create** · [Claim](claim.md) · [Clone](clone.md) ·
[Push](push.md) · [List](list.md) · [Disable](disable.md) · [Enable](enable.md)
· [Unclaim](unclaim.md) · [Remove](remove.md) · [Lockdown](lockdown.md) ·
[Handback](handback.md) · [Permissions](permissions.md) — [all
docs](../index.md)

How `ai-tools projects create` makes a directory, initializes git in it
and claims it in one step, what it refuses, and the one question it can still
ask you.

```bash
ai-tools projects create ~/src/newproject
```

Creates the directory, initializes an empty git repository in it, writes
a `README.md` naming it, then runs the same claim
that `ai-tools projects claim` runs on a tree you already have
([Claim](claim.md)). The `DIRECTORY` is required: the current directory exists,
so it cannot be the default of a command whose subject is a directory that does
not exist yet.

## The one question it can ask

The tree is empty when the claim starts, so the claim's questions
about an existing tree are answered by that: there is no pending step
to confirm with a warning about modifying permissions throughout the tree, no
secret-named file to scan a directory the command made a moment ago for, and no
git history to expose in a repository with no commits. The claim therefore
proceeds without the proceed confirm, the secret scan or the `.git` question,
and opens `.git` to the agent so that your own later commits stay readable
to it.

The traverse grant is the one question left, because it is about the project's
**parents** rather than the tree: where the sandbox account cannot enter
a directory enclosing the new project, the claim asks (default No) whether
to let it pass through. What the grant permits, and what it prints
when declined without a terminal, are under Reachability on [Claim](claim.md).

## Modes on a restrictive umask

```text
    created /home/you/src/newproject
    modes set to 0750/0640 -- your umask (0077) would have made them
    owner-only, which the agent cannot read
```

On a host whose umask makes every new file owner-only, the create sets modes
the agent's group can read on the directory, the `README.md` and `.git`,
and prints that notice; on a permissive umask it prints nothing about modes.
A umask is a default for every new file, so the create does not read it
as the deliberate owner-only seal that keeps a path out of the agent's reach
everywhere else ([Lockdown](lockdown.md)). The modes it sets, and why it sets
them without asking, are
[ref-section-x8s5](../../.claude/rules/cli.rule.md#ref-section-x8s5).

## What it refuses

```text
ai-tools: the parent directory does not exist: /home/you/Devlopment
```

It creates exactly one directory, so the parent has to exist. A `mkdir -p`
would have created `Devlopment/`, put the project inside it, claimed it
and reported success — a claimed project in a directory nobody meant to make.
The refusal names the missing parent, and a `mkdir -p` of your own, once you
have checked the path, makes it.

```text
ai-tools: this path already exists: /home/you/src/newproject
```

A path that already exists is refused, naming `ai-tools projects claim`
instead: claiming grants an agent access to whatever a tree already holds,
which is not an operation to arrive at by a typo. A location the sandbox
account could not reach through any grant — under a directory owned by someone
else, or under a system directory — is refused before anything exists,
and names the clone as the way in.

Every refusal fires before the directory is made. A step that fails after it —
a root step whose password round did not complete — leaves the directory
in place, and `ai-tools projects claim` on it finishes the claim.

## For another operator

`ai-tools projects create --for svc-ci /srv/projects/api` makes the tree owned
by `svc-ci` and registers it in that account's allowlist. Because the directory
is made **as** that account, the run needs a `sudo` grant to act as it,
and a parent that account can write; [Service
accounts](../operators/service-accounts.md) covers what to do when either is
missing.

## Exit status

0 when the project is created and claimed; 1 when a step failed
after the directory was made; 2 for a rejected command line (a missing
`DIRECTORY`, an unknown option); 3 when the path is a protected system
directory or a home root. `man ai-tools` has the full list.
