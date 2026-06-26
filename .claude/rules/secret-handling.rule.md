---
paths:
  - "src/usr/local/sbin/ai-tools/ai-tools-lockdown.sh"
  - "src/usr/local/sbin/ai-tools/ai-tools-chown.sh"
  - "src/home/user/.config/ai-tools/secret-patterns"
  - "src/usr/local/lib/ai-tools/secret-patterns.lib.sh"
---

# Secret-named file handling

Two consumers classify basenames against one shared pattern set and revoke
`SANDBOX_USER`'s read: `ai-tools-chown` reactively (per agent-written path, see
[ownership-and-hooks](ownership-and-hooks.rule.md)) and `ai-tools-lockdown` proactively
(over a whole project).

## Reactive: `ai-tools-chown`

A secret-named file the agent wrote is breached. `ai-tools-chown` classifies the
basename against the shared pattern set (`.env`, `*.key`, `*.pem`, `id_*`, `kubeconfig`,
`*.jks`, `.pgpass`, the name-anchored .NET config patterns, …) and chowns a match (when
`SANDBOX_USER`-owned, per the agent-written-paths rule) to `<you>:<you> 600`, so
`SANDBOX_USER` — neither owner nor group member — cannot read the contents. `<you>` is the
operator that owns the path: `ai-tools-chown` resolves it per path via `operator.lib.sh`
(`ai_tools_resolve_owner`) and loads that operator's pattern set, so a secret returns to its
project's operator at `600`, where only that operator can read it. It writes a
NOTICE to stderr (the hook relays it into the session) and, at `WARNING` level, to the
operation log (`/var/log/ai-tools/chown.log` and journald; see [logging](logging.rule.md)).

This revokes read only. `SANDBOX_USER` is a group-writer on the project dir (not its
owner), so it can still unlink/replace the path; a replacement is agent-written and
re-triggers the same handling, and the audit log is root-owned. A project-wide sticky bit
does not apply: `SANDBOX_USER` is a group-writer and handed-back files are `<you>`-owned,
so it would block the agent's atomic-rename re-edits. To prevent unlink/replace of the
operator's own secrets, place them in a dir the agent cannot write (`700 <you>:<you>`) and
`!`-exclude it — the allowlist is not a read boundary.

## Shared secret-pattern set (one source, two consumers)

The secret basename patterns live in a single user-owned config file,
`~/.config/ai-tools/secret-patterns` (`<you>:<you> 600`), co-located with
`allowed-projects` and owned the same way: the operator edits it; `SANDBOX_USER` —
neither its owner nor in its group, and unable to enter the `700 .config/ai-tools` dir —
can neither read nor write it; the root helpers read it on the operator's behalf, so the
agent cannot weaken its own secret classification.

Both root helpers source `/usr/local/lib/ai-tools/secret-patterns.lib.sh` (root-owned
`644`, not in a `SANDBOX_USER`-writable dir) for one matcher over that file, so
`ai-tools-chown` and `ai-tools-lockdown` never drift apart. The library carries a built-in
default list identical to the shipped `secret-patterns` seed
(`src/home/user/.config/ai-tools/secret-patterns`); if the config file is missing or
empty the defaults apply, so classification never degrades to "match nothing". A failure
to source the library is fail-closed: `ai-tools-chown` exits non-zero and skips that
path's handback (it stays `SANDBOX_USER`-owned) rather than handing a possible secret back
as an ordinary file. `ai-tools-chown` runs in `ai_tools_handback_t` (inherited from the
handback daemon, no transition), so the policy grants that domain `libs_read_lib_files` to
read the `lib_t`-labelled library.

The patterns are name- or environment-anchored (`appsettings.*.json`, `web.*.config`,
`*.Production.*`, …), **not** broad `*.*.json`/`*.*.config` catch-alls: those would also
match build artifacts the toolchain must read (`*.deps.json`, `*.runtimeconfig.json`,
`project.assets.json`, `*.dll.config`), and quarantining them breaks builds. The set uses
basename-safe globs only, no bare `config`. A `secrets.*`/`secret.*`/`*.secret`-style stem
also matches ordinary files named after the topic — which is why rule files use a
non-matching stem (see [authoring](authoring.rule.md)).

## Quirks

A file the agent writes whose basename matches the secret patterns is quarantined the
instant it is written — `ai-tools-chown` chowns it to `<you>:<you> 600`, which also catches
files merely *named* after the topic, not just real secrets: a doc or rule file called
`secrets.md` matches `secrets.*` and becomes unreadable to the agent. This is why rule
files use a non-matching stem (`secret-handling.rule.md`, not `secrets.rule.md`; see
[authoring](authoring.rule.md)).

## Proactive: `ai-tools-lockdown`

`ai-tools-chown` is reactive — it acts only on `SANDBOX_USER`-owned paths, so it never
touches a pre-existing user-owned secret the agent could already read.
`ai-tools-lockdown` (`/usr/local/sbin/ai-tools/ai-tools-lockdown`, run
`ai-tools --lockdown <project>` or `cd <project> && sudo ai-tools-lockdown`) is the
proactive counterpart: it walks the current directory and, for every path matching the
shared secret patterns, sets regular files `600`, directories `700`, and owner
`<you>:SANDBOX_GROUP` — revoking `SANDBOX_USER`'s read regardless of who created the path.
It runs only when the CWD is an allowed project and skips `!`-excluded paths, reusing the
same allowlist parse, and applies each change through a pinned fd (re-verifying inode and
type) so a `SANDBOX_USER` path swap cannot redirect root's chmod/chown. `--dry-run`
previews; `--yes` skips the TTY confirmation.

It is a user tool: there is **no** sudoers grant letting `SANDBOX_USER` run it, and it
refuses to run as `SANDBOX_USER`. The `ai-tools` CLI wraps it as `ai-tools --lockdown
[path]` (it `cd`s into the project and `sudo`s the helper, so sudo prompts for the
projects user's password; `-n`/`--dry-run` and `-y`/`--yes` pass through). The CLI never
pre-checks the helper's path: `/usr/local/sbin/ai-tools` is `750 root:root`, so the
projects user cannot stat the helper — only `sudo`, as root, can reach it.

### Lockdown on clone

`ai-tools --sandbox-create` invokes this lockdown directly after a shallow clone, since
the clone's tip commit may still hold credential files. If the user declines or `sudo` is
unavailable, the CLI drops a guard `CLAUDE.md` into the clone instructing the agent to do
nothing until lockdown runs (any existing `CLAUDE.md` is preserved via `git mv` to
`CLAUDE.md.bak`); a later successful `ai-tools --lockdown` removes the guard and restores
the original. The guard carries a sentinel comment (`ai-tools-lockdown-guard`) so the CLI
recognizes its own placeholder and never clobbers a real `CLAUDE.md`.
