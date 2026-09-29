# Work in a sandbox clone

[Projects](index.md) · [Create](create.md) · [Claim](claim.md) · **Clone** ·
[Push](push.md) · [List](list.md) · [Disable](disable.md) · [Enable](enable.md)
· [Unclaim](unclaim.md) · [Remove](remove.md) · [Lockdown](lockdown.md) ·
[Handback](handback.md) · [Permissions](permissions.md) — [all
docs](../index.md)

How `ai-tools projects clone` makes a shallow clone under the sandbox area,
locks its secrets before the agent reaches it, and resumes a clone
that stopped.

```bash
ai-tools projects clone ~/src/repo
```

Shallow-clones the repository at that path into the sandbox area,
`/var/opt/ai-tools/sandbox-projects/<name>`, creates the branch the agent's
commits will go to, and registers the clone in your allowlist. The exact
`git branch`, `git push` and `git clone` commands are shown for confirmation
before any of them runs. The agent does not read the origin's history, no
directory enclosing the clone needs a grant, and your real checkout is
untouched — the reasons to pick this model over a claim in place are
on [Project lifecycle](index.md).

Any operator creates clones in that area. A clone belongs to the operator
who made it and pushes with that operator's git credentials, which is
why the command does not take `--for`.

## Each input has a default and a flag

```bash
ai-tools projects clone ~/src/repo --from main --branch hotfix/login --dir repo-hotfix
```

- `--from REF` — the branch or ref to fork from; default the current branch.
  A local branch, a `REMOTE/REF` or any commit-ish, so a hotfix is based
  on `main` without checking it out.
- `--branch NAME` — the full branch to create and track; default
  `sandbox/LEAF`, where `LEAF` is the last component of `--from`. Any valid git
  ref is accepted as written.
- `--dir NAME` — the clone's directory name under the sandbox area; default
  the repository's base name.
- `-y`, `--yes` — skips the final confirmation, `Create the sandbox clone?`,
  which defaults to Yes. The secret lockdown still asks.

A flag left out is prompted for at a terminal and takes its default without
one, so the command runs from a script. `man ai-tools` has the option
reference.

## Locked before it is opened

The clone is born private to you, so a credential checked into the tip commit
is unreadable to the sandbox account from the first instant. The secret scan
then runs over every directory of the clone, a checked-in `node_modules`
included, and only past it is the clone opened to the agent, labelled
and registered, with the locked files kept yours alone. Declining the lockdown,
or a lockdown that failed, stops the command with the clone on disk, private
and unregistered, and a guard `CLAUDE.md` inside it that tells a session
to wait until the lockdown runs. Your real `CLAUDE.md`, where there is one, is
kept beside it as `CLAUDE.md.bak`. The gate and the order it imposes are
[ref-section-u9a9](../../.claude/rules/cli.rule.md#ref-section-u9a9).

## Resume a clone that stopped

```bash
ai-tools projects clone /var/opt/ai-tools/sandbox-projects/repo
```

Pointing the command at the existing clone path resumes where it stopped:
the scan, then opening, labelling and registering, and the guard `CLAUDE.md` is
removed on success. On a clone that is already open, the resume re-runs
the scan and leaves the tree's modes as they are, so a directory you sealed
inside it keeps its mode.

## Day to day

A session runs in the clone like in any project. `ai-tools projects push` sends
the agent's commits to the branch the clone tracks ([Push](push.md)),
and whoever has access to the repository merges that branch back,
with the agent's commits kept one by one. `ai-tools projects remove`
on the clone path deletes the clone and its registration ([Remove](remove.md)).
`/var/opt/ai-tools/README.md` on the host documents the cycle for an operator
working at the console.

## Exit status

0 when the clone is registered; 1 when it could not be completed — a declined
confirmation, or a step that failed after the clone was made, in which case
the resume command is printed; 2 for a rejected command line. `man ai-tools`
has the full list.
