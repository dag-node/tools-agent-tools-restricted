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
  the other, resolving any conflict against the code, never defaulting to one side. Adding,
  moving, or renaming a source file a rule documents obligates updating that rule's `paths:`
  in the same change — the file→rule auto-load is only as complete as `paths:`, and a
  documented file left out of it silently stops loading its rule.
  Conventions for writing rules: `.claude/rules/authoring.rule.md`.
- **Auto memory** (`/memory`) — decisions, rejected alternatives, and open follow-ups
  that are not derivable from the code.

### Component map

| Area | Source | Rule |
|---|---|---|
| Launch, allowlist gating, sudoers, PATH | `bin/ai-tools-run.sh`, `usr/local/bin/claude.sh`, `allowed-projects`, `sudoers.d/ai-tools-claude`, `lib/ai-tools/path-dedup.sh` | [launch](.claude/rules/launch.rule.md) |
| Namespaces, SELinux transition, preflight, `/tmp` | `selinux/**`, `bin/ai-tools-run.sh` | [confinement](.claude/rules/confinement.rule.md) |
| Root-op socket (daemon/client/units) | `ai-tools-handback*`, `ai-tools-handback-client*` | [handback-bridge](.claude/rules/handback-bridge.rule.md) |
| Hooks, sweeps, `.git` reclaim, setgid, control-plane integrity | `.claude/**`, `ai-tools-chown.sh`, `ai-tools-setgid.sh` | [ownership-and-hooks](.claude/rules/ownership-and-hooks.rule.md) |
| Claude Code settings, Bash deny rules ↔ SELinux policy | `.claude/settings.json` | [claude-settings](.claude/rules/claude-settings.rule.md) |
| Shipped assets: shared skills + per-agent agents, their placement chain and seeding | `usr/share/ai-tools/**`, `lib/ai-tools/managed-assets.lib.sh` | [shipped-assets](.claude/rules/shipped-assets.rule.md) |
| Secret-named files, lockdown, pattern set | `ai-tools-lockdown.sh`, `ai-tools-chown.sh`, `secret-patterns*` | [secrets](.claude/rules/secret-handling.rule.md) |
| Toolchain provisioning + Node/claude updater, symlink repoint, post-upgrade relabel | `ai-tools-bootstrap.sh`, `nvm-update.sh`, `ai-tools-launcher-symlink.sh`, `ai-tools-relabel-agent.sh`, `nvm-update`/`ai-tools-relabel` units | [updater](.claude/rules/updater.rule.md) |
| Provider manifests + fail-closed enablement (agents + integrations), the shared `KEY=value` config grammar, the `session-env.d` session-env seam, and the dotnet integration | `lib/ai-tools/{conf,providers}.lib.sh`, `lib/ai-tools/{agents,integrations,session-env}.d/**`, `ai-tools-dotnet.sh`, `operator.conf` `AI_TOOLS_{AGENTS,INTEGRATIONS}` | [providers](.claude/rules/providers.rule.md) |
| Management CLI, project lifecycle, relabel | `bin/ai-tools.sh`, `ai-tools-{setfacl,unclaim,safedir,relabel}.sh`, `relabel.lib.sh` | [cli](.claude/rules/cli.rule.md) |
| Protected-paths backstop (refuse system dirs as targets) | `safe-paths.lib.sh` + the wrapper/CLI/elevated helpers | [safe-paths](.claude/rules/safe-paths.rule.md) |
| Shared logging library | `log.lib.sh` | [logging](.claude/rules/logging.rule.md) |
| User-facing message formatting (box, wrap, ties) | `msg.lib.sh` + its consumers | [messaging](.claude/rules/messaging.rule.md) |
| Test organization, hermeticity, categories | `tests/**` | [tests](.claude/rules/tests.rule.md) |
| ShellCheck baseline, `.shellcheckrc`, accepted findings | `src/**/*.sh`, `.shellcheckrc` | [shellcheck](.claude/rules/shellcheck.rule.md) |

## Trust chain (summary)

Each step's mechanism is in the rule files above; the invariant each guarantees:

1. An agent's command (`claude`) resolves to that agent's system wrapper
   (`/usr/local/bin/claude`), running as the non-root operator who invoked it; it refuses a
   caller not in the `ai-ops` operators group before doing anything else.
2. The wrapper launches only inside an allowed project, never a `!`-excluded CWD.
3. It resolves the versioned binary via a single `readlink` hop, validates it, and
   execs the shared confinement shim `ai-tools-run` as `SANDBOX_USER` with the path in
   `AI_TOOLS_AGENT_EXEC`.
