# Push a clone's commits

[Projects](index.md) · [Create](create.md) · [Claim](claim.md) ·
[Clone](clone.md) · **Push** · [List](list.md) · [Disable](disable.md) ·
[Enable](enable.md) · [Unclaim](unclaim.md) · [Remove](remove.md) ·
[Lockdown](lockdown.md) · [Handback](handback.md) ·
[Permissions](permissions.md) — [all docs](../index.md)

How `ai-tools projects push` sends the commits an agent made in a sandbox clone
to the branch the clone tracks, and who merges them from there.

```bash
cd /var/opt/ai-tools/sandbox-projects/repo
ai-tools projects push
```

Counts the commits the clone holds that its remote branch does not, asks
`Push N commit(s) to <remote>/<branch>?` with a default of Yes, and pushes them
to the branch the clone tracks — `sandbox/LEAF` by default, or the name given
to `--branch` when the clone was made ([Clone](clone.md)). Enter, and a run
without a terminal, push. From there, whoever has access to the repository
merges the branch back, with the agent's commits kept one by one; the remote
branch stays after a merge, and after a `projects remove` of the clone,
for others to merge.

Only you push. The sandbox account does not hold any git credentials,
so a session in the clone commits and does not reach the remote; the push is
your step, made with your credentials, and the command does not run `sudo`.

## What it refuses

It does not take an option. One given is refused with exit 2 before anything is
pushed, since the confirmation would otherwise proceed without a terminal.
A path that is not a sandbox clone — a directory outside the sandbox area,
or one inside it that is not a git working tree — is refused, so the command
does not push from a tree you did not clone with `projects clone`. It does not
take `--for`, for the reason the clone does not: a clone belongs
to the operator who made it.

## Exit status

0 when the commits are pushed or there were none; 1 when the push failed or you
declined; 2 for a rejected command line. `man ai-tools` has the full list.
