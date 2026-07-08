---
paths:
  - "src/usr/local/bin/ai-tools.sh"
  - "src/usr/local/sbin/ai-tools/ai-tools-setfacl.sh"
  - "src/usr/local/sbin/ai-tools/ai-tools-unclaim.sh"
  - "src/usr/local/sbin/ai-tools/ai-tools-safedir.sh"
  - "src/usr/local/sbin/ai-tools/ai-tools-reclaim.sh"
  - "src/usr/local/sbin/ai-tools/ai-tools-relabel.sh"
  - "src/usr/local/lib/ai-tools/relabel.lib.sh"
---

# Management CLI and project lifecycle (`ai-tools`)

`ai-tools` (`/usr/local/bin/ai-tools`) is the project-lifecycle CLI. It runs **as the
projects user** — not root, not the sandbox account. It writes the operator-owned allowlist
(`~/.config/ai-tools/allowed-projects`) directly, and reaches the root-owned git
`safe.directory` list in `/opt/ai-tools/.gitconfig` (`root:ai-tools 644`: world-readable,
root-write-only) through the `ai-tools-safedir` root helper (`sudo`), alongside its other
root operations. It refuses to run as root (would write the registries with the wrong owner)
and as the sandbox account (the agent must not manage its own allowlist).

## Commands

- `--project-claim [path]` (alias `--project-create`) — claim a real project in place
  (idempotent; default cwd): register it (allowlist + git `safe.directory` via
  `ai-tools-safedir`), pin repo-local `core.filemode=true`, set the project's directory group +
  setgid via `ai-tools-setgid` and apply the group-permission ACL via `ai-tools-setfacl`, apply the
  SELinux project label, run the secret pre-check, ensure the sandbox account can traverse the path
  to the project (a default-NO prompt grants a traverse-only `u:SANDBOX_USER:--x` ACL on each
  blocking ancestor the operator owns and that is not a system directory; see *Reachability* below),
  and — when a `.git` tree is present but not yet normalized — offer (default-yes prompt) to
  normalize it for agent git-history access via `ai-tools-setfacl --with-git`, re-stating the
  sandbox-clone alternative when history should stay hidden.
- `--project-unclaim [path]` (alias `--project-remove`) — unclaim a real project
  (directory left on disk): revert the label, drop both registries, and (default-yes
  confirm) hand the tree's files back to a target group with the agent's write access
  revoked, via `ai-tools-unclaim`.
- `--sandbox-create [path]` — shallow-clone a repo into the sandbox area and register it.
- `--sandbox-push [path]` / `--sandbox-remove [path]` — push the clone's commits to its
  branch / remove the clone and unregister it.
- `--lockdown [path]` — wrapper over `ai-tools-lockdown` (see
  [secret-handling](secret-handling.rule.md)).
- `--reclaim [--full] [path]` — hand agent-written files under the project back to the
  operator via `ai-tools-reclaim` (which walks the tree and delegates per-path to
  `ai-tools-chown`, the same boundary the handback uses). Reclaims the `.git` tree the
  per-session sweeps skip; the ownership companion to the `user:<operator>` ACL, run on
  demand before an ACL-unaware backup so ownership (not the ACL) carries the operator's access
  into the copy. `--full` includes the skipped heavy trees (`node_modules`, `.venv`, …). See
  [ownership-and-hooks](ownership-and-hooks.rule.md).
- `--relabel` — restore `ai_tools_exec_t` on the claude entrypoint(s) after a Node upgrade,
  via `ai-tools-relabel-entrypoint`. The manual counterpart to the automatic post-upgrade
  relabel the `nvm-update` timer runs (see [updater](updater.rule.md)); for an out-of-band
  upgrade or if the timer's relabel failed and `claude-run` is fail-closing on the launch.
- `--list`, `--version` (the deploy-stamped package version; `dev` from a raw source tree),
  `--help`.

## Two project models

