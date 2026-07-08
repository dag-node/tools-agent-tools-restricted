---
paths:
  - "src/usr/local/lib/ai-tools/safe-paths.lib.sh"
  - "src/usr/local/sbin/ai-tools/ai-tools-chown.sh"
  - "src/usr/local/sbin/ai-tools/ai-tools-reclaim.sh"
  - "src/usr/local/sbin/ai-tools/ai-tools-setgid.sh"
  - "src/usr/local/sbin/ai-tools/ai-tools-setfacl.sh"
  - "src/usr/local/sbin/ai-tools/ai-tools-unclaim.sh"
  - "src/usr/local/sbin/ai-tools/ai-tools-lockdown.sh"
  - "src/usr/local/sbin/ai-tools/ai-tools-relabel.sh"
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
  `ai-tools --project-claim` (`cmd_project_claim`) refuses to *claim* a protected directory, so
  a mis-entered allowlist neither starts a session nor registers a project where the handback
  would then act. The CLI does not front-line-guard unclaim, so an already-claimed system
  directory stays recoverable; the helper below still refuses to act on it.
- **Last line** — `ai-tools-{chown,reclaim,setgid,setfacl,unclaim,lockdown,relabel}` each call
  the guard right after resolving their canonical target, before any mutation. The walkers
  (`reclaim`, `setgid`, `setfacl`, `unclaim`) refuse the whole pass at the project root, before
  descending.

Refusal exits `3` in the helpers (distinct from usage `2` and the silent skips) and `1` in the
launch wrapper (matching its `die`); a load failure (below) uses the same codes.

## Load failure fails closed

Every consumer requires the library; none installs a fail-open stub, so the protected-path
check is in force whenever a consumer runs. A consumer that cannot load the library refuses
rather than continue with the check absent — a broken or mis-permissioned install yields a
refusal, not an unguarded operation. Two forms:

- **User-facing entry points (`claude.sh`, `ai-tools`)** source the library and verify its
  guard functions are defined; on failure they log to journald and print a framed notice naming
  the likely cause (an untraversable lib dir, a missing or unreadable lib), then exit (`1` for
  the wrapper's `die`, `3` for the CLI), so an operator reads why the launch or claim stopped.
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
- **`msg.lib` is sourced from within the library** only when its function is not already defined
  (a `declare -F` guard), so the root helpers get the box without each sourcing it while the
  wrapper/CLI — which already source `msg.lib` — do not re-source it (`msg.lib` has no include
  guard, and its `readonly` vars abort a re-source under `set -e`).
