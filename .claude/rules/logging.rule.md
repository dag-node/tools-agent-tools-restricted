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
  `-hook`, `-handback`, `ai-tools`, `ai-tools-install`), with `-p warning` to filter by
  level.
- **`/var/log/ai-tools/<component>.log`** — only when the caller sets `AI_TOOLS_LOG_FILE`,
  which only the root writers do. The directory is `700 root:root`, each file
  `600 root:root`: the root helpers append as root, while `SANDBOX_USER` — neither the dir
  owner nor able to traverse a `700` dir — can neither read nor tamper with the trail. That
  keeps the secret filenames `ai-tools-chown` records out of the agent's reach. The files
  are `chown.log`, `setgid.log`, `setfacl.log`, `symlink.log`, `lockdown.log`,
  `relabel.log`, `handback.log`, and `install.log`. Most are written through this library
  by the root helpers; `handback.log` is the exception — the socket daemon
  (`ai-tools-handback`, root, Python) writes it directly (not through this library, which it
  does not source), recording the bridge's own events (rejected peers, malformed/refused
  requests, helper timeouts, one line per served request) in the same
  `<ts> <LEVEL> [<pid>] <msg>` format. The agent-side client writes no file (DAC), only
  journald. The directory path defaults to `/var/log/ai-tools` but
  honors an `AI_TOOLS_LOG_DIR` override — a root-only test hook (sudo strips it, the
  handback daemon execs with its own environment), so the test suite points a run's file
  logs at a throwaway dir instead of the production trail (see
  [tests](tests.rule.md)); no production principal can redirect it.

What is logged is a caller convention, not enforced by the library: the privileged
operations the hooks and helpers perform, the CLI's workflow milestones (project/sandbox
created, pushed, removed, locked down), and the full install transcript (`do_install` tees
a colour-stripped copy to `install.log`). Routine per-path sweep churn is `DEBUG` only and
is emitted only when a path actually changes. A message placed before its operation is
present-tense `DEBUG`; one after a completed unit of work is past-tense `INFO`. Both sinks
are best-effort — a failed write is swallowed, so logging never aborts or alters the exit
status of the operation it describes.

The directory is labelled `ai_tools_log_t` (`selinux/policy/ai_tools.fc`); the helpers that run
in `ai_tools_t` (`ai-tools-chown`, `ai-tools-setgid`, and `ai-tools-claude-symlink` under
the updater) are granted append/create on that type (`selinux/policy/ai_tools.te`), so file
writes succeed under enforcing. `ai-tools-lockdown` and the CLI run unconfined; the hooks
reach journald over the already-granted `/dev/log` path.
