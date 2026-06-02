# Claude Code on RHEL — sandboxed `ai-tools` user

## Purpose

This repo installs and maintains a way to run Anthropic's **Claude Code on
RHEL 9 as a dedicated, locked-down system user (`ai-tools`)** instead of as your
own login account. The goal: let an autonomous coding agent work on your
projects without inheriting your user's privileges. It runs under a separate
UID with no login shell, can only launch inside explicitly approved project
directories, can escalate only through two narrow `sudo` rules, and should not
reach your secrets, SSH keys, or unrelated projects.

A scheduled `nvm-update` job keeps Node.js v22 and `@anthropic-ai/claude-code`
current for both your login user and the sandbox user, pinned to the same build.

## How it works (the trust chain)

1. You type `claude` → resolves to the wrapper `~/.local/bin/claude` (runs as you).
2. The wrapper checks the current directory against the **approved-projects
   allowlist** (`~/.config/ai-tools/allowed-projects`); refuses to start anywhere
   else, and refuses a CWD carved out by a `!` exclusion.
3. It resolves the versioned binary via the stable symlink
   `/opt/ai-tools/bin/claude` (one `readlink` hop), then
   `exec sudo -u ai-tools -g ai-tools -- <versioned claude>`.
4. Claude runs as uid `ai-tools`. Files it writes are owned `ai-tools`; a
   `PostToolUse` hook calls `sudo ai-tools-chown` (the only command `ai-tools`
   may sudo) to restore `<you>:ai-tools` ownership and strip world bits, inside
   allowlisted paths only (never on `!`-excluded paths). The hook also walks the
   written file's parent directories and hands each back to `<you>:ai-tools`
   (world bits stripped, group `rwx` kept so the agent can keep writing into a dir
   it made), but **only** for directories the agent itself created (currently
   `ai-tools`-owned): the walk stops at the first pre-existing user-owned dir, and
   `ai-tools-chown` independently refuses any non-`ai-tools` directory, so it never
   grants the agent group access to a dir it did not already own. Secret-named
   files (`.env`, `*.key`, SSH keys, `kubeconfig`, …) are instead moved to your
   private group with group+world bits stripped (`<you>:<you> 600`), revoking
   ai-tools' read access, with a `NOTICE` surfaced in the session + audit log.
5. The `PostToolUse` hook only fires for `Write`/`Edit`, so files the agent
   creates via the `Bash` tool (build output, codegen, `mv`, redirects) carry no
   `file_path` and are missed. A `Stop` hook (`post-write-sweep.sh`) closes that
   gap: at each turn's end it reads `.cwd`, finds the `ai-tools`-owned paths under
   it (bounded by a timestamp marker, heavy trees like `.git`/`node_modules`
   pruned) and hands each to the same `ai-tools-chown`. It runs at turn end, not
   per-Bash-call, so handing a file to `640` (group loses write) can't break an
   in-progress in-place Bash edit. PostToolUse stays the immediate path — only it
   quarantines a secret the instant it is written; Stop is the catch-all net.
6. The `Stop` sweep is bounded by the (global, not per-project) timestamp marker,
   so it can miss `ai-tools`-owned paths left by a session that exited before its
   Stop hook ran (`kill -9`, crash, closed terminal) — and miss older paths when
   the working project changes. A `SessionStart` hook runs the same
   `post-write-sweep.sh` with the `session-start` argument to close that gap: on
   `source` `startup`/`resume` (a freshly started process, the only case that can
   follow an interrupted session) it does one **unbounded** pass — every
   `ai-tools`-owned path under `.cwd`, ignoring the marker — then resets the marker
   so this session's Stop sweeps bound from session start. `clear`/`compact` stay
   within a live process whose Stop sweeps already cover the tree, so they are a
   no-op. Like every sweep, it only ever acts on `ai-tools`-owned paths (the agent
   wrote them) and `ai-tools-chown` re-validates each against the allowlist, so it
   reclaims agent files to `<you>:ai-tools` but never claims a user-owned file.

## Security model — what `ai-tools` can and cannot do

The sudoers drop-in (`/etc/sudoers.d/ai-tools-claude`, `@PROJECTS_USER@`
substituted at install) grants exactly:

```
<you>    ALL=(ai-tools:ai-tools) NOPASSWD: /opt/ai-tools/.nvm/versions/node/*/bin/claude
<you>    ALL=(ai-tools:ai-tools) NOPASSWD: /opt/ai-tools/bin/nvm-update.sh v[0-9]*.[0-9]*.[0-9]*
ai-tools ALL=(root)             NOPASSWD: /usr/local/sbin/ai-tools-chown
ai-tools ALL=(root)             NOPASSWD: /usr/local/sbin/ai-tools-claude-symlink /opt/ai-tools/.nvm/versions/node/v[0-9]*
```