4. `ai-tools-run` names no agent: it accepts the executable only at a semver version
   directory inside the sandbox toolchain **and** only when its launcher belongs to an
   enabled agent manifest, then wraps the session in a transient systemd `--user`
   service unit whose kernel properties confine it (`RestrictNamespaces=yes`,
   `NoNewPrivileges`, SELinux `ai_tools_t`), with an env allowlist and the project as
   `WorkingDirectory`.
5. The session runs as `SANDBOX_USER`; files it writes are born `SANDBOX_USER`-owned.
6. `PostToolUse`/`Stop`/`SessionStart` hooks hand agent-written paths back to
   `<you>:SANDBOX_GROUP` (secret-named files to `<you>:<you> 600`) through the
   `ai-tools-handback` socket — `sudo` is never used inside the session. An agent whose manifest
   declares no such hooks (`handback` ≠ `hooks`) gets the same handback from `ai-tools-run`'s
   session-end sweep instead, so no agent leaves the operator's tree sandbox-owned.
7. `SessionStart` additionally reclaims `.git` and normalizes setgid for the project.

## Security model — what `SANDBOX_USER` can and cannot do

The sudoers drop-in (`/etc/sudoers.d/ai-tools-claude`) is a static `%ai-ops` group rule
granting the **operators** (members of the `ai-ops` group, managed by `ai-tools-admin`)
two NOPASSWD rules:

```
%ai-ops  ALL=(SANDBOX_USER:SANDBOX_GROUP) NOPASSWD: /opt/ai-tools/bin/ai-tools-run
%ai-ops  ALL=(root)                       NOPASSWD: /usr/local/sbin/ai-tools/ai-tools-relabel-agent ""
```

The first **drops** privilege to `SANDBOX_USER` (launch); the second runs **as root** for
the on-demand `ai-tools --relabel` entrypoint relabel (a fixed path, pinned by the trailing
`""` to the zero-argument form — see [launch](.claude/rules/launch.rule.md)). The toolchain update runs as `SANDBOX_USER` in
its own `systemd --user` instance and the automatic post-upgrade relabel runs through the
root-side `ai-tools-relabel.path` watcher, so neither needs a sudo rule. The agent runs
*as* `SANDBOX_USER`, which is not in `ai-ops` and has no rule of its own, so **neither**
rule grants it anything — including the root rule, which `SANDBOX_USER` cannot reach.
`ai-tools-run` additionally refuses to launch
unless it runs as `SANDBOX_USER` and refuses if `SANDBOX_USER` is ever in `ai-ops`, so the
sandbox account can never hold the operator grant.

### Trust is one-sided, and every refusal moves to less access

The invariants below are instances of one property, stated once here rather than re-derived in
each: **every input that decides what a session may do passes a single predicate for its kind,
and every way that predicate can fail resolves to *less* access — never more — and is reported.**
There is no input whose corruption, absence, or tampering widens what the agent gets, so the
sandbox cannot improve its own position by breaking something.

| decision | its predicate | what a failure yields |
|---|---|---|
| where a session may start | the canonicalized allowlist + the protected-paths backstop | no launch |
| which executable may start it | a launcher an enabled manifest claims, at a semver path in the toolchain | no launch |
| whether it will be confined | the pre-launch SELinux transition probe | no launch |
| which providers it gets | `ai_tools_conf_is_trusted` on every manifest, directory, and fragment | the default-enabled baseline, never "enable all" |
| which paths handback may touch | born-`SANDBOX_USER` ownership, re-checked race-safely as root | the path is left alone |
| which toolchain may be activated | npm registry signature verification | the previous, trusted version stays |

The invariants the agent operates under:

- **`SANDBOX_USER` has no sudo rights** — not `rm -rf /`, not `cat /etc/shadow`, not any
  root helper. Root operations (chown, setgid, symlink repoint) go **exclusively**
  through the authenticated `ai-tools-handback` socket, which verifies the caller's uid
  with a kernel-supplied credential the peer cannot forge and adds no trust of its own —
  each verb's root helper re-validates independently
  ([handback-bridge](.claude/rules/handback-bridge.rule.md)). The session runs under
  `PR_SET_NO_NEW_PRIVS`, which drops `sudo`'s SUID bit, so `sudo` is inoperative from
  inside the session by construction.
