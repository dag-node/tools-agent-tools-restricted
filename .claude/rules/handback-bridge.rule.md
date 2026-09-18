---
paths:
  - "src/usr/local/libexec/ai-tools/ai-tools-handback.py"
  - "src/usr/local/bin/ai-tools-handback-client.py"
  - "src/usr/lib/systemd/system/ai-tools-handback.socket"
  - "src/usr/lib/systemd/system/ai-tools-handback@.service"
---

# Handback socket bridge (`ai-tools-handback`)

The session runs under `PR_SET_NO_NEW_PRIVS` (forced by `RestrictNamespaces=yes`, see
[confinement](confinement.rule.md)), which drops `sudo`'s SUID bit. The `PostToolUse`, `Stop`/`SessionStart` hooks (see
[ownership-and-hooks](ownership-and-hooks.rule.md)) and `nvm-update.sh` (see [updater](updater.rule.md)) therefore reach
root operations through an `AF_UNIX SOCK_STREAM` socket (`/run/ai-tools/handback.sock`, `0660 root:SANDBOX_GROUP`)
served by a systemd `Accept=yes` socket unit started at boot. This is the session's only privilege path; `sudo` is never
exec'd from inside the session.

The socket unit is **enabled by a shipped preset**, `85-ai-tools.preset` (`enable ai-tools-handback.socket`, read
before the distro's `90-default.preset`), so a package install brings the handback up by itself. A bare
`%systemd_post`/`install.sh` without the preset would leave the unit at the distro default (`disabled`) — a socket
that never listens, whose whole effect is silent: every `CHOWN` fails, files stay `SANDBOX_USER`-owned, and git reports
"dubious ownership". The preset is applied by `%systemd_post` on **initial install only**, so a later operator
`systemctl disable` survives upgrades. The socket being down is not a security failure — DAC, `ai_tools_t`,
and the project `user:<operator>` ACL keep the operator's access intact — so the consumers **warn and proceed** rather
than fail closed: `ai-tools-run` emits a launch-time NOTICE naming the fix, and the sweeps and the reclaim report
the stranded work (see [ownership-and-hooks](ownership-and-hooks.rule.md) and [launch](launch.rule.md)).

## Protocol

One `VERB SP ARG LF` request per connection. The response is zero or more `MSG TEXT LF` relay lines followed by `OK LF`
or `ERR REASON LF`. MSG lines carry helper stderr (for example a secret-file NOTICE) back to the client's stderr,
which the hooks forward into the agent session.

## Authentication

The daemon reads `SO_PEERCRED` on fd 0 (the accepted socket) and rejects any peer whose uid ≠ `SANDBOX_USER`. DAC
provides the outer gate: the socket file is `0660 root:SANDBOX_GROUP`, so only root and `SANDBOX_GROUP` members connect;
world gets `EACCES` before reaching the daemon.

Under SELinux, systemd derives the listening socket's context from the daemon binary's on-disk label at bind time,
and the session's `connectto` is granted against that context (`ai_tools_handback_t`). The SELinux installer therefore
relabels the daemon (`_relabel_helpers`) before any socket restart (`_relabel_runtime`).

## Verbs

- `CHOWN ARG` → `ai-tools-chown ARG`
- `SETGID ARG` → `ai-tools-setgid ARG`
- `SYMLINK ARG` → `ai-tools-launcher-symlink ARG`

Each root helper re-validates the path against the allowlist and the `SANDBOX_USER`-owned guard independently,
so the daemon dispatches without adding trust of its own.

## Logging

The daemon keeps its own operation trail (`_audit`), the socket-layer counterpart to the helpers'
`chown.log`/`setgid.log`/`symlink.log`. Because it is Python it does not source `log.lib.sh`; it writes the same
`<ts> <LEVEL> [<pid>] <msg>` format to two sinks: journald (stderr → `StandardError=journal`, with an sd-daemon `<N>`
priority prefix so `journalctl -t ai-tools-handback -p warning` filters) and the root-only
`/var/log/ai-tools/handback.log`. It runs as root (and `ai_tools_handback_t` holds `create`/`append`
on `ai_tools_log_t`, so the write succeeds under enforcing), so it is the file's only writer; the agent-side client
cannot write the `700` dir (DAC) and stays journald-only. Recorded events: rejected peers (`SO_PEERCRED` mismatch,
`WARNING`), malformed or refused requests (`WARNING`), helper timeouts/exec failures (`ERROR`), and one `INFO` line
per served request (`verb`, peer pid, arg, helper result) — a non-zero helper exit stays `INFO`, since it is often
a routine skip (a path outside the allowlist). Both sinks are wrapped in `try`/`except OSError`, so a failed write never
blocks or fails a handback. See [logging](logging.rule.md).

### The session a root operation was performed for

The journald record carries native fields beside its `MESSAGE` — `AI_TOOLS_SESSION_UNIT`, `AI_TOOLS_VERB`,
`AI_TOOLS_PATH`, `AI_TOOLS_RESULT`. `AI_TOOLS_SESSION_UNIT` is the field only this daemon can supply: a root helper does
not run in the session's unit, so the daemon's own record is where a `chown` is tied to the session that asked for one.

```bash
sudo journalctl _SYSTEMD_USER_UNIT=<unit> + AI_TOOLS_SESSION_UNIT=<unit>
```

`_peer_user_unit` reads the value from `/proc/<peer_pid>/cgroup` immediately after the `SO_PEERCRED` check, while
the peer is still blocked on the response, which bounds the pid-reuse window. The header on the function states
how the unit is taken out of the cgroup line and which kernel interface would close the reuse window.

**Two layers permit that read, and the SELinux one is type-wide.** The unit's `ProtectControlGroups=yes` mounts
`/sys/fs/cgroup` read-only and leaves procfs alone; under enforcing, a file under a process's own `/proc` entry carries
that process's domain, so `ai_tools.te` grants `ai_tools_handback_t` `search` on `ai_tools_t:dir` and `read`
on `ai_tools_t:file`. Type enforcement cannot express "the process on the other end of this socket", so that grant
covers **every** process in the domain; what holds the read to the peer is the code, which opens the one pid
`SO_PEERCRED` reported. A peer outside the domain — the updater's `--user` unit, which does not exec any entrypoint
and so does not compute a transition — leaves the field absent on its records. Neither layer decides anything: the uid
is what authorizes.

**The value is attribution: the `SO_PEERCRED` uid decides what is served, and this field labels the record afterwards.**
An unreadable or unmatched cgroup leaves the field **absent** rather than guessed.

**The string is agent-influenceable, so it is validated at the reader.** A cgroup *directory* name is held to no systemd
rule — the kernel takes any byte but NUL and `/` — and the session's manager delegates a subtree the sandbox account may
`mkdir` in, so the component this field is read from can carry control characters, a forged unit name, or 255 bytes
of noise. `_unit_name_or_empty` admits only systemd's own valid-unit-name set (alphanumerics and `:-_.\@`) within
`UNIT_NAME_MAX`, and anything else yields the absent field rather than a recorded value: a string that is not a unit
name is not attribution. Field injection into the journald datagram is closed in `_journal_entry`, which sanitizes every
value and so cannot emit the newline that would terminate a field early; the reader's allowlist is what keeps a rejected
value from being *recorded* as a `?`-substituted one.

A rejection is logged at `WARNING` with the peer pid and the truncated value — the level malformed peer input takes
here. Nothing a host does in the ordinary way produces one (systemd cannot name a unit outside that set), so the record
is the only trace that something wrote the delegated cgroup subtree directly; a silent `''` would be indistinguishable
from the routine absent case. The routine case itself — a peer with no `user@<uid>.service` component in its cgroup
at all — returns earlier and stays silent.

journald's stream protocol reads a `MESSAGE` and the `<N>` priority and stamps its own `_` fields, so a custom field
does not reach the journal over stderr. The daemon sends **one datagram** to `/run/systemd/journal/socket`
with the stdlib (`socket.sendto`); `sendto` is in `@network-io` (included by `@system-service`), and the policy already
grants `logging_send_syslog_msg(ai_tools_handback_t)`. `python3-systemd` would add a package dependency,
and a `logger --journald` subprocess would fork and exec a root process holding `CAP_DAC_OVERRIDE` for every audit line.
`_journal_entry` assembles the bytes and `_journal_send` sends them, so the record's shape is asserted without a socket
(`tests/unit/handback.sh`); `AI_TOOLS_JOURNAL_SOCKET` moves the destination for that test, with the same standing
as `AI_TOOLS_LOG_DIR` (see [tests](tests.rule.md)).

**The fail direction is a missing field, never a delayed handback.** A send that fails — a full journald buffer,
an absent socket — falls through to the stderr write, so the `MESSAGE` still lands and only the fields are lost;
`PRIORITY` and `SYSLOG_IDENTIFIER` ride in the datagram, so `journalctl -t ai-tools-handback -p warning` selects this
daemon's warnings whichever sink wrote them. `Accept=yes` spawns one process per connection, which share no state,
and a datagram is atomic per message, so the daemon does not take a lock.

## Files

- daemon `/usr/local/libexec/ai-tools/ai-tools-handback` (750 root:root, Python 3)
- client `/usr/local/bin/ai-tools-handback-client` (750 `root:SANDBOX_GROUP`, Python 3)
- socket unit `/usr/lib/systemd/system/ai-tools-handback.socket`
- service template `/usr/lib/systemd/system/ai-tools-handback@.service`
- preset `/usr/lib/systemd/system-preset/85-ai-tools.preset` (enables the socket on install)