`umask=0007` (for claude) and `env_keep` (for nvm-update.sh) are scoped
per-command with `Defaults!<command>`, so they apply only to those two commands
and never alter your other sudo invocations.

- You may run **only** claude (and the pinned updater) as `ai-tools` — never an
  arbitrary shell or other binary. Both `<you>` rules **drop** privilege to the
  lower-privileged `ai-tools`; the agent runs *as* `ai-tools` and cannot invoke a
  `<you>` rule, so neither grants the agent anything.
- `ai-tools` may run **only** two root commands: `ai-tools-chown` (restores
  ownership inside the allowlist) and `ai-tools-claude-symlink` (repoints the
  stable claude symlink at a validated versioned path) — not `rm -rf /`, not
  `cat /etc/shadow`, not anything else in `/usr/bin`.
- `ai-tools` has no login shell, no password, and no other sudo rights.
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
to `ai-tools` actually takes effect and the binary is owned by `ai-tools`.

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

### sudoers glob + symlink resolution — IMPORTANT
The glob `*/bin/claude` matches the versioned path
`/opt/ai-tools/.nvm/versions/node/<ver>/bin/claude`. The wrapper must resolve
the stable symlink **exactly one hop** (`readlink`, not `realpath`/`readlink
-f`). The versioned `bin/claude` is itself an npm symlink into the package
(`-> .../@anthropic-ai/claude-code/bin/claude.exe`); fully resolving it would
(a) produce a path the sudoers rule cannot match — so sudo denies/prompts and
claude never launches — and (b) require traversing the package dir (mode 700,
ai-tools), which the invoking user cannot enter (EACCES). The one-hop readlink
and the sudoers glob are coupled — don't change one without the other.

### Allowlist `!` exclusions are honored by both consumers
`!`-prefixed lines in `allowed-projects` are exclusions and override allows.
`ai-tools-chown` skips ownership restoration on excluded paths, and the wrapper
refuses to launch with an excluded CWD. Keep the two in sync (a plain `!`-path
also covers its contents; globs match as-is).

### Control-plane file integrity (`/opt/ai-tools/.claude`, `bin/nvm-update.sh`)
The files that drive the sandbox's own enforcement — `settings.json` (declares
the `PostToolUse` hook), `post-tool-hook.sh` (the hook body), and
`bin/nvm-update.sh` (the updater the sudoers rule lets you run as `ai-tools`) —
must not be writable by the agent, or it could disable its own hand-back and
secret-quarantine guardrails. They are owned `<you>:ai-tools` (group read/exec,
no group write), **not** `ai-tools:ai-tools`.

Ownership alone is insufficient: `/opt/ai-tools/.claude` is group-writable by
`ai-tools` (Claude must write `sessions/`, `history.jsonl`, etc. there), and a
group-writer can `unlink`+recreate any file in a dir it can write — regardless of
the file's owner. So `.claude` is owned `<you>:ai-tools` (**not** `ai-tools`) with
**setgid + sticky** (`3770`): the agent stays a group-writer for its own state,
but the sticky bit forbids deleting/replacing files it does not own, and since it
is not the dir owner it cannot bypass that. setgid keeps new entries in group
`ai-tools`. This is the inverse of the project-dir reasoning below — sticky is
wanted here precisely because the agent never legitimately re-edits these files.

`/opt/ai-tools/bin` is locked harder still: owned `<you>:ai-tools` at `550`, so
it is not even group-writable. `ai-tools` gets group `r-x` — enough to execute
`nvm-update.sh` and resolve the `claude` symlink — but no write, and it is not the
dir owner, so it cannot edit `nvm-update.sh` in place, `unlink`/replace it, or swap
the symlink. No sticky bit is needed because nothing here is group-writable; only
root (and `<you>` after a deliberate `chmod`) can change it. This is a stronger
guarantee than the `.claude` files.

Locking `bin` means `ai-tools` can no longer refresh the versioned `claude`
symlink itself after a Node upgrade. That repoint is delegated to a narrow root
helper, `ai-tools-claude-symlink`: it accepts one argument, validates it is
exactly a `…/node/v<MAJOR>.<MINOR>.<PATCH>/bin/claude` path that exists (its own
anchored-regex check, **not** the coarse sudoers glob, is authoritative — argument
wildcards can match `/`), then atomically repoints the symlink. The sandbox
updater and `install.sh` are the only callers. See
[[symlink-repoint-root-helper]].

