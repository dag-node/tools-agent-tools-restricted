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
([Lockdown](lockdown.md)). `ai-tools projects handback` runs the same pass
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

## What a claim leaves alone, and what does not come back

**An owner-only path is never opened**, because every walk a claim runs skips
it: a file or directory with no group and no other bits is your standing "keep
this private" signal, a sealed directory takes its whole subtree with it,
and the claim reports how many paths it left alone ([Lockdown](lockdown.md) has
the seal).

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

## Files you move into a claimed project

```bash
mv ~/Downloads/report.csv ~/src/api/data/
ai-tools projects claim ~/src/api
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

A `!` line for the file in `allowed-projects` keeps a re-claim from asking
about it again (`man 5 ai-tools-allowed-projects`). It does not stop a later
relabel from resetting the file's SELinux type.

Each question covers every file in its list. To act on only some of them,
relabel those yourself — you own them, so it does not need `sudo`:

```bash
restorecon -F ~/src/api/data/report.csv
```

For the group and ACL, `chmod 600` the files to leave out, or give them a `!`
line, then re-claim and answer yes. The claim does not ask about a file with no
group or other bits: it leaves such a file out of both scans. The scans,
and what each question changes, are
[ref-section-a9b2](../../.claude/rules/cli.rule.md#ref-section-a9b2).

A moved-in file under a build or dependency directory (`node_modules`, `bin`,
`obj`) keeps its group: the claim does not walk those directories. The notice
names the `operator.conf` settings that open one to the claim
([Claim](claim.md)).
