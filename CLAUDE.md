# Claude CR

Claude Code Restricted, run sessions as sandboxed user.

## Purpose

This repo installs and maintains a way to run Anthropic's **Claude Code as a
dedicated, locked-down system user (`SANDBOX_USER`, the account created as
`ai-tools`)** instead of as your own login account. The goal: let an
autonomous coding agent work on your projects without inheriting your user's
privileges. It runs under a separate UID with no login shell, can only launch
inside explicitly approved project directories, can escalate only through two
narrow `sudo` rules, and should not reach your secrets, SSH keys, or unrelated
projects.

A scheduled `nvm-update` job keeps Node.js v22 and `@anthropic-ai/claude-code`
current for both your login user and `SANDBOX_USER`, pinned to the same build.

Terminology follows `docs/naming-conventions.md`: `SANDBOX_USER`/`SANDBOX_GROUP`
name the sandbox service account and its group (`@SANDBOX_USER@`/`@SANDBOX_GROUP@`,
substituted to `ai-tools` at install), while the literal `ai-tools` is retained
only in filesystem paths (`/opt/ai-tools`, `~/.config/ai-tools`), SELinux types
(`ai_tools_t`), the management CLI (`ai-tools`), and root-helper binary names
(`ai-tools-chown`, …).

## How it works (the trust chain)

1. You type `claude` → resolves to the wrapper `~/.local/bin/claude` (runs as you).
2. The wrapper checks the current directory against the **approved-projects
   allowlist** (`~/.config/ai-tools/allowed-projects`); refuses to start anywhere
   else, and refuses a CWD carved out by a `!` exclusion.
3. It resolves the versioned binary via the stable symlink
   `/opt/ai-tools/bin/claude` using `readlink` (one hop only — `realpath`/`readlink
   -f` would traverse the npm package dir, which is mode 700 `SANDBOX_USER`-owned
   and EACCES for the invoking user). The resolved path is checked to be absolute,
   `..`-free, and within the nvm versioned-binary subtree — an integrity check
   against a misconfigured or compromised `ai-tools-claude-symlink` root helper,
   not a guard against external injection (only root and `<you>` can write
   `/opt/ai-tools/bin`). The validated path is then exported as `CLAUDE_EXEC` and
   `exec sudo -u SANDBOX_USER -g SANDBOX_GROUP -- /opt/ai-tools/bin/claude-run`
   is called.
3a. `claude-run` (550 `<you>:SANDBOX_GROUP`, not writable by the agent) re-validates
   `CLAUDE_EXEC` against the same nvm-path pattern and wraps the session in a
   **systemd transient service unit** (`systemd-run --user --pty`) before exec'ing
   the versioned binary. The unit applies two security properties:
   `RestrictNamespaces=yes` installs a seccomp filter blocking creation (and joining)
   of every namespace type for the entire session process tree — the agent holds no
   capabilities, so the only namespace it could create unaided is a user namespace,
   and blocking that closes user-namespace creation as a kernel-CVE escalation vector
   (every other type needs `CAP_SYS_ADMIN`, reachable only through a user namespace);
   and `UMask=0007` keeps
   agent-created files group-writable (a service unit does not inherit the caller's
   umask, unlike a scope). `PrivateTmp` is not set: it is a no-op for an unprivileged
   `--user` manager, which cannot mount a private `/tmp`, so the session uses the shared
   host `/tmp` where claude keeps its runtime at a fixed `/tmp/claude-<uid>` (labelled
   `ai_tools_tmp_t`) and reuses it across sessions. `NoNewPrivileges` is intentionally
   absent from the service unit definition: the session always runs under NNP regardless
   (forced by `RestrictNamespaces=yes`, which installs the seccomp filter via
   `PR_SET_NO_NEW_PRIVS`) — so adding it to the unit would be redundant. Under NNP
   `sudo`'s SUID bit is dropped silently; the hooks therefore do not call `sudo` and
   instead use the **handback socket bridge** (`ai-tools-handback-client`) — a Python
   client connecting to the root-owned `ai-tools-handback.socket` (systemd-activated,
   `Accept=yes`), which authenticates via `SO_PEERCRED` and calls the matching root
   helper. This eliminates the session's sudo surface entirely. The unit receives only an explicit
   allowlist of environment variables (terminal, locale, proxy; `HOME`, `PATH`, and
   `NODE_COMPILE_CACHE` are pinned to sandbox values), so the operator's secrets never
   cross into the session, and its `WorkingDirectory` is set to the validated project
   directory (exported by the wrapper as `CLAUDE_PROJECT_DIR`, re-validated in `claude-run`)
   since a transient unit otherwise defaults to `/`.
   The service runs in `SANDBOX_USER`'s systemd user instance, kept alive by
   `loginctl enable-linger`. `--pty` service mode (not `--scope`) is required:
   `RestrictNamespaces` and `UMask` are exec-context directives that
   systemd 252 rejects on a scope unit (`Unknown assignment`), because a scope has no
   exec context — the caller, not the manager, performs the final `exec`. In service
   mode the user manager performs the `exec`, so the domain transition fires from its
   domain (`init_t` on RHEL/Rocky 9 targeted) via `domtrans_pattern(init_t,
   ai_tools_exec_t, ai_tools_t)` in `ai_tools.te`. Before launching, `claude-run` runs a
   fail-closed confinement preflight: it reads the entrypoint's label and the manager's
   domain (the two inputs to that transition), logs them every launch, and — when SELinux
   is enforcing and confinement was expected — refuses to start if either is wrong (a
   mislabelled binary, or a manager domain no `domtrans_pattern` covers) rather than run
   unconfined. The check is pre-launch because a wrapper cannot observe its successor's
   post-`exec` domain, so it verifies the transition's inputs instead.
