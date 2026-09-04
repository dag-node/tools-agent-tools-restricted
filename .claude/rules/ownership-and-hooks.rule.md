---
paths:
  - "src/opt/ai-tools/agents/**"
  - "src/usr/local/libexec/ai-tools/ai-tools-chown.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-setgid.sh"
  - "src/usr/local/lib/ai-tools/skip-dirs.lib.sh"
  - "src/usr/local/lib/ai-tools/owner-only.lib.sh"
  - "src/usr/local/lib/ai-tools/control-plane.lib.sh"
---

# Ownership handback, hooks, and sweeps

Files the agent writes are born `SANDBOX_USER`-owned. The hooks restore
`<you>:SANDBOX_GROUP` ownership through `ai-tools-chown` (via the
[handback bridge](handback-bridge.rule.md)) so the operator and agent stay co-writers.

The hooks below are **Claude Code's** driver for that handback, declared by its manifest as
`handback=hooks`. An agent that declares otherwise has none, and `ai-tools-run` sweeps the project
at session end in their place — same `ai-tools-chown` boundary, per session instead of per turn
(see [providers](providers.rule.md)).
`<you>` is the operator that **owns** the path — the one whose allowlist covers it, which
`ai-tools-chown` resolves per path via `operator.lib.sh` (`ai_tools_resolve_owner`), so on a
host with several operators each project's files return to that project's operator.
Secret-named files take a different path (see [secrets](secret-handling.rule.md)).

## `ai-tools-chown` acts only on agent-written paths

`ai-tools-chown` acts on a path **only when it is currently `SANDBOX_USER`-owned**.
Write/Edit create files and parent dirs via atomic rename, which stamps them
`SANDBOX_USER`-owned — the signal that the agent itself just wrote the path. Any path
not owned by `SANDBOX_USER` is a pre-existing user file or directory the agent could not
have written; it is left completely untouched (no re-chown, no bit-stripping, and for a
secret-named path no false `breached` NOTICE about a secret the agent never accessed).

It acts only on a regular file or directory — a symlink or a hardlinked file is refused —
and applies the `chown`/`chmod` race-safely: it opens the target, re-verifies inode and
type through the held descriptor, and mutates via `/proc/self/fd`, so a `SANDBOX_USER` path
swap between validation and mutation cannot redirect root's `chown` onto a file outside the
tree. The full pinned-fd sequence is in the `ai-tools-chown.sh` header.

## `PostToolUse` — the immediate path

`post-tool-hook.sh` serves two events, dispatched on its argument the way `session-hook.sh`
dispatches its session phases. **Both record the tool call** in the operator-readable trail —
the grammar, the content bound, and why the trail is evidence rather than proof are in
[logging](logging.rule.md). The argument-less form (`Write|Edit`) additionally performs the
handback below; the `record` form (`Bash`) records and stops, since a Bash-created file carries
no `file_path` and is caught by the `Stop` sweep instead. The two are declared as separate
matcher groups rather than one widened matcher for a reason that belongs to the upgrade path;
see [claude-settings](claude-settings.rule.md).

A `PostToolUse` hook (`post-tool-hook.sh`, declared in `settings.json`) calls
`ai-tools-handback-client CHOWN <file>` to restore `<you>:SANDBOX_GROUP` and strip world
bits, inside allowlisted paths only (never on `!`-excluded paths). It also walks the
written file's parent directories and hands each back (world bits stripped, group `rwx`
kept so the agent keeps writing into a dir it made) — but **only** for directories the
agent created (currently `SANDBOX_USER`-owned): the walk stops at the first pre-existing
user-owned dir, and `ai-tools-chown` independently refuses any non-`SANDBOX_USER`
directory, so it never grants the agent group access to a dir it did not already own.

`PostToolUse` is the only path that quarantines a secret the instant it is written. It
fires only for `Write`/`Edit`, so files the agent creates via the `Bash` tool (build
output, codegen, `mv`, redirects) carry no `file_path` and are caught by the sweeps
below instead.

