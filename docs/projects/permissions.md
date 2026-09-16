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

`ai-tools projects handback` is the on-demand form of that same pass,
for what a session left behind: the writes of a session that was killed,
and the `.git` tree the per-turn passes skip. The project stays claimed
and the agent keeps its access; only the owner on those files moves ([Project
lifecycle](index.md)).

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
