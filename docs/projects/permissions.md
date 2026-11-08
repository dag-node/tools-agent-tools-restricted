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

A secret-named file comes back yours alone ([Lockdown](lockdown.md)).
`atr projects handback` runs the same pass on demand, for what a killed session
left behind ([Handback](handback.md)).

## You and the agent co-write one tree

A claim writes two grants on the project, and the pair is what makes a shared
tree work without either side joining the other's group: one gives the agent
access to the files **you** write, and the other gives you access to the files
**the agent** writes.

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
([Lockdown](lockdown.md) has the seal).

**World access is removed at claim time and does not come back.** A claim
closes other-access on every path it touches, and an unclaim then drops
the agent's write without restoring the world's read. A tree that needs to stay
world-readable is not a candidate for a claim in place — use a sandbox clone
([Clone](clone.md)).

Watching a claim with `ls -l` can mislead: with an ACL on a path, the group
column shows the ACL **mask**, and the only visible hint that an ACL exists is
the trailing `+`. Use `getfacl -e` to see effective access.

## Which files you and the agent can run

```bash
chmod ug+x scripts/build.sh   # you and the agent can run it
chmod g-x scripts/build.sh    # only you can, until a claim walks the project
ls -l scripts/build.sh        # -rwxrwx---+ : the group column is the agent's
```

A claim sets the group column from your own permissions on the file,
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

A *walk* is a claim that applies the project's permissions again to every file
([What walks the project](#what-walks-the-project)). The usual cases:

| You want | Run | Mode | The agent | After unclaim |
|---|---|---|---|---|
| you and the agent edit it | — (a file you create), or `chmod ug-x` | `660` | read, write | `640` |
| you and the agent run it | `chmod ug+x`, or commit it as `100755` | `770` | read, write, run | `750`; `740` for a file that was a data file before the claim |
| the agent cannot reach a file | `chmod 600` | `600` | no access | `600` |
| the agent cannot reach a directory | `chmod 700` | `700` | no access to it or anything inside | `700` |

Every other case — a file a program creates, `chmod g-x` and `g+x`, read-only
files and a sticky directory, a numeric mode, and what a later walk changes —
is
[ref-table-b5v7](../../.claude/rules/ownership-and-hooks.rule.md#ref-table-b5v7).
Use the symbolic form: a numeric mode replaces the agent's access with its
middle digit.

Git keeps one permission bit per file, whether you can run it. A checkout,
a pull or a branch switch that changes a tracked file writes it as a new file,
so the file takes the access the table gives from that bit: `770` for a file
committed as `100755`, and `660` for one committed without it, whatever `chmod`
you made since.

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
  and the group the file had loses it. No leaves each file as it is,
  through every step of the claim, the `.git` share among them.

Say no to the group and ACL, and keep the file as it is, when:

| The file | Example | Keep it that way with |
|---|---|---|
| is shared with a team | `you:devteam 640` on a shared host | a `!` line |
| is read by a service's group | `you:wheel`, a daemon's group | a `!` line |
| is private but not sealed | an export with your own group, `640` | `chmod 600` |

A `!` line for the file in your project registry keeps a re-claim from asking
about it again (`man 5 ai-tools-project-registry`). It does not stop a later
relabel from resetting the file's SELinux type.

Each question covers every file in its list. To act on only some of them,
relabel those yourself — you own them, so it does not need `sudo`:

```bash
restorecon -F ~/src/api/data/report.csv
```

For the group and ACL, `chmod 600` the files to leave out, or give them a `!`
line, then re-claim and answer yes.

## What walks the project

A walk sets each file's permissions from your own, as the table under [Which
files you and the agent can run](#which-files-you-and-the-agent-can-run) shows.

| You run | Walks the project? |
|---|---|
| `atr projects create` | yes |
| `atr projects claim` on an unclaimed project | yes |
| "Claim here" on the screen a session shows in an unclaimed directory | yes |
| `atr projects claim` on a claimed project | only where you answer yes to the `.git` question or to a group and ACL repair, or apply the pending step for *ACL entries from an earlier claim*; `-y` applies that step and answers neither question |

No other command walks the project: not a session or the handback after each
write, and not `atr projects handback`, `lockdown`, `enable`, `disable`,
`unclaim` or `remove`. `--for <operator>` follows the same rows as the command
without it.