4. Claude runs as uid `SANDBOX_USER`. Files it writes are owned `SANDBOX_USER`; a
   `PostToolUse` hook calls `/usr/local/bin/ai-tools-handback-client CHOWN <file>`
   to restore `<you>:SANDBOX_GROUP` ownership and strip world bits, inside
   allowlisted paths only (never on `!`-excluded paths). The client connects to the
   `ai-tools-handback` socket (an `Accept=yes` root daemon), which authenticates the
   caller via `SO_PEERCRED` and runs `ai-tools-chown` as root. The
   hook also walks the written file's parent directories and hands each back to
   `<you>:SANDBOX_GROUP` (world bits stripped, group `rwx` kept so the agent can
   keep writing into a dir it made), but **only** for directories the agent itself
   created (currently `SANDBOX_USER`-owned): the walk stops at the first
   pre-existing user-owned dir, and `ai-tools-chown` independently refuses any
   non-`SANDBOX_USER` directory, so it never grants the agent group access to a dir
   it did not already own. Secret-named files (`.env`, `*.key`, SSH keys,
   `kubeconfig`, …) are instead moved to your private group with group+world bits
   stripped (`<you>:<you> 600`), revoking `SANDBOX_USER`'s read access, with a
   `NOTICE` surfaced in the session + audit log.
5. The `PostToolUse` hook only fires for `Write`/`Edit`, so files the agent
   creates via the `Bash` tool (build output, codegen, `mv`, redirects) carry no
   `file_path` and are missed. A `Stop` hook (`session-hook.sh`) closes that
   gap: at each turn's end it reads `.cwd`, finds the `SANDBOX_USER`-owned paths
   under it (bounded by a timestamp marker, heavy trees like `.git`/`node_modules`
   pruned) and hands each to the same `ai-tools-chown`. It runs at turn end, not
   per-Bash-call, so handing a file to `640` (group loses write) can't break an
   in-progress in-place Bash edit. PostToolUse stays the immediate path — only it
   quarantines a secret the instant it is written; Stop is the catch-all net.
6. The `Stop` sweep is bounded by the (global, not per-project) timestamp marker,
   so it can miss `SANDBOX_USER`-owned paths left by a session that exited before
   its Stop hook ran (`kill -9`, crash, closed terminal) — and miss older paths
   when the working project changes. A `SessionStart` hook runs the same
   `session-hook.sh` with the `session-start` argument to close that gap: on
   `source` `startup`/`resume` (a freshly started process, the only case that can
   follow an interrupted session) it does one **unbounded** pass — every
   `SANDBOX_USER`-owned path under `.cwd`, ignoring the marker — then resets the
   marker so this session's Stop sweeps bound from session start. `clear`/`compact`
   stay within a live process whose Stop sweeps already cover the tree, so they are
   a no-op. Like every sweep, it only ever acts on `SANDBOX_USER`-owned paths (the
   agent wrote them) and `ai-tools-chown` re-validates each against the allowlist,
   so it reclaims agent files to `<you>:SANDBOX_GROUP` but never claims a user-owned
   file.

   Every unbounded pass also performs a **`.git` reclaim**, which the bounded Stop
   sweeps cannot. Every sweep prunes `.git` (a heavy tree), so `SANDBOX_USER`-owned
   objects the agent writes there via `git commit` (a `Bash`-tool action — no
   `file_path`, so no `Write`/`Edit` `PostToolUse` handback) escape the sweep on
   graceful and killed exits alike. Such objects leave `.git` in mixed ownership
   (work tree `<you>`-owned, `.git` internals `SANDBOX_USER`-owned) that makes git
   report *dubious ownership* and, once `<you>` is not a `SANDBOX_GROUP` member,
   blocks reads and repacks. The pass therefore descends the otherwise-pruned `.git`
   of `.cwd` and hands each `SANDBOX_USER`-owned path to `ai-tools-chown` (same
   allowlist + exclusion + secret re-validation as any sweep), restoring a uniformly
   `<you>:SANDBOX_GROUP` repo. The other pruned trees (`node_modules`, `.venv`, …)
   stay skipped: their contents are world-readable, so leftover `SANDBOX_USER`
   ownership there is harmless and not worth the per-path cost. The reclaim is scoped
   to the once-per-session `session-start` pass, not the per-turn Stop sweep, so it
   never flips ownership mid-turn under a live `git` command.

   Whether a session was interrupted is read from a **clean-exit marker**
   (`/opt/ai-tools/.claude/.session-active`): the `session-start` pass writes it
   (recording `.cwd`), and a `SessionEnd` hook — the same `session-hook.sh` with the
   `session-end` argument — removes it on graceful exit. A marker that *survives*
   into the next `session-start` means the previous session was killed before its
   `SessionEnd` ran. That signal **widens** the `.git` reclaim to also cover the
   killed session's recorded `.cwd` — which may be a **different** project than the
   new session's — and selects the interrupted-session `NOTICE` wording. (A
   gracefully-exited session clears its marker, so its `.git` is reclaimed by its
   next `session-start` in that project; the cross-project pointer is only needed for
   a kill.) The reclaim is reported through a `NOTICE` on the `SessionStart`
   `additionalContext` channel, so the agent can relay it and offer the manual `sudo
   chown -R --from=SANDBOX_USER <you>:SANDBOX_GROUP <project>` reconcile for anything
   the helper could not reach.
