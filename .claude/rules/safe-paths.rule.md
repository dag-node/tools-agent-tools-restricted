---
paths:
  - "src/usr/local/lib/ai-tools/safe-paths.lib.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-chown.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-reclaim.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-setgid.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-setfacl.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-unclaim.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-lockdown.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-relabel.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-stop.sh"
---

# Protected-paths backstop

`safe-paths.lib.sh` is the single source of truth for the system directories the elevated
ai-tools operations refuse to act on, plus the guard that enforces it. The allowlist
authorizes wherever it points, so a system directory added to `allowed-projects` by mistake
(or passed straight to a helper) would let a recursive chown/setgid/setfacl/relabel rewrite
it. This list is the independent backstop: every elevated operation refuses a protected
target regardless of the allowlist, before acting, so a misconfigured allowlist cannot turn
a system tree into a claim target.

## Matching: exact or ancestor

A target is protected when its resolved real path **equals** a list entry or **contains** one
(is an ancestor, e.g. `/`). A **user home root** (a direct child of `/home`) is additionally
protected exactly: a whole home as a claim or sweep target would hand the agent every dotfile
and key in it (`~/.ssh`, `~/.gnupg`, …). Descendants pass, so a real project nested under an
operator home (`/home/<user>/<proj>`) or a sandbox clone
(`/var/opt/ai-tools/sandbox-projects/<repo>`) is unaffected — those are the trees the helpers
act on. The boundary catches a *whole* system
directory being claimed or swept, which requires the target to be (or contain) the system
tree; a deeper or glob-expanded path *inside* a protected tree is covered instead by each
helper's owner-guard, which acts only on agent- or operator-owned paths and never the
root-owned files that fill a system directory ([ownership-and-hooks](ownership-and-hooks.rule.md),
[cli](cli.rule.md)).

The list (`AI_TOOLS_PROTECTED_PATHS`) covers the FHS system roots — `/`, the usrmerge
symlinks and `/usr` tree, `/etc`, `/var`, `/boot`, `/root`, `/home` (with each home root
matched by the rule above; projects inside a home pass), `/srv`, `/opt` and `/opt/ai-tools`
(the control plane), the `/dev`/`/proc`/`/sys`/`/run` pseudo-filesystems, the `/mnt`/`/media`
mount points, and `/tmp`/`/lost+found`. The sandbox's own working areas — `/opt/ai-tools` and
`/var/opt/ai-tools/sandbox-projects` — are reached as *descendants* of listed entries, so they
work without a carve-out.

## Two functions

- `ai_tools_protected_path_match <abspath>` — the pure predicate: prints the matching entry
  and returns 0 when protected, 1 otherwise. Normalizes a trailing slash.
- `ai_tools_assert_safe_target <path> [op-label]` — the guard the consumers call: resolves the
  path (`realpath -m`, falling back to the raw argument so an unresolvable path is still
  matched), and on a protected target emits a framed refusal (a `msg.lib` box on a terminal,
  plain lines otherwise; see [messaging](messaging.rule.md)), logs it at `WARNING`, and returns
  non-zero so the caller aborts before acting. A safe target returns 0 silently.

## Where the guard runs

Two layers, both fail-closed:

- **Front line** — `claude.sh` refuses to *launch* a session in a protected CWD, and
  `ai-tools --project-claim` (`cmd_project_claim`) and `--project-unclaim`
  (`cmd_project_unclaim`) both refuse a protected directory as their target, so a mis-entered
  allowlist neither starts a session nor claims/unclaims a system tree where the handback would
  act. Unclaim guards each *modification target* (in ancestor mode the search root may be a
  protected path such as `/home` while the projects nested under it are not). Its `--force`
  flag does **not** reach this guard: `--force` overrides *allowlist membership only*, and is
  itself gated on the target carrying the on-disk ai-tools fingerprint, so a protected system
  directory is refused in both modes. A protected path can never legitimately be a claimed
  project, so the only cleanup a stray hand-edited entry needs is a registry/label edit, which
  `ai-tools --list` reports.
  `--sandbox-remove`/`--sandbox-push` add a second front-line for the destructive `rm -rf`:
  `require_sandbox_clone` calls the backstop **and** requires a direct-child clone of
  `SANDBOX_ROOT` that is a git worktree, so the shared clone-area root — a *descendant* of the
  protected `/var`, hence not caught by the backstop alone — is never a removal target.
