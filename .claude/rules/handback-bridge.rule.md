---
paths:
  - "src/usr/local/libexec/ai-tools/ai-tools-handback.py"
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

The socket unit is **enabled by a shipped preset**, `85-ai-tools.preset`
(`enable ai-tools-handback.socket`, read before the distro's `90-default.preset`), so a package
install brings the handback up by itself. A bare `%systemd_post`/`install.sh` without the preset
would leave the unit at the distro default (`disabled`) — a socket that never listens, whose whole
effect is silent: every `CHOWN` fails, files stay `SANDBOX_USER`-owned, and the tree rots into
"dubious ownership". The preset is applied by `%systemd_post` on **initial install only**, so a
later operator `systemctl disable` survives upgrades. The socket being down is not a security
failure — DAC, `ai_tools_t`, and the project `user:<operator>` ACL keep the operator's access
intact — so the consumers **warn and proceed** rather than fail closed: `ai-tools-run` emits a
launch-time NOTICE naming the fix, and the sweeps/reclaim skip the walk and report the stranded
work instead of a count of failed calls (see [ownership-and-hooks](ownership-and-hooks.rule.md)
and [launch](launch.rule.md)).

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
- `SYMLINK ARG` → `ai-tools-launcher-symlink ARG`

Each root helper re-validates the path against the allowlist and the
`SANDBOX_USER`-owned guard independently, so the daemon dispatches without adding
trust of its own.

## Logging

The daemon keeps its own operation trail (`_audit`), the socket-layer counterpart to the
helpers' `chown.log`/`setgid.log`/`symlink.log`. Because it is Python it does not source
`log.lib.sh`; it writes the same `<ts> <LEVEL> [<pid>] <msg>` format to two sinks: journald
(stderr → `StandardError=journal`, with an sd-daemon `<N>` priority prefix so `journalctl -t
ai-tools-handback -p warning` filters) and the root-only `/var/log/ai-tools/handback.log`.
It runs as root (and `ai_tools_handback_t` holds `create`/`append` on `ai_tools_log_t`, so
the write succeeds under enforcing), so it is the file's only writer; the agent-side client
cannot write the `700` dir (DAC) and stays journald-only. Recorded events: rejected peers
(`SO_PEERCRED` mismatch, `WARNING`), malformed or refused requests (`WARNING`), helper
timeouts/exec failures (`ERROR`), and one `INFO` line per served request (`verb`, peer pid,
arg, helper result) — a non-zero helper exit stays `INFO`, since it is often a routine skip
(a path outside the allowlist). Writes are best-effort, never blocking or failing a
handback. See [logging](logging.rule.md).

## Files

- daemon `/usr/local/libexec/ai-tools/ai-tools-handback` (750 root:root, Python 3)
- client `/usr/local/bin/ai-tools-handback-client` (750 root:SANDBOX_GROUP, Python 3)
- socket unit `/usr/lib/systemd/system/ai-tools-handback.socket`
- service template `/usr/lib/systemd/system/ai-tools-handback@.service`
- preset `/usr/lib/systemd/system-preset/85-ai-tools.preset` (enables the socket on install)
