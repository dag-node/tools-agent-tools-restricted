---
paths:
  - "src/opt/ai-tools/bin/nvm-update.sh"
  - "src/home/user/.local/bin/nvm-update.sh"
  - "src/usr/local/sbin/ai-tools/ai-tools-claude-symlink.sh"
  - "src/usr/local/sbin/ai-tools/ai-tools-relabel-entrypoint.sh"
  - "src/home/user/.config/systemd/user/nvm-update.service"
  - "src/home/user/.config/systemd/user/nvm-update.timer"
---

# Node/claude updater and symlink repoint

A scheduled `nvm-update` job keeps Node.js v22 and `@anthropic-ai/claude-code` current
for both the login user and `SANDBOX_USER`, pinned to the same build. After an upgrade
the versioned `claude` symlink is repointed through a root helper.

## Version resolution

When multiple v22 versions exist, `nvm ls-remote | sort -V | tail -1` selects the highest
semver — not "first match" or "currently active". Prune logic collects all versions
referenced by any named alias into an associative array before removing anything, so a
version another alias points to is retained.

## Symlink repoint root helper (`ai-tools-claude-symlink`)

`/opt/ai-tools/bin` is `550` and not group-writable (see
[ownership-and-hooks](ownership-and-hooks.rule.md)), so `SANDBOX_USER` cannot refresh the
versioned `claude` symlink itself after a Node upgrade. That repoint is delegated to the
narrow root helper `ai-tools-claude-symlink`: it accepts one argument, validates it is
exactly a `…/node/v<MAJOR>.<MINOR>.<PATCH>/bin/claude` path that exists (its own
anchored-regex check, **not** the coarse sudoers glob, is authoritative — argument
wildcards can match `/`), then atomically repoints the symlink. The sandbox updater and
`install.sh` are the only callers; the updater reaches it through the
[handback bridge](handback-bridge.rule.md) `SYMLINK` verb. The repoint helper does **not**
relabel the new entrypoint (see below) — it runs in the handback domain, which has no
relabel rights.

## Post-upgrade entrypoint relabel (`ai-tools-relabel-entrypoint`)

A fresh Node tree's `claude.exe` is born mislabelled (`bin_t`), so the
`unconfined_t → ai_tools_t` transition stops firing; under enforcing `claude-run`
fail-closes (refuses to launch rather than run unconfined) until the label is restored.
The relabel runs from the **login-side `nvm-update.sh`** (the projects user, `unconfined_t`,
which *can* relabel), right after it delegates the sandbox update: it calls the root helper
`ai-tools-relabel-entrypoint` through a dedicated fixed-path NOPASSWD sudo rule (the third
rule in `sudoers.d/ai-tools-claude`; see [launch](launch.rule.md)). The helper restorecons
every `claude.exe` under the nvm tree and verifies `ai_tools_exec_t`. It is best-effort
(a failure warns, never aborts the upgrade) and idempotent, and no-ops cleanly when SELinux
is off **or** the optional `ai_tools` module is not installed — it acts only on entrypoints
the file-context DB maps to `ai_tools_exec_t`, the same condition `claude-run` keys on.

The relabel is deliberately **not** done in the handback domain that repoints the symlink:
`ai_tools_handback_t` is agent-reachable and is intentionally not granted relabel rights
(`ai_tools.te`), so keeping the privilege on the login-updater side leaves it off the
agent's reach. `ai-tools --relabel` (see [cli](cli.rule.md)) runs the same helper on demand
as the manual fallback — for an out-of-band upgrade or if the timer's relabel failed — while
`install-selinux.sh relabel` remains the comprehensive source-tree sweep.

## `loginctl enable-linger`

`loginctl enable-linger` keeps the projects user's systemd instance running after logout,
so the daily `nvm-update` timer fires without an active login. Required for
headless/unattended operation.