7. The same `SessionStart` pass also normalizes the project's **setgid** bit, via
   the root helper `ai-tools-setgid` (allowlist-validated, idempotent): every
   project directory is set group `SANDBOX_GROUP` with `g+s`, so a file *you* create
   there is born in group `SANDBOX_GROUP` and the agent can read/write it —
   **without you being a member of `SANDBOX_GROUP`**. That lets the projects user
   stay out of `SANDBOX_GROUP` entirely (defense in depth: your home-dir configs are
   then unreachable from `SANDBOX_GROUP`) while collaboration on project files still
   works. Heavy/transient trees (`.git`, `node_modules`, `.venv`, `__pycache__`,
   `bin`, `obj`, `packages`) are skipped; that prune list is shared with the sweep
   and `ai-tools-lockdown` via `/usr/local/lib/ai-tools/prune-dirs.lib.sh`. All four
   root sudo-helpers live under `/usr/local/sbin/ai-tools/` (`chown`, `setgid`,
   `claude-symlink`, `lockdown`).

## Security model — what `SANDBOX_USER` can and cannot do

The sudoers drop-in (`/etc/sudoers.d/ai-tools-claude`, `@PROJECTS_USER@`/
`@SANDBOX_USER@` substituted at install) grants exactly:

```
<you>  ALL=(SANDBOX_USER:SANDBOX_GROUP) NOPASSWD: /opt/ai-tools/bin/claude-run
<you>  ALL=(SANDBOX_USER:SANDBOX_GROUP) NOPASSWD: /opt/ai-tools/bin/nvm-update.sh v[0-9]*.[0-9]*.[0-9]*
```

`SANDBOX_USER` has **no** `sudo` rights in this file. The former three
`SANDBOX_USER ALL=(root)` rules (chown, setgid, claude-symlink) have been removed
because they were inoperative anyway: `RestrictNamespaces=yes` forces
`PR_SET_NO_NEW_PRIVS`, which drops `sudo`'s SUID bit, leaving it running as
`SANDBOX_USER` rather than root — incapable of reading `/etc/sudoers` or switching UID.
Those operations are now handled by the **`ai-tools-handback` socket bridge** (a
root-owned system daemon, `ai-tools-handback.socket`), which the hooks and updater
reach via `/usr/local/bin/ai-tools-handback-client` without SUID.

`umask=0007,umask_override` and `env_keep += "CLAUDE_EXEC CLAUDE_PROJECT_DIR"` (for
`claude-run`) and `env_keep` (for `nvm-update.sh`) are scoped per-command with
`Defaults!<command>`, so they apply only to those commands and never alter your
other sudo invocations. The sudoers `umask` sets `claude-run`'s own process umask;
a transient *service* unit does not inherit it (a scope would), so the agent's umask
is applied authoritatively by the `UMask=0007` property `claude-run` sets on the
unit. `CLAUDE_EXEC` carries the wrapper-validated versioned path through to
`claude-run` for re-validation there; `CLAUDE_PROJECT_DIR` carries the validated project
directory the same way, becoming the unit's `WorkingDirectory`.

- You may run **only** `claude-run` (and the pinned updater) as `SANDBOX_USER` —
  never an arbitrary shell or other binary. `claude-run` is a fixed-path sudo
  target (no glob), 550 `<you>:SANDBOX_GROUP`, not writable by the agent; the
  versioned claude binary is no longer a direct sudo target and is exec'd by
  `claude-run` itself after re-validating `CLAUDE_EXEC`. Both `<you>` rules
  **drop** privilege to the lower-privileged `SANDBOX_USER`; the agent runs *as*
  `SANDBOX_USER` and cannot invoke a `<you>` rule, so neither grants the agent
  anything.
- `SANDBOX_USER` has **no** sudo rights — not `rm -rf /`, not `cat /etc/shadow`,
  not any of the former root helpers. Root operations (chown, setgid, symlink repoint)
  go exclusively through the `ai-tools-handback` socket (see below). (`ai-tools-lockdown`
  is user-run and has no `SANDBOX_USER` sudo grant.)