- **Last line** — `ai-tools-{chown,reclaim,setgid,setfacl,unclaim,lockdown,relabel}` each call
  the guard right after resolving their canonical target, before any mutation. The walkers
  (`reclaim`, `setgid`, `setfacl`, `unclaim`) refuse the whole pass at the project root, before
  descending.

Refusal exits `3` in the helpers (distinct from usage `2` and the silent skips) and `1` in the
launch wrapper (matching its `die`); a load failure (below) uses the same codes.

**`ai-tools-stop` is not a consumer, and the reason is instructive.** It loaded this library while
it took a per-project target, to vet that caller-supplied path — advisorily, since it only
*selected processes* by the path and never wrote to it. It now takes no path at all: what it
terminates is decided by cgroup-slice membership, so there is no caller-supplied path to vet and
the library is not loaded. A helper comes into scope here by *taking an argument that names a
path*, which is the same rule that keeps `ai-tools-dotnet` out.
[docs/session-stop.md](../../docs/session-stop.md).

## Load failure fails closed

Every consumer of this backstop *gates* on it and therefore requires the library; none installs a
fail-open stub, so the protected-path check is in force whenever a consumer runs. Such a
consumer that cannot load the library refuses rather than continue with the check absent — a
broken or mis-permissioned install yields a refusal, not an unguarded operation. Two forms:

- **User-facing entry points (`claude.sh`, `ai-tools`)** source the library and verify its
  guard functions are defined; on failure they log to journald and print a framed notice naming
  the likely cause (an untraversable lib dir, a missing or unreadable lib), then exit (`1` for
  the wrapper's `die`, `3` for the CLI), so an operator reads why the launch or claim stopped.
The backstop guards *caller-supplied* paths, so it scopes to the helpers that take one. A root
helper whose targets are fixed literals compiled into it — `ai-tools-dotnet`, which only ever
touches only its own `/opt/ai-tools/integrations/dotnet` tree — has no path to validate and does not
load the library; giving a helper an argument that names a path is what brings it into scope here.

- **Root helpers** bare-`source` the library under `set -e`: an unreadable lib aborts the
  helper, with bash writing the path and reason to stderr (journald captures it for a
  daemon-invoked helper), and a lib that loads without defining the guard is refused at the call
  site (`ai_tools_assert_safe_target … || exit 3`).

The load-or-die check is inline at each entry point because the guard against a missing library
cannot itself live in a shared library — loading that library has the same failure mode. The
rationale is single-sourced here, and each consumer carries a one-line pointer to it.

## Design notes

- **Deployed `644 root:root`**, world-readable like `msg.lib.sh`/`log.lib.sh`: the operator
  wrapper, the CLI, and the root helpers read one list; it carries no secrets. The lib directory
  `/usr/local/lib/ai-tools` is `0751 root:SANDBOX_GROUP`, so an operator who is not a
  `SANDBOX_GROUP` member (the multi-operator default) traverses in to source the `644` libs by
  path without listing the directory — the world-execute bit is what makes the world-readable
  guarantee hold for that operator. The group-restricted `640` files (secret-patterns, relabel)
  stay protected by their own modes.
- **Sourced, not executed**, so every consumer shares one list and one matcher — the same
  single-source pattern as `skip-dirs.lib.sh`.
- **`msg.lib` is required from within the library** (a bare `source`, no fallback): the
  refusal renders through it, and it is a required dependency everywhere (see
  [messaging](messaging.rule.md)). A missing `msg.lib` fails this library's own load, so the
  consumer's fail-closed handling takes over; `msg.lib`'s include guard makes the wrapper/CLI's
  own earlier source plus this one a single load.
