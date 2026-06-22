---
paths:
  - "src/usr/local/bin/ai-tools.sh"
  - "src/usr/local/sbin/ai-tools/ai-tools-relabel.sh"
  - "src/usr/local/lib/ai-tools/relabel.lib.sh"
---

# Management CLI and project lifecycle (`ai-tools`)

`ai-tools` (`/usr/local/bin/ai-tools`) is the project-lifecycle CLI. It runs **as the
projects user** — never root, never the sandbox account — and needs no privilege for the
registries it edits: the allowlist (`~/.config/ai-tools/allowed-projects`) and the git
`safe.directory` list in `/opt/ai-tools/.gitconfig`, both writable by the projects user. It
refuses to run as root (would write the registries with the wrong owner) and as the sandbox
account (the agent must not manage its own allowlist).

## Commands

- `--project-claim [path]` (alias `--project-create`) — claim a real project in place
  (idempotent; default cwd): register it, pin repo-local `core.filemode=true`, apply the
  group-permission ACL via `ai-tools-setfacl`, apply the SELinux project label, run the
  secret pre-check, and — when a `.git` tree is present but not yet normalized — offer
  (default-yes prompt) to normalize it for agent git-history access via `ai-tools-setfacl
  --with-git`, re-stating the sandbox-clone alternative when history should stay hidden.
- `--project-unclaim [path]` (alias `--project-remove`) — unclaim a real project
  (directory left on disk): revert the label, drop both registries, and (default-yes
  confirm) hand the tree's files back to a target group with the agent's write access
  revoked, via `ai-tools-unclaim`.
- `--sandbox-create [path]` — shallow-clone a repo into the sandbox area and register it.
- `--sandbox-push [path]` / `--sandbox-remove [path]` — push the clone's commits to its
  branch / remove the clone and unregister it.
- `--lockdown [path]` — wrapper over `ai-tools-lockdown` (see
  [secret-handling](secret-handling.rule.md)).
- `--relabel` — restore `ai_tools_exec_t` on the claude entrypoint(s) after a Node upgrade,
  via `ai-tools-relabel-entrypoint`. The manual counterpart to the automatic post-upgrade
  relabel the `nvm-update` timer runs (see [updater](updater.rule.md)); for an out-of-band
  upgrade or if the timer's relabel failed and `claude-run` is fail-closing on the launch.
- `--list`, `--help`.

## Two project models

**Claim in place** (`--project-claim`) registers an existing working tree where it lives.
The confined agent (`ai_tools_t`) reaches it only if the tree carries the
`ai_tools_project_t` SELinux label, so claim applies that label via the root helper
`ai-tools-relabel`, and `--project-unclaim` reverts it. The label primitive (semanage
fcontext + restorecon) lives in the shared `relabel.lib.sh`, sourced by both
`ai-tools-relabel` and `install-selinux.sh`, so the CLI and the policy installer apply one
implementation. Claim also applies the group-permission ACL (via `ai-tools-setfacl`) and
pins repo-local `core.filemode=true`; these complement the recursive group-ownership grant.
A separate default-yes prompt offers to normalize the `.git` tree (`ai-tools-setfacl
--with-git`: group `SANDBOX_GROUP` + setgid on its dirs + the same ACL) so the operator's
own commits stay agent-readable — `.git` being the one heavy tree the per-session passes
skip yet both parties write (see [ownership-and-hooks](ownership-and-hooks.rule.md));
declining re-states the sandbox-clone model for keeping git history out of the agent's reach.
Claim inspects current state and runs only the missing steps, so a re-run is a quiet no-op
and existing projects retrofit the ACL/`filemode`/`.git` normalization on the next claim.

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

## Privilege model

The CLI itself is unprivileged. Four of its root operations — `ai-tools-lockdown`,
`ai-tools-relabel`, `ai-tools-setfacl`, and `ai-tools-unclaim` — run via `sudo` with **no**
NOPASSWD grant by design, so sudo prompts for the projects user's password; the sandbox
account has no grant for any. The fifth, `--relabel` → `ai-tools-relabel-entrypoint`, is the
exception: it has a dedicated fixed-path NOPASSWD rule (shared with the `nvm-update` timer,
see [updater](updater.rule.md) / [launch](launch.rule.md)), so it runs **as root without a
prompt** — kept safe by being a fixed-path, no-argument target the projects user cannot
modify. `ai-tools-setfacl` and `ai-tools-unclaim` need root
(`CAP_FOWNER`) to act on files the projects user does not own (e.g. agent-written files from
a prior session); each re-validates its target path
against the allowlist and shares the exclusion/secret-skip/prune rules with `ai-tools-setgid`
(see [ownership-and-hooks](ownership-and-hooks.rule.md)). Repo-local `core.filemode=true`
and the two registries are plain writes the projects user performs unprivileged.
`/usr/local/sbin/ai-tools` is `750 root:root`, so the projects user cannot even stat the
helpers — only sudo, as root, reaches them.

## Secret pre-check on claim/clone

Before granting access, the CLI runs `ai-tools-lockdown --dry-run` and, when secret-matching
files are present, prompts to lock them down (see
[secret-handling](secret-handling.rule.md)). When lockdown is declined or unavailable it
drops a guard `CLAUDE.md` (sentinel `ai-tools-lockdown-guard`) instructing the agent to do
nothing until lockdown runs, preserving any real `CLAUDE.md` via `git mv` to `CLAUDE.md.bak`.