- `SANDBOX_USER` has no login shell, no password, and no sudo rights.
- The allowlist gates where claude **launches** and which written files get
  ownership restored. It is **not** a kernel-enforced read boundary — once
  running, ordinary Unix permissions govern reads/writes. Those filesystem
  permissions are the enforced isolation boundary; a per-session `bubblewrap`
  mount namespace to make the allowlist a true access boundary is proposed (see
  project memory).

## Key design decisions

### Why `/opt/ai-tools`, not `/home`
`/home` is mounted `nosuid`, so a `sudo` UID-switch that execs a binary there
still runs as the invoking user. `/opt/ai-tools` has no `nosuid`, so the switch
to `SANDBOX_USER` actually takes effect and the binary is owned by `SANDBOX_USER`.

### Version resolution in `nvm-update.sh`
When multiple v22 versions exist, `nvm ls-remote | sort -V | tail -1` always
selects the highest semver — not "first match" or "currently active". Prune
logic collects all versions referenced by any named alias into an associative
array before removing anything, so a version another alias points to is
retained.

### Wrapper safety check
The wrapper resolves `/opt/ai-tools/bin/claude` with a single `readlink` hop,
then validates the target is an absolute, `..`-free path matching
`${AI_TOOLS_NVM_DIR}/versions/node/*/bin/claude` before calling sudo. String
checks only — no filesystem traversal beyond the symlink.

### Symlink resolution — one hop, not full resolution
The wrapper resolves `/opt/ai-tools/bin/claude` with a single `readlink` hop.
The versioned `bin/claude` is itself an npm symlink into the package
(`-> .../@anthropic-ai/claude-code/bin/claude.exe`); fully resolving it with
`realpath`/`readlink -f` would require traversing the package directory (mode 700,
`SANDBOX_USER`-owned), which the invoking user cannot enter — EACCES, silent abort
under `set -e`. One hop yields the versioned `.../node/<ver>/bin/claude` path,
which the wrapper validates (absolute, `..`-free, within the nvm subtree) and
exports as `CLAUDE_EXEC`.

The `<you>` sudoers rule targets the fixed path `/opt/ai-tools/bin/claude-run`;
the versioned binary is exec'd by `claude-run` after it re-validates `CLAUDE_EXEC`.
The one-hop readlink constraint exists solely to avoid EACCES — it carries no
coupling to sudoers matching.

### `claude-run` service shim — security properties and constraints
`claude-run` (550 `<you>:SANDBOX_GROUP`) wraps each session in a `systemd-run
--user --pty` transient *service* unit to apply kernel-level security properties
before `claude.exe` is exec'd. Three properties are set:

**`RestrictNamespaces=yes`** installs a seccomp filter blocking creation and joining
of every namespace type for the entire session process tree. This is the minimal
allow-list, and the set the agent needs is empty: an unprivileged process (the agent
holds no capabilities) can only ever create a *user* namespace by itself, since every
other type (`cgroup`/`ipc`/`mnt`/`net`/`pid`/`uts`) requires `CAP_SYS_ADMIN`, which is
reachable only *through* a user namespace. Blocking `user` therefore blocks all the
rest transitively; `=yes` makes that explicit and, unlike a `~user` denylist, also
fail-closes against any namespace type a future kernel adds. The load-bearing effect
is closing `clone(CLONE_NEWUSER)`: an agent-accessible user namespace lets a process
appear as uid 0 inside it, the precondition for exploiting kernel bugs that require
root-in-userns and for overlay mounts that confuse application-layer access checks.
seccomp runs at syscall entry, before the SELinux LSM hook, so this is also the only
*enforcing* layer for user-ns creation — SELinux cannot block it on this policy
(the `process2` class carries no `create_user_ns` permission; see ESC-001 in
`ai_tools.te`). SELinux type enforcement still survives into any namespace, so the
residual risk is kernel-CVE surface, not file-access bypass. System-wide user
namespaces remain enabled — Firefox and rootless Podman need them; the filter is
per-session and touches no sysctl, so other workloads are unaffected. The one
trade-off: `=yes` is incompatible with running unprivileged `bubblewrap` *inside* the
session (bwrap must create user+mnt namespaces), which the deferred bwrap phase must
resolve.

**`PrivateTmp` is not used.** It is a no-op for an unprivileged `--user` manager,
which has no privilege to mount a private `/tmp`: the unit sees the shared host `/tmp`
regardless (independent of `RestrictNamespaces`). The session therefore shares `/tmp`,
where claude keeps its runtime at a fixed `/tmp/claude-<uid>` (it does not honour
`TMPDIR`) and reuses it across sessions; `claude-run` does not touch that directory —
removing it would race claude's exists-then-`mkdir` check against another live session
of the same uid, which recreates it and makes startup fail with `EEXIST mkdir
/tmp/claude-<uid>`. Concurrent same-uid sessions share the directory; true per-session
`/tmp` isolation (and concurrent instances) would require a privileged (`--system`)
manager mounting `PrivateTmp` for the payload. Node's V8 compile cache is the one piece of
session scratch kept OUT of the shared `/tmp` — pinned to `ai_tools_home_t` via
`NODE_COMPILE_CACHE` (see the environment allowlist below) — because its default
`/tmp/node-compile-cache` collides with `user_tmp_t` leftovers and other uids.