### Acts only on agent-written paths
`ai-tools-chown` acts on a path **only when it is currently `ai-tools`-owned**.
Claude Code's Write/Edit tools create files and parent dirs via atomic rename,
which stamps them `ai-tools`-owned, so this is the signal that *the agent itself
just wrote the path*. Any path not owned by `ai-tools` is a pre-existing user
file or directory the agent could not have written — it is left completely
untouched (no re-chown, no bit-stripping, and for a secret-named path no false
`breached` NOTICE about a secret the agent never had access to). This is the
file/secret counterpart of the directory rule above.

### Secret-named files
A secret-named file the agent wrote is breached. `ai-tools-chown` classifies the
basename against a shared pattern set (`.env`, `*.key`, `*.pem`, `id_*`,
`kubeconfig`, `*.jks`, `.pgpass`, the name-anchored .NET config patterns, …;
basename-safe globs only, no bare `config`) and chowns a match (when
`ai-tools`-owned, per above) to `<you>:<you> 600`, so ai-tools — neither owner nor
group member — cannot read the contents. It writes a `NOTICE` to stderr (the hook
relays it into the session) and `/var/log/ai-tools-chown.log`.

This revokes read only. ai-tools is a group-writer on the project dir (not its
owner), so it can still unlink/replace the path; a replacement is agent-written
and re-triggers the same handling, and the audit log is root-owned. A
project-wide sticky bit does not apply: ai-tools is a group-writer and
handed-back files are `<you>`-owned, so it would block the agent's atomic-rename
re-edits. To prevent unlink/replace of the user's own secrets, place them in a
dir the agent cannot write (`700 <you>:<you>`) and `!`-exclude it. See
[[allowlist-not-an-access-boundary]].

### Shared secret-pattern set (one source, two consumers)
The secret basename patterns live in a single user-owned config file,
`~/.config/ai-tools/secret-patterns` (`<you>:<you> 600`), co-located with
`allowed-projects` and owned the same way: the user edits it; ai-tools — neither
its owner nor in its group, and unable to enter the `700 .config/ai-tools` dir —
can neither read nor write it; the root helpers read it on the user's behalf.
The agent therefore cannot weaken its own secret classification.

Both root helpers source `/usr/local/lib/ai-tools/secret-patterns.lib.sh`
(root-owned `644`, not in an ai-tools-writable dir) for one matcher over that
file, so `ai-tools-chown` and `ai-tools-lockdown` can never drift apart. The
library carries a built-in default list identical to the shipped
`secret-patterns.conf`; if the config file is missing or empty the defaults
apply, so classification never silently degrades to "match nothing". A failure
to source the library is fail-closed: `ai-tools-chown` exits non-zero and simply
skips that path's handback (it stays `ai-tools`-owned) rather than handing a
possible secret back as an ordinary file. `ai-tools-chown` runs in `ai_tools_t`
with no transition, so the policy grants that domain `libs_read_lib_files` to
read the `lib_t`-labelled library; without it the source fails under enforcing.

The patterns are name- or environment-anchored (`appsettings.*.json`,
`web.*.config`, `*.Production.*`, …), deliberately **not** broad
`*.*.json`/`*.*.config` catch-alls — those would also match build artifacts the
toolchain must read (`*.deps.json`, `*.runtimeconfig.json`,
`project.assets.json`, `*.dll.config`), and quarantining them breaks builds.

### `ai-tools-lockdown` — proactive secret lockdown
`ai-tools-chown` is reactive: it fires per agent-written path and acts only on
`ai-tools`-owned paths, so it never touches a pre-existing user-owned secret the
agent could already read (the allowlist is not a read boundary). `ai-tools-lockdown`
(`/usr/local/sbin/ai-tools-lockdown`, run `cd <project> && sudo ai-tools-lockdown`)
is the proactive counterpart: it walks the current directory and, for every path
matching the shared secret patterns, sets regular files `600`, directories `700`,
and owner `<you>:ai-tools` — revoking ai-tools' read regardless of who created
the path. It runs only when the CWD is an allowed project and skips `!`-excluded
paths, reusing the same allowlist parse, and applies each change through a pinned
fd (re-verifying inode and type) so an ai-tools path swap cannot redirect root's
chmod/chown. `--dry-run` previews; `--yes` skips the TTY confirmation. It is a
user tool: there is **no** sudoers grant letting ai-tools run it, and it refuses
to run as `ai-tools`.

### `loginctl enable-linger`
Without this, the user systemd instance exits on logout and the daily timer
never fires unless you're logged in. Required for headless/unattended operation.

### PATH ordering
`~/.local/bin` must precede the nvm shims in `$PATH`, or the nvm-managed
`claude` shadows the wrapper. `path_dedup.sh` (in `/etc/profile.d/`) handles
this when sourced **after** `nvm.sh` in `~/.bashrc` and `~/.bash_profile`;
`install.sh` warns if the ordering is wrong rather than editing dotfiles itself.
