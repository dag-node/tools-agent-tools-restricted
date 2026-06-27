---
paths:
  - "src/opt/ai-tools/bin/claude-run.sh"
  - "src/usr/local/bin/claude.sh"
  - "src/etc/sudoers.d/ai-tools-claude"
  - "src/etc/profile.d/path_dedup.sh"
---

# Launch path and project gating

The wrapper → `claude-run` → session handoff: binary resolution, allowlist
gating, and placing the session in a transient systemd unit. Kernel confinement
of that unit (namespaces, SELinux transition, `/tmp`) lives in
[confinement](confinement.rule.md); ownership handback in
[ownership-and-hooks](ownership-and-hooks.rule.md).

## Resolution and gating (the wrapper)

1. `claude` resolves to the system wrapper `/usr/local/bin/claude` (`claude.sh`,
   `root:root 0755`, rpm-owned), which runs as the invoking operator. `path_dedup.sh`
   ranks `/usr/local/bin` (Tier 1) above the nvm shims, so it shadows the nvm-managed
   `claude` on every login shell's PATH without any per-operator dotfile edit.
2. It gates on `ai-ops` membership first: a caller not in the operators group is refused
   with a framed `msg.lib` message that names the `ai-tools-admin operator add` fix,
   rather than leaking the raw `sudo` denial the `%ai-ops` rule would otherwise produce.
3. The wrapper checks the current directory against the operator's approved-projects
   allowlist (`~/.config/ai-tools/allowed-projects`, keyed off the launching operator's
   `${HOME}`); it starts only inside an allowed project and refuses a CWD carved out by a
   `!` exclusion.
4. It resolves the versioned binary via the stable symlink `/opt/ai-tools/bin/claude`
   with a single `readlink` hop, validates the target is an absolute, `..`-free path
   matching `${AI_TOOLS_NVM_DIR}/versions/node/*/bin/claude`, exports it as
   `CLAUDE_EXEC`, and execs
   `sudo -u SANDBOX_USER -g SANDBOX_GROUP -- /opt/ai-tools/bin/claude-run`.

The resolved path is validated as an integrity check against a misconfigured or
compromised `ai-tools-claude-symlink` root helper, not a guard against external
injection — only root writes `/opt/ai-tools/bin` (`0551 root:SANDBOX_GROUP`).

### Symlink resolution is one hop, not full resolution

The versioned `bin/claude` is itself an npm symlink into the package
(`-> .../@anthropic-ai/claude-code/bin/claude.exe`). Fully resolving it with
`realpath`/`readlink -f` traverses the package directory (mode 700,
`SANDBOX_USER`-owned), which the invoking user cannot enter — EACCES, a silent abort
under `set -e`. One hop yields the versioned `.../node/<ver>/bin/claude` path, which
the wrapper validates with string checks only (no filesystem traversal beyond the
symlink). The one-hop constraint exists solely to avoid EACCES; it carries no coupling
to sudoers matching, which targets the fixed path `/opt/ai-tools/bin/claude-run`.

## The `claude-run` service shim (launch mechanics)

`claude-run` (550 `<you>:SANDBOX_GROUP`, not writable by the agent) re-validates
`CLAUDE_EXEC` against the same nvm-path pattern and wraps the session in a transient
systemd *service* unit (`systemd-run --user --pty`) before exec'ing the versioned
binary. The service runs in `SANDBOX_USER`'s systemd user instance, kept alive by
`loginctl enable-linger` (see [updater](updater.rule.md)). The kernel security properties
that unit carries are in [confinement](confinement.rule.md); the launch-shaping properties:

**`UMask=0007`** keeps agent-created files group-writable so the collaborative
ownership model holds. A service unit does not inherit the caller's umask (a scope
does), so the umask is set as a unit property, authoritative over the per-command
sudoers `umask`.

**Environment is an explicit allowlist.** The user manager spawns the service with
its own environment, not `claude-run`'s, so `claude-run` forwards only a named
allowlist (`TERM`/`COLORTERM`, the locale `LC_*`/`LANG` set, proxy vars) via
`--setenv=NAME`, and pins `HOME=/opt/ai-tools`, a controlled `PATH`, and
`NODE_COMPILE_CACHE=/opt/ai-tools/.cache/node-compile-cache`. The operator's secrets
(`ANTHROPIC_API_KEY`, `AWS_*`, `SSH_AUTH_SOCK`, …) stay out of the session by
construction, independent of sudo's `env_reset`/`env_keep`. To share a variable
deliberately, add its name to `_ENV_ALLOW` in `claude-run`. `HOME` stays
`/opt/ai-tools`: the agent's control plane (`settings.json`, the hooks,
`~/.claude.json`) is operator-owned and `ai_tools_home_t`, and is not relocated into
the agent-writable project tree.

