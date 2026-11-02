# Ownership and shared access

[Projects](index.md) · [Create](create.md) · [Claim](claim.md) ·
[Clone](clone.md) · [Push](push.md) · [List](list.md) · [Disable](disable.md) ·
[Enable](enable.md) · [Unclaim](unclaim.md) · [Remove](remove.md) ·
[Lockdown](lockdown.md) · [Handback](handback.md) · **Permissions** — [all
docs](../index.md)

What owns a file the agent wrote, how you and the agent both keep write access
to one tree without joining each other's groups, and what a claim leaves alone.

```bash
ls -l  ~/src/api/newfile.go   # you own it; the agent reads it through the group
getfacl -e ~/src/api          # the two grants a claim writes, and their effective access
```

<a id="ref-diagram-r3t3"></a>**The life of a file in a claimed project**

<picture> <source media="(prefers-color-scheme: dark)"
srcset="../static/diagrams/ownership-lifecycle-dark.svg"> <source
media="(prefers-color-scheme: light)"
srcset="../static/diagrams/ownership-lifecycle-light.svg"> <img alt="The life
of a file in a claimed project, as owner, group, and who reads and writes it.
Before the claim a file of yours has your group, and the coding agent
and others reach it as its mode allows. After projects claim its group is
ai-tools: you and the coding agent read and write it, others have no access,
and owner-only paths and secret-named files are left out. A new file the coding
agent writes is owned by ai-tools with the group ai-tools, and you read
and write it through your grant before any handback. Handed back after each
tool call and turn, or by projects handback for the rest, it is owned by you
with the group ai-tools; a secret-named file is locked to you and your group,
and the coding agent loses access. After projects unclaim a handed-back file is
yours with your group, the coding agent has no access, and world access does
not come back. No step re-owns a file you wrote, an owner-only path or a path
on a ! line of your project registry; atr projects handback returns files
a session that ended early left behind, and the files the coding agent writes
inside .git come back at the start and end of each session."
src="../static/diagrams/ownership-lifecycle-light.svg"> </picture>

## Files the agent writes come back to you

A file the agent creates is born owned by the sandbox account. Getting it back
is not a command you run: as the session goes — per tool call and per turn —
each written file is returned to you, so you reach it through the owner bits
and the agent keeps reading it through the group. World access is removed
on the way. A directory the agent created while writing comes back with it,
keeping the group's access; a directory that was already yours is left alone.

The return happens inside claimed paths only, and acts on a path only while
the sandbox account still owns it — the state an agent write leaves behind —
so a file you wrote yourself, which you already own, is not touched.
A secret-named file is the one exception, and comes back yours alone
([Lockdown](lockdown.md)). `atr projects handback` runs the same pass
on demand, for what a killed session left behind ([Handback](handback.md)).
The hooks that return each file, and the helper they call, are
[ownership-and-hooks](../../.claude/rules/ownership-and-hooks.rule.md).

## You and the agent co-write one tree

