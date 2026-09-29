# List the registered projects

[Projects](index.md) · [Create](create.md) · [Claim](claim.md) ·
[Clone](clone.md) · [Push](push.md) · **List** · [Disable](disable.md) ·
[Enable](enable.md) · [Unclaim](unclaim.md) · [Remove](remove.md) ·
[Lockdown](lockdown.md) · [Handback](handback.md) ·
[Permissions](permissions.md) — [all docs](../index.md)

What `ai-tools projects list` reports about each entry in your allowlist,
the cleanup it suggests, and what it shows when run as root or for another
operator.

```bash
ai-tools projects        # the same command as: ai-tools projects list
```

Lists every registered project — claimed in place, sandbox clone, `!`-parked —
with the git `safe.directory` status of each, then a **Suggested cleanup**
section naming each inconsistent entry with the command that reconciles it:
a path that no longer exists, a project listed but not fully claimed, a glob
on an allow line (inert, since the launch gate reads an allow line as one
literal path), or a `safe.directory` entry no line in the allowlist covers. It
is read-only: every fix is a command it prints for you to run, carrying
the full path.

The command does not take an argument; one given exits 2. It does not need
`sudo`, and it stays open to an account that is not an operator, so it is
the command to read a host from.

## As root, and for another operator

Run as root it reads root's own registry, which no bootstrap creates, so it
reports an empty list and says whose registry it read, naming the enrolled
operators to run it as instead. `ai-tools projects list --for svc-ci` lists
that operator's projects: their allowlist is readable by its owner alone,
so this is the one `--for` read that asks for your `sudo` password ([Service
accounts](../operators/service-accounts.md)).

## Exit status

0 after the report, whatever it found; 2 for an argument or an unknown option.
`man ai-tools` has the full list.
