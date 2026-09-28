# Ownership and shared access

[Projects](index.md) · **Permissions** · [Lockdown](lockdown.md) — [all
docs](../index.md)

What owns a file the agent wrote, how you and the agent both keep write access
to one tree without joining each other's groups, and what a claim leaves alone.

```bash
ls -l  ~/src/api/newfile.go   # you own it; the sandbox account reads it through the group
getfacl -e ~/src/api          # the two grants a claim writes, and their effective access
```

## Files the agent writes come back to you

A file the agent creates is born owned by the sandbox account. Getting it back
is not a command you run: the agent's lifecycle hooks offer each written path
to a root helper as the session goes — per tool call and per turn —
and the helper restores it to `<you>:ai-tools`, so you reach it
through the owner bits and the agent keeps reading it through the group bits.
World access is removed on the way. Directories the agent created while writing
are restored with it, keeping group `rwx`; a directory that was already yours
is left alone.

The restore happens inside claimed paths only, and acts on a path only while
the sandbox account still owns it — the state an agent write leaves behind —
so a file you wrote yourself, which you already own, is not a path it acts on.
A secret-named file is the one exception, and goes to you alone
([Lockdown](lockdown.md)).

`ai-tools projects handback` runs that same pass on demand, for what a killed
session left behind ([Project lifecycle](index.md)).

## You and the agent co-write one tree

A claim writes two POSIX ACL entries on the project, and the pair is what makes
a shared tree work without either side joining the other's group:

- `g:ai-tools:rwX` grants the agent access to the files **you** write.
- `user:<you>:rwX` grants you access to the files **the agent** writes.

Each entry is umask-independent, so a file's access does not depend
on which side created it or on what either account's umask was at the time.
World access stays closed. You stay out of the sandbox group and the sandbox
account stays out of yours, which keeps each side to one permission tier:
the operator does not gain blanket read of the agent's own session state,
and the grant does not depend on the ownership hand-back having run yet.

The entries are applied at `ai-tools projects claim`, which **skips owner-only
paths**. A file or directory with no group and no other bits (`600`, `700`) is
your standing "keep this private" signal, so the claim leaves it alone —
a sealed directory takes its whole subtree with it — and reports how many paths
it left that way.

What each mode becomes at a claim and after an unclaim is in [Project
lifecycle](index.md), with the caveat that `ls -l` shows the ACL **mask**
in the group column: use `getfacl -e` to read effective access.

## Files you move into a claimed project

```bash
mv ~/Downloads/report.csv ~/src/api/data/
ai-tools projects claim ~/src/api
```

A file you move in keeps what it had where it came from: its group, its mode
and its SELinux type. A file created inside the project takes the project's
instead. A re-claim finds the moved-in files and asks about each kind on its
own, right under the list of files it found:

- **SELinux type**, default yes. The relabel gives the files the project's
  type, and their permissions still decide whether the agent can open them. It
  resets every file in the project, so a directory another service uses —
  a Podman `:Z` volume, a directory a web server serves — loses the type
  that service needs. Keep such a directory outside the project. A claim run
  without a terminal, from cron or a systemd unit, relabels only with `-y`.
- **Group and ACL**, default no. Yes moves each file to the `ai-tools` group
  with the project ACL: the agent gets the access its group bits grant,
  and the group the file had loses it.

After the claim, each file is checked again and listed on one line
with the kind and what it was before:

| Outcome | Meaning |
|---|---|
| `fixed` | the file now has what the claim gives it |
| `not-fixed` | it does not — you said no, or the repair did not take |
| `unverified` | the claim could not read the file's state |
| `gone` | the file no longer exists |

The claim exits 4 when a file is left `not-fixed` and 5 when one is
`unverified`, so a script can tell a clean claim from one that left work.
`ai-tools projects claim --format tsv` writes the same outcomes as a record
stream (`man 5 ai-tools-records`) for a script to read.

The agent can open a file listed under each kind only once it is fixed
for each; where you answered yes to one question and no to the other, the claim
says how many files that leaves closed.

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
relabel those yourself — you own them, so it does not need sudo:

```bash
restorecon -F ~/src/api/data/report.csv
```

For the group and ACL, `chmod 600` the files to leave out, or give them a `!`
line, then re-claim and answer yes. The claim does not ask about a file with no
group or other bits (`600`, `700`): it leaves such a file out of both scans.

A moved-in file under a build or dependency directory (`node_modules`, `bin`,
`obj`) keeps its group: the claim does not walk those directories. The notice
names the `operator.conf` settings that open one to the claim.
