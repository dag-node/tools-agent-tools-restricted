# Agent Tools Restricted

Run coding agents sandboxed — under their own locked-down system user. Claude Code is the
first supported agent.

<!-- This file is the router + invariants. Component deep-dives live in
     .claude/rules/*.rule.md (path-scoped, loaded when you open matching src files).
     Decisions and open follow-ups live in auto memory. Keep load-bearing
     security invariants HERE: path-scoped rules do not load unless a matching
     file is open, and nested files do not survive /compact. -->

## Purpose

This repo installs and maintains a way to run an autonomous coding agent as a
dedicated, locked-down system user (`SANDBOX_USER`, the account created as
`ai-tools`) instead of as your own login account, so the agent works on your projects
without inheriting your user's privileges. **Claude Code is the first supported agent**;
the confinement, ownership-handback, and toolchain machinery are agent-agnostic. It runs
under a separate UID with no login shell, launches only inside explicitly approved project
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
| Launch, allowlist gating, sudoers, PATH | `bin/claude-run.sh`, `usr/local/bin/claude.sh`, `allowed-projects`, `sudoers.d/ai-tools-claude`, `lib/ai-tools/path-dedup.sh` | [launch](.claude/rules/launch.rule.md) |
| Namespaces, SELinux transition, preflight, `/tmp` | `selinux/**`, `bin/claude-run.sh` | [confinement](.claude/rules/confinement.rule.md) |
| Root-op socket (daemon/client/units) | `ai-tools-handback*`, `ai-tools-handback-client*` | [handback-bridge](.claude/rules/handback-bridge.rule.md) |
| Hooks, sweeps, `.git` reclaim, setgid, control-plane integrity | `.claude/**`, `ai-tools-chown.sh`, `ai-tools-setgid.sh` | [ownership-and-hooks](.claude/rules/ownership-and-hooks.rule.md) |
| Claude Code settings, Bash deny rules ↔ SELinux policy | `.claude/settings.json` | [claude-settings](.claude/rules/claude-settings.rule.md) |
| Secret-named files, lockdown, pattern set | `ai-tools-lockdown.sh`, `ai-tools-chown.sh`, `secret-patterns*` | [secrets](.claude/rules/secret-handling.rule.md) |
| Toolchain provisioning + Node/claude updater, symlink repoint, post-upgrade relabel | `ai-tools-bootstrap.sh`, `nvm-update.sh`, `ai-tools-claude-symlink.sh`, `ai-tools-relabel-entrypoint.sh`, `nvm-update`/`ai-tools-relabel` units | [updater](.claude/rules/updater.rule.md) |
| Management CLI, project lifecycle, relabel | `bin/ai-tools.sh`, `ai-tools-{setfacl,unclaim,safedir,relabel}.sh`, `relabel.lib.sh` | [cli](.claude/rules/cli.rule.md) |
| Protected-paths backstop (refuse system dirs as targets) | `safe-paths.lib.sh` + the wrapper/CLI/elevated helpers | [safe-paths](.claude/rules/safe-paths.rule.md) |
| Shared logging library | `log.lib.sh` | [logging](.claude/rules/logging.rule.md) |
| User-facing message formatting (box, wrap, ties) | `msg.lib.sh` + its consumers | [messaging](.claude/rules/messaging.rule.md) |
| Test organization, hermeticity, categories | `tests/**` | [tests](.claude/rules/tests.rule.md) |
| ShellCheck baseline, `.shellcheckrc`, accepted findings | `src/**/*.sh`, `.shellcheckrc` | [shellcheck](.claude/rules/shellcheck.rule.md) |

## Trust chain (summary)

Each step's mechanism is in the rule files above; the invariant each guarantees:

1. `claude` resolves to the system wrapper `/usr/local/bin/claude`, running as the
   non-root operator who invoked it; it refuses a caller not in the `ai-ops` operators
   group before doing anything else.
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

The sudoers drop-in (`/etc/sudoers.d/ai-tools-claude`) is a static `%ai-ops` group rule
granting the **operators** (members of the `ai-ops` group, managed by `ai-tools-admin`)
two NOPASSWD rules:

```
%ai-ops  ALL=(SANDBOX_USER:SANDBOX_GROUP) NOPASSWD: /opt/ai-tools/bin/claude-run
%ai-ops  ALL=(root)                       NOPASSWD: /usr/local/sbin/ai-tools/ai-tools-relabel-entrypoint
```

The first **drops** privilege to `SANDBOX_USER` (launch); the second runs **as root** for
the on-demand `ai-tools --relabel` entrypoint relabel (a fixed-path, no-argument target —
see [launch](.claude/rules/launch.rule.md)). The toolchain update runs as `SANDBOX_USER` in
its own `systemd --user` instance and the automatic post-upgrade relabel runs through the
root-side `ai-tools-relabel.path` watcher, so neither needs a sudo rule. The agent runs
*as* `SANDBOX_USER`, which is not in `ai-ops` and has no rule of its own, so **neither**
rule grants it anything — including the root rule, which `SANDBOX_USER` cannot reach.
`claude-run` additionally refuses to launch
unless it runs as `SANDBOX_USER` and refuses if `SANDBOX_USER` is ever in `ai-ops`, so the
sandbox account can never hold the operator grant. The invariants the agent operates under:

- **`SANDBOX_USER` has no sudo rights** — not `rm -rf /`, not `cat /etc/shadow`, not any
  root helper. Root operations (chown, setgid, symlink repoint) go **exclusively**
  through the authenticated `ai-tools-handback` socket, which verifies the caller's uid
  with a kernel-supplied credential the peer cannot forge and adds no trust of its own —
  each verb's root helper re-validates independently
  ([handback-bridge](.claude/rules/handback-bridge.rule.md)). The session runs under
  `PR_SET_NO_NEW_PRIVS`, which drops `sudo`'s SUID bit, so `sudo` is inoperative from
  inside the session by construction.
- **`SANDBOX_USER` has no login shell and no password.**
- **The `%ai-ops` rules run only `claude-run` as `SANDBOX_USER`** — never an arbitrary
  shell or binary. `claude-run` is a fixed-path target (no glob), `root:SANDBOX_GROUP` and
  not writable by the agent. The agent itself, *as* `SANDBOX_USER`, holds no sudo rule at
  all.
- **The control-plane files are not agent-writable** — `settings.json`, the hooks,
  `nvm-update.sh`, and `claude-run` are `root:SANDBOX_GROUP` with no group write;
  `/opt/ai-tools/.claude` is setgid+sticky (the agent keeps its own state there but cannot
  delete or replace files it does not own) and `/opt/ai-tools/bin` is not group-writable,
  so the agent cannot unlink/replace them to disable its own guardrails. Root owns the
  control plane, so no operator can rewrite a guardrail either. See
  [ownership-and-hooks](.claude/rules/ownership-and-hooks.rule.md) for the exact modes
  (single-sourced in `control-plane.lib.sh`).
- **The allowlist gates where the agent launches and which written files get ownership
  restored. It is NOT a kernel-enforced read boundary** — once running, ordinary Unix
  permissions plus the `ai_tools_t` SELinux type govern reads/writes. Those filesystem
  permissions are the enforced isolation boundary. The CWD and every allowlist entry are
  canonicalized (`realpath`) before matching, so a symlink or `..` cannot smuggle a path
  past the gate ([launch](.claude/rules/launch.rule.md)). (A per-session `bubblewrap` mount
  namespace to make the allowlist a true access boundary is a deferred proposal; see
  [Boundaries and non-goals](#boundaries-and-non-goals) and memory.)
- **The ownership handback touches only `SANDBOX_USER`-owned inodes and cannot be
  redirected outside the tree.** `ai-tools-chown` acts on a path only while it is
  `SANDBOX_USER`-owned (the born-owner of an agent write), refuses symlinks and hardlinks,
  and applies the change race-safely against a path swap
  ([ownership-and-hooks](.claude/rules/ownership-and-hooks.rule.md)).
- **A protected-paths backstop refuses system directories as targets.** Independently of
  the allowlist, the launch wrapper, the claim CLI, and every elevated helper refuse to act
  on a system directory (`/`, `/etc`, `/var`, `/usr`, `/home`, `/opt/ai-tools`, …) or a user
  home root (`/home/<user>` — a whole home as a target would hand the agent its dotfiles
  and keys) — defense in depth against a system directory mistakenly added to
  `allowed-projects`. Matching is exact-or-ancestor, so real projects nested under an
  operator home or the sandbox-clone area pass. See
  [safe-paths](.claude/rules/safe-paths.rule.md).

## Boundaries and non-goals

The enforced isolation boundary is DAC plus the `ai_tools_t` SELinux type. The following are
deliberate scope decisions, not gaps, so a reader tells bounded design from an oversight:

- **The shared `SANDBOX_USER` account is the trust unit, not the session.** All operators'
  sessions run as one UID; per-project *ownership* returns to the owning operator, but two
  sessions under that account are not kernel-isolated from each other, and session scratch
  (`/tmp/claude-<uid>`, `/opt/ai-tools/.claude`) is shared. Per-operator UIDs and per-session
  `bubblewrap`/`--system` isolation are deferred (see
  [confinement](.claude/rules/confinement.rule.md) and memory).
- **`ai-ops` operators are trusted.** The model defends the host and other users from the
  *agent*, not from an operator, who already holds the launch grant.
- **Toolchain provenance is checksum-, allowlist-, and signature-gated.** The updater
  checksum-verifies Node, gates npm install scripts behind an allowlist, and verifies the
  installed toolchain's npm registry signatures before activating it — failing closed on a
  tamper (see [updater](.claude/rules/updater.rule.md)). Pinning the registry signing key
  (defense against a fully compromised registry) is deferred.

## Cross-cutting conventions

- **`/opt/ai-tools`, not `/home`** — `/home` is `nosuid`, which would defeat the
  `sudo` UID-switch; `/opt/ai-tools` is not. Detail in
  [launch](.claude/rules/launch.rule.md).
- **Collaborative ownership** — the operator and agent co-write the project tree via two
  umask-independent POSIX ACL grants on it (the permission companions to setgid's
  shared-group inheritance): `g:SANDBOX_GROUP:rwX` is the agent's access to operator-written
  files, and `user:<operator>:rwX` is the operator's access to agent-written files. Both
  directions are ACL-based, so the operator stays **out** of `SANDBOX_GROUP` and its access
  does not hinge on the ownership handback's timing. Detail in
  [ownership-and-hooks](.claude/rules/ownership-and-hooks.rule.md).
- **Logging** — components log through `log.lib.sh` to journald (always) and root-only
  `/var/log/ai-tools/*.log` (root writers only). Detail in
  [logging](.claude/rules/logging.rule.md).
- **User-facing messages** — refusals, notices, and warnings render through `msg.lib.sh`:
  wrapped within 80 columns with no line ending on a preposition, framed in a paste-safe
  `#` box on a terminal and emitted plain when piped (so logs and test greps stay
  line-matchable). Detail in [messaging](.claude/rules/messaging.rule.md).
- **Root sudo-helpers** live under `/usr/local/sbin/ai-tools/` (`chown`, `setgid`, `setfacl`,
  `unclaim`, `safedir`, `reclaim`, `claude-symlink`, `lockdown`, `relabel`); shared libraries under
  `/usr/local/lib/ai-tools/` (`secret-patterns`, `skip-dirs`, `safe-paths`, `relabel`,
  `operator`, `msg`, `log`), plus `path-dedup.sh`, the PATH-ordering fragment
  `ai-tools-admin` wires into operator dotfiles (see [launch](.claude/rules/launch.rule.md)).

### Documentation register

Match the surface to its skill — they use different voices:

- `CLAUDE.md`, `.claude/rules/*.rule.md`, file/module headers, design notes → **reference-docs**
  (present-tense spec; state current behavior, not history).
- `README.md`, getting-started, usage guides → **usage-docs**.
- Method/function/class doc comments and docstrings → **doc-comments**.
- Changelogs, release notes, migration guides → **change-docs**.