**`UMask=0007`** keeps agent-created files group-writable so the collaborative
ownership model holds. A service unit does not inherit the caller's umask (a scope
did), so this is set as a unit property rather than relying on the sudoers `umask`.

**Environment is an explicit allowlist.** A service is spawned by the user manager
with its own environment, not `claude-run`'s, so `claude-run` forwards only a named
allowlist (`TERM`/`COLORTERM`, the locale `LC_*`/`LANG` set, proxy vars) via
`--setenv=NAME`, and pins `HOME=/opt/ai-tools`, a controlled `PATH`, and
`NODE_COMPILE_CACHE=/opt/ai-tools/.cache/node-compile-cache`. The compile-cache pin keeps
Node's V8 cache (claude calls `module.enableCompileCache()`) out of its default
`os.tmpdir()/node-compile-cache` on the shared `/tmp`, where an entry left by an earlier
unconfined run carries `user_tmp_t` — a type `ai_tools_t` has no rule for, so node's own
`open()` is denied and the session dies at startup under enforcing; `.cache` is
`ai_tools_home_t`, which the agent already manages. The operator's secrets
(`ANTHROPIC_API_KEY`, `AWS_*`, `SSH_AUTH_SOCK`, …) never cross into the session by
construction, independent of how sudo's `env_reset`/`env_keep` is configured. To share a
variable deliberately, add its name to `_ENV_ALLOW` in `claude-run`.

**`WorkingDirectory` is the validated project directory.** A transient unit does not
inherit the caller's cwd — it defaults to `/`. The wrapper exports the realpath'd,
allowlist- and claim-validated project directory as `CLAUDE_PROJECT_DIR`, carried through
sudo via `env_keep` (`sudoers.d/ai-tools-claude`); `claude-run` re-validates it (absolute,
`..`-free, existing) and sets it as the unit's `--working-directory`, so the session starts
in the project. The `WorkingDirectory` `chdir` runs in the user manager's domain before the
`exec` that transitions into `ai_tools_t`, so that domain needs `search` on
`ai_tools_project_t` (free for an `unconfined_t` manager; verify under enforcing if the
manager is `init_t`). `HOME` stays `/opt/ai-tools`: the agent's control plane
(`settings.json`, the hooks, `~/.claude.json`) is operator-owned and `ai_tools_home_t`, and
is deliberately not relocated into the agent-writable project tree.

**`NoNewPrivileges` — absent from the unit, but always in effect.** The session
always runs under `PR_SET_NO_NEW_PRIVS` because `RestrictNamespaces=yes` installs
its seccomp filter via that flag — `NoNewPrivileges` is a precondition for seccomp,
not a separate setting the unit can opt out of. Adding `NoNewPrivileges=yes`
explicitly to the unit would be redundant. The hooks do NOT call `sudo`:
`PR_SET_NO_NEW_PRIVS` would drop `sudo`'s SUID bit, leaving it running as
`SANDBOX_USER` instead of root — so every hook call would fail silently. The
hooks instead use the **`ai-tools-handback` socket bridge**: a Python client
(`/usr/local/bin/ai-tools-handback-client`) that connects to the root-owned
`ai-tools-handback.socket` (an `Accept=yes` system service, activated at boot)
and sends one `VERB ARG\n` request. The daemon authenticates the connection via
`SO_PEERCRED` (peer uid must equal `SANDBOX_USER`) and calls the matching root
helper. This eliminates all SUID usage from the session entirely: the agent holds
no capabilities, `sudo` is never exec'd, and the only privilege path is the
authenticated socket.

**`--pty` service vs `--scope`.** `RestrictNamespaces` and `UMask`
are exec-context sandbox directives, which systemd 252 rejects on a scope unit
(`Unknown assignment`): a scope has no exec context because the caller, not the
manager, performs the final `exec`. Only a service unit (the manager exec's
`ExecStart`) accepts them, and `--pty` keeps the session attached to the terminal so
claude's TUI works. The cost is that the `exec` now originates from the user manager,
not from `systemd-run` in `unconfined_t`, so the SELinux transition is keyed on the
manager's domain — `init_t` on RHEL/Rocky 9 targeted — via
`domtrans_pattern(init_t, ai_tools_exec_t, ai_tools_t)` in `ai_tools.te` (the
`unconfined_t` rule is retained for a direct exec). The live manager domain *and* its
role must be verified on the box (`ps -eZ | grep 'systemd --user'`); the policy
authorises both `unconfined_r` and `system_r` for `ai_tools_t` so the transition fires
regardless of which role the manager holds.