A claim writes two grants on the project, and the pair is what makes a shared
tree work without either side joining the other's group: one gives the agent
access to the files **you** write, and the other gives you access to the files
**the agent** writes. Each grant is umask-independent, so a file's access does
not depend on which side created it or on what either account's umask was
at the time. World access stays closed. You stay out of the sandbox group
and the sandbox account stays out of yours, which keeps each side to one
permission tier: you do not gain blanket read of the agent's own session state,
and your access does not wait on the handback having run yet. The grants,
and the check a re-claim reads them with, are
[ref-section-h7d3](../../.claude/rules/cli.rule.md#ref-section-h7d3).

<a id="ref-diagram-j7k9"></a>**The two grants on a claimed project**

<picture> <source media="(prefers-color-scheme: dark)"
srcset="../static/diagrams/two-grants-dark.svg"> <source
media="(prefers-color-scheme: light)"
srcset="../static/diagrams/two-grants-light.svg"> <img alt="Two grants
on a claimed project, set on every directory and inherited. You, the operator
in the ai-ops group and not in the group ai-tools, reach your files as their
owner; the coding agent, running as the ai-tools service in none of your
groups, reaches its files as their owner. Grant 1, the coding agent's group
grant, lets it read and write a file you write under any umask. Grant 2, your
named grant, lets you open a file the coding agent writes before the handback
makes you its owner. Others have no access, since a claim closes world access
on every path it touches; a project directory gives every new file the sandbox
group and both grants; owner-only paths, lines of your project registry
starting with ! and secret-named files get neither grant. getfacl -e shows
a path's effective access, and ls -l marks a file carrying an ACL with +."
src="../static/diagrams/two-grants-light.svg"> </picture>

## What a claim leaves alone, and what does not come back

**An owner-only path is never opened**, because every permission walk a claim
runs skips it: a file or directory with no group and no other bits is your
standing "keep this private" signal, a sealed directory takes its whole subtree
with it, and the claim reports how many paths it left alone
([Lockdown](lockdown.md) has the seal). The label step types the whole tree,
that path included; its mode keeps the agent out whatever its label.

**World access is removed at claim time and does not come back.** A claim
closes other-access on every path it touches, and an unclaim then drops
the agent's write without restoring the world's read. A tree that needs to stay
world-readable is not a candidate for a claim in place — use a sandbox clone
([Clone](clone.md)). What each path's permissions become at a claim
and after an unclaim, mode by mode, is
[ref-table-b5v7](../../.claude/rules/ownership-and-hooks.rule.md#ref-table-b5v7).

Watching a claim with `ls -l` can mislead: with an ACL on a path, the group
column shows the ACL **mask**, and the only visible hint that an ACL exists is
the trailing `+`. Use `getfacl -e` to see effective access.

## Which files you and the agent can run

```bash
chmod ug+x scripts/build.sh   # you and the agent can run it
chmod g-x scripts/build.sh    # only you can, until a claim walks the project
ls -l scripts/build.sh        # -rwxrwx---+ : the group column is the agent's
```

On a file whose `ls -l` line ends in `+`, the group column is what the agent
gets right now. A claim sets it from your own permissions on the file,
so the agent can do what you can: read and write, and run a file you can run.
After the claim, `chmod ug+x` and `chmod g-x` change the agent's execute,
and change only the bit you name; `chmod u+x` alone does not give the agent
anything.

On a host with SELinux confinement, the default, the agent runs a project
script through its interpreter (`bash build.sh`) and does not run it directly,
whatever the group column shows. There the group execute bit matters to it
for build output once the `buildexec` policy group is enabled
([SELinux](../system/selinux.md)), and it matters to you for the files
the agent wrote. On a host without confinement it decides for every file.

The tables read left to right: what a case leaves, what a later walk makes
of it, and what an unclaim after that walk leaves. A *walk* is a claim
that applies the project's permissions again to every file ([What walks
the project](#what-walks-the-project)). Where an unclaim with no walk
in between leaves something else, the cell says so. The cases that do not
follow from the group column are in bold.

**Files you and the agent edit together**

| The file | Mode | The agent | After a walk | After unclaim |
|---|---|---|---|---|
| a data file you had before the claim (`640`, `644`, `660`, `664`) | `660` | read, write | `660` | `640` |
| a file created later in an editor, or checked out by git as `100644` | `660` | read, write | `660` | `640` |
| **a file a program creates `0644`** (`install -m 644`) | `640` | **read only** | **`660`, read, write** | `640` |

**Scripts and programs**

| You want | Run | Mode | The agent | After a walk | After unclaim |
|---|---|---|---|---|---|
| you and the agent run it | `chmod ug+x`, or commit it as `100755` | `770` | read, write, run | `770` | `750` |
| **only you run it** | `chmod g-x` | `760` | read, write | **`770`, the agent can run it again** | `750`; **`740` with no walk** |
| nobody runs it | `chmod ug-x` | `660` | read, write | `660` | `640` |
| **the agent runs it and you do not** | `chmod g+x` on a data file | `670` | **read, write, run** | **`660`, no run: a walk follows your own execute bit** | `640` |
| **a program a build creates `0755`** | — | `750` | **read, run, no write** | `770` | `750` |

`chmod g+x` on a file you cannot run is the one way the agent runs something
you do not, and only until the next walk.

**Read-only and private**

| You want | Run | Mode | The agent | After a walk | After unclaim |
|---|---|---|---|---|---|
| nobody writes it | `chmod a-w` | `440` | read; **it can still replace the file while it can write the directory** | `440` | `440` |
| **the agent only reads it** | `chmod g-w` | `640` | read | **`660`, the agent writes again** | `640` |
| **nobody changes your files in a directory** | `chmod a-w` on the files and `chmod +t` on the directory | `440` files, `3770` directory | reads them, adds files of its own; **cannot write, rename or delete yours, nor rename or delete its own once they come back to you** | kept | kept |
| the agent cannot reach it | `chmod 600`, or `chmod 700` on a directory | `600` | no access; **a tracked file only until git changes it** | `600` | `600` |

The agent cannot write into a read-only file, but a directory it can write lets
it delete or rename the file and put its own in its place. The sticky bit stops
the delete and the rename alone: in a sticky directory the agent can still
write into a file whose group column holds `w`, such as a `660` one. The files
need to be read-only as well, or kept out of the project.

**Files the agent writes**, after they come back to you

| The agent writes | Mode | The agent | After a walk | After unclaim |
|---|---|---|---|---|
| a file, the usual way | `660` | read, write | `660` | `640` |
| **a script it makes executable in the same command** | `770` | read, write, run; **you can run it too** | `770` | `750` |
| **a file a program creates `0644` / `0755`** | `640` / `750` | **read / read, run: no write to its own output** | `660` / `770` | `640` / `750` |

**Numeric modes replace the agent's access with their middle digit**

| Run | Mode | The agent | After a walk | After unclaim |
|---|---|---|---|---|
| `chmod 770` / `chmod 660` | as set | read, write (and run) | as set | `750` / `640` |
| **`chmod 750`** | `750` | **read, run, no write** | `770` | `750` |
| **`chmod 755`** | `755` | **read, run, no write** | `770` | `750`; **`755` with no walk: the file keeps its other bits, and the directories still block other accounts** |
| **`chmod 644`** | `644` | **read only** | `660` | `640`; **`644` with no walk, the same** |

The real cost of a numeric mode is the agent's write. The last digit sets
the file's own bits for other accounts, but a claim closes every directory
in the project to them, so they still cannot reach the file. Use the symbolic
form.

A walk writes both grants again and sets the agent's access to your own
permissions on the file, so the agent gets what you have: read and write,
and run where you can run it. An unclaim gives each file's group the read,
and the run, it had when the file was claimed or created, without write: `640`
on a file you cannot run and `750` on one you can, as most files had,
and `440`, `550` and owner-only files as they are. A file whose group could
only read before the claim stays that way, so a `640` file you made `ug+x`
unclaims to `740`, and a `711` one to `710`.

Git keeps one permission bit per file, whether you can run it. A checkout,
a pull or a branch switch that changes a tracked file writes it as a new file,
so the file takes the first table's access from that bit, whatever mode you had
set: a tracked file you made `600` comes back `660`, and the agent can read
and write it. An untracked file, such as a `.env` git ignores, keeps its mode,
and a `700` directory keeps the files git writes inside it out of the agent's
reach. Every mode, step by step, is
[ref-table-b5v7](../../.claude/rules/ownership-and-hooks.rule.md#ref-table-b5v7).

## Files you move into a claimed project

```bash
mv ~/Downloads/report.csv ~/src/api/data/
atr projects claim ~/src/api
```

A file you move in keeps what it had where it came from: its group, its mode
and its SELinux type. A file created inside the project takes the project's
instead. A re-claim finds the moved-in files and asks about each kind on its
own, right under the list of files it found:

- **SELinux type**, default No. The relabel gives the files the project's type,
  and their permissions still decide whether the agent can open them: a file
  readable by others opens to it. It resets every file in the project,
  so a directory another service uses — a Podman `:Z` volume, a directory a web
  server serves — loses the type that service needs. Keep such a directory
  outside the project.
- **Group and ACL**, default No. Yes moves each file to the agent's group
  with the project's grants: the agent gets the access its group bits give,
  and the group the file had loses it.

Which flag pre-answers which question, and what a run without a terminal does,
is on [Claim](claim.md). On an enforcing host the group question is not asked
when the relabel did not run and every file on its list is also on the relabel
list: those files would keep a type the agent is refused, so a group change
alone would share none of them. A file whose name, or whose directory inside
the project, matches your secret patterns is marked `[secret]`; accepting
either repair locks it owner-only first, so neither repair shares it.

After the claim, each file is checked again and listed on one line
with the kind and what it was before:

| Outcome | Meaning |
|---|---|
| `fixed` | the file has what the claim gives it |
| `not-fixed` | it does not — you said no, or the repair did not take |
| `unverified` | the claim could not read the file's state |
| `gone` | the file no longer exists |

A file listed under each kind opens to the agent only once it is fixed
for each; where you answered yes to one question and no to the other, the claim
says how many files that leaves closed. The exit codes those rows fold
to, and `--format tsv` for a script, are on [Claim](claim.md); the rows
themselves are
[ref-table-x8q5](../../.claude/rules/cli.rule.md#ref-table-x8q5).

Say no to the group and ACL, and keep the file as it is, when:

| The file | Example | Keep it that way with |
|---|---|---|
| is shared with a team | `you:devteam 640` on a shared host | a `!` line |
| is read by a service's group | `you:wheel`, a daemon's group | a `!` line |
| is private but not sealed | an export with your own group, `640` | `chmod 600` |

A `!` line for the file in your project registry keeps a re-claim from asking
about it again (`man 5 ai-tools-project-registry`). It does not stop a later
relabel from resetting the file's SELinux type. A `!` line, a group
and `chmod 600` each hold for a file git does not track; a file git tracks
takes the project's access again whenever git writes it.

Each question covers every file in its list. To act on only some of them,
relabel those yourself — you own them, so it does not need `sudo`:

```bash
restorecon -F ~/src/api/data/report.csv
```

For the group and ACL, `chmod 600` the files to leave out, or give them a `!`
line, then re-claim and answer yes. Both hold for a file git does not track.
A file git tracks takes the project's access again whenever git writes it
([Which files you and the agent can
run](#which-files-you-and-the-agent-can-run)), so keep such a file
in a directory you made `700`, or outside the project. The claim does not ask
about a file with no group or other bits: it leaves such a file out of both
scans. The scans, and what each question changes, are
[ref-section-a9b2](../../.claude/rules/cli.rule.md#ref-section-a9b2).

A moved-in file under a build or dependency directory (`node_modules`, `bin`,
`obj`) keeps its group: the claim does not walk those directories. The notice
names the `operator.conf` settings that open one to the claim
([Claim](claim.md)).

A file the coding agent moves in from `/tmp` comes back to you like any file it
writes, and keeps the temporary-file SELinux type until you re-claim
the project: the re-claim lists it under SELinux type, and the relabel gives it
the project's type.

## What walks the project

A walk sets each file's permissions from your own, as the tables under [Which
files you and the agent can run](#which-files-you-and-the-agent-can-run) show.
These run one:

| You run | Walks the project |
|---|---|
| `atr projects claim` on a project not claimed yet | yes |
| `atr projects create` | yes, over the new directory |
| "Claim here" on the screen a session shows in a directory not claimed yet | yes |
| `atr projects claim` on a claimed project, answering yes to the `.git` question or to a group and ACL repair | yes |
| `atr projects claim` on a claimed project with no question to ask, or where you answer no | no |
| `sudo /usr/local/libexec/ai-tools/ai-tools-setfacl <project>`, with `--with-git` to include `.git` | yes |
| a session, the handback after each write, `atr projects handback`, `lockdown`, `enable`, `disable`, `unclaim`, `remove` | no |

`--for <operator>` follows the same rows as the command without it.
