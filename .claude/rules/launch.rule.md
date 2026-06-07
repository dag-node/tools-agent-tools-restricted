---
paths:
  - "src/opt/ai-tools/bin/claude-run.sh"
  - "src/home/user/.local/bin/claude.sh"
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

1. `claude` resolves to the wrapper `~/.local/bin/claude` (`claude.sh`), which runs
   as the invoking user.
2. The wrapper checks the current directory against the approved-projects allowlist
   (`~/.config/ai-tools/allowed-projects`); it starts only inside an allowed project
   and refuses a CWD carved out by a `!` exclusion.
3. It resolves the versioned binary via the stable symlink `/opt/ai-tools/bin/claude`
   with a single `readlink` hop, validates the target is an absolute, `..`-free path
   matching `${AI_TOOLS_NVM_DIR}/versions/node/*/bin/claude`, exports it as
   `CLAUDE_EXEC`, and execs
   `sudo -u SANDBOX_USER -g SANDBOX_GROUP -- /opt/ai-tools/bin/claude-run`.

The resolved path is validated as an integrity check against a misconfigured or
compromised `ai-tools-claude-symlink` root helper, not a guard against external
injection — only root and the invoking user can write `/opt/ai-tools/bin`.

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

## Sudoers grants (the two `<you>` rules)

The drop-in (`/etc/sudoers.d/ai-tools-claude`, `@PROJECTS_USER@`/`@SANDBOX_USER@`
substituted at install) grants exactly:

```
<you>  ALL=(SANDBOX_USER:SANDBOX_GROUP) NOPASSWD: /opt/ai-tools/bin/claude-run
<you>  ALL=(SANDBOX_USER:SANDBOX_GROUP) NOPASSWD: /opt/ai-tools/bin/nvm-update.sh v[0-9]*.[0-9]*.[0-9]*
```

Both rules **drop** privilege to the lower-privileged `SANDBOX_USER`; the agent runs
*as* `SANDBOX_USER` and cannot invoke a `<you>` rule, so neither grants the agent
anything. `claude-run` is a fixed-path target (no glob); the versioned binary is
exec'd by `claude-run` after it re-validates `CLAUDE_EXEC`. `SANDBOX_USER` holds no
sudo rights in this file (see the security-model invariants in `CLAUDE.md`).

`umask=0007,umask_override` and `env_keep += "CLAUDE_EXEC CLAUDE_PROJECT_DIR"` (for
`claude-run`) and `env_keep` (for `nvm-update.sh`) are scoped per-command with
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

`~/.local/bin` precedes the nvm shims in `$PATH`, so the wrapper resolves ahead of the
nvm-managed `claude` (which would otherwise shadow it). `path_dedup.sh` (in
`/etc/profile.d/`) enforces this when sourced after `nvm.sh` in `~/.bashrc` and
`~/.bash_profile`; `install.sh` warns when the ordering is wrong rather than editing
dotfiles.
