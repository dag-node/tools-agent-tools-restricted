# Claim a project in place

[Projects](index.md) · [Create](create.md) · **Claim** · [Clone](clone.md) ·
[Push](push.md) · [List](list.md) · [Disable](disable.md) · [Enable](enable.md)
· [Unclaim](unclaim.md) · [Remove](remove.md) · [Lockdown](lockdown.md) ·
[Handback](handback.md) · [Permissions](permissions.md) — [all
docs](../index.md)

How `ai-tools projects claim` registers a tree you already have, what it asks
in the order it asks, what each answer grants, and what a re-claim repairs.

```bash
cd ~/src/existing
ai-tools projects claim
```

Registers the tree in your allowlist and in git's `safe.directory` list, gives
the agent access to it through the shared group and the grants a claim writes,
and marks the tree as one the confined session may read. It runs only the steps
that are missing, so a re-claim over a fully claimed tree is a quiet no-op.
Which files the agent can then open, and which you keep, is
on [Permissions](permissions.md); the grants themselves are
[ref-section-h7d3](../../.claude/rules/cli.rule.md#ref-section-h7d3).

## The blocks, in the order they run

A claim is a sequence of self-contained blocks, each with its own headline, its
own list and its own decision. In the order they appear on the page:

1. **Review** — the pending steps, the notices about the tree, the drift
   reports of a re-claim, then the proceed confirm, which covers exactly
   the steps listed:

   ```text
   Apply these pending steps to the tree in place? [y/N] (default: No):
   ```

2. **Interior drift** — on a re-claim only, one block per kind of file
   that kept what it had where it came from. The SELinux type question defaults
   to Yes; the group and ACL question defaults to No. Each is asked under its
   own list of paths. When to say no is on [Permissions](permissions.md).
3. **Reachability** — the traverse grant on a parent directory
   whose permissions keep the sandbox account out, default No.
4. **Secret lockdown** — the scan for secret-named files, and the run's first
   `sudo` prompt. Locking what it finds defaults to Yes; declining stops
   the claim ([Lockdown](lockdown.md)).
5. **`.git` history** — whether the agent may read the repository's history,
   default Yes.
6. **Apply** — the approved steps, one result line each, then one outcome line
   per drifted file, then the closing `claimed` line.

A first claim skips the drift blocks: its normal walks repair the whole tree.
The blocks and what closes each one are
[ref-list-g6f5](../../.claude/rules/cli.rule.md#ref-list-g6f5).

## What answers a question

Every yes/no question states its default; Enter, and a run without a terminal,
take it (`man ai-tools`). Which flag or variable pre-answers which question:

- `-y` answers the proceed confirm and the SELinux type question, and only
  those. It does not answer the traverse grant, the group and ACL repair,
  the secret lockdown or the `.git` question, which ask on their own terms.
- `AI_TOOLS_ASSUME_YES=1` answers the `.git` history question alone:
  the SELinux type question does not take it, and the lockdown runs
  through `sudo`, which does not pass it on. A question that widens access
  defaults to No, and the environment does not answer it.
- Without a terminal, the SELinux type question runs only with `-y`;
  the traverse grant is declined, and the claim prints the command to run
  by hand.

The full matrix, question by question, is
[ref-table-s7c5](../../.claude/rules/cli.rule.md#ref-table-s7c5).

## Reachability: a parent that keeps the agent out

```text
WARNING: parent directories block the agent
  the sandbox account must be able to traverse every parent directory to
  reach the project; the grant below is traverse-only (enter, never list
  or read)
      /home/you

Grant the sandbox account traverse-only access on them? [y/N] (default: No):
```

The session runs as the sandbox account, so a project under a directory
that account cannot enter — a private home is the usual case — is unreachable
even after a clean claim. The grant permits that account to pass through each
listed directory you own; it does not permit a listing of the directory
or the reading of a file in it, since each file's own mode still decides.
What it makes reachable is whatever under that directory is already
world-readable; where the directory is your home, the prompt names the command
that lists it, `find /home/you -maxdepth 1 -perm -o+r`, so you read the answer
for this host rather than guess it. It defaults to No because it widens access
on the project's parents.

Declining leaves every parent as it was, and the claim goes on: the closing
line says the agent may be unable to enter the project. A run without
a terminal declines, and prints the `setfacl` line for each parent so you can
apply it by hand. A parent you do not own, or a system directory, is not
offered at all: the claim says why and names `ai-tools projects clone`
as the way in. The grant is
[ref-section-d7d5](../../.claude/rules/cli.rule.md#ref-section-d7d5).

## Secret lockdown before any access

The scan runs before any step that widens the agent's access, and it is
the first `sudo` prompt of the run. Locking what it finds makes those files
yours alone; declining stops the claim, so the agent is not granted a tree
with exposed secrets in it. What the patterns match, and what they do not, is
on [Lockdown](lockdown.md).

## `.git` history

```text
Normalize .git so the agent can access git history here? [Y/n] (default: Yes):
```

Yes opens `.git` to the agent, so it reads the repository's full history
and your own later commits stay readable to it. Decline it to keep the history
hidden; the working tree is claimed either way. A credential committed
and since removed is one `git show` away for anything that reads `.git`,
which is what this question is about ([Lockdown](lockdown.md)).

## Notices in the Review block

```text
NOTICE: configuration above this project the agent cannot read
  2 file(s) above /home/you/src/app are configuration an installed toolchain
  reads for a build here, and the sandbox account cannot open them ...
      /home/you/src/.editorconfig
      /home/you/src/Directory.Build.props
```

A build toolchain collects configuration by walking from the project toward
`/`. A session reaches the project and not the directories enclosing it,
so a file found there is opened, denied, and the build stops with an error
naming a path outside the project. .NET is where this shows up today
(`.editorconfig`, `Directory.Build.props`, `Directory.Packages.props`,
`global.json`, `NuGet.config`); a project built with another toolchain does not
raise the notice. The claim reports the files and changes none of them, since
every step it performs acts inside the project, and a launch reports them
again. A file moved into the project is readable to the agent; one left outside
it is not.

Two more notices name what the claim saw and left alone:

- **Setgid on an owner-only directory** held by a group that is neither
  the agent's nor your own is kept, since the claim cannot tell whether it was
  deliberate. `chmod g-s` on the directory clears it if it was not.
- **Drift under skip-listed directories** — `node_modules`, build output,
  caches — is reported and not repaired, since the claim's walks do not enter
  those trees. Where one of them is really source, name it in `operator.conf`
  (the notice names the key, `SKIP_ARTIFACT_DIRS_EXCLUDED_PATHS_RELATIVE`)
  and claim again; for ownership alone inside them, run
  `ai-tools projects handback --full`.

An owner-only path, and one named on a `!` line of your allowlist, is skipped
by every step and reported as a count. Either mark is also how you stop a path
being reported again.

## Re-claiming

```bash
ai-tools projects claim    # from inside the project
```

Running the claim again is the repair. It reads the tree, performs only
the steps that are missing, and is a no-op when none are. Run it after you move
files in from elsewhere, after you change permissions by hand, or when a claim
stopped part-way. A re-claim repairs group, permissions and the label; it does
not hand files back, so a file the agent wrote stays owned by the sandbox
account until you run `ai-tools projects handback` ([Handback](handback.md)).

Files you moved in are the usual reason to need one: `mv` keeps a file's old
group and type, so the agent cannot write that one file while everything
around it works. The re-claim lists such files, asks about each kind under its
list, and after the Apply block prints one line per file saying whether
the repair took. The questions, when to say no, and what each outcome means are
on [Permissions](permissions.md). `ai-tools projects claim --format tsv` writes
those outcome lines to standard output as a record stream
(`man 5 ai-tools-records`), with every other line on standard error
and the questions still asked on the terminal, so a script reads the rows
alone.

## A parked entry

`projects claim` on a project you disabled does not claim over it and does not
add a second line: it reports the exclusion, shows the line, and offers
to re-enable it behind a default-No confirm. Yes claims the project again
with its line, and its comment, where they were ([Enable](enable.md)).

## For another operator

```bash
ai-tools projects claim --for svc-ci /srv/projects/api
```

The entry lands in `svc-ci`'s allowlist, so files the agent writes there come
back to that account and its own agent launches there without further setup.
The tree has to be owned by that operator or by the sandbox account: a claim
for an operator over a tree they do not own would register the project
and leave the agent without access to it, so the claim refuses it up front
and names the `chown` that fixes it. The worked flow for a service account is
on [Service accounts](../operators/service-accounts.md).

## Exit status

0 when the tree is claimed or there was no work; 1 when a root step failed,
with the pending steps named — a re-run applies exactly those; 2 for a rejected
command line (an unknown option, a `--format` other than `tsv`); 3
when the path is a protected system directory or a home root; 4 when a drifted
file was left as it was or a scan stopped early; 5 when a file's state or part
of the tree could not be read. `man ai-tools` has the full list.
