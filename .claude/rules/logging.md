---
paths:
  - "src/usr/local/lib/ai-tools/log.lib.sh"
---

# Operation logging

The sandbox components log through one shared library,
`/usr/local/lib/ai-tools/log.lib.sh` (`644 root:root`, world-readable — it carries no
secrets and every principal sources it). It exposes `ai_tools_log <level>` and
`ai_tools_log_{debug,info,warn,error}`, writing to two sinks:

- **journald** — always, via `logger` with a per-component `SyslogIdentifier`
  (`AI_TOOLS_LOG_TAG`) and a syslog priority matching the level. This is the universal
  sink: the non-root components write here because they cannot write the root-only files.
  Query with `journalctl -t ai-tools-chown` (or `-setgid`, `-claude-symlink`, `-lockdown`,
  `-hook`, `ai-tools`, `ai-tools-install`), with `-p warning` to filter by level.
- **`/var/log/ai-tools/<component>.log`** — only when the caller sets `AI_TOOLS_LOG_FILE`,
  which only the root writers do. The directory is `700 root:root`, each file
  `600 root:root`: the root helpers append as root, while `SANDBOX_USER` — neither the dir
  owner nor able to traverse a `700` dir — can neither read nor tamper with the trail. That
  keeps the secret filenames `ai-tools-chown` records out of the agent's reach. The files
  are `chown.log`, `setgid.log`, `symlink.log`, `lockdown.log`, and `install.log`.

What is logged is a caller convention, not enforced by the library: the privileged
operations the hooks and helpers perform, the CLI's workflow milestones (project/sandbox
created, pushed, removed, locked down), and the full install transcript (`do_install` tees
a colour-stripped copy to `install.log`). Routine per-path sweep churn is `DEBUG` only and
is emitted only when a path actually changes. A message placed before its operation is
present-tense `DEBUG`; one after a completed unit of work is past-tense `INFO`. Both sinks
are best-effort — a failed write is swallowed, so logging never aborts or alters the exit
status of the operation it describes.

The directory is labelled `ai_tools_log_t` (`selinux/ai_tools.fc`); the helpers that run
in `ai_tools_t` (`ai-tools-chown`, `ai-tools-setgid`, and `ai-tools-claude-symlink` under
the updater) are granted append/create on that type (`selinux/ai_tools.te`), so file
writes succeed under enforcing. `ai-tools-lockdown` and the CLI run unconfined; the hooks
reach journald over the already-granted `/dev/log` path.
