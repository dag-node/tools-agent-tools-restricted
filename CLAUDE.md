# Claude CR

Claude Code Restricted — run sessions as a sandboxed user.

<!-- This file is the router + invariants. Component deep-dives live in
     .claude/rules/*.rule.md (path-scoped, loaded when you open matching src files).
     Decisions and open follow-ups live in auto memory. Keep load-bearing
     security invariants HERE: path-scoped rules do not load unless a matching
     file is open, and nested files do not survive /compact. -->

## Purpose

This repo installs and maintains a way to run Anthropic's **Claude Code as a
dedicated, locked-down system user (`SANDBOX_USER`, the account created as
`ai-tools`)** instead of as your own login account, so an autonomous coding agent
works on your projects without inheriting your user's privileges. It runs under a
separate UID with no login shell, launches only inside explicitly approved project
directories, escalates only through two narrow `sudo` rules, and does not reach your
secrets, SSH keys, or unrelated projects.

## Terminology

Terminology follows `docs/naming-conventions.md`: `SANDBOX_USER`/`SANDBOX_GROUP` name
the sandbox service account and its group (`@SANDBOX_USER@`/`@SANDBOX_GROUP@`,
substituted to `ai-tools` at install), while the literal `ai-tools` is retained only in
filesystem paths (`/opt/ai-tools`, `~/.config/ai-tools`), SELinux types (`ai_tools_t`),
the management CLI (`ai-tools`), and root-helper binary names (`ai-tools-chown`, …).

## How instructions are organized

- **This file** — the trust-chain summary, the security-model invariants, and
  cross-cutting conventions an agent needs in every session.
- **`.claude/rules/*.rule.md`** — per-component reference prose, scoped to the source files
  it describes via `paths:` frontmatter, so it loads when you open a matching file under
  `src/` (or `selinux/`). See the component map below. A rule and its source file's header
  overlap by design and are bidirectionally coupled: changing either obligates reconciling
  the other, resolving any conflict against the code, never defaulting to one side.
  Conventions for writing rules: `.claude/rules/authoring.rule.md`.
- **Auto memory** (`/memory`) — decisions, rejected alternatives, and open follow-ups
  that are not derivable from the code.

### Component map

| Area | Source | Rule |
|---|---|---|
| Launch, allowlist gating, sudoers, PATH | `bin/claude-run.sh`, `.local/bin/claude.sh`, `allowed-projects`, `sudoers.d/ai-tools-claude` | [launch](.claude/rules/launch.rule.md) |
| Namespaces, SELinux transition, preflight, `/tmp` | `selinux/**`, `bin/claude-run.sh` | [confinement](.claude/rules/confinement.rule.md) |
| Root-op socket (daemon/client/units) | `ai-tools-handback*`, `ai-tools-handback-client*` | [handback-bridge](.claude/rules/handback-bridge.rule.md) |
| Hooks, sweeps, `.git` reclaim, setgid, control-plane integrity | `.claude/**`, `ai-tools-chown.sh`, `ai-tools-setgid.sh` | [ownership-and-hooks](.claude/rules/ownership-and-hooks.rule.md) |
| Secret-named files, lockdown, pattern set | `ai-tools-lockdown.sh`, `ai-tools-chown.sh`, `secret-patterns*` | [secrets](.claude/rules/secret-handling.rule.md) |
| Node/claude updater, symlink repoint | `nvm-update.sh`, `ai-tools-claude-symlink.sh` | [updater](.claude/rules/updater.rule.md) |
| Management CLI, project lifecycle, relabel | `bin/ai-tools.sh`, `ai-tools-relabel.sh`, `relabel.lib.sh` | [cli](.claude/rules/cli.rule.md) |
| Shared logging library | `log.lib.sh` | [logging](.claude/rules/logging.rule.md) |
| Test organization, hermeticity, categories | `tests/**`, `test.sh` | [tests](.claude/rules/tests.rule.md) |

## Trust chain (summary)

Each step's mechanism is in the rule files above; the invariant each guarantees:

1. `claude` resolves to the wrapper `~/.local/bin/claude`, running as you.
2. The wrapper launches only inside an allowed project, never a `!`-excluded CWD.
3. It resolves the versioned binary via a single `readlink` hop, validates it, and
   execs `claude-run` as `SANDBOX_USER` with the path in `CLAUDE_EXEC`.
4. `claude-run` re-validates, then wraps the session in a transient systemd `--user`
   service unit whose kernel properties confine it (`RestrictNamespaces=yes`,
   `NoNewPrivileges`, SELinux `ai_tools_t`), with an env allowlist and the project as
   `WorkingDirectory`.
5. The session runs as `SANDBOX_USER`; files it writes are born `SANDBOX_USER`-owned.
6. `PostToolUse`/`Stop`/`SessionStart` hooks hand agent-written paths back to
   `<you>:SANDBOX_GROUP` (secret-named files to `<you>:<you> 600`) through the
   `ai-tools-handback` socket — `sudo` is never used inside the session.
7. `SessionStart` additionally reclaims `.git` and normalizes setgid for the project.

## Security model — what `SANDBOX_USER` can and cannot do

The sudoers drop-in (`/etc/sudoers.d/ai-tools-claude`) grants the **invoking user** two
NOPASSWD rules that drop privilege to `SANDBOX_USER`:

```
<you>  ALL=(SANDBOX_USER:SANDBOX_GROUP) NOPASSWD: /opt/ai-tools/bin/claude-run
<you>  ALL=(SANDBOX_USER:SANDBOX_GROUP) NOPASSWD: /opt/ai-tools/bin/nvm-update.sh v[0-9]*.[0-9]*.[0-9]*
```

The agent runs *as* `SANDBOX_USER` and cannot invoke a `<you>` rule, so neither grants
it anything. The invariants the agent operates under:

- **`SANDBOX_USER` has no sudo rights** — not `rm -rf /`, not `cat /etc/shadow`, not any
  root helper. Root operations (chown, setgid, symlink repoint) go **exclusively**
  through the authenticated `ai-tools-handback` socket
  ([handback-bridge](.claude/rules/handback-bridge.rule.md)). The session runs under
  `PR_SET_NO_NEW_PRIVS`, which drops `sudo`'s SUID bit, so `sudo` is inoperative from
  inside the session by construction.
- **`SANDBOX_USER` has no login shell and no password.**
- **The agent may run only `claude-run` and the pinned updater as `SANDBOX_USER`** —
  never an arbitrary shell or binary. `claude-run` is a fixed-path target (no glob), `550
  <you>:SANDBOX_GROUP`, not writable by the agent.
- **The control-plane files are not agent-writable** — `settings.json`, the hooks,
  `nvm-update.sh`, and `claude-run` are `<you>:SANDBOX_GROUP` with no group write;
  `/opt/ai-tools/.claude` is `3770` setgid+sticky and `/opt/ai-tools/bin` is `550`, so the
  agent cannot unlink/replace them to disable its own guardrails. See
  [ownership-and-hooks](.claude/rules/ownership-and-hooks.rule.md).
- **The allowlist gates where the agent launches and which written files get ownership
  restored. It is NOT a kernel-enforced read boundary** — once running, ordinary Unix
  permissions plus the `ai_tools_t` SELinux type govern reads/writes. Those filesystem
  permissions are the enforced isolation boundary. (A per-session `bubblewrap` mount
  namespace to make the allowlist a true access boundary is a deferred proposal; see
  memory.)

## Cross-cutting conventions

- **`/opt/ai-tools`, not `/home`** — `/home` is `nosuid`, which would defeat the
  `sudo` UID-switch; `/opt/ai-tools` is not. Detail in
  [launch](.claude/rules/launch.rule.md).
- **Collaborative ownership** — the operator and agent are co-writers via setgid (group
  ownership) + a POSIX default ACL `g:SANDBOX_GROUP:rwX` on the project tree (group
  permission, umask-independent so `git checkout`/`merge` keeps the tree
  group-accessible). The operator stays **out** of `SANDBOX_GROUP`. Detail in
  [ownership-and-hooks](.claude/rules/ownership-and-hooks.rule.md).
- **Logging** — components log through `log.lib.sh` to journald (always) and root-only
  `/var/log/ai-tools/*.log` (root writers only). Detail in
  [logging](.claude/rules/logging.rule.md).
- **Root sudo-helpers** live under `/usr/local/sbin/ai-tools/` (`chown`, `setgid`,
  `claude-symlink`, `lockdown`, `relabel`); shared libraries under
  `/usr/local/lib/ai-tools/` (`secret-patterns`, `prune-dirs`, `relabel`, `log`).

### Documentation register

Match the surface to its skill — they use different voices:

- `CLAUDE.md`, `.claude/rules/*.rule.md`, file/module headers, design notes → **reference-docs**
  (present-tense spec; state current behavior, not history).
- `README.md`, getting-started, usage guides → **usage-docs**.
- Method/function/class doc comments and docstrings → **doc-comments**.
- Changelogs, release notes, migration guides → **change-docs**.