**Fail-closed confinement preflight.** If the session fails to transition into
`ai_tools_t` it runs *unconfined*, and because `ai-tools` is mapped to `unconfined_u`
this cannot be forbidden in the module (the ESC-001 base-policy floor; `user_u` was
rejected — it breaks the `ai-tools`→root sudo). A wrapper cannot observe its successor's
post-`exec` domain (the transition fires when the manager exec's `claude.exe`), so
`claude-run` instead verifies the transition's two inputs *before* launch: the
entrypoint's label (`matchpathcon` vs `stat -c %C`) and the `systemd --user` manager's
domain (read from `/proc/<pid>/attr/current`). It logs both on every launch (journald,
`claude-run` tag), and — when SELinux is enforcing and confinement was expected (the
module's file-contexts are installed) — refuses to launch if the binary is mislabelled
(→ `relabel`) or the manager domain is not one `ai_tools.te` has a `domtrans_pattern`
for (→ add the rule, `rebuild`). It is a no-op where the SELinux layer is absent, so
DAC-only and permissive boxes are unaffected.

**Optional SELinux groups and the namespace filter.** Enabling an optional policy
group (`install-selinux.sh enable-group <name>`) widens what SELinux permits but does
not lift this seccomp filter. Of the optional groups only `podman` creates namespaces
(rootless containers need user+mnt+pid+ipc+net+uts), so `RestrictNamespaces=yes` blocks
it even with the podman group loaded — the SELinux grant is necessary but not
sufficient. Supporting rootless podman means re-allowing the user namespace, which *is*
ESC-001, so it is not a clean partial relaxation. `claude-run` emits an actionable
NOTICE at launch when the podman group is loaded while the filter is active.

### Handback socket bridge (`ai-tools-handback`)
The session always runs under `PR_SET_NO_NEW_PRIVS` (forced by `RestrictNamespaces=yes`),
which drops `sudo`'s SUID bit. The `PostToolUse`, `Stop`/`SessionStart` hooks, and
`nvm-update.sh` therefore reach root operations through an `AF_UNIX SOCK_STREAM` socket
(`/run/ai-tools/handback.sock`, `0660 root:SANDBOX_GROUP`) served by a systemd
`Accept=yes` socket unit started at boot.

**Protocol:** one `VERB SP ARG LF` request per connection; response is zero or more
`MSG TEXT LF` relay lines followed by `OK LF` or `ERR REASON LF`. MSG lines carry
helper stderr (e.g. secret-file NOTICE) back to the client's stderr, which the hooks
forward into the agent session.

**Authentication:** the daemon reads `SO_PEERCRED` on fd 0 (the accepted socket) and
rejects any peer whose uid ≠ `SANDBOX_USER`. DAC provides the outer gate: the socket
file is `0660 root:SANDBOX_GROUP`, so only root and `SANDBOX_GROUP` members can
connect; world gets `EACCES` before reaching the daemon.

**Verbs:** `CHOWN ARG` → `ai-tools-chown ARG`; `SETGID ARG` → `ai-tools-setgid ARG`;
`SYMLINK ARG` → `ai-tools-claude-symlink ARG`. Each root helper re-validates the path
against the allowlist and the `SANDBOX_USER`-owned guard independently.

**Files:** daemon `/usr/local/sbin/ai-tools/ai-tools-handback` (750 root:root, Python 3);
client `/usr/local/bin/ai-tools-handback-client` (750 root:SANDBOX_GROUP, Python 3);
socket unit `/usr/lib/systemd/system/ai-tools-handback.socket`;
service template `/usr/lib/systemd/system/ai-tools-handback@.service`.

### Allowlist `!` exclusions are honored by both consumers
`!`-prefixed lines in `allowed-projects` are exclusions and override allows.
`ai-tools-chown` skips ownership restoration on excluded paths, and the wrapper
refuses to launch with an excluded CWD. Keep the two in sync (a plain `!`-path
also covers its contents; globs match as-is).

### Control-plane file integrity (`/opt/ai-tools/.claude`, `bin/`)
The files that drive the sandbox's own enforcement — `settings.json` (declares
the `PostToolUse` hook), `post-tool-hook.sh` (the hook body), `bin/nvm-update.sh`
(the updater the sudoers rule lets you run as `SANDBOX_USER`), and `bin/claude-run`
(the scope shim the sudoers rule lets you run to launch claude) — must not be
writable by the agent, or it could disable its own hand-back, secret-quarantine,
or scope-security guardrails. They are owned `<you>:SANDBOX_GROUP` (group
read/exec, no group write), **not** `SANDBOX_USER:SANDBOX_GROUP`.

Ownership alone is insufficient: `/opt/ai-tools/.claude` is group-writable by
`SANDBOX_GROUP` (Claude must write `sessions/`, `history.jsonl`, etc. there), and a
group-writer can `unlink`+recreate any file in a dir it can write — regardless of
the file's owner. So `.claude` is owned `<you>:SANDBOX_GROUP` (**not**
`SANDBOX_USER`) with **setgid + sticky** (`3770`): the agent stays a group-writer
for its own state, but the sticky bit forbids deleting/replacing files it does not
own, and since it is not the dir owner it cannot bypass that. setgid keeps new
entries in group `SANDBOX_GROUP`. This is the inverse of the project-dir reasoning
below — sticky is wanted here precisely because the agent never legitimately
re-edits these files.