## `Stop` — the per-turn catch-all sweep

A `Stop` hook (`session-hook.sh`) closes the `Bash`-tool gap: at each turn's end it
reads `.cwd`, finds the `SANDBOX_USER`-owned paths under it (bounded by a timestamp
marker; heavy trees like `.git`/`node_modules` skipped) and hands each to `ai-tools-chown`.
Running at turn end rather than per-Bash-call means handing a file back (world stripped)
cannot break an in-progress in-place Bash edit.

On an ordinary file `ai-tools-chown` strips the world bits and, keyed on the *owner*-execute
bit (the only exec bit git records), a stray group/mask **execute** that Claude Code's Write
tool leaves on a data file — a data file drops to group `rw` (`-rw-rw----+`), a genuine script
(owner `rwx`) keeps group `r-x` (`750`). It removes execute only, not read or write, so on an
ACL'd file the mask stays `rw` and the agent can still edit the file the next turn. Left
unstripped, that mask-execute becomes a real group-execute bit when the tree is archived
(`tar`/`zip` store `st_mode`, whose group bits are the mask) and extracted without ACLs — which
is why unclaim strips it the same way (see [cli](cli.rule.md)).

### Listing the agent's session footprint

A useful side effect falls out of the born-`SANDBOX_USER`-owned + handback model: the
`SessionStart` pass restores every non-skipped project file to the operator, and thereafter
each file the agent writes is born `SANDBOX_USER`-owned until a sweep hands it back. So among
the non-skipped files, *owned by `SANDBOX_USER`* means *touched since the last handback* —
the agent's current, not-yet-reconciled footprint. Reusing the same skip set keeps the heavy
trees (agent-owned from before) out of the result:

```
find <project> <skip-expr> -prune -o -user SANDBOX_USER -print
```

This is a cheap way for the operator (or the agent) to see what the agent changed this
session, distinct from `git status` in that it also surfaces untracked and `.gitignore`d
writes.

## `SessionStart` — the unbounded recovery pass

The `Stop` sweep is bounded by a global (not per-project) timestamp marker, so it can
miss paths left by a session that exited before its `Stop` hook ran (`kill -9`, crash,
closed terminal), and miss older paths when the working project changes. A `SessionStart`
hook runs `session-hook.sh` with the `session-start` argument to close that gap: on
`source` `startup`/`resume` (a freshly started process, the only case that can follow an
interrupted session) it does one **unbounded** pass — every `SANDBOX_USER`-owned path
under `.cwd`, ignoring the marker — then resets the marker so this session's `Stop` sweeps
bound from session start. `clear`/`compact` stay within a live process whose `Stop` sweeps
already cover the tree, so they are a no-op.

Like every sweep, it acts only on `SANDBOX_USER`-owned paths, and `ai-tools-chown`
re-validates each against the allowlist, so it reclaims agent files to
`<you>:SANDBOX_GROUP` and never claims a user-owned file.

### `.git` reclaim

Every sweep skips `.git`, so `SANDBOX_USER`-owned objects the agent writes there via `git
commit` (a `Bash`-tool action with no `file_path`, so no `PostToolUse` handback) stay
agent-owned. **Access** to them is carried by the `user:<operator>` ACL (`ai-tools-setfacl
--with-git`, above): a `<you>` out of `SANDBOX_GROUP` reads and repacks those objects through the
named entry regardless of who owns them, timing-independently. The reclaim is the **ownership**
companion to that ACL: it descends the otherwise-skipped `.git` of `.cwd` and hands each
`SANDBOX_USER`-owned path to `ai-tools-chown` (same allowlist + exclusion + secret re-validation as
any sweep), so `.git` ownership converges to `<you>:SANDBOX_GROUP` — consistent with the work tree,
and so the operator's access survives an ACL-unaware copy (an `rsync`/`tar` that drops ACLs
preserves owner). It runs on the once-per-session `session-start` pass (which also covers a killed
prior session's leftovers) and the `session-end` pass (graceful-exit convergence), never the
per-turn `Stop` sweep, so it never flips ownership mid-turn under a live `git` command. The other
skipped trees (`node_modules`, `.venv`, …) stay agent-owned — harmless (world-readable,
regenerable). The operator's on-demand counterpart is `ai-tools --reclaim [--full]` (the
`ai-tools-reclaim` helper, which walks a project and delegates to the same `ai-tools-chown`; see
[cli](cli.rule.md)) — e.g. before a backup, with `--full` to include the skipped heavy trees.

