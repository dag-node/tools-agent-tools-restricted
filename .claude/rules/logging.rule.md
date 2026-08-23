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
  Query with the tag **and** the writer's uid — `journalctl -t ai-tools-chown _UID=0`, and
  likewise `_UID=0` for `-setgid`, `-setfacl`, `-unclaim`, `-safedir`, `-reclaim`,
  `-allowlist`, `-launcher-symlink`, `-lockdown`, `-relabel`, `-relabel-agent`, `-dotnet`,
  `-handback` and `ai-tools-install`; the sandbox account's uid for `ai-tools-run` and
  `-hook`; the operator's for `ai-tools`. Add `-p warning` to filter by level. The uid is not
  decoration — see "A tag attributes nothing, `_UID` does" below.
- **`/var/log/ai-tools/<component>.log`** — only when the caller sets `AI_TOOLS_LOG_FILE`,
  which only the root writers do. The directory is `700 root:root`, each file
  `600 root:root`: the root helpers append as root, while `SANDBOX_USER` — neither the dir
  owner nor able to traverse a `700` dir — can neither read nor tamper with the trail. That
  keeps the secret filenames `ai-tools-chown` records out of the agent's reach. The files
  are `chown.log`, `setgid.log`, `setfacl.log`, `symlink.log`, `lockdown.log`,
  `relabel.log`, `dotnet.log`, `handback.log`, and `install.log`. Most are written through this library
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

## A tag attributes nothing, `_UID` does

The syslog identifier is chosen by whoever writes the line, and `ai_tools_t` may write
`/dev/log` — that is how the hooks reach journald at all. So a session can emit
`logger -t ai-tools-chown "handed back /etc/shadow"`, and the line lands in the same trail an
operator reads, under a root helper's tag. A query filtered by tag alone is poisonable by the
account it is being read about.

`_UID` is not. journald stamps it from the sender's kernel credentials, which the peer cannot
set, so pairing the tag with the uid of that tag's **legitimate** writer separates the real lines
from anything the sandbox account appended: `_UID=0` for the root helpers, the handback daemon and
the installer; the sandbox account's uid for `ai-tools-run` and the hooks; the operator's uid for
the CLI. `ai-tools-run` prints its own recipe in exactly that form
(`sudo journalctl -t ai-tools-run _UID=<sandbox uid> -n 50`).

Two tags have no separating filter, because the agent **is** their legitimate writer:
`ai-tools-hook` and `ai-tools-run` both run as the sandbox account, so a forged line under either
carries the same `_UID` as a real one. Their journal lines are the session's own account of what
happened — evidence to reconcile, not proof of it. The trail that carries no such doubt is the
file sink above: `700 root:root`, root writers only, which the agent can neither read nor append
to. Where a journald line and the file sink disagree, the file sink is what happened.

`tests/boundary/access.sh` asserts the separation from the agent's side: a line the sandbox
account writes under a root helper's tag lands under the sandbox uid and is absent from the same
tag at `_UID=0`.

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
in `ai_tools_t` (`ai-tools-chown`, `ai-tools-setgid`, and `ai-tools-launcher-symlink` under
the updater) are granted append/create on that type (`selinux/policy/ai_tools.te`), so file
writes succeed under enforcing. `ai-tools-lockdown` and the CLI run unconfined; the hooks
reach journald over the already-granted `/dev/log` path.
