---
paths:
  - "src/opt/ai-tools/bin/nvm-update.sh"
  - "src/home/user/.local/bin/nvm-update.sh"
  - "src/usr/local/sbin/ai-tools/ai-tools-claude-symlink.sh"
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
[ownership-and-hooks](ownership-and-hooks.md)), so `SANDBOX_USER` cannot refresh the
versioned `claude` symlink itself after a Node upgrade. That repoint is delegated to the
narrow root helper `ai-tools-claude-symlink`: it accepts one argument, validates it is
exactly a `…/node/v<MAJOR>.<MINOR>.<PATCH>/bin/claude` path that exists (its own
anchored-regex check, **not** the coarse sudoers glob, is authoritative — argument
wildcards can match `/`), then atomically repoints the symlink. The sandbox updater and
`install.sh` are the only callers; the updater reaches it through the
[handback bridge](handback-bridge.md) `SYMLINK` verb.

## `loginctl enable-linger`

`loginctl enable-linger` keeps the projects user's systemd instance running after logout,
so the daily `nvm-update` timer fires without an active login. Required for
headless/unattended operation.