### Clean-exit marker

Whether a session was interrupted is read from a clean-exit marker
(`.session-active`, beside the hook in that agent's config directory): the `session-start` pass writes it (recording
`.cwd`), and a `SessionEnd` hook (`session-hook.sh` with the `session-end` argument)
removes it on graceful exit and runs the `.git` reclaim for `.cwd` (above). A marker that
survives into the next `session-start` means
the previous session was killed before its `SessionEnd` ran. That signal **widens** the
`.git` reclaim to also cover the killed session's recorded `.cwd` — which may be a
different project than the new session's — and selects the interrupted-session NOTICE
wording. A gracefully-exited session clears its marker and reclaims its `.git` at
`session-end`; the cross-project pointer is needed only for a kill.
Every reclaim is logged to journald (the audit trail), but only the **interrupted** case
is also surfaced as a `SessionStart` `additionalContext` NOTICE — the only actionable one,
since a killed prior session can leave cross-project mixed ownership the agent should relay,
with the manual `sudo chown -R --from=SANDBOX_USER <you>:SANDBOX_GROUP <project>` reconcile
for anything the helper could not reach (the command is kept on its own line, outside the
frame, so it stays copy-pasteable). The routine post-git-activity reclaim runs on nearly
every `session-start` and has already repaired ownership, so it stays journald-only:
injecting it would force a TUI re-render that clobbers claude's startup banner with a line
the user cannot act on. The surfaced NOTICE is framed through `msg.lib.sh` (see
[messaging](messaging.rule.md)).

Every pass checks the handback socket before acting, since a socket that is down fails every
`CHOWN` and would otherwise report a reassuring count of calls that changed no ownership. So the
sweeps and the reclaim count **confirmed** handbacks (client exit 0), not attempts; a down socket
makes each pass skip its walk and record the stranded count, and the `session-start` pass — the
one the operator reads — surfaces a distinct `SessionStart` NOTICE naming the fix (`systemctl
enable --now ai-tools-handback.socket`, then `ai-tools --reclaim <project>`) whenever agent-owned
`.git` paths are stranded, instead of the "reclaimed N" wording. `ai-tools-run`'s launch-time
preflight is the front-line detector for the same condition (see [launch](launch.rule.md),
[handback-bridge](handback-bridge.rule.md)).

## Setgid normalization

The same `SessionStart` pass normalizes the project's setgid bit via the root helper
`ai-tools-setgid` (allowlist-validated, idempotent): every project directory is set group
`SANDBOX_GROUP` with `g+s`, so a file the operator creates there is born in group
`SANDBOX_GROUP` and the agent can read/write it — **without the operator being a member of
`SANDBOX_GROUP`**. That keeps the operator out of `SANDBOX_GROUP` entirely (defense
in depth: home-dir configs stay unreachable from `SANDBOX_GROUP`) while project-file
collaboration works. Like the claim-side ACL and unclaim helpers, it resolves the project's
owning operator (`ai_tools_resolve_owner`) and acts **only** on dirs that operator or the
sandbox account holds — a dir held by any third party (root, another developer) is left
untouched, so normalization never pulls a foreign-held dir into the agent's group. This is the claim-side partner to `ai-tools-chown`'s "act only on
`SANDBOX_USER`-owned paths" rule.

