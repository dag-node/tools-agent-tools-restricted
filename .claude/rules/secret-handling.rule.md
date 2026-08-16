---
paths:
  - "src/usr/local/libexec/ai-tools/ai-tools-lockdown.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-chown.sh"
  - "src/home/user/.config/ai-tools/secret-patterns"
  - "src/usr/local/lib/ai-tools/secret-patterns.lib.sh"
  - "src/usr/local/lib/ai-tools/owner-only.lib.sh"
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

`ai-tools-setfacl` makes that recipe hold: a path whose mode carries no group and no other
bits (`0600`, `0700`) is never granted — no `group:SANDBOX_GROUP:rwX` entry, no
`user:<operator>:rwX` entry, no default ACL on a directory, no mask recalculation, mode bits
untouched — and a skipped directory takes its subtree with it. Widening the mode and
re-claiming is how a path opts in; the skip count is reported, since on a project root it
means the sandbox account cannot enter the tree at all.

This is what keeps the `700 <you>:<you>` directory above protective. `setfacl -m` recalculates
the mask to cover the entries it adds, so granting such a directory would return it as `0770` —
write on the directory, and with it the ability to unlink the secrets inside, which is the very
thing the `700` is there to stop.

**The mode is not the whole boundary, so sealing also strips.** Setgid and default-ACL
inheritance act at create time, so a path created inside a claimed tree is *already* group
`SANDBOX_GROUP`, setgid, and carrying the project's default ACL. A later `chmod 700` holds the
ACL mask at `---` but removes none of that, and a numeric `chmod` does not clear a directory's
setgid at all; files created inside are born `0660` with the inherited entry **effective**.
Nothing is reachable while the `700` stands — traversal is denied at the directory — but the
grant is dormant, not gone: widening that one mode later re-activates it over everything already
inside, including files written while the directory looked private.

Every walk over a claimed tree therefore **strips** that residue from an owner-only path rather
than merely skipping it — the `group:SANDBOX_GROUP` access and default ACL entries, the setgid
bit, and the sandbox group owner — so the seal does not rest on a single mode bit staying put.
Predicate and strip are single-sourced in `owner-only.lib.sh`, shared by `ai-tools-setgid`,
`ai-tools-setfacl`, `ai-tools-lockdown` and `ai-tools-chown`; it removes only what the sandbox
put there and leaves mode bits, ownership and every other ACL entry as found. A setgid bit whose
group is neither the sandbox account's nor the operator's is kept and reported, not removed. A
`!`-exclusion remains the stronger form, since an excluded subtree is skipped by every walk
whatever its mode.

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
`ai-tools-lockdown` (`/usr/local/libexec/ai-tools/ai-tools-lockdown`, run
`ai-tools --lockdown <project>` or `cd <project> && sudo ai-tools-lockdown`) is the
proactive counterpart: it walks the current directory and, for every path matching the
shared secret patterns, sets regular files `600`, directories `700`, and owner `<you>:<you>` —
revoking `SANDBOX_USER`'s read regardless of who created the path. The owner's own private group
is the target, the same one `ai-tools-chown` gives an agent-written secret, so a secret ends up
identically owned whether it was locked down proactively or quarantined on write; leaving the
group as `SANDBOX_GROUP` would re-expose it the moment the mode was widened. Each locked path
also has its sandbox residue stripped (see above).
It runs only when the CWD is an allowed project and skips `!`-excluded paths, reusing the
same allowlist parse, and applies each change through a pinned fd (re-verifying inode and
type) so a `SANDBOX_USER` path swap cannot redirect root's chmod/chown. `--dry-run`
previews; `--yes` skips the TTY confirmation.

It is a user tool: there is **no** sudoers grant letting `SANDBOX_USER` run it, and it
refuses to run as `SANDBOX_USER`. The `ai-tools` CLI wraps it as `ai-tools --lockdown
[path]` (it `cd`s into the project and `sudo`s the helper, so sudo prompts for the
projects user's password; `-n`/`--dry-run` and `-y`/`--yes` pass through). The CLI never
pre-checks the helper's path: `/usr/local/libexec/ai-tools` is `750 root:root`, so the
projects user cannot stat the helper — only `sudo`, as root, can reach it.

### Lockdown on clone

`ai-tools --sandbox-create` runs this lockdown directly after a shallow clone and
**before** the clone is opened to the agent group or registered, since the tip commit may
still hold credential files (the clone is born owner-only via `umask 077`, so nothing is
group-readable in the interim — see [cli](cli.rule.md)). If the user declines or lockdown
fails, the create stops fail-closed — the clone stays private and unregistered — and the
CLI drops a guard `CLAUDE.md` into the clone instructing the agent to do nothing until
lockdown runs (any existing `CLAUDE.md` is preserved via `git mv` to `CLAUDE.md.bak`);
re-running `--sandbox-create` on the clone path resumes the gate and, on success, removes
the guard and restores the original. The guard carries a sentinel comment
(`ai-tools-lockdown-guard`) so the CLI recognizes its own placeholder and never clobbers
a real `CLAUDE.md`.
