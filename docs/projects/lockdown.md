# Lock secrets away

[Projects](index.md) · [Create](create.md) · [Claim](claim.md) ·
[Clone](clone.md) · [Push](push.md) · [List](list.md) · [Disable](disable.md) ·
[Enable](enable.md) · [Unclaim](unclaim.md) · [Remove](remove.md) ·
**Lockdown** · [Handback](handback.md) · [Permissions](permissions.md) — [all
docs](../index.md)

How a secret-named file is kept out of the agent's reach, when the scan
that finds one runs on its own, and what the pattern set can and cannot
recognize.

```bash
ai-tools projects lockdown ~/src/api   # scan for secret-named files and lock what it finds
```

Lists every file under the project whose name matches a secret pattern, asks
`Lock down these secrets now?` (default Yes), and makes each one yours alone,
which takes the agent's read away. It runs through `sudo` and asks before it
changes a file. Run it after adding a credential file to a claimed tree,
or before re-running a claim that stopped.

## A secret-named file is locked, not shared

A file whose name matches a known secret pattern — `.env`, `*.key`, `*.pem`,
SSH private keys, `kubeconfig`, and the rest of the shipped set — is treated
apart from every other file in a claimed tree. Where the agent writes one,
the handback locks it to you alone rather than returning it to the shared
ownership every other file gets ([Permissions](permissions.md)),
and the session and the operation log each record that it did.

The same scan runs **before** a claim or a clone grants anything, as the first
`sudo` prompt of the run, and declining it stops the command, so access is
never granted over exposed secrets. The gate is
[ref-section-u5h3](../../.claude/rules/cli.rule.md#ref-section-u5h3).

## What the walk covers

The walk enters the heavy trees a claim's own walks skip — `node_modules`,
`.venv`, caches — since a secret under one of them is otherwise reachable
through the tree's own permissions. Under `.git` it skips `objects`, `refs`
and `logs`, the subtrees git names itself and where no file lands
by an operator's choice, and walks the rest, where a hook template or a resumed
clone puts an operator-written file such as `hooks/deploy.pem`. The walk is
[ref-section-g6s6](../../.claude/rules/secret-handling.rule.md#ref-section-g6s6).

```bash
ai-tools projects lockdown --dry-run ~/src/api
```

`--dry-run` names every path the lockdown would lock, and what it would strip
from the paths you have already sealed by mode, and does not change a file.
`-y` skips the confirmation; beside `--dry-run` it is refused with exit 2,
since a dry run neither changes a path nor asks.

## Sealing a path by mode

```bash
chmod -R go-rwx path/to/dir
ai-tools projects lockdown path/to/project   # apply the seal's cleanup now
```

A path with no group and no other bits — a file or directory only you can open
— is your standing "keep this private" signal, and every command here honours
it: a claim does not open it, a sealed directory takes its whole subtree
with it, and the claim reports how many paths it left alone. The seal holds
even if you widen the mode again later, because each pass over the tree also
strips what the path inherited from the claimed tree around it;
`projects lockdown` runs that pass at once instead of at the next claim
or session start. Check the result with `getfacl -e path`, which shows
effective access. What the seal is, and what a pass strips, is
[ref-definition-e3h3](../../.claude/rules/secret-handling.rule.md#ref-definition-e3h3).

Two things to know:

- A setgid bit set to some third group is taken as deliberate and kept.
  The claim reports it rather than clearing it; clear it with `chmod g-s` if it
  was not intended.
- For a seal that does not depend on a mode at all, add a `!` line for the path
  to `~/.config/ai-tools/allowed-projects`. An excluded subtree is skipped
  by every walk whatever its mode.

## What the patterns do not cover

Matching is on **names**, not contents, and the shipped list is a baseline
of the credential names software writes in general. A secret under a name
the list does not know is yours to handle first: make it owner-only,
which a claim then leaves alone, or `!`-exclude it from your allowlist,
which every walk skips whatever its mode.

Your own list lives at `~/.config/ai-tools/secret-patterns` and **replaces**
the baseline rather than adding to it, so a file written once holds this host
to the set it named then. Each launch records the difference to journald,
naming the baseline patterns your file drops. The file's grammar and the full
baseline are in `man 5 ai-tools-secret-patterns`.

## Git history is a separate exposure

A credential committed years ago and since removed is invisible in the working
tree and one `git show` away for anything that can read `.git`, which is
what a claim's `.git` question ([Claim](claim.md)) and the shallow clone
([Clone](clone.md)) answer.

## Exit status

0 when the files are locked or none matched; 2 for a rejected command line
(`-y` with `--dry-run`); 3 when the path is a protected system directory
or a home root; 6 when you declined, with no file changed. `man ai-tools` has
the full list.