**That skip is counted and reported, never silent.** It is the one skip that can leave a claim
granting the agent *no access at all* while every other step succeeds, so each walk (`ai-tools-setgid`,
`ai-tools-setfacl`) counts the paths its owner guard declined and closes with the count on stderr,
the **project root** called out on its own — every directory below an unreachable root inherits
neither the group nor the ACL, so that case is the whole outcome of the claim rather than one skipped path. The CLI's
front line for the same condition is `require_claimable_owner`, which refuses such a claim before
its first registry write (see [cli](cli.rule.md)).

An **owner-only** directory (`0600`/`0700`) is left out of
the normalization too, and its subtree with it: that mode is the operator's standing seal, and
this pass honours it exactly as `ai-tools-setfacl` does. Rather than normalize such a directory
it *strips* the sandbox residue the directory still carries — the inherited
`group:SANDBOX_GROUP` ACL entries, the setgid bit, and the sandbox group owner — since setgid
and default-ACL inheritance act at create time and a later `chmod` only masks them. Predicate
and strip are single-sourced in `owner-only.lib.sh`, shared with `ai-tools-setfacl`,
`ai-tools-lockdown` and `ai-tools-chown`; see [secrets](secret-handling.rule.md). Heavy/transient trees (`.git`, `node_modules`, `.venv`,
`__pycache__`, `packages`) are skipped; that skip list is shared with the sweep and
`ai-tools-lockdown` via `/usr/local/lib/ai-tools/skip-dirs.lib.sh` (the authoritative
reference), which groups the names into categories (VCS, package, artifact, cache) an
operator can override per category in `operator.conf` — read through the shared `KEY=value`
grammar in `conf.lib.sh`, so a category list separates on commas or whitespace with optional
quotes, and a **present** key replaces that category's default while an absent one leaves it
standing (see [providers](providers.rule.md)) — and combines per consumer. The
artifact category ships empty — `bin`/`obj`-style build-output names double as source dirs
in many codebases, so skipping them is a per-host perf opt-in (`SKIP_ARTIFACT_DIRS="bin
obj"`), with root-relative exemptions for same-named source dirs
(`SKIP_ARTIFACT_DIRS_EXCLUDED_PATHS_RELATIVE`; every walk passes its root to the selector).
"Skip" means omitted from the walk, not hidden from the agent — a skipped tree's files
stay agent-owned. A Stop sweep that hands back an unusually large batch logs a
journald hint naming the artifact opt-in.

Setgid handles group *ownership* inheritance; a POSIX ACL handles *permission* inheritance in
both directions. The root helper `ai-tools-setfacl` (run at project claim, see
[cli](cli.rule.md)) applies a **default** ACL `user:<operator>:rwX,g:SANDBOX_GROUP:rwX,o::-` to
every project directory, plus the matching **access** ACL on existing entries. The group grant is
the AGENT's access: a file the operator's `git checkout`/`merge` writes under a restrictive umask
is born group-accessible (and a pre-existing `600` operator file is opened to the agent group),
others-denied independent of that umask. The `user:<operator>` grant is the mirror — the
OPERATOR's umask-independent access to AGENT-written files — so the operator co-writes the tree,
and reads agent-written `.git` objects, **without joining `SANDBOX_GROUP` and without waiting on
the ownership handback**; it is the access counterpart to setgid's `operator→agent` group grant.
The named entry governs agent-owned files and yields to the owner entry on operator-owned ones.
The helper shares the allowlist/exclusion/secret-skip/skip-list rules with the setgid pass, so
secret-named and `!`-excluded paths receive neither grant. `other::---` is pinned explicitly
rather than cloned from each directory's mode, which on a permissive-umask directory would
otherwise seed `default:other::r-x` and leak read access to every future file.

