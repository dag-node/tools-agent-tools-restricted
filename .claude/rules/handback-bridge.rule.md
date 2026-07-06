---
paths:
  - "src/usr/local/sbin/ai-tools/ai-tools-handback.py"
  - "src/usr/local/bin/ai-tools-handback-client.py"
  - "src/usr/lib/systemd/system/ai-tools-handback.socket"
  - "src/usr/lib/systemd/system/ai-tools-handback@.service"
---

# Handback socket bridge (`ai-tools-handback`)

The session runs under `PR_SET_NO_NEW_PRIVS` (forced by `RestrictNamespaces=yes`, see
[confinement](confinement.rule.md)), which drops `sudo`'s SUID bit. The `PostToolUse`,
`Stop`/`SessionStart` hooks (see [ownership-and-hooks](ownership-and-hooks.rule.md)) and
`nvm-update.sh` (see [updater](updater.rule.md)) therefore reach root operations through an
`AF_UNIX SOCK_STREAM` socket (`/run/ai-tools/handback.sock`, `0660 root:SANDBOX_GROUP`)
served by a systemd `Accept=yes` socket unit started at boot. This is the session's only
privilege path; `sudo` is never exec'd from inside the session.

## Protocol

One `VERB SP ARG LF` request per connection. The response is zero or more `MSG TEXT LF`
relay lines followed by `OK LF` or `ERR REASON LF`. MSG lines carry helper stderr (for
example a secret-file NOTICE) back to the client's stderr, which the hooks forward into
the agent session.

## Authentication

The daemon reads `SO_PEERCRED` on fd 0 (the accepted socket) and rejects any peer whose
uid ≠ `SANDBOX_USER`. DAC provides the outer gate: the socket file is
`0660 root:SANDBOX_GROUP`, so only root and `SANDBOX_GROUP` members connect; world gets
`EACCES` before reaching the daemon.

Under SELinux, systemd derives the listening socket's context from the daemon binary's
on-disk label at bind time, and the session's `connectto` is granted against that
context (`ai_tools_handback_t`). The SELinux installer therefore relabels the daemon
(`_relabel_helpers`) before any socket restart (`_relabel_runtime`).

## Verbs

- `CHOWN ARG` → `ai-tools-chown ARG`
- `SETGID ARG` → `ai-tools-setgid ARG`
- `SYMLINK ARG` → `ai-tools-claude-symlink ARG`

Each root helper re-validates the path against the allowlist and the
`SANDBOX_USER`-owned guard independently, so the daemon is a thin dispatcher that adds
no trust of its own.

## Files

- daemon `/usr/local/sbin/ai-tools/ai-tools-handback` (750 root:root, Python 3)
- client `/usr/local/bin/ai-tools-handback-client` (750 root:SANDBOX_GROUP, Python 3)
- socket unit `/usr/lib/systemd/system/ai-tools-handback.socket`
- service template `/usr/lib/systemd/system/ai-tools-handback@.service`
