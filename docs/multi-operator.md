# Multi-operator model

**Status: proposed.** This note specifies the target model that lets several login
users (project users) — a human plus rootless service accounts on the same host —
drive the sandbox through one shared `ai-tools` account. It supersedes the
single-operator ownership model in which `/opt/ai-tools` is owned by one
`PROJECTS_USER`. It is the contract the spec, `enroll`, the handback, and the
rewritten `CLAUDE.md` will satisfy. Open questions are listed at the end; they
gate implementation.

## Scope and threat model

The host has multiple non-root accounts that need Claude Code access — typically a
human project user plus rootless service accounts (e.g. a CI runner). They form
**one trusting team**: they share a single `ai-tools` sandbox account and therefore
share its agent state and project reach. There is **no kernel isolation between
operators' agent sessions** — every session runs as the same `ai-tools` uid. Hosts
needing mutually-distrusting operators require per-operator sandbox accounts, which
this model does not implement (it is a documented future option, keyed off the
operators list).

## Decisions

- A new group **`ai-ops`** (`@OPERATORS_GROUP@`) names the operators. `enroll` adds
  each project user to it; the agent account `ai-tools` is **not** a member.
- The control plane (`/opt/ai-tools`) is owned **`root:ai-tools` permanently** and is
  never re-owned to a person. The RPM-shipped placeholder is the final state, so the
  re-own / `--reassert` / `%posttrans` machinery is removed.
- Operators reach the control plane only as far as the launcher needs: a **search
  bit** (`o+x`) on `/opt/ai-tools` and `/opt/ai-tools/bin` lets any operator `readlink`
  the launcher. Everything deeper stays `o=0`.
- The launch wrapper ships system-wide as **`/usr/local/bin/claude`** (`root:root
  0755`), rpm-owned. `path_dedup.sh` already ranks `/usr/local/bin` (Tier 1) above the
  nvm shim, so it shadows any nvm-managed `claude`.
- The wrapper checks `ai-ops` membership first and frames a `msg.lib` refusal for a
  non-operator, instead of leaking a raw `sudo` denial.
- The `nvm-update` timer runs **once**, in `ai-tools`'s own `systemd --user` instance
  (`%h=/opt/ai-tools`), updating the shared `.nvm` directly. The per-operator timer,
  the per-operator `~/.local/bin/nvm-update.sh`, and the `nvm-update.sh` sudoers rule
  are removed.
- `/etc/ai-tools/operator.conf` holds `OPERATORS="alice bob svc-ci"` — one
  space-separated list naming both human and rootless-service project users (they all
  drive the same `ai-tools` account, so they share one list). Home and primary group
  are derived per name via `getent`. The handback restores agent-written project files
  to the operator whose **allowlist contains the path** (`opX:ai-tools`; secret-named
  files `opX:opX 600`). When more than one operator lists the same path, the tie-break is
  the **nearest parent directory's owner**, provided that owner is an operator whose
  allowlist covers the path — the on-disk project owner wins. The control plane needs no
  restore.
- **`safe.directory` edits go through a root helper.** `.gitconfig` stays `root:ai-tools 644`
  (world-readable so the agent reads `safe.directory` and the operator and launch wrapper read it
  for the gap check without depending on `ai-tools` group membership; root-write-only). `ai-tools
  --project-claim` registers the project's `safe.directory` through the `ai-tools-safedir` root
  helper (operator `sudo`, no NOPASSWD — the same model as `ai-tools-setfacl`/`-relabel`/
  `-unclaim`), and `--project-unclaim` removes it; the agent has no path to `.gitconfig` writes.
  No setgid fight, no `ai-ops` group-write, and no new sudoers rule.
- **Each operator gets a private agent-state subdir.** `claude-run` points the session's
  Claude state dir at `/opt/ai-tools/state/<operator>/` (history, sessions,
  `.claude.json`), keyed off the launching operator the wrapper passes in, so operators'
  conversations do not intermix and `.claude.json` writes do not race. This is
  organizational, not kernel, isolation (one shared `ai-tools` uid). The shared control
  settings and hooks apply from Claude's global/managed-settings layer; only per-operator
  state lives in the subdir. Per-session scratch is isolated the same way: each session
  gets a private `/tmp` (`PrivateTmp` on the transient unit), so concurrent same-uid
  sessions do not collide on Claude's hardcoded `/tmp/claude-<uid>` path (which ignores
  `TMPDIR`, so isolation must be at the mount-namespace level, not an env var).
