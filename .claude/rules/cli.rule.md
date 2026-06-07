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
  (idempotent; default cwd): register it, apply the SELinux project label, and run the
  secret pre-check.
- `--project-remove [path]` — unregister a real project (directory left on disk; label
  reverted).
- `--sandbox-create [path]` — shallow-clone a repo into the sandbox area and register it.
- `--sandbox-push [path]` / `--sandbox-remove [path]` — push the clone's commits to its
  branch / remove the clone and unregister it.
- `--lockdown [path]` — wrapper over `ai-tools-lockdown` (see
  [secret-handling](secret-handling.rule.md)).
- `--list`, `--help`.

## Two project models

**Claim in place** (`--project-claim`) registers an existing working tree where it lives.
The confined agent (`ai_tools_t`) reaches it only if the tree carries the
`ai_tools_project_t` SELinux label, so claim applies that label via the root helper
`ai-tools-relabel`, and `--project-remove` reverts it. The label primitive (semanage
fcontext + restorecon) lives in the shared `relabel.lib.sh`, sourced by both
`ai-tools-relabel` and `install-selinux.sh`, so the CLI and the policy installer apply one
implementation.

**Sandbox clone** (`--sandbox-create`) shallow-clones the repo under `SANDBOX_ROOT`
(`/var/opt/ai-tools/sandbox-projects`) so the agent never reads the origin's full history.
Work is pushed to a per-repo branch `ai-tools/sandbox-<user>/<leaf>` (default leaf `main`);
only the projects user can push (the sandbox account holds no git credentials), and anyone
with repo access merges that branch back, preserving the agent's commits granularly (see
`/var/opt/ai-tools/README.md`). Clones are labelled statically by `ai_tools.fc` + a plain
restorecon, not by `ai-tools-relabel`.

## Privilege model

The CLI itself is unprivileged. Its two root operations — `ai-tools-lockdown` and
`ai-tools-relabel` — run via `sudo` with **no** NOPASSWD grant by design, so sudo prompts
for the projects user's password; the sandbox account has no grant for either.
`/usr/local/sbin/ai-tools` is `750 root:root`, so the projects user cannot even stat the
helpers — only sudo, as root, reaches them.

## Secret pre-check on claim/clone

Before granting access, the CLI runs `ai-tools-lockdown --dry-run` and, when secret-matching
files are present, prompts to lock them down (see
[secret-handling](secret-handling.rule.md)). When lockdown is declined or unavailable it
drops a guard `CLAUDE.md` (sentinel `ai-tools-lockdown-guard`) instructing the agent to do
nothing until lockdown runs, preserving any real `CLAUDE.md` via `git mv` to `CLAUDE.md.bak`.
