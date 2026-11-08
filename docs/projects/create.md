# Create a new project

[Projects](index.md) · **Create** · [Claim](claim.md) · [Clone](clone.md) ·
[Push](push.md) · [List](list.md) · [Disable](disable.md) · [Enable](enable.md)
· [Unclaim](unclaim.md) · [Remove](remove.md) · [Lockdown](lockdown.md) ·
[Handback](handback.md) · [Permissions](permissions.md) — [all
docs](../index.md)

How `atr projects create` makes a directory, initializes git in it and claims
it in one step, what it refuses, and the questions it still asks you.

```bash
atr projects create ~/src/newproject
```

Creates the directory, initializes an empty git repository in it, writes
a `README.md` naming it, then runs the same claim that `atr projects claim`
runs on a tree you already have ([Claim](claim.md)). The `DIRECTORY` is
required: the current directory exists, so it cannot be the default
of a command whose subject is a directory that does not exist yet.

## The questions it asks

The tree is empty when the claim starts, so two of the claim's questions
about an existing tree are answered by that: there is no pending step
to confirm with a warning about modifying permissions throughout the tree, and
no secret-named file to scan a directory the command made a moment ago for.
The claim therefore proceeds without the proceed confirm or the secret scan.

```text
Normalize .git so the agent can access git history here? [Y/n] (default: Yes):
```

The `.git` question is still asked, where `git init` made a repository.
A new repository has no history, so yes lets the agent read the commits you
make there from now on. No keeps `.git` out of the agent's reach: the create
leaves it in the owner's group with no access for other accounts, which suits
a service account whose agent works the tree while you commit. If the create
cannot set those modes, it warns that the agent may be able to read `.git`
whatever you answer. Enter,
`AI_TOOLS_ASSUME_YES=1` and a run without a terminal answer yes. A later
`atr projects claim` offers the share again, and a `chmod` on `.git` withdraws
it. Where `git init` fails, the create warns and claims the directory without
a repository, and the question is not asked.

The traverse grant is the other question, because it is about the project's
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
ai-tools: cannot resolve the parent directory: /home/you/Devlopment -- it does not exist, or a symbolic link on its path leads through a directory you cannot enter
```

It creates exactly one directory, so the parent has to exist
([ref-section-x8s5](../../.claude/rules/cli.rule.md#ref-section-x8s5) states
why). The refusal names the missing parent, and a `mkdir -p` of your own, once
you have checked the path, makes it. A symbolic link that leads
through a directory you cannot enter looks the same as a missing directory
from your account, so the refusal names both causes.

```text
ai-tools: this path already exists: /home/you/src/newproject
```

A path that already exists is refused, naming `atr projects claim` instead:
claiming grants an agent access to whatever a tree already holds, which is not
an operation to arrive at by a typo.

```text
ai-tools: cannot create at a symbolic link: /home/you/src/link -- projects create makes a new directory and does not follow a link there
```

A path whose last part is a symbolic link is refused by the name you gave,
whether or not the link points at anything. Remove the link and create
the project there, or name the directory the link points at.

A location the sandbox account could not reach through any grant —
under a directory owned by someone else, or under a system directory — is
refused before anything exists, and names the clone as the way in.

Every refusal fires before the directory is made. A step that fails after it —
a root step whose password round did not complete — leaves the directory
in place, and the run names the directory and the `atr projects claim` that
finishes the claim, with `--for` where the create carried it.

## For another operator

`atr projects create --for svc-ci /srv/projects/api` makes the tree owned
by `svc-ci` and registers it in that account's project registry. Because
the directory is made **as** that account, the run needs a `sudo` grant to act
as it, and a parent that account can write; [Service
accounts](../operators/service-accounts.md) covers what to do when either is
missing.

## Exit status

0 when the project is created and claimed; 1 for a refusal before the directory
is made, and when a step failed after it was made; 2 for a rejected command
line (a missing `DIRECTORY`, an unknown option); 3 when the path is a protected
system directory or a home root; 5 when the new tree could not be read
as its owner, and the claim then names what is left to finish. `man ai-tools`
has the full list.
