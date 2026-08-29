# Project lifecycle

How a project enters the agent's reach, what each consent prompt actually grants, and how
every path recovers or reverses. All commands run as your own user — the `ai-tools` CLI
invokes `sudo` itself where a step needs root and prompts for your password there.

```bash
ai-tools --project-create /path/to/new        # start a new project and claim it
ai-tools --project-claim /path/to/project     # work in the real tree, in place
ai-tools --sandbox-create /path/to/repo       # work in an isolated shallow clone
ai-tools --list                               # what is registered, and which model
```

| Command | Registers | Reverses |
|---|---|---|
| `--project-create` | a **new** directory it creates, then claims in place | `--project-unclaim`, or `--project-remove` to delete it too |
| `--project-claim` | the real tree, in place | `--project-unclaim` |
| `--project-remove` | nothing — **unclaims and deletes** a claimed project | — (not reversible) |
| `--sandbox-create` | a shallow clone under `/var/opt/ai-tools/sandbox-projects/` | `--sandbox-remove` |
| `--lockdown` | nothing — locks secret-named files, any time | — |
| `--reclaim [--full]` | nothing — hands agent-written files back to you | — |

Copied a claimed project somewhere else and want its permissions normalized without
registering it first? That is `--project-unclaim --force` — see
[a copy that was never unclaimed](#--force-a-copy-that-was-never-unclaimed).

## Starting a new project

```bash
ai-tools --project-create ~/src/newproject
```

This makes the directory, initializes an empty git repository in it, writes a `README.md`
naming it, and then runs the ordinary claim on the result.

It asks nothing. A tree that did not exist a moment ago has no pre-existing permissions to
warn about, no secret-named files worth a `sudo` password to scan for, and no git history to
expose — so the questions a claim asks about an existing tree are answered by the tree being
empty, not by you. The one prompt that can still appear is the traverse grant on a parent
directory, which widens access *above* the project and is never answered for you.

On a host with a restrictive `umask` (`077`, the `/etc/login.defs` default on many systems) it
also sets the modes rather than inheriting them — `0750` for the directory, `0640` for the
`README.md`, and group read/traverse on `.git` — and says so:

```text
    created /home/you/src/newproject
    modes 0750/0640 -- this host's umask (0077) would have made what this
    creates owner-only, which the claim honours as a seal and grants nothing on
```

Owner-only (`700`/`600`) is how you seal a path *away* from the agent, and the claim honours it
everywhere. But it is a statement about a file you restricted on purpose, and a umask is only a
default for every new file — so it is not read as one about a directory this command just made
for the agent to work in. To seal a path inside the project afterwards, `chmod 700` it and
re-claim; that is respected.

It creates exactly one directory. The parent has to exist already, so a mistyped path is
refused rather than quietly built:

```text
ai-tools: the parent directory does not exist: /home/you/Devlopment
```

That refusal is the point of the design. With `mkdir -p` semantics the typo above would have
created `Devlopment/`, created the project inside it, claimed it, and reported success — a
working project in a directory nobody meant to make. For the same reason the verb refuses a
path that **already** exists, naming `--project-claim` instead: claiming grants an agent
access to whatever is already in a tree, and that is not an operation to arrive at by a typo.

If the location is one the sandbox account could never reach, the create is refused **before**
anything exists, and it names an alternative only if it has checked that one on your host.

## Choosing the model

Claim in place when the agent should work your real checkout: shared files, shared git
history (opt-in), results land directly in your tree. The trade is exposure — the setgid
group and the `g:ai-tools:rwX` ACL make the whole tree agent-readable and -writable, so
everything under it is in scope once claimed. Two things stay out: paths that are
owner-only (`600`/`700`) and paths you `!`-exclude. Everything else loses world access and
gains the agent — see [what a claim and an unclaim do to
permissions](#what-a-claim-and-an-unclaim-do-to-permissions) for the exact modes.

Create a sandbox clone when the tree, its history, or its surroundings should stay out of
reach: the clone is shallow (`--depth=1`), so the agent never sees the origin's history,
and it lives under the already-isolated sandbox area, so nothing above it needs a grant.
The agent's commits go to a dedicated branch (`ai-tools/sandbox-<user>/<leaf>`) that you
push and merge back yourself — the day-to-day work cycle is documented on the host in
`/var/opt/ai-tools/README.md`.

The launch wrapper offers the same choice interactively when you run `claude` in an
unregistered directory.

## What each prompt grants

```text
Do you want to proceed? [Y/n] (default: Yes):
```

Every yes/no question states its default; Enter — and any run without a terminal — takes
it. Defaults fall on the safe side, so a question that *widens* access defaults to No and
is never auto-answered by the environment; only an explicit flag (`--project-claim -y`
for the proceed prompt, `--yes` on `ai-tools-lockdown`) pre-answers one.

A claim walks through self-contained blocks, each with its own decision:

- **Proceed confirm** (`[y/N]`) — approves exactly the pending steps the Review block
  lists: registration, the setgid group + ACL grant on the tree, the SELinux label, and
  any drift repair shown above it.
- **Secret lockdown** (`[Y/n]`) — runs before anything widens access. The scan
  (`ai-tools-lockdown --dry-run`, the first sudo prompt) matches known secret-name
  patterns; locking sets the finds to owner-only (`600`/`700`). Declining stops the claim
  — access is never granted over exposed secrets. Lockdown is best-effort pattern
  matching: handle any secret it cannot know about yourself first.
- **`.git` history** (`[Y/n]`) — normalizes `.git` so the agent reads the repo's full
  history and your own commits stay agent-accessible. Decline it to keep history hidden;
  the working tree stays claimed either way.
- **Traverse-only parents** (`[y/N]`) — when the project sits under a directory the
  sandbox account cannot enter (a `700` home), grants `u:ai-tools:--x` on each blocking
  parent you own: enter only, never list or read. It widens access *above* the project,
  hence default No.

## Re-claiming: drift and skip-lists

```bash
ai-tools --project-claim        # from inside the project; idempotent
```

A re-claim is a quiet no-op when nothing is missing, and repairs what is. Files moved
into the tree from outside (`mv` keeps their old group and inherits no ACL) surface as
*interior permission drift* — listed with owner and mode, repaired under the same proceed
confirm and secret gate as a first claim. Hits under skip-listed directory names
(`node_modules`, build output — the trees claim deliberately leaves alone) are reported
separately with their remedies:

```bash
# /etc/ai-tools/operator.conf — reopen a source dir that shares a skipped name
SKIP_ARTIFACT_DIRS_EXCLUDED_PATHS_RELATIVE="tools/bin"
```

then re-claim; or `ai-tools --reclaim --full` for ownership alone. To keep a subtree out
of the agent's reach on purpose, make it owner-only (`chmod 700`) or add a `!`-exclusion
line for it in `~/.config/ai-tools/allowed-projects` — both stop it being re-reported, and
the claim skips an owner-only path outright rather than granting it, telling you how many
it left alone.

### Sealing a path created after the claim

`chmod 700` (or `600` for a file) is all you need to do:

```bash
chmod -R go-rwx path/to/dir
```

The mode by itself would not be enough, which is why the tooling does the rest. A directory
created inside a claimed tree inherits the project's default ACL at `mkdir`, and a file is born
`660` in group `ai-tools` by setgid inheritance — grants your `chmod` *masks* but does not
remove, and a numeric `chmod` does not clear a directory's setgid bit at all. Left alone they
are dormant rather than gone, and widening the mode later would bring them back over everything
inside. So every pass over a claimed tree strips that residue from an owner-only path instead of
merely skipping it: the `group:ai-tools` ACL entries, the setgid bit, and the `ai-tools` group
owner. Nothing else is touched — your mode bits, ownership and any other ACL entry are left as
they are.

The setgid pass runs at every session start and the ACL pass at every claim, so a path you seal
is cleaned up at the next of either. To do it immediately:

```bash
ai-tools --lockdown path/to/project
```

Check the result with `getfacl -e`, which shows effective permissions; `ls -l` reports the ACL
mask in the group column, so it can read as more open than the path is.

A setgid bit set to a group that is neither `ai-tools` nor your own is taken as deliberate and
kept — the claim reports it rather than clearing it, so clear it yourself with `chmod g-s` if it
was not intended.

For a seal that does not depend on a mode at all, add a `!` exclusion for the path to
`~/.config/ai-tools/allowed-projects`: an excluded subtree is skipped by every walk whatever its
mode.

## Sandbox clones are secured before they open

```bash
ai-tools --sandbox-create /path/to/repo
```

The clone is born owner-only (`umask 077`), so checked-in credentials in the tip commit
are unreadable to the sandbox account from the first instant. The lockdown gate runs
next; only past it is the clone opened to the agent group, labelled, and registered —
with the locked paths kept private. Declining (or a failed lockdown) stops fail-closed:
the clone stays on disk, private and unregistered, with a guard `CLAUDE.md` inside.

```bash
ai-tools --sandbox-create /var/opt/ai-tools/sandbox-projects/<name>   # resume
```

Pointing `--sandbox-create` at the existing clone path resumes exactly where it stopped:
gate, then normalize + label + register, removing the guard on success.

## Recovery and reversal

```bash
ai-tools --lockdown /path/to/project    # lock secret-named files, any time
ai-tools --reclaim  /path/to/project    # hand agent-written files back to you
ai-tools --project-unclaim              # revert a claim; the directory stays on disk
```

`--lockdown` runs the same scan-and-lock on demand — after adding a credential file to a
claimed tree, or before re-running a stopped claim. `--reclaim` returns agent-written
files to `<you>:ai-tools` (including the `.git` tree the per-session sweeps skip); run it
before an ACL-unaware backup so plain ownership carries your access into the copy, and
add `--full` to include the heavy skipped trees. `--sandbox-remove` deletes a
clone and its registration, warning about unpushed commits first; the remote branch stays
for others to merge.

### Removing a project, directory and all

`--project-unclaim` reverses a claim and leaves the files. `--project-remove` does the same
**and deletes the directory**:

```bash
ai-tools --project-remove ~/src/oldproject
```

There is no undo and nothing is moved to a trash location, so the command is deliberately
hard to reach by accident. It acts only on a path with an **exact** entry in
`allowed-projects` — registration is what authorizes the deletion, and there is no `--force`
to get around that. An ancestor of claimed projects, a path *inside* one, an unregistered
path, and a project that **contains** another claimed project are each refused, the last
because deleting it would take the nested one with it and leave that project registered at a
path that no longer exists.

Before anything changes it checks that the whole tree is actually deletable by you, and
refuses if not:

```text
WARNING: this tree cannot be fully deleted
    take ownership of the tree first, then re-run the removal:
      ai-tools --reclaim --full ~/src/oldproject
```

That check exists so a removal never stops partway and leaves an unregistered fragment behind.
It also reports uncommitted changes, unpushed commits, and a repository with no upstream at
all — reported, not refused: deleting a scratch repository on purpose is legitimate.

Then it asks twice: a confirmation that defaults to **No**, and the project's name typed out.
Neither can be answered by a run with no terminal, so nothing is ever deleted unattended
unless you pass `-y` — and with `-y` a path argument is required, so an unattended removal
can never inherit the directory it happened to start in.

Teardown removes the SELinux label and both registries first and deletes last. If the
deletion fails, the project is already deregistered, so what remains is out of the agent's
reach and you can remove it by hand.

### What a claim and an unclaim do to permissions

Claiming grants the agent access through a POSIX ACL and group ownership; unclaiming takes
it back. Neither is a round trip, so it is worth seeing the actual modes before you run
either half:

| before claim | while claimed | after unclaim |
|---|---|---|
| `600`, `700` | *never opened* — sealed | *unchanged* |
| `640`, `644`, `660`, `664` | `660` | `640` |
| `750`, `755`, `775` | `770` | `750` |

Two things stand out. **Owner-only paths are never opened.** A file or directory with no
group or other bits (`600`, `700`) is your standing "keep this private" signal, and the
claim never grants it — a sealed directory takes its whole subtree with it — and strips the
sandbox residue it inherited, so the seal holds even if the mode is widened later
(*Sealing a path created after the claim*, above). This is what makes
the advice in *Recovery* below work: a `700 <you>:<you>` directory keeps the agent out,
because if the claim granted it, the raised ACL mask would give the agent write on that
directory and with it the ability to unlink what is inside. The claim reports how many
paths it left alone.

**World access is removed at claim time and never comes back.** The claim sets
`other::---` on every path it touches, so `644` becomes `660` immediately; unclaiming then
drops group write and leaves `640`. If a tree needs to stay world-readable, it is not a
candidate for an in-place claim — use a sandbox clone.

The rest of what unclaim does not restore: **every** extended ACL is cleared, including
entries that predated the claim and had nothing to do with ai-tools; directory setgid is
removed whether or not the claim set it; the group owner becomes whoever you hand the tree
to. Nothing records a tree's pre-claim state, so no command can put any of it back. **Back
up first** — that is the only real safeguard, which is why both the claim and the forced
unclaim say so before asking.

> Watching a claim with `ls -l` can mislead: a POSIX ACL shows the **mask** in the group
> bits, not the group's own permission, and the only visible hint is the trailing `+`. Use
> `getfacl -e` to see effective access.

### Which path you gave it

The path is classified against the allowlist, and the five outcomes are distinct:

| what you pointed at | what happens |
|---|---|
| a claimed project | unclaimed |
| a directory with claimed projects nested under it | they are listed, one confirm covers all, each is unclaimed outermost-first |
| a path *inside* a claimed project | refused, naming the nearest claimed parent and the command that works |
| a path the allowlist does not cover, carrying no ai-tools permissions | refused — nothing here was ever claimed |
| a path the allowlist does not cover, still carrying ai-tools permissions | reported, and `--force` offered |

### `--force`: a copy that was never unclaimed

Copy or move a claimed project (`cp -a`, `rsync -a`, `mv`, `tar -p`) and the copy carries
the ai-tools group, ACLs, and setgid bits with it — but no allowlist entry names it, so
the normal unclaim refuses. `--force` handles exactly that tree:

```bash
ai-tools --project-unclaim --force --dry-run /backup/staging/proj   # list, change nothing
ai-tools --project-unclaim --force /backup/staging/proj             # apply
```

It swaps the allowlist gate for a per-path one rather than removing a gate: a path is
touched **only** while it still carries ai-tools ownership, group, or an ai-tools ACL
entry. Run it on a directory that was never claimed and it changes nothing at all — which
is what makes a mistyped path harmless. What it does to a path it *accepts* is identical
to a normal unclaim.

It does **not** relax anything else. The protected-paths backstop still refuses system
directories and home roots; the owner guard still skips files belonging to anyone else; a
hardlinked file is still refused (its inode is reachable from outside the tree, and
`chgrp`/`chmod` act on the inode — a locally-cloned `.git` hits this in bulk and the count
is reported); secret-named and `!`-excluded paths are still skipped. On a registered
project `--force` is refused outright.

Two flags pair with it. `--full` extends the walk into the skip-listed heavy trees
(`node_modules`, `.venv`, caches), where residue survives a copy exactly as it does
elsewhere; without it those paths are reported but left alone. `--dry-run` lists every
path that would change, with ownership and mode, and changes nothing.

### Scripting it

Normalizing a copy before a backup or a deployment is the case that needs no terminal:

```bash
ai-tools --project-unclaim --force -y --group builders /backup/staging/proj
```

`-y` pre-answers the confirm — an explicit per-invocation flag, never ambient state — and
`--group` names the target group outright. Supply `--group` in any unclaim, forced or not:
without it the command asks whether to hand back and whose group to use, and a run with no
terminal quietly takes the invoking user's group. A script should say which group it means.

## Where the security boundary actually is

The allowlist (`~/.config/ai-tools/allowed-projects`) gates where sessions *launch* and
which written files get ownership handed back — it is not a read boundary. Once any
session runs, ordinary file permissions plus the SELinux `ai_tools_project_t` label are
what confine it, which is why every flow above locks secrets down *before* granting group
access, and why declining a lockdown always fails closed. The invariants live in
[`CLAUDE.md` — Security model](../CLAUDE.md#security-model--what-sandbox_user-can-and-cannot-do);
the per-component mechanism in [`.claude/rules/`](../.claude/rules/).
