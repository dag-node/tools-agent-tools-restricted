# Project lifecycle

How a project enters the agent's reach, what each prompt grants, and how every step reverses.
Run every command as your own user: the `ai-tools` CLI calls `sudo` itself for the steps that
need root and prompts for your password there.

```bash
ai-tools --project-create ~/src/newproject    # make a new project and claim it
ai-tools --project-claim  ~/src/existing      # claim a tree you already have, in place
ai-tools --sandbox-create ~/src/repo          # work in an isolated shallow clone instead
ai-tools --list                               # what is registered, and under which model
```

A project moves through four states, and one command moves it between each pair:

```
   (nothing)  --project-create-->  claimed  --project-disable-->  disabled
                --project-claim-->          <--project-enable---
                                      |
                    --project-unclaim | --project-remove
                                      v
                       registered no more (files kept / files deleted)
```

| Command | What it does | How to reverse it |
|---|---|---|
| `--project-create <path>` | creates a directory, `git init`s it, claims it | `--project-unclaim`, or `--project-remove` |
| `--project-claim [path]` | claims a tree in place | `--project-unclaim` |
| `--project-disable [path]` | parks a claimed project: no session may start in it | `--project-enable` |
| `--project-unclaim [path]` | hands the files back; the directory stays | re-claim it |
| `--project-remove [path]` | hands back, then **deletes the directory** | — |
| `--sandbox-create [path]` | shallow-clones a repo into the sandbox area | `--sandbox-remove` |
| `--lockdown [path]` | locks secret-named files, any time | — |
| `--reclaim [--full] [path]` | hands agent-written files back to you | — |

## Choose a model first