- `/opt/ai-tools/.git` is **`root:root 0700`** (root-private drift capture, no
  per-operator owner).
- Sudoers grants are **group** rules: `%ai-ops ALL=(ai-tools:ai-tools) NOPASSWD:
  /opt/ai-tools/bin/claude-run`. The per-operator-line form is gone.
- **Operator management is a symmetric root helper, `ai-tools-admin operator
  add|remove|list`** (run via `sudo`), replacing the one-shot `ai-tools-enroll`. It is a
  root helper, not an `ai-tools` CLI verb, because the CLI is unprivileged and refuses
  root while this edits host config (sudoers group, `ai-ops`, `OPERATORS`); the
  `ai-tools-admin` name leaves room for other root-side admin subcommands. `add` with an
  argument enrols that user or service account; with none it offers to add the non-root
  user running it (`$SUDO_USER`). `add` is accumulating and idempotent: it appends the
  name to `OPERATORS`, adds it to `ai-ops`, seeds that user's allowlist, and ensures the
  sandbox account's linger. `remove` reverses it (drops from `OPERATORS` and `ai-ops`, leaves
  the user's own allowlist/config). `list` prints the current operators. An operator runs
  `claude` from its own active login, so it needs no linger of its own; the toolchain timer
  is enabled once in `ai-tools`'s instance, not per operator.

## Permission mapping (single-operator → multi-operator)

