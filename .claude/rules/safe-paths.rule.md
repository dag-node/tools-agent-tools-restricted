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
ai-tools operations must never act on, and the guard that enforces it. It is defense in
depth against an operator config error: the allowlist alone authorizes wherever it points,
so a system directory mistakenly added to `allowed-projects` (or passed to a helper) would
let a recursive chown/setgid/setfacl/relabel rewrite it. This list is the independent
backstop — every elevated operation refuses a protected target regardless of the allowlist,
before acting.

## Matching: exact or ancestor

A target is protected when its resolved real path **equals** a list entry or **contains**
one (is an ancestor, e.g. `/`). Descendants pass, so a real project nested under an operator
home (`/home/<user>/<proj>`) or a sandbox clone
(`/var/opt/ai-tools/sandbox-projects/<repo>`) is unaffected — those are the trees the
helpers legitimately act on. This is deliberate: the catastrophe to prevent is a *whole*
system directory being claimed or swept, which requires the target to be (or contain) the
system tree. A deeper or glob-expanded accident *inside* a protected tree stays covered by
each helper's owner-guard, which acts only on agent- or operator-owned paths and never the
root-owned files that fill a system directory ([ownership-and-hooks](ownership-and-hooks.rule.md),
[cli](cli.rule.md)).

The list (`AI_TOOLS_PROTECTED_PATHS`) covers the FHS system roots — `/`, the usrmerge
symlinks and `/usr` tree, `/etc`, `/var`, `/boot`, `/root`, `/home` (the parent of every
user home; the homes themselves pass), `/srv`, `/opt` and `/opt/ai-tools` (the control
plane), the `/dev`/`/proc`/`/sys`/`/run` pseudo-filesystems, the `/mnt`/`/media` mount
points, and `/tmp`/`/lost+found`. The sandbox's own working areas — `/opt/ai-tools` and
`/var/opt/ai-tools/sandbox-projects` — are reached as *descendants* of listed entries, so
they keep working without a carve-out.

## Two functions

- `ai_tools_protected_path_match <abspath>` — the pure predicate: prints the matching entry
  and returns 0 when protected, returns 1 otherwise. Normalizes a trailing slash.
- `ai_tools_assert_safe_target <path> [op-label]` — the guard the consumers call: resolves
  the path (`realpath -m`, falling back to the raw argument so an unresolvable path is still
  matched), and on a protected target emits a framed refusal (a `msg.lib` box on a terminal,
  plain lines otherwise; see [messaging](messaging.rule.md)), logs it at `WARNING`, and
  returns non-zero so the caller aborts before acting. Safe targets return 0 silently.

## Where it is enforced

Two layers, both fail-closed (exit on refusal), per the chosen coverage:

- **Front line** — `claude.sh` refuses to *launch* a session in a protected CWD, and
  `ai-tools --project-claim` (`cmd_project_claim`) refuses to *claim* a protected directory,
  so a mis-entered allowlist never starts a session or registers a project where the
  handback would then act. Unclaim is not front-line-guarded at the CLI, so an
  already-claimed system directory can still be recovered — but the helper below still
  refuses to act on it.
- **Elevated helpers (last line)** — `ai-tools-{chown,reclaim,setgid,setfacl,unclaim,
  lockdown,relabel}` each call the guard right after resolving their canonical target,
  before any mutation. The walkers (`reclaim`, `setgid`, `setfacl`, `unclaim`) refuse the
  whole pass at the project root, before descending.

The guard exits with status `3` on refusal in the helpers (distinct from usage `2` and the
silent skips), and exit `1` in the launch wrapper to match its `die`.

## Design notes

- **Deployed `644 root:root`**, world-readable like `msg.lib.sh`/`log.lib.sh`: the operator
  wrapper, the CLI, and the root helpers all read the same list; it carries no secrets.
- **Sourced, not executed**, so every consumer shares one list and one matcher — the same
  single-source pattern as `skip-dirs.lib.sh`.
- **`msg.lib` is sourced from within the library** only when its function is not already
  defined (a `declare -F` guard), so the root helpers get the box without each sourcing it,
  while the wrapper/CLI — which already source `msg.lib` — do not re-source it. `msg.lib`
  has no include guard and its `readonly` vars would abort a re-source under `set -e`.
- **A missing library fails open**, not closed: each consumer's source line installs a
  no-op `ai_tools_assert_safe_target` stub, so a broken install still runs with the
  allowlist and owner-guard as the primary controls rather than refusing every operation.