**Claim in place** (`--project-claim`) registers an existing working tree where it lives.
The confined agent (`ai_tools_t`) reaches it only if the tree carries the
`ai_tools_project_t` SELinux label, so claim applies that label via the root helper
`ai-tools-relabel`, and `--project-unclaim` reverts it. The label primitive (semanage
fcontext + restorecon) lives in the shared `relabel.lib.sh`, sourced by both
`ai-tools-relabel` and `install-selinux.sh`, so the CLI and the policy installer apply one
implementation. Claim sets group `SANDBOX_GROUP` + the setgid bit on the project's directories
(via `ai-tools-setgid`, so the agent traverses the tree and new files inherit the group), applies
the group-permission ACL for existing files (via `ai-tools-setfacl`), and pins repo-local
`core.filemode=true`.
A separate default-yes prompt offers to normalize the `.git` tree (`ai-tools-setfacl
--with-git`: group `SANDBOX_GROUP` + setgid on its dirs + the same ACL) so the operator's
own commits stay agent-readable — `.git` being the one heavy tree the per-session passes
skip yet both parties write (see [ownership-and-hooks](ownership-and-hooks.rule.md));
declining re-states the sandbox-clone model for keeping git history out of the agent's reach.
Claim inspects current state and runs only the missing steps, so a re-run is a quiet no-op
and existing projects retrofit the ACL/`filemode`/`.git` normalization on the next claim.

**Interior drift.** Root-level state cannot see paths inside a claimed tree that lack the
group/ACL — brought in by rename (which keeps the old group and carries no ACL entries;
creation under the setgid + default-ACL parents inherits both), or sitting under a
skip-listed directory name the claim walks leave alone. Claim therefore scans the tree
(`acl_drift_scan`, read-only and unprivileged) for shared-looking paths with a foreign
group — owner-only paths (`600`/`700`, e.g. locked-down secrets) and `!`-excluded subtrees
stay unreported as out-of-reach by intent — and splits the hits on the shared skip list
(`skip-dirs.lib.sh`, which the CLI sources): repairable hits become a pending step whose
repair (setgid walk + ACL walk) runs only behind the same default-NO confirm and secret gate
as a first claim, while hits under skip-listed names get an informational warning naming the
remedies that do reach them — narrow the category override in `operator.conf`, list the
path in `SKIP_ARTIFACT_DIRS_EXCLUDED_PATHS_RELATIVE` (a source dir sharing a skipped
build-output name), then re-claim; or `ai-tools --reclaim --full` for ownership alone.
Declining plus a `!` exclusion (or `chmod 700`) records an intentional carve-out so it is
not re-reported.

**Reachability.** The confined session runs *as* the sandbox account, so it must be able to
**traverse** the path to the project; a project nested under a directory the account cannot enter
(a private home, `700`) is unreachable, and `claude-run` — which re-checks the project directory as
the agent — refuses it as missing even after a clean claim. Claim closes this with a **default-NO**
prompt that grants a **traverse-only** ACL (`u:SANDBOX_USER:--x` — execute, no read) on each
blocking ancestor, so the account can *enter* a directory to reach the project but never *list* or
*read* it. The grant is scoped by the same owner-guard + [safe-paths](safe-paths.rule.md) backstop
the rest of claim uses: only directories the **operator owns** and that are **not** protected system
directories, and it is **unprivileged** (the operator owns them, so no `sudo`). A blocking ancestor
that is a system directory or owned by someone else is left untouched — there the sandbox clone
(under `/var/opt/ai-tools`, already agent-traversable) is the way in. The grant is idempotent: an
ancestor the account can already traverse (e.g. one carrying the ACL from a prior claim) is skipped.