**Claim in place** when the agent should work your real checkout: shared files, shared git
history (opt-in), results land directly in your tree. The trade is exposure — the setgid group
and the `g:ai-tools:rwX` ACL make the whole tree agent-readable and -writable, so everything
under it is in scope once claimed. Two things stay out: paths that are owner-only (`600`/`700`)
and paths you `!`-exclude. Everything else loses world access and gains the agent; the exact
modes are in [what a claim and an unclaim do to permissions](#what-a-claim-and-an-unclaim-do-to-permissions).

**Create a sandbox clone** when the tree, its history, or its surroundings should stay out of
reach: the clone is shallow (`--depth=1`), so the agent never sees the origin's history, and it
lives under the already-isolated sandbox area, so nothing above it needs a grant. The agent's
commits go to a dedicated branch you push and merge back yourself.

Running `claude` in an unregistered directory offers the same choice interactively.

## Start a new project

```bash
ai-tools --project-create ~/src/newproject
```

Creates the directory, initializes an empty git repository in it, writes a `README.md` naming
it, then runs the ordinary claim on the result.

It asks nothing. A tree that did not exist a moment ago has no pre-existing permissions to warn
about, no secret-named files worth a `sudo` password to scan for, and no git history to expose,
so the questions a claim asks about an existing tree are answered by the tree being empty. The
one prompt that can still appear is the traverse grant on a parent directory, which widens
access *above* the project.

On a host with a restrictive `umask` (`077`, the `/etc/login.defs` default on many systems) it
sets the modes rather than inheriting them — `0750` for the directory, `0640` for the
`README.md`, group read and traverse on `.git` — and says so:

```text
    created /home/you/src/newproject
    modes 0750/0640 -- this host's umask (0077) would have made what this
    creates owner-only, which the claim honours as a seal and grants nothing on
```

Owner-only (`700`/`600`) is how you seal a path *away* from the agent, and the claim honours it
everywhere. It is a statement about a file you restricted on purpose, while a umask is a default
for every new file — so it is not read as one about a directory this command just made for the
agent to work in. To seal a path inside the project afterwards, `chmod 700` it and re-claim.

It creates exactly one directory, and the parent has to exist:

```text
ai-tools: the parent directory does not exist: /home/you/Devlopment
```

With `mkdir -p` semantics that typo would have created `Devlopment/`, put the project inside it,
claimed it, and reported success — a working project in a directory nobody meant to make. The
verb refuses a path that **already** exists for the same reason, naming `--project-claim`
instead: claiming grants an agent access to whatever is already in a tree, which is not an
operation to arrive at by a typo.

A location the sandbox account could never reach is refused **before** anything exists.

## Claim a project you already have

```bash
cd ~/src/existing
ai-tools --project-claim
```

Registers the tree, sets group `ai-tools` and the setgid bit on its directories, applies the
`g:ai-tools:rwX` ACL, pins repo-local `core.filemode=true`, and applies the SELinux
`ai_tools_project_t` label. It runs only the steps that are missing, so a re-claim is a quiet
no-op.

### What each prompt grants

```text
Do you want to proceed? [Y/n] (default: Yes):
```

Every yes/no question states its default; Enter — and any run without a terminal — takes it.
Defaults fall on the safe side, so a question that *widens* access defaults to No and is never
auto-answered by the environment. Only an explicit flag (`--project-claim -y` for the proceed
prompt, `--yes` on `ai-tools-lockdown`) pre-answers one.

A claim walks through self-contained blocks, each with its own decision:

- **Proceed confirm** (`[y/N]`) — approves exactly the pending steps the Review block lists:
  registration, the setgid group and ACL grant, the SELinux label, and any drift repair shown
  above it.
- **Secret lockdown** (`[Y/n]`) — runs before anything widens access. The scan
  (`ai-tools-lockdown --dry-run`, the first sudo prompt) matches known secret-name patterns;
  locking sets the finds to owner-only. Declining stops the claim, so access is never granted
  over exposed secrets. Pattern matching is best-effort: handle any secret it cannot know about
  yourself first.
- **`.git` history** (`[Y/n]`) — normalizes `.git` so the agent reads the repository's full
  history and your own commits stay agent-accessible. Decline it to keep history hidden; the
  working tree stays claimed either way.
- **Traverse-only parents** (`[y/N]`) — where the project sits under a directory the sandbox
  account cannot enter (a `700` home), grants `u:ai-tools:--x` on each blocking parent you own:
  enter only, never list or read. It widens access above the project, hence the No default.

### Re-claiming: drift and skip-lists

```bash
ai-tools --project-claim        # from inside the project; idempotent
```

A re-claim repairs what is missing. Files moved into the tree from outside (`mv` keeps their old
group and inherits no ACL) surface as *interior permission drift* — listed with owner and mode,
repaired under the same proceed confirm and secret gate as a first claim. Hits under skip-listed
directory names (`node_modules`, build output — the trees a claim deliberately leaves alone) are
reported separately with their remedies:

```bash
# /etc/ai-tools/operator.conf -- reopen a source dir that shares a skipped name
SKIP_ARTIFACT_DIRS_EXCLUDED_PATHS_RELATIVE="tools/bin"
```

then re-claim; or `ai-tools --reclaim --full` for ownership alone. To keep a subtree out of the
agent's reach on purpose, make it owner-only (`chmod 700`) or add a `!`-exclusion line for it in
`~/.config/ai-tools/allowed-projects`. Both stop it being re-reported, and the claim skips an
owner-only path outright rather than granting it, telling you how many it left alone.

### Sealing a path created after the claim

```bash
chmod -R go-rwx path/to/dir
```

The mode by itself would not be enough, which is why the tooling does the rest. A directory
created inside a claimed tree inherits the project's default ACL at `mkdir`, and a file is born
`660` in group `ai-tools` by setgid inheritance — grants your `chmod` *masks* but does not
remove, and a numeric `chmod` does not clear a directory's setgid bit at all. Left alone they
are dormant rather than gone, and widening the mode later would bring them back over everything
inside. So every pass over a claimed tree strips that residue from an owner-only path: the
`group:ai-tools` ACL entries, the setgid bit, and the `ai-tools` group owner. Your mode bits,
ownership and any other ACL entry are left as they are.

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

## Work in a sandbox clone

```bash
ai-tools --sandbox-create ~/src/repo
```

The clone is born owner-only (`umask 077`), so checked-in credentials in the tip commit are
unreadable to the sandbox account from the first instant. The lockdown gate runs next; only past
it is the clone opened to the agent group, labelled, and registered, with the locked paths kept
private. Declining, or a failed lockdown, stops fail-closed: the clone stays on disk, private
and unregistered, with a guard `CLAUDE.md` inside.

```bash
ai-tools --sandbox-create /var/opt/ai-tools/sandbox-projects/<name>   # resume
```

Pointing `--sandbox-create` at the existing clone path resumes where it stopped: gate, then
normalize, label and register, removing the guard on success. The day-to-day cycle — the
per-repo branch, pushing it, merging it back — is documented on the host in
`/var/opt/ai-tools/README.md`.

## Take a project out of service

```bash
ai-tools --project-disable ~/src/api    # park it: no session may start here
ai-tools --project-enable  ~/src/api    # put it back
```

Both edit **your line, in place**. The entry keeps its position and its end-of-line comment, so
an `allowed-projects` you maintain as an ordered, documented file comes back exactly as it was:

```text
# projects
  /home/you/src/api   # payments, dev stage      ->    !/home/you/src/api   # payments, dev stage
  /home/you/src/web                                     /home/you/src/web
```

Disabling changes the registry and nothing else: the group, the ACLs, the setgid bits and the
SELinux label all stay, so re-enabling grants nothing that was not already granted and neither
command runs a secret scan. Prefixing the line with `!` by hand does the same thing — the verbs
make the edit the file has always supported.

One consequence is worth knowing before you park a project a session is still writing to: while
it is disabled the **ownership handback stops restoring files** written under it, because the
root helpers resolve a path's owner through the same allowlist. Stop the session first, or
re-enable and run `ai-tools --reclaim` afterwards.

Two refusals keep a `!` line unambiguous:

- `--project-enable` refuses an exclusion **inside** a claimed project. That line is a
  *carve-out* — a subtree you withheld from the agent — and lifting it would hand that subtree
  over. Delete it yourself if that is what you mean.
- `--project-disable` refuses a project **nested inside** another claimed project, because the
  line it would write could not later be told apart from such a carve-out. Unclaim the nested
  project, or park the one above it.

Launching in a parked project refuses and names the way back:

```text
claude: /home/you/src/api: this project is disabled in your approved projects list
claude: re-enable it with:  ai-tools --project-enable
```

## Release a project

```bash
ai-tools --project-unclaim ~/src/api
```

Reverts the SELinux label, drops both registries, and — behind its own confirm — hands the tree
back to your group with the agent's write removed. The directory stays on disk.

The path is classified against the allowlist first, and the five outcomes are distinct:

| what you pointed at | what happens |
|---|---|
| a claimed project | unclaimed |
| a directory with claimed projects nested under it | they are listed, one confirm covers all, each is unclaimed outermost-first |
| a path *inside* a claimed project | refused, naming the nearest claimed parent and the command that works |
| a path the allowlist does not cover, carrying no ai-tools permissions | refused — nothing here was ever claimed |
| a path the allowlist does not cover, still carrying ai-tools permissions | reported, and `--force` offered |

### Keeping your place across a release

```bash
ai-tools --project-unclaim --keep-entry ~/src/api   # files handed back; the line stays, parked
# ... release ...
ai-tools --project-claim ~/src/api                  # offers to re-enable it, in place
```

A common rhythm is to unclaim before a production release, so the tree carries clean ordinary
permissions, then claim again for the next development stage. A plain unclaim deletes the line,
so the later claim appends a new one at the end of the file; `--keep-entry` parks it instead.

The claim then finds the parked entry, shows it, and asks (default **No**) whether to re-enable
it before claiming — it never appends a second line over an exclusion that would go on winning.
Answer yes and the project is claimed again with its line, and its comment, where they were.

### A copy that was never unclaimed

```bash
ai-tools --project-unclaim --force --dry-run /backup/staging/proj   # list, change nothing
ai-tools --project-unclaim --force /backup/staging/proj             # apply
```

Copy or move a claimed project (`cp -a`, `rsync -a`, `mv`, `tar -p`) and the copy carries the
ai-tools group, ACLs, and setgid bits with it, while no allowlist entry names it — so the normal
unclaim refuses. `--force` handles exactly that tree.

It swaps the allowlist gate for a per-path one rather than removing a gate: a path is touched
**only** while it still carries ai-tools ownership, group, or an ai-tools ACL entry. Run it on a
directory that was never claimed and it changes nothing at all, which is what makes a mistyped
path harmless. What it does to a path it *accepts* is identical to a normal unclaim.

It relaxes nothing else. The protected-paths backstop still refuses system directories and home
roots; the owner guard still skips files belonging to anyone else; a hardlinked file is still
refused (its inode is reachable from outside the tree, and `chgrp`/`chmod` act on the inode — a
locally-cloned `.git` hits this in bulk, and the count is reported); secret-named and
`!`-excluded paths are still skipped. On a registered project `--force` is refused outright.

Two flags pair with it. `--full` extends the walk into the skip-listed heavy trees
(`node_modules`, `.venv`, caches), where residue survives a copy exactly as it does elsewhere;
without it those paths are reported and left alone. `--dry-run` lists every path that would
change, with ownership and mode, and changes nothing.

### Scripting an unclaim

```bash
ai-tools --project-unclaim --force -y --group builders /backup/staging/proj
```

Normalizing a copy before a backup or a deployment is the case that needs no terminal. `-y`
pre-answers the confirm — an explicit per-invocation flag, never ambient state — and `--group`
names the target group outright. Supply `--group` in any unclaim, forced or not: without it the
command asks whether to hand back and whose group to use, and a run with no terminal takes the
invoking user's group. A script should say which group it means.

## Delete a project

```bash
ai-tools --project-remove ~/src/oldproject
```

Does what an unclaim does **and deletes the directory**. There is no undo and nothing is moved
to a trash location, so the command is deliberately hard to reach by accident.

It acts only on a path with an **exact** entry in `allowed-projects` — registration is what
authorizes the deletion, and there is no `--force` to get around that. A parked (`!`) entry
counts, since it records "not right now" rather than "not mine", and you get one extra
confirmation naming that state. An ancestor of claimed projects, a path *inside* one, an
unregistered path, and a project that **contains** another claimed project are each refused —
the last because deleting it would take the nested one with it and leave that project registered
at a path that no longer exists.

Before anything changes it checks that the whole tree is deletable by you:

```text
WARNING: this tree cannot be fully deleted
    take ownership of the tree first, then re-run the removal:
      ai-tools --reclaim --full ~/src/oldproject
```

That check keeps a removal from stopping partway and leaving an unregistered fragment behind. It
also reports uncommitted changes, unpushed commits, and a repository with no upstream at all —
reported rather than refused, since deleting a scratch repository on purpose is legitimate.

Then it asks twice: a confirmation that defaults to **No**, and the project's name typed out.
Neither can be answered by a run with no terminal, so nothing is deleted unattended unless you
pass `-y` — and with `-y` a path argument is required, so an unattended removal cannot inherit
the directory it happened to start in.

Teardown removes the SELinux label and both registries first and deletes last. If the deletion
fails, the project is already deregistered, so what remains is out of the agent's reach and you
can remove it by hand.

## Claim for another operator

```bash
ai-tools --project-claim --for svc-ci /srv/projects/api
```

A service account that runs an agent usually has no password, so it cannot authenticate the root
helpers a claim needs — and a claim performed by a human lands in the *human's* registry, which
is not the one that account's launch gate reads. `--for` closes both: the allowlist entry goes
into `svc-ci`'s registry, so `ai-tools-setfacl` grants `user:svc-ci`, the ownership handback
restores files to them, and their agent may launch there. You run it once; that account never
meets a password prompt.

It applies to `--project-claim`, `--project-create`, `--project-unclaim`, `--project-remove`,
`--project-enable`, `--project-disable`, `--lockdown`, `--reclaim` and `--list`, and is refused —
rather than ignored — on anything else.

### Two verbs also act as that operator

`--project-create` and `--project-remove` write the **filesystem** as the operator they act for,
not just a registry: the create makes the tree so that account owns it, and the remove deletes a
tree only its owner can delete. Both therefore need permission for **you** to act as that
account (`sudo -u svc-ci`), which is a separate sudoers question from the `ai-tools-*` helper
grants. A host can grant every helper and still restrict which accounts you may become, so the
check runs before anything is created:

```text
ai-tools: --project-create --for svc-ci acts on the filesystem AS svc-ci, and you hold no
sudo grant to run mkdir as that account.

  Run it as svc-ci, or create the project without --for and hand it over:

    ai-tools --project-create /srv/projects/api
    sudo chown -R svc-ci /srv/projects/api
    ai-tools --project-claim --for svc-ci /srv/projects/api
```

Ownership carries weight here: the two helpers that grant the agent its access act only on paths
held by the resolved operator or the sandbox account, so a claim *for* an operator over a tree
that operator does not own grants nothing. The claim refuses such a tree up front and names the
`chown`.

### Put it where that account can reach

The create runs its `mkdir` as the target, so **the parent must be a directory that account can
write** — your own home is usually the one place it is not:

```text
mkdir: cannot create directory '/home/you/projects/api': Permission denied
```

A shared location fixes it. On a stock install the clone area
(`/var/opt/ai-tools/sandbox-projects`) carries a `g:ai-ops:rwX` ACL, so every enrolled operator
can create there; any other directory works as long as both accounts can. This is the
reachability rule the claim enforces for the sandbox account, arriving one layer earlier.

## Lock secrets and take ownership back, any time

```bash
ai-tools --lockdown /path/to/project    # lock secret-named files
ai-tools --reclaim  /path/to/project    # hand agent-written files back to you
```

`--lockdown` runs the same scan-and-lock a claim runs, on demand — after adding a credential
file to a claimed tree, or before re-running a stopped claim.

`--reclaim` returns agent-written files to `<you>:ai-tools`, including the `.git` tree the
per-session sweeps skip. Run it before an ACL-unaware backup so plain ownership carries your
access into the copy, and add `--full` to include the heavy skipped trees. `--sandbox-remove`
deletes a clone and its registration, warning about unpushed commits first; the remote branch
stays for others to merge.

## What a claim and an unclaim do to permissions

Claiming grants the agent access through a POSIX ACL and group ownership; unclaiming takes it
back. Neither is a round trip, so it is worth seeing the actual modes before you run either half:

| before claim | while claimed | after unclaim |
|---|---|---|
| `600`, `700` | *never opened* — sealed | *unchanged* |
| `640`, `644`, `660`, `664` | `660` | `640` |
| `750`, `755`, `775` | `770` | `750` |

**Owner-only paths are never opened.** A file or directory with no group or other bits
(`600`, `700`) is your standing "keep this private" signal: the claim leaves it alone — a sealed
directory takes its whole subtree with it — and strips the sandbox residue it inherited, so the
seal holds even if the mode is widened later. This is what makes a `700 <you>:<you>` directory
keep the agent out: were the claim to grant it, the raised ACL mask would give the agent write on
that directory and with it the ability to unlink what is inside. The claim reports how many paths
it left alone.

**World access is removed at claim time and does not come back.** The claim sets `other::---` on
every path it touches, so `644` becomes `660` immediately, and unclaiming then drops group write
and leaves `640`. A tree that needs to stay world-readable is not a candidate for an in-place
claim — use a sandbox clone.

The rest of what an unclaim does not restore: **every** extended ACL is cleared, including
entries that predated the claim and had nothing to do with ai-tools; directory setgid is removed
whether or not the claim set it; the group owner becomes whoever you hand the tree to. Nothing
records a tree's pre-claim state, so no command can put any of it back. **Back up first** — that
is the only real safeguard, which is why both the claim and the forced unclaim say so before
asking.

> Watching a claim with `ls -l` can mislead: a POSIX ACL shows the **mask** in the group bits,
> not the group's own permission, and the only visible hint is the trailing `+`. Use
> `getfacl -e` to see effective access.

## Where the security boundary actually is

The allowlist (`~/.config/ai-tools/allowed-projects`) gates where sessions *launch* and which
written files get ownership handed back. It is not a read boundary: once a session runs, ordinary
file permissions plus the SELinux `ai_tools_project_t` label are what confine it, which is why
every flow above locks secrets down *before* granting group access, and why declining a lockdown
fails closed. The invariants are in
[`CLAUDE.md` — Security model](../CLAUDE.md#security-model--what-sandbox_user-can-and-cannot-do);
the per-component mechanism is in [`.claude/rules/`](../.claude/rules/).