**`WorkingDirectory` is the validated project directory.** A transient unit defaults
its cwd to `/`. The wrapper exports the realpath'd, allowlist- and claim-validated
project directory as `CLAUDE_PROJECT_DIR`, carried through sudo via `env_keep`;
`claude-run` re-validates it (absolute, `..`-free, existing) and sets it as the unit's
`--working-directory`, so the session starts in the project. The `chdir` runs in the
user manager's domain before the transitioning `exec`, so that domain needs `search`
on `ai_tools_project_t` (see [confinement](confinement.rule.md)).

**`--pty` service, not `--scope`.** `RestrictNamespaces` and `UMask` are exec-context
directives; systemd 252 rejects them on a scope unit (`Unknown assignment`) because a
scope has no exec context — the caller, not the manager, performs the final `exec`.
A service unit (the manager execs `ExecStart`) accepts them, and `--pty` keeps the
session attached to the terminal so claude's TUI works.

## Why `/opt/ai-tools`, not `/home`

`/home` is mounted `nosuid`, so a `sudo` UID-switch that execs a binary there still
runs as the invoking user. `/opt/ai-tools` has no `nosuid`, so the switch to
`SANDBOX_USER` takes effect and the binary is owned by `SANDBOX_USER`.

## Sudoers grants (the two `%ai-ops` rules)

The drop-in (`/etc/sudoers.d/ai-tools-claude`) is a **static** `%ai-ops` group rule the
package ships unchanged — membership in the `ai-ops` operators group (managed by
`ai-tools-admin`) is what grants access, so there is no per-operator line to generate:

```
%ai-ops  ALL=(SANDBOX_USER:SANDBOX_GROUP) NOPASSWD: /opt/ai-tools/bin/claude-run
%ai-ops  ALL=(root)                       NOPASSWD: /usr/local/sbin/ai-tools/ai-tools-relabel-entrypoint
```

The first rule **drops** privilege to the lower-privileged `SANDBOX_USER`; the agent runs
*as* `SANDBOX_USER`, which is not in `ai-ops` and has no rule of its own, so it can invoke
neither. `claude-run` is a fixed-path target (no glob); the versioned binary is exec'd by
`claude-run` after it re-validates `CLAUDE_EXEC`.

The second rule runs **as root**: `ai-tools --relabel` uses it to restore `ai_tools_exec_t`
on the new claude entrypoint after a Node upgrade, which needs the `unconfined_t` that root
holds (see [updater](updater.rule.md)). The grant is scoped to exactly that action — a
**fixed, non-glob path with no arguments**, so it resolves to one program doing one thing
(`restorecon` the nvm-tree entrypoint) — and the helper is `750 root:root`, owned and
writable by root alone. It is an operators-group grant, keeping the root privilege on the
operator side beside the launch rule. The automatic post-upgrade relabel runs through the
root-side `ai-tools-relabel.path` watcher, which needs no sudo rule. The toolchain update
runs as `SANDBOX_USER` in its own `systemd --user` instance, so it needs no sudo rule
either.

`SANDBOX_USER` holds no sudo rights in this file. Two `claude-run` preflights enforce the
account boundary the sudoers model assumes: it refuses to launch unless it runs **as**
`SANDBOX_USER` (a direct or sudo invocation landing as root or another user fails closed), and
it refuses if `SANDBOX_USER` is ever a member of `ai-ops` (so the sandbox account can never
hold the operator grant). See the security-model invariants in `CLAUDE.md`.

`umask=0007,umask_override` and `env_keep += "CLAUDE_EXEC CLAUDE_PROJECT_DIR"` (for
`claude-run`) are scoped per-command with
`Defaults!<command>`, applying only to those commands. The sudoers `umask` sets
`claude-run`'s own process umask; the transient service unit does not inherit it, so
the agent's umask comes authoritatively from the `UMask=0007` unit property.
`CLAUDE_EXEC` carries the wrapper-validated versioned path for re-validation;
`CLAUDE_PROJECT_DIR` carries the validated project directory, becoming the unit's
`WorkingDirectory`.

## Allowlist `!` exclusions are honored by both consumers

`!`-prefixed lines in `allowed-projects` are exclusions and override allows. The
wrapper refuses to launch with an excluded CWD, and `ai-tools-chown` skips ownership
restoration on excluded paths. Keep the two in sync — a plain `!`-path also covers its
contents; globs match as-is.

## PATH ordering

The wrapper lives in `/usr/local/bin`, which `path_dedup.sh` ranks Tier 1 — above the nvm
shims it leaves in Tier 4 — so `/usr/local/bin/claude` resolves ahead of the nvm-managed
`claude` regardless of where the operator's dotfiles place anything. `path_dedup.sh` (in
`/etc/profile.d/`) is sourced host-wide for every login shell, so the ordering holds with no
per-operator action there; interactive non-login shells read `~/.bashrc` only, so the dotfile
must source `path_dedup.sh` after `nvm.sh` to get the same PATH. `ai-tools-admin operator add`
offers to add that guard to the operator's two dotfiles (after their nvm init), and
`ai-tools-bootstrap` adds it to the sandbox account's `~/.bash_profile`.
