# List the registered projects

[Projects](index.md) · [Create](create.md) · [Claim](claim.md) ·
[Clone](clone.md) · [Push](push.md) · **List** · [Disable](disable.md) ·
[Enable](enable.md) · [Unclaim](unclaim.md) · [Remove](remove.md) ·
[Lockdown](lockdown.md) · [Handback](handback.md) ·
[Permissions](permissions.md) — [all docs](../index.md)

What `atr projects list` reports about each line of your project registry,
the cleanup it suggests, and what it shows when run as root or for another
operator.

```bash
atr projects        # the same command as: atr projects list
```

Lists every line of the registry by its kind, the word in the first column:
a project (`@`), `project` when claimed in place and `sandbox` for a sandbox
clone; a `disabled` project (`%`), with the `atr projects enable` that
restores it; and an excluded path (`!`), `exclude`. Each project and disabled
project carries its git `safe.directory` status. A **Suggested cleanup**
section follows, naming each inconsistent line with the command that
reconciles it: a path that no longer exists, a project listed but not fully
claimed, or a `safe.directory` entry for a tree of yours that no line in the
registry covers. It is read-only: every fix is a command it prints for you to
run, carrying the full path.

Every operator's claims write into one host-wide `safe.directory` list, so
an entry for a tree you do not own, or under a directory you cannot enter,
is counted in one closing line rather than listed: the owner's own
`atr projects` reports it. An entry for a tree the sandbox account holds is
named with its removal, to run only if the tree is yours: a claim accepts
that owner for any operator, so no listing can attribute it. A trust rule,
`*` or a directory followed by `/*`, is named with no removal, since removing
it stops git trusting every repository under it. A path git expands from
a leading `~` or `%(prefix)/`, and any other value that is not an absolute
path, is named the same way. A registry line under
a directory you cannot enter is named as one the command cannot read, without
a removal.

A registry the grammar refuses is not listed: the command prints the line
the grammar refuses and exits 1, as every other `projects` command does
over that file. The `~/.config/ai-tools/allowed-projects` an earlier release
wrote is listed under a line naming `atr admin system post-upgrade`, with every
`!` line read as an excluded path.

The command does not take an argument; one given exits 2. It does not need
`sudo`, and it stays open to an account that is not an operator, so it is
the command to read a host from.

## As root, and for another operator

Run as root it reads root's own registry, which no bootstrap creates, so it
reports an empty list and says whose registry it read, naming the enrolled
operators to run it as instead. `atr projects list --for svc-ci` lists
that operator's projects: their registry is readable by its owner alone,
so this is the one `--for` read that asks for your `sudo` password ([Service
accounts](../operators/service-accounts.md)). An account without a `sudo`
grant for that read is refused before the password prompt. The removal it
prints for a stale project line edits that operator's registry for you:

```bash
sudo /usr/local/libexec/ai-tools/ai-tools-allowlist --operator svc-ci --remove DIRECTORY
```

## Exit status

0 after the report, whatever it found; 1 for a registry the grammar refuses; 2
for an argument or an unknown option. `man ai-tools` has the full list.
