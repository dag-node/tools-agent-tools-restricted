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

Messages are **reduced to safe-for-display characters** before either sink by
`ai_tools_log_sanitize`, a default-deny **allowlist**: it keeps only printable ASCII
(0x20–0x7E) and replaces every other byte — the ASCII controls (ESC, the C0 set, DEL) and
every byte of a non-ASCII sequence — with `?`. Allowing a known-safe set, rather than
blocklisting an open-ended list of dangerous control/format/bidi code points (which the shell
cannot enumerate — it has no Unicode database), rejects every unknown by construction, with no
maintenance. Matching is byte-wise under a forced `C` locale, so it is locale-independent and
neutralizes multi-byte sequences a byte at a time; the cost is deliberate — a legitimate
non-ASCII filename shows as `?` while the real name stays on disk. Agent-created filenames
reach the log (a handback records the path it restored), so this stops a crafted filename from
injecting a terminal escape into a session that `cat`s the root-owned file log, forging a log
line, or visually reordering the audit text (the Trojan-Source bidi class). When a message is
altered, `ai_tools_log` appends an inline `[!] non-standard characters replaced` marker — a
non-standard byte where a path is expected is a probe worth recording; the marker is pure
ASCII, so it cannot itself re-trigger a replacement.

The handback daemon carries the same allowlist at its `handback.log` write site (`_sanitize`,
`' ' <= c <= '~'` per code point, with the same inline marker) so both trails share one
contract; `tests/unit/log.sh` pins both on the same byte vectors. The daemon's
request-argument pre-filter already rejects a control **byte**, but a bidi or zero-width code
point is a valid path byte that reaches the served-request line, so it is reduced at the log
boundary.

The reduction is **fail-closed** where it protects a terminal: the helpers that print an
agent-named path straight to stderr — `ai-tools-chown`'s per-path prompt and breach `NOTICE`,
`ai-tools-reclaim`'s pre-confirmation sample, `ai-tools-lockdown`'s scan and locked lines —
route each path through `ai_tools_log_sanitize` and **require** `log.lib.sh` (a missing logger
aborts the helper rather than emitting an agent path raw), unlike the pure-logging consumers
that keep a soft no-op fallback. The test harness applies the same allowlist to every
`pass`/`fail`/`skip`/`section` line (`_san`), so a suite run — which executes as root via
`sudo`, often on a live host — cannot print a crafted byte a fixture carried into a result
message.

## Deferred

- **Control/bidi as a malicious-attempt detector.** The allowlist above reduces non-standard
  bytes to `?` for safe display. Retained but **not yet wired**:
  `ai_tools_log_sanitize_unicode_controlchars` (shell, byte-wise C0/C1/zero-width/bidi/BOM
  ranges) and `_sanitize_unicode_controlchars` (daemon, `unicodedata` categories
  `Cc`/`Cf`/`Cs`/`Co`/`Zl`/`Zp`, covering the astral tag chars too). A sane agent never emits
  these in a path, so their presence is a signal worth **quarantine-logging** (who, which path,
  which code points) rather than silently reducing. Wire the retained functions into a
  quarantine sink when that detector is built.

The directory is labelled `ai_tools_log_t` (`selinux/policy/ai_tools.fc`); the helpers that run
in `ai_tools_t` (`ai-tools-chown`, `ai-tools-setgid`, and `ai-tools-claude-symlink` under
the updater) are granted append/create on that type (`selinux/policy/ai_tools.te`), so file
writes succeed under enforcing. `ai-tools-lockdown` and the CLI run unconfined; the hooks
reach journald over the already-granted `/dev/log` path.