`/opt/ai-tools/bin` is locked harder still: owned `<you>:SANDBOX_GROUP` at `550`, so
it is not even group-writable. `SANDBOX_USER` gets group `r-x` — enough to execute
`nvm-update.sh` and resolve the `claude` symlink — but no write, and it is not the
dir owner, so it cannot edit `nvm-update.sh` in place, `unlink`/replace it, or swap
the symlink. No sticky bit is needed because nothing here is group-writable; only
root (and `<you>` after a deliberate `chmod`) can change it. This is a stronger
guarantee than the `.claude` files.

Because `bin` is locked, `SANDBOX_USER` cannot refresh the versioned `claude`
symlink itself after a Node upgrade. That repoint is delegated to a narrow root
helper, `ai-tools-claude-symlink`: it accepts one argument, validates it is
exactly a `…/node/v<MAJOR>.<MINOR>.<PATCH>/bin/claude` path that exists (its own
anchored-regex check, **not** the coarse sudoers glob, is authoritative — argument
wildcards can match `/`), then atomically repoints the symlink. The sandbox
updater and `install.sh` are the only callers. See
[[symlink-repoint-root-helper]].

### Acts only on agent-written paths
`ai-tools-chown` acts on a path **only when it is currently `SANDBOX_USER`-owned**.
Claude Code's Write/Edit tools create files and parent dirs via atomic rename,
which stamps them `SANDBOX_USER`-owned, so this is the signal that *the agent
itself just wrote the path*. Any path not owned by `SANDBOX_USER` is a pre-existing
user file or directory the agent could not have written — it is left completely
untouched (no re-chown, no bit-stripping, and for a secret-named path no false
`breached` NOTICE about a secret the agent never had access to). This is the
file/secret counterpart of the directory rule above.

### Secret-named files
A secret-named file the agent wrote is breached. `ai-tools-chown` classifies the
basename against a shared pattern set (`.env`, `*.key`, `*.pem`, `id_*`,
`kubeconfig`, `*.jks`, `.pgpass`, the name-anchored .NET config patterns, …;
basename-safe globs only, no bare `config`) and chowns a match (when
`SANDBOX_USER`-owned, per above) to `<you>:<you> 600`, so `SANDBOX_USER` — neither
owner nor group member — cannot read the contents. It writes a `NOTICE` to stderr
(the hook relays it into the session) and, at `WARNING` level, to the operation log
(`/var/log/ai-tools/chown.log` and journald; see [[operation-logging]]).

This revokes read only. `SANDBOX_USER` is a group-writer on the project dir (not
its owner), so it can still unlink/replace the path; a replacement is agent-written
and re-triggers the same handling, and the audit log is root-owned. A
project-wide sticky bit does not apply: `SANDBOX_USER` is a group-writer and
handed-back files are `<you>`-owned, so it would block the agent's atomic-rename
re-edits. To prevent unlink/replace of the user's own secrets, place them in a
dir the agent cannot write (`700 <you>:<you>`) and `!`-exclude it. See
[[allowlist-not-an-access-boundary]].

### Shared secret-pattern set (one source, two consumers)
The secret basename patterns live in a single user-owned config file,
`~/.config/ai-tools/secret-patterns` (`<you>:<you> 600`), co-located with
`allowed-projects` and owned the same way: the user edits it; `SANDBOX_USER` —
neither its owner nor in its group, and unable to enter the `700 .config/ai-tools`
dir — can neither read nor write it; the root helpers read it on the user's behalf.
The agent therefore cannot weaken its own secret classification.

Both root helpers source `/usr/local/lib/ai-tools/secret-patterns.lib.sh`
(root-owned `644`, not in a `SANDBOX_USER`-writable dir) for one matcher over that
file, so `ai-tools-chown` and `ai-tools-lockdown` can never drift apart. The
library carries a built-in default list identical to the shipped `secret-patterns`
seed (`src/home/user/.config/ai-tools/secret-patterns`); if the config file is
missing or empty the defaults apply, so classification never silently degrades to
"match nothing". A failure to source the library is fail-closed: `ai-tools-chown`
exits non-zero and simply skips that path's handback (it stays `SANDBOX_USER`-owned)
rather than handing a possible secret back as an ordinary file. `ai-tools-chown`
runs in `ai_tools_t` with no transition, so the policy grants that domain
`libs_read_lib_files` to read the `lib_t`-labelled library; without it the source
fails under enforcing.

The patterns are name- or environment-anchored (`appsettings.*.json`,
`web.*.config`, `*.Production.*`, …), deliberately **not** broad
`*.*.json`/`*.*.config` catch-alls — those would also match build artifacts the
toolchain must read (`*.deps.json`, `*.runtimeconfig.json`,
`project.assets.json`, `*.dll.config`), and quarantining them breaks builds.