**Unclaim** (`--project-unclaim`) reverts that: it removes the SELinux label and both
registries, then (default-yes confirm) runs `ai-tools-unclaim` to hand the filesystem back.
For every eligible path that helper clears the agent ACL **and** the default ACL
(`setfacl -b`), changes the group owner to a target group (the invoking user's own group by
default; any other user can be named, handing the tree to that user's group), and removes
group write (`660→640`, `770→750`, `400` stays `400`) — additionally clearing the setgid bit
claim added on **directories** (numeric `chmod` cannot, so symbolic `g-s` is used), returning
them to plain perms. The agent loses access via both the group owner and the named ACL entry,
while the new group owner keeps read/traverse. `.git`, skipped by the main walk like the other
heavy trees, is reverted by its own pass — for the same reason claim normalizes it (both
parties write it) — so the unclaim fully revokes git-history access too.

**Owner guard (claim and unclaim).** The root helpers `ai-tools-setgid`, `ai-tools-setfacl`,
and `ai-tools-unclaim` act **only** on paths owned by the projects user or the sandbox
account; a path owned by any third party (root, another developer) is left untouched, on top
of the secret-name and `!`-exclusion skips. This is the claim-side partner to
`ai-tools-chown`'s "act only on `SANDBOX_USER`-owned paths" rule
([ownership-and-hooks](ownership-and-hooks.rule.md)): claim never pulls a foreign-owned file
into the agent's group, and unclaim never regroups one out.

**Sandbox clone** (`--sandbox-create`) shallow-clones the repo under `SANDBOX_ROOT`
(`/var/opt/ai-tools/sandbox-projects`) so the agent never reads the origin's full history.
Work is pushed to a per-repo branch `ai-tools/sandbox-<user>/<leaf>` (default leaf `main`);
only the projects user can push (the sandbox account holds no git credentials), and anyone
with repo access merges that branch back, preserving the agent's commits granularly (see
`/var/opt/ai-tools/README.md`). Clones are labelled statically by `ai_tools.fc` + a plain
restorecon, not by `ai-tools-relabel`.

The shared sandbox area carries a `g:ai-ops:rwX` ACL (traverse on `/var/opt/ai-tools`, rwX +
default on `sandbox-projects`, applied by `install.sh`), so an operator creates and works in
clones without `SANDBOX_GROUP` membership — the shared-area counterpart to `ai-tools-setfacl`'s
per-project `user:<operator>` grant. The agent is not in `ai-ops` (`claude-run` refuses to launch
otherwise), so the grant adds it no access.

## Privilege model

The CLI itself is unprivileged. Seven of its root operations — `ai-tools-lockdown`,
`ai-tools-relabel`, `ai-tools-setfacl`, `ai-tools-setgid`, `ai-tools-unclaim`, `ai-tools-safedir`,
and `ai-tools-reclaim` — run via `sudo` with **no** NOPASSWD grant by design, so sudo prompts for
the projects user's password; the sandbox account has no grant for any. The exception, `--relabel` →
`ai-tools-relabel-entrypoint`, is: it has a dedicated fixed-path NOPASSWD rule
(shared with the `nvm-update` timer, see [updater](updater.rule.md) / [launch](launch.rule.md)),
so it runs **as root without a prompt** — kept safe by being a fixed-path, no-argument target
the projects user cannot modify. `ai-tools-setfacl` and `ai-tools-unclaim` need root
(`CAP_FOWNER`) to act on files the projects user does not own (e.g. agent-written files from
a prior session); `ai-tools-setgid` needs root to `chgrp` the project's directories to
`SANDBOX_GROUP` — a group the operator is not a member of (multi-operator), so the change is not
possible unprivileged. Each re-validates its target path against the allowlist and shares the
exclusion/secret-skip/skip-list rules (see [ownership-and-hooks](ownership-and-hooks.rule.md)). `ai-tools-safedir` needs root to
write the root-owned `.gitconfig`; on add it re-validates the path against the allowlist through
the shared `operator.lib.sh` resolver, but edits a single entry rather than walking a tree.
`ai-tools-reclaim` walks the project and hands each agent-owned path to `ai-tools-chown`, so the
allowlist/secret/exclusion enforcement and the need for root are that helper's, not its own.
Repo-local `core.filemode=true` and the allowlist are plain writes the projects user performs
unprivileged.
`/usr/local/sbin/ai-tools` is `750 root:root`, so the projects user cannot even stat the
helpers — only sudo, as root, reaches them.

## Secret pre-check on claim/clone

Before granting access, the CLI runs `ai-tools-lockdown --dry-run` and, when secret-matching
files are present, prompts to lock them down (see
[secret-handling](secret-handling.rule.md)). When lockdown is declined or unavailable it
drops a guard `CLAUDE.md` (sentinel `ai-tools-lockdown-guard`) instructing the agent to do
nothing until lockdown runs, preserving any real `CLAUDE.md` via `git mv` to `CLAUDE.md.bak`.