Ownership cells use the shell-variable identities from
[naming-conventions.md](naming-conventions.md): `PROJECTS_USER` (the owner),
`PROJECTS_GROUP` (the owner's private group), `SANDBOX_USER`/`SANDBOX_GROUP`
(`ai-tools`), and `ai-ops` (the operators group).

| Path | Single-operator | Multi-operator | Effect |
|---|---|---|---|
| `/opt/ai-tools` | `PROJECTS_USER:SANDBOX_GROUP 2750` | `root:SANDBOX_GROUP 2751` | `+o+x` search so any operator traverses to the launcher; no `o+r`. Root owner drops the single-operator binding. |
| `/opt/ai-tools/bin` | `PROJECTS_USER:SANDBOX_GROUP 0550` | `root:SANDBOX_GROUP 0551` | `+o+x` so operators `readlink bin/claude` (readlink needs dir search, not link read). |
| `bin/claude-run` | `PROJECTS_USER:SANDBOX_GROUP 0550` | `root:SANDBOX_GROUP 0550` | unchanged surface — `sudo` transitions to `ai-tools` first, so the exec check is the group bit. |
| `bin/nvm-update.sh` | `PROJECTS_USER:SANDBOX_GROUP 0550` | `root:SANDBOX_GROUP 0550` | run as `ai-tools` by its own timer; group-x. |
| `bin/claude` (symlink) | `PROJECTS_USER:SANDBOX_GROUP` | `root:SANDBOX_GROUP` | owner irrelevant for readlink; root-owned = agent still can't swap it. |
| `.claude` | `PROJECTS_USER:SANDBOX_GROUP 3770` | `root:SANDBOX_GROUP 3770` | unchanged (`o=0`): operators get nothing; agent group-writes its state, sticky blocks unlink of root-owned control files. |
| `.claude/{settings.json,hooks}` | `PROJECTS_USER:SANDBOX_GROUP 640/750` | `root:SANDBOX_GROUP 640/750` | unchanged; only the agent reads these. |
| `.claude.json` | `PROJECTS_USER:SANDBOX_GROUP 0460` | `root:SANDBOX_GROUP 0460` | unchanged; agent group-writes state; root owner can't be silently rewritten. |
| `.gitconfig` | `PROJECTS_USER:SANDBOX_GROUP 640` | `root:SANDBOX_GROUP 644` | agent reads `safe.directory`; world-readable so the operator and wrapper read it without `ai-tools` group membership; root-write-only. Operators register entries through the `ai-tools-safedir` root helper (`sudo`), not by writing the file. |
| `.gitignore` | `PROJECTS_USER:SANDBOX_GROUP 640` | `root:SANDBOX_GROUP 640` | unchanged; agent reads, never writes. |
| `.git` | `PROJECTS_USER:PROJECTS_GROUP 2750` | `root:root 0700` | root-private; per-operator drift capture is meaningless with N operators. |
| `state/<operator>/` | n/a (shared `.claude`) | `SANDBOX_USER:SANDBOX_GROUP 0700` per operator | private agent state (history, sessions, `.claude.json`); `claude-run` selects it by the launching operator. |
| `.nvm/.cache/.local/.npm` | `SANDBOX_USER:SANDBOX_GROUP 0750` | unchanged | agent toolchain. |
| `/var/opt/ai-tools[/sandbox-projects]` | `PROJECTS_USER:SANDBOX_GROUP 2750/2770` | `root:SANDBOX_GROUP 2750/2770` | agent workspace; operator ownership was incidental. |
| `~/.config/ai-tools/*` | `PROJECTS_USER:PROJECTS_GROUP 700/600` | unchanged, **per operator** | each operator keeps their own allowlist/secret config; already scales to N. |
| `~/.local/bin/claude` | `PROJECTS_USER:PROJECTS_GROUP 0750` | **removed** → `/usr/local/bin/claude root:root 0755` | system wrapper; rpm-owned, fails safe for non-operators. |
| user `nvm-update.{service,timer}` | `PROJECTS_USER:PROJECTS_GROUP 640` in operator home | `root:root` in `%{_userunitdir}`, enabled once in `ai-tools`'s `--user` instance | one shared toolchain timer, not N. |
| `/etc/sudoers.d/ai-tools-claude` | per-operator lines | `%ai-ops` group rules | one rule covers all operators. |
| `/etc/ai-tools/operator.conf` | one `PROJECTS_USER` | `OPERATORS` **list** | handback resolves the per-project owner from it via allowlist match (tie-break: nearest parent-dir owner). |
| helpers / libs / CLI / handback / `/var/log` | `root:*` | unchanged | already operator-agnostic. |

## Properties and accepted trade-offs

- **Shared agent memory.** All operators' sessions share `/opt/ai-tools/.claude`
  (history, sessions, `.claude.json`). Conversations intermix; `.claude.json` can race
  under simultaneous use. Accepted for a trusting team.
- **No inter-operator isolation.** Any operator's session, as `ai-tools`, can read what
  `ai-tools` can read — including another operator's project files. Accepted.
- **`/usr/local/bin/claude` is on every user's PATH.** A non-operator invocation fails
  safe at the sudoers gate; the wrapper frames a friendly refusal first.
- **Search-bit exposure.** `o+x` on `/opt/ai-tools` and `bin` lets any user traverse
  and `readlink` the launcher (a non-secret `.nvm` path); deeper dirs stay `o=0`.

## What this removes

The root-owned control plane has no per-operator ownership to restore, so the
`reown_control_plane` routine, the `ai-tools-enroll --reassert` mode, and the
`%posttrans` re-assert hook are dropped. `control-plane.lib.sh` keeps only the
boundary-mode constants the installer/spec assert.

## Resolved (was open)

- **(A) `safe.directory` write path** → the `ai-tools-safedir` root helper (operator `sudo`,
  no NOPASSWD — the model `ai-tools-setfacl`/`-relabel`/`-unclaim` use). `.gitconfig` is
  `root:ai-tools 644` (world-readable, root-write-only); `--project-claim` registers and
  `--project-unclaim` removes the entry through the helper. No setgid fight, no group-write,
  no new sudoers rule. (The handback `SAFEDIR` verb was considered and dropped: a session-side
  verb leaves stale entries on unclaim and re-introduces agent-triggered control-plane writes.)
- **(B) operator.conf format** → `OPERATORS="alice bob svc-ci"`, one list for human and
  service accounts alike (they share `ai-tools`); home/group derived via `getent`.
- **(C) operator lifecycle** → `ai-tools-admin operator add|remove|list`; `add` with no
  arg offers `$SUDO_USER`, with an arg enrols that user or service account.
- **(D) per-operator isolation** → private `state/<operator>/` for agent state, private
  `/tmp` per session via `PrivateTmp`.

## Remaining verification

Claude Code's config-vs-state split: which env var/path selects the per-session **state**
dir (history/sessions/`.claude.json`) independently of the **global** managed settings and
hooks, so a per-operator `state/<operator>/` does not lose the shared control settings.
Confirmed before wiring `claude-run`'s per-operator state selection.

## Migration

The branch carrying the single-operator re-own work is rewritten before merge so the
history does not track the superseded `reown`/`--reassert`/`%posttrans` changes. Any
relocation of tracked source files (e.g. the wrapper to its system path) uses `git mv`
so file history is preserved.