### `ai-tools-lockdown` — proactive secret lockdown
`ai-tools-chown` is reactive: it fires per agent-written path and acts only on
`SANDBOX_USER`-owned paths, so it never touches a pre-existing user-owned secret the
agent could already read (the allowlist is not a read boundary). `ai-tools-lockdown`
(`/usr/local/sbin/ai-tools/ai-tools-lockdown`, run `ai-tools --lockdown <project>`
or `cd <project> && sudo ai-tools-lockdown`)
is the proactive counterpart: it walks the current directory and, for every path
matching the shared secret patterns, sets regular files `600`, directories `700`,
and owner `<you>:SANDBOX_GROUP` — revoking `SANDBOX_USER`'s read regardless of who
created the path. It runs only when the CWD is an allowed project and skips
`!`-excluded paths, reusing the same allowlist parse, and applies each change
through a pinned fd (re-verifying inode and type) so a `SANDBOX_USER` path swap
cannot redirect root's chmod/chown. `--dry-run` previews; `--yes` skips the TTY
confirmation. It is a user tool: there is **no** sudoers grant letting
`SANDBOX_USER` run it, and it refuses to run as `SANDBOX_USER`. The `ai-tools` CLI
wraps it as `ai-tools --lockdown [path]` (it `cd`s into the project and `sudo`s the
helper, so sudo prompts for the projects user's password; `-n`/`--dry-run` and
`-y`/`--yes` pass through). The CLI never pre-checks the helper's path:
`/usr/local/sbin/ai-tools` is `750 root:root`, so the projects user cannot stat the
helper — only `sudo`, as root, can reach it.

`ai-tools --sandbox-create` invokes this lockdown directly after a shallow clone,
since the clone's tip commit may still hold credential files. If the user declines
or `sudo` is unavailable, the CLI instead drops a guard `CLAUDE.md` into the clone
instructing the agent to do nothing until lockdown runs (any existing `CLAUDE.md`
is preserved via `git mv` to `CLAUDE.md.bak`); a later successful `ai-tools
--lockdown` removes the guard and restores the original. The guard carries a
sentinel comment (`ai-tools-lockdown-guard`) so the CLI recognizes its own
placeholder and never clobbers a real `CLAUDE.md`.

### Operation logging
The sandbox components log through one shared library,
`/usr/local/lib/ai-tools/log.lib.sh` (`644 root:root`, world-readable — it carries
no secrets and every principal sources it). It exposes `ai_tools_log <level>` and
`ai_tools_log_{debug,info,warn,error}`, writing to two sinks:

- **journald** — always, via `logger` with a per-component `SyslogIdentifier`
  (`AI_TOOLS_LOG_TAG`) and a syslog priority matching the level. This is the
  universal sink: the non-root components write here because they cannot write the
  root-only files. Query with `journalctl -t ai-tools-chown` (or `-setgid`,
  `-claude-symlink`, `-lockdown`, `-hook`, `ai-tools`, `ai-tools-install`), with
  `-p warning` to filter by level.
- **`/var/log/ai-tools/<component>.log`** — only when the caller sets
  `AI_TOOLS_LOG_FILE`, which only the root writers do. The directory is `700
  root:root`, each file `600 root:root`: the root helpers append as root, while
  `SANDBOX_USER` — neither the dir owner nor able to traverse a `700` dir — can
  neither read nor tamper with the trail. That is what keeps the secret filenames
  `ai-tools-chown` records out of the agent's reach. The files are `chown.log`,
  `setgid.log`, `symlink.log`, `lockdown.log`, and `install.log`.

What is logged is a caller convention, not enforced by the library: the privileged
operations the hooks and `sudo` helpers perform, the CLI's workflow milestones
(project/sandbox created, pushed, removed, locked down), and the full install
transcript (`do_install` tees a colour-stripped copy to `install.log`). Routine
per-path sweep churn is `DEBUG` only and is emitted only when a path actually
changes. A message placed before its operation is present-tense `DEBUG`; one after a
completed unit of work is past-tense `INFO`. Both sinks are best-effort — a failed
write is swallowed so logging never aborts or alters the exit status of the
operation it describes.

The directory is labelled `ai_tools_log_t` (`selinux/ai_tools.fc`); the helpers that
run in `ai_tools_t` (`ai-tools-chown`, `ai-tools-setgid`, and `ai-tools-claude-symlink`
under the updater) are granted append/create on that type (`selinux/ai_tools.te`), so
the file writes succeed under enforcing. `ai-tools-lockdown` and the CLI run
unconfined; the hooks reach journald over the already-granted `/dev/log` path. After
editing the policy source, rebuild and reload the loaded module with `sudo
selinux/install-selinux.sh rebuild`.

### `loginctl enable-linger`
`loginctl enable-linger` keeps the projects user's systemd instance running after
logout, so the daily `nvm-update` timer fires without an active login. Required
for headless/unattended operation.

### PATH ordering
`~/.local/bin` must precede the nvm shims in `$PATH`, or the nvm-managed
`claude` shadows the wrapper. `path_dedup.sh` (in `/etc/profile.d/`) handles
this when sourced **after** `nvm.sh` in `~/.bashrc` and `~/.bash_profile`;
`install.sh` warns if the ordering is wrong rather than editing dotfiles itself.
