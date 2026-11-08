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
atr projects lockdown ~/src/api   # scan for secret-named files and lock what it finds
```

Lists every file under the project whose name matches a secret pattern, asks
`Lock down these secrets now?` (default Yes), and makes each one yours alone,
which takes the agent's read away. It runs through `sudo` and asks before it
changes a file. Run it after adding a credential file to a claimed tree,
or before re-running a claim that stopped. Without a directory it acts
on the project the current directory is in, named on its first line.

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
atr projects lockdown --dry-run ~/src/api
```

`--dry-run` names every path the lockdown would lock, and what it would strip
from the paths you have already sealed by mode, and does not change a file.
`-y` skips the confirmation; beside `--dry-run` it is refused with exit 2,
since a dry run neither changes a path nor asks.

## Sealing a path by mode

```bash
chmod -R go-rwx path/to/dir
atr projects lockdown path/to/project   # apply the seal's cleanup now
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
- To keep the claim's permission walks and the hand-back out of a subtree
  whatever its mode, add an excluded line, `!` and the path,
  to `~/.config/ai-tools/project-registry`; the label step still types it,
  and `man 5 ai-tools-project-registry` states what the line does not take
  back.

## What the patterns do not cover

Matching is on **names**, not contents, and the shipped list is a baseline
of the credential names software writes in general. A secret under a name
the list does not know is yours to handle first: make it owner-only,
which a claim then leaves alone, or exclude it with a `!` line in your project
registry, which the hand-back and the claim's permission walks skip whatever
its mode.

Your own list lives at `~/.config/ai-tools/secret-patterns` and **replaces**
the baseline rather than adding to it, so a file written once holds this host
to the set it named then. Each launch records the difference to journald,
naming the baseline patterns your file drops. The file's grammar and the full
baseline are in `man 5 ai-tools-secret-patterns`.

## A matched file the agent must read

```bash
cd ~/src/api
cat appsettings.Development.json   # read what the agent would read
printf '!%s\n' "$(realpath appsettings.Development.json)" \
    "$(realpath -m bin/Debug/net10.0/appsettings.Development.json)" \
    >> ~/.config/ai-tools/secret-patterns
```

A pattern also matches some files a build or a run reads. A web project's
`appsettings.Development.json` is one: `dotnet build` copies it into `bin/`,
and the app reads that copy when it starts in Development, so with either file
locked both fail inside a session with `Access to the path … is denied`.

Keep such a file open only after reading it. What the agent reads can reach
the model provider with its requests, so the file should hold only settings you
are content to send there; keep a password or a key in user secrets
or an environment variable instead. The line in your secret-patterns file, `!`
and a full path as `realpath` prints it, keeps that one path open whichever
patterns are in force, and does not cover a path inside it. A copy a build
writes is matched at its own path, so name each output path the session's
builds write to as well: `bin/Release/…` for a Release build, another directory
for another target framework. The line names the path, not what the file holds:
a credential written into the file later is not locked. A line that does not
name a full path, or that carries `*`, `?` or `[`, is ignored and reported,
and the file stays locked.

The baseline itself leaves open a few paths that a package or a project
template ships under a matching name, such as the `private` source directories
of Angular's build packages and an Angular project's
`src/environments/environment.prod.ts`; `man 5 ai-tools-secret-patterns` lists
them. A secret-patterns file of your own with a pattern line replaces those
along with the baseline.

A path a claim or a lockdown has already locked stays locked when you add
a line, and so does one the baseline now leaves open, such as an Angular
`private` directory an earlier release locked to `700`. Review each one
and open it yourself, a directory without `-R` so a secret locked inside it
stays locked. You are not in the `ai-tools` group, so the group change takes
`sudo`. `getfacl -e` shows the access the agent then has. The next claim, clone
or lockdown leaves a path the baseline exempts open while the baseline is
in force, leaves any path open while a `!` line in your secret-patterns file
names it, and locks it again otherwise. A copy a build wrote under `bin/`
or `obj/` before the `!` line stays locked, and a copy the session's build
writes once the line names its path is handed back open.

```bash
sudo chgrp ai-tools appsettings.Development.json
chmod 660 appsettings.Development.json
find ~/src/web -type d -perm 700 -user "$USER" \
    \( -path '*/node_modules/@angular/build/private' \
    -o -path '*/node_modules/@angular/material/core/tokens' \
    -o -path '*/node_modules/@angular/material/core/density/private' \)
sudo chgrp ai-tools ~/src/web/node_modules/@angular/build/private   # each one listed
chmod 770 ~/src/web/node_modules/@angular/build/private
getfacl -e ~/src/web/node_modules/@angular/build/private
```

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