- **`SANDBOX_USER` has no login shell and no password.**
- **The `%ai-ops` rules run only `ai-tools-run` as `SANDBOX_USER`** — never an arbitrary
  shell or binary. `ai-tools-run` is a fixed-path target (no glob), `root:SANDBOX_GROUP` and
  not writable by the agent. The agent itself, *as* `SANDBOX_USER`, holds no sudo rule at
  all.
- **The control-plane files are not agent-writable** — `settings.json`, the hooks,
  `nvm-update.sh`, and `ai-tools-run` are `root:SANDBOX_GROUP` with no group write;
  each agent's config directory (`/opt/ai-tools/<config_dir>`, `.claude` for Claude Code — the
  agent's own package owns it, the base pins its mode) is setgid+sticky, so the agent keeps its
  own state there but cannot delete or replace files it does not own, and `/opt/ai-tools/bin` is
  not group-writable,
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
- **The sandbox cannot widen its own surface.** Which agents the toolchain installs, what
  environment and PATH a session is handed, which binary may be labelled as an agent entrypoint,
  and which launcher symlinks exist all come from `operator.conf` and the root-owned provider
  manifests and fragments. The code reading them runs *as* `SANDBOX_USER`, so each input — **and
  the directory holding it**, since a group-writable directory lets a non-root writer replace a
  root-owned file inside it — is honored only while it passes the trust predicate above. A
  provider marked `default_enable=no` because it widens host surface can therefore only be turned
  on by an operator editing a root-owned file. See [providers](.claude/rules/providers.rule.md).
- **A protected-paths backstop refuses system directories as targets.** Independently of
  the allowlist, the launch wrapper, the claim CLI, and every elevated helper that takes a
  caller-supplied path refuse to act on a system directory (`/`, `/etc`, `/var`, `/usr`, `/home`, `/opt/ai-tools`, …) or a user
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

- **A security guarantee is asserted from both ends.** Every refusal above is covered by a
  **pair** of tests: a runtime one that the refusal actually fires (drive the resolver or helper
  into the bad state and assert it moves to less access), and a boundary one, run **as the
  agent**, that the state which triggers it is unreachable in the first place. Neither is
  sufficient alone — the first catches a host someone has already broken, the second catches the
  agent trying to break it — so a new guarantee lands with both. Detail and the worked example in
  [tests](.claude/rules/tests.rule.md).
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
  wrapped with no line ending on a preposition, framed in a paste-safe `#` box on a
  terminal (alerts within 50 columns, flow-block headlines and guidance screens within 80)
  and emitted plain when piped (so logs and test greps stay line-matchable). Detail
  in [messaging](.claude/rules/messaging.rule.md).
- **One confinement shim serves every agent.** `/opt/ai-tools/bin/ai-tools-run` is
  `ai-tools-base`-owned and agent-agnostic; an `ai-tools-agents-*` package ships its wrapper,
  its manifest, and its session-env fragment, and inherits the single `%ai-ops` sudoers grant
  rather than adding one. See [launch](.claude/rules/launch.rule.md).
- **Root sudo-helpers** live under `/usr/local/sbin/ai-tools/` (`chown`, `setgid`, `setfacl`,
  `unclaim`, `safedir`, `reclaim`, `launcher-symlink`, `lockdown`, `relabel`, `bootstrap`,
  `relabel-agent`, `admin`, `dotnet`); shared libraries under `/usr/local/lib/ai-tools/`
  (`conf`, `secret-patterns`, `skip-dirs`, `safe-paths`, `relabel`, `operator`, `control-plane`,
  `confinement`, `npm-verify`, `managed-assets`, `providers`, `msg`, `log`), plus `path-dedup.sh`,
  the PATH-ordering fragment `ai-tools-admin` wires into operator dotfiles (see
  [launch](.claude/rules/launch.rule.md)). That directory is `0751 root:SANDBOX_GROUP` and its
  contents `root`-owned and non-group-writable — load-bearing, since the sandbox account sources
  several of these libraries (see the provider-seam invariant below).

### Documentation register

Match the surface to its skill — they use different voices:

- `CLAUDE.md`, `.claude/rules/*.rule.md`, file/module headers, design notes → **reference-docs**
  (present-tense spec; state current behavior, not history).
- `README.md`, getting-started, usage guides → **usage-docs**.
- Method/function/class doc comments and docstrings → **doc-comments**.
- Changelogs, release notes, migration guides → **change-docs**.