`.git` is the one skipped tree both parties commit into. The per-session passes leave it
alone for cost, so the agent's own `.git` writes are reclaimed by the `.git` reclaim above;
the operator's `.git` writes — born in the operator's primary group (e.g. `<you>:<you>`) and
unreadable to the agent once `<you>` is not a `SANDBOX_GROUP` member — are handled at claim
instead. `ai-tools-setfacl --with-git` normalizes `.git` once: group `SANDBOX_GROUP` + setgid
on its dirs and the same default+access group ACL, so later operator commits are born agent-
accessible. The claim CLI asks before applying (default yes; see [cli](cli.rule.md)) and
points to the sandbox-clone model when git history should stay out of the agent's reach. The
two mechanisms together keep `.git` uniformly `<you>:SANDBOX_GROUP`, and the same secret-name
and `!`-exclusion skips apply, so a credential committed into `.git` is never ACL'd. Unclaim
reverses this symmetrically: `ai-tools-unclaim` reverts `.git` in its own pass (regroup to the
target group, clear the agent + default ACL, drop group write, drop a stray group execute on a
data file, clear dir setgid), so the agent loses history access along with the rest of the tree
(see [cli](cli.rule.md)).

## Control-plane file integrity (the agent config dirs, `bin/`)

The files that drive the sandbox's own enforcement — `settings.json` (declares the
hooks), `post-tool-hook.sh`, `session-hook.sh` and `filter-hook.sh` (the hook bodies),
`bin/nvm-update.sh` (the updater), and `bin/ai-tools-run` (the service shim) — are not
writable by the agent, so it cannot disable its own handback, secret-quarantine, or
confinement guardrails. They are owned `root:SANDBOX_GROUP` (group read/exec, no group
write), **not** `SANDBOX_USER:SANDBOX_GROUP` — and not any operator, so no single operator
can rewrite a guardrail either; only root owns the control plane.

Ownership alone is insufficient: an agent's config directory is group-writable by
`SANDBOX_GROUP` (claude writes `sessions/`, `history.jsonl`, etc. there), and a
group-writer can `unlink`+recreate any file in a dir it can write, regardless of the
file's owner. So every agent config directory is owned `root:SANDBOX_GROUP` with
**setgid + sticky** (`CP_AGENT_CONFIG_MODE`): the agent stays a group-writer for its own state,
but the sticky bit forbids deleting/replacing files it does not own, and since it is not the dir
owner it cannot bypass that. setgid keeps new entries in group `SANDBOX_GROUP`. Sticky is wanted
here precisely because the agent never legitimately re-edits these files — the inverse of the
project-dir reasoning in [secrets](secret-handling.rule.md).

`/opt/ai-tools/bin` is locked harder: owned `root:SANDBOX_GROUP` at `0551`, not
group-writable. `SANDBOX_USER` gets group `r-x` — enough to execute `nvm-update.sh` and
resolve the `claude` symlink — but no write, and it is not the dir owner, so it cannot
edit `nvm-update.sh` in place, `unlink`/replace it, or swap the symlink. The `o+x` bit
(search without read) lets an operator `readlink` a known `bin/<launcher>` path
without listing or writing the directory — the one concession that distinguishes `0551`
from a bare `0550`. No sticky bit is needed because no path here is group-writable; only
root can change it. Repointing a launcher symlink at a new toolchain version is delegated to
the `ai-tools-launcher-symlink` root helper (see [updater](updater.rule.md)).

The control-plane modes are single-sourced as constants in
`/usr/local/lib/ai-tools/control-plane.lib.sh` (`CP_HOME_MODE`, `CP_DIR_MODES` for the
base-owned `bin`, and `CP_AGENT_CONFIG_MODE` for every agent's config directory), which
`install.sh` and the RPM `%files` both apply; cite the constants rather than re-stating the octal
so the modes stay defined in one place.

**Which directory that is belongs to the agent, not the base.** Its name comes from the agent
manifest's `config_dir`, its files (`settings.json`, the hooks) are shipped by that agent's
package, and its SELinux label is applied from the same manifest — so a second agent brings its
own control-plane directory instead of sharing this one, and the base names none of them (see
[providers](providers.rule.md)). The hook bodies derive their state paths (`.sweep-marker`,
`.session-active`) from their own location for the same reason.
