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
   allowlisted paths only (never on `!`-excluded paths). Secret-named files
   (`.env`, `*.key`, SSH keys, `kubeconfig`, …) are instead moved to your
   private group with group+world bits stripped (`<you>:<you> 600`), revoking
   ai-tools' read access, with a `NOTICE` surfaced in the session + audit log.

## Security model — what `ai-tools` can and cannot do

The sudoers drop-in (`/etc/sudoers.d/ai-tools-claude`, `@INSTALL_USER@`
substituted at install) grants exactly:

```
<you>    ALL=(ai-tools:ai-tools) NOPASSWD: /opt/ai-tools/.nvm/versions/node/*/bin/claude
<you>    ALL=(ai-tools:ai-tools) NOPASSWD: /opt/ai-tools/bin/nvm-update.sh v[0-9]*
ai-tools ALL=(root)             NOPASSWD: /usr/local/sbin/ai-tools-chown
```

- You may run **only** claude (and the pinned updater) as `ai-tools` — never an
  arbitrary shell or other binary.
- `ai-tools` may run **only** `ai-tools-chown` as root — not `rm -rf /`, not
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

### Secret-named files
A secret-named file written by the agent is breached. `ai-tools-chown` matches a
basename list (`.env`, `*.key`, `*.pem`, `id_*`, `kubeconfig`, `*.jks`,
`.pgpass`, …; basename-safe globs only, no bare `config`) and chowns matches to
`<you>:<you> 600`, so ai-tools — neither owner nor group member — cannot read
the contents. It writes a `NOTICE` to stderr (the hook relays it into the
session) and `/var/log/ai-tools-chown.log`.

This revokes read only. ai-tools is a group-writer on the project dir (not its
owner), so it can still unlink/replace the path; a replacement is agent-written
and re-triggers the same handling, and the audit log is root-owned. A
project-wide sticky bit does not apply: ai-tools is a group-writer and
handed-back files are `<you>`-owned, so it would block the agent's atomic-rename
re-edits. To prevent unlink/replace of the user's own secrets, place them in a
dir the agent cannot write (`700 <you>:<you>`) and `!`-exclude it. See
[[allowlist-not-an-access-boundary]].

### `loginctl enable-linger`
Without this, the user systemd instance exits on logout and the daily timer
never fires unless you're logged in. Required for headless/unattended operation.

### PATH ordering
`~/.local/bin` must precede the nvm shims in `$PATH`, or the nvm-managed
`claude` shadows the wrapper. `path_dedup.sh` (in `/etc/profile.d/`) handles
this when sourced **after** `nvm.sh` in `~/.bashrc` and `~/.bash_profile`;
`install.sh` warns if the ordering is wrong rather than editing dotfiles itself.
