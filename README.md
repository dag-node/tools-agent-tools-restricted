# Claude Code on RHEL 9 — sandboxed `SANDBOX_USER` account + nvm auto-updater

Run Anthropic's **Claude Code as a dedicated, unprivileged system user
(`SANDBOX_USER`, the account created as `ai-tools`)** on RHEL 9 instead of as your
own login account, and keep Node.js and the `claude` CLI current automatically.

## Why

Claude Code is an autonomous agent that reads, writes, and runs commands. Run as
your own user it inherits everything you can touch — SSH keys, browser profiles,
every project, your full sudo rights. This project gives the agent its own UID
with a tightly scoped set of privileges instead:

- **Separate identity** — `${SANDBOX_USER}` is a system account with no login shell
  and no password. Claude executes under that UID via `sudo`, not as you.
- **Launches only in approved projects** — a wrapper refuses to start Claude
  unless the working directory is listed in `~/.config/ai-tools/allowed-projects`
  (with `!` exclusions to carve out subdirectories or secrets).
- **Minimal sudo surface** — `${SANDBOX_USER}` may run only three narrow root
  helpers (`ai-tools-chown`, `ai-tools-setgid`, and `ai-tools-claude-symlink`, each
  allowlist- or argument-validated). You may run only `claude` (and the pinned
  updater) as `${SANDBOX_USER}`. Nothing else.
- **Ownership hand-back** — files Claude writes are chowned back to
  `${PROJECTS_USER}:${SANDBOX_GROUP}` (group-readable, world-closed) inside approved paths only, along
  with any directories Claude created on the way (world bits stripped, group
  `rwx` kept; only dirs the agent itself made are touched). Secret-named files
  (`.env`, `*.key`, `*.pem`, SSH keys, `kubeconfig`, …) are chowned to
  `${PROJECTS_USER}:${PROJECTS_GROUP} 600` instead, removing `${SANDBOX_USER}`'s read access; a `NOTICE` is written to
  the session and an audit log.
- **Auto-updating** — a systemd user timer keeps Node v22 and
  `@anthropic-ai/claude-code` current for both you and the sandbox user, pinned
  to the same build.

> **On the boundary.** The allowlist gates where Claude *launches* and which
> files get ownership restored — it is not a kernel-enforced read boundary. Once
> running as `${SANDBOX_USER}`, ordinary Unix permissions govern access; that is what
> actually isolates the agent from other users' files. A per-session
> `bubblewrap` mount namespace to make the allowlist a true access boundary is
> proposed but not yet implemented.

## Identities and naming

Three identities recur throughout this README, the scripts, and the templates.
They are referred to by fixed names so each reference is unambiguous; the full
spec is in [`docs/naming-conventions.md`](docs/naming-conventions.md).

| Identity | Variable / token | Default | Meaning |
|---|---|---|---|
| Projects user | `PROJECTS_USER` / `@PROJECTS_USER@` | your login (`$SUDO_USER`) | the account that owns the projects, installs the sandbox, and launches `claude` |
| …its group | `PROJECTS_GROUP` / `@PROJECTS_GROUP@` | your primary group | the projects user's private group |
| …its home | `PROJECTS_HOME` / `@PROJECTS_HOME@` | `$HOME` | the projects user's home directory |
| Sandbox user | `SANDBOX_USER` / `@SANDBOX_USER@` | `ai-tools` | the unprivileged service account Claude Code runs as |
| …its group | `SANDBOX_GROUP` / `@SANDBOX_GROUP@` | `ai-tools` | the sandbox user's group |

`install.sh` resolves these automatically. The `@…@` token form is what the
shipped templates carry; `install.sh` substitutes it at deploy time. The literal
`ai-tools` is kept in paths (`/opt/ai-tools`), SELinux types (`ai_tools_t`), and
helper names (`ai-tools-chown`) — these are not the account and stay fixed even
if `SANDBOX_USER` changes.

For the **manual** install steps below, export the variables once so the
commands paste verbatim:

    PROJECTS_USER="$(id -un)"
    PROJECTS_GROUP="$(id -gn)"
    PROJECTS_HOME="${HOME}"
    SANDBOX_USER=ai-tools
    SANDBOX_GROUP=ai-tools

## Architecture at a glance

```
you type `claude`
  └─ ~/.local/bin/claude                      (wrapper, runs as you)
       ├─ CWD ∈ allowed-projects?             refuse if not, or if !-excluded
       ├─ resolve /opt/ai-tools/bin/claude    (one readlink hop)
       └─ exec sudo -u "${SANDBOX_USER}" -- <versioned claude>
            └─ claude runs as ${SANDBOX_USER}
                 └─ on Write/Edit → PostToolUse hook
                      └─ sudo ai-tools-chown <file>   (root; allowlist-checked)
                           └─ chown ${PROJECTS_USER}:${SANDBOX_GROUP}, strip world bits
```

## Files

| File | Deploy path |
|---|---|
| src/etc/profile.d/path_dedup.sh | /etc/profile.d/path_dedup.sh (root) |
| src/home/user/.local/bin/nvm-update.sh | ~/.local/bin/nvm-update.sh |
| src/opt/ai-tools/bin/nvm-update.sh | /opt/ai-tools/bin/nvm-update.sh |
| src/usr/local/sbin/ai-tools/ai-tools-chown.sh | /usr/local/sbin/ai-tools/ai-tools-chown (root) |
| src/usr/local/sbin/ai-tools/ai-tools-setgid.sh | /usr/local/sbin/ai-tools/ai-tools-setgid (root) |
| src/usr/local/sbin/ai-tools/ai-tools-claude-symlink.sh | /usr/local/sbin/ai-tools/ai-tools-claude-symlink (root) |
| src/usr/local/sbin/ai-tools/ai-tools-lockdown.sh | /usr/local/sbin/ai-tools/ai-tools-lockdown (root) |
| src/usr/local/lib/ai-tools/secret-patterns.lib.sh | /usr/local/lib/ai-tools/secret-patterns.lib.sh (root) |
| src/usr/local/lib/ai-tools/prune-dirs.lib.sh | /usr/local/lib/ai-tools/prune-dirs.lib.sh (root) |
| src/home/user/.local/bin/claude.sh | ~/.local/bin/claude |
| src/opt/ai-tools/.claude/post-tool-hook.sh | /opt/ai-tools/.claude/post-tool-hook.sh |
| src/opt/ai-tools/.claude/session-hook.sh | /opt/ai-tools/.claude/session-hook.sh |
| src/opt/ai-tools/.claude/settings.json | /opt/ai-tools/.claude/settings.json |
| src/home/user/.config/systemd/user/nvm-update.service | ~/.config/systemd/user/nvm-update.service |
| src/home/user/.config/systemd/user/nvm-update.timer | ~/.config/systemd/user/nvm-update.timer |
| src/etc/sudoers.d/ai-tools-claude | /etc/sudoers.d/ai-tools-claude (root) |
| install.sh | run in place via sudo |

---

## Why /opt/ai-tools, not `${PROJECTS_HOME}`

`/home` is mounted `nosuid`. The kernel refuses to honour the setuid bit when
a process doing a UID-switch executes a binary on a `nosuid` filesystem.
`sudo` can switch UIDs, but the target binary (`claude`) still runs as the
_invoking_ user because the exec happens on `nosuid` storage.

Installing nvm and claude under `/opt/ai-tools` (which has no `nosuid`
restriction) fixes this: the UID switch via `sudo` works, and the binary is
owned by `${SANDBOX_USER}` so the kernel is satisfied.

---

## 1. Install PATH deduplication script (root, once)

    sudo install -o root -g root -m 644 \
        src/etc/profile.d/path_dedup.sh /etc/profile.d/path_dedup.sh

nvm must be sourced **before** path_dedup in both init files. nvm prepends
its versioned bin dir to `$PATH`; path_dedup then restructures it into Tier 4,
keeping it behind T1 system bins and T2 `~/.local/bin` (the claude wrapper).
If path_dedup runs first, nvm prepends itself ahead of T1 and breaks the
ordering.

### ~/.bashrc (interactive non-login shells)

`/etc/profile.d/` is not sourced for non-login shells, so path_dedup must be
called explicitly here, after nvm:

    # #######
    # $PATH #
    # #######
    export NVM_DIR="${HOME}/.nvm"
    [ -s "${NVM_DIR}/nvm.sh" ] && source "${NVM_DIR}/nvm.sh"

    # shellcheck source=/etc/profile.d/path_dedup.sh
    [[ -f /etc/profile.d/path_dedup.sh ]] && source /etc/profile.d/path_dedup.sh

### ~/.bash_profile (login shells)

`/etc/profile.d/path_dedup.sh` is sourced automatically by `/etc/profile`
early in login shell startup — before nvm runs. A second call at the end of
`~/.bash_profile`, after nvm, corrects the order:

    export NVM_DIR="${HOME}/.nvm"
    [ -s "${NVM_DIR}/nvm.sh" ] && source "${NVM_DIR}/nvm.sh"

    # Re-order after nvm; /etc/profile sourced path_dedup earlier but nvm
    # had not run yet at that point.
    # shellcheck source=/etc/profile.d/path_dedup.sh
    [[ -f /etc/profile.d/path_dedup.sh ]] && source /etc/profile.d/path_dedup.sh

path_dedup.sh is idempotent — sourcing it a second time in the same shell
produces the same PATH, so the double call for login shells is safe.

## 2. Create the SANDBOX_USER OS account at /opt (root, once)

    sudo mkdir -p /opt/ai-tools
    sudo useradd \
        --system \
        --shell /sbin/nologin \
        --home-dir /opt/ai-tools \
        --no-create-home \
        --comment "AI tools sandbox user" \
        "${SANDBOX_USER}"
    sudo chown ${SANDBOX_USER}:${SANDBOX_GROUP} /opt/ai-tools
    sudo chmod 755 /opt/ai-tools       # ${PROJECTS_USER} needs +x to traverse into bin/

    # Lock password (system users have no password by default, but be explicit)
    sudo passwd -l "${SANDBOX_USER}"

## 3. Install nvm + Node v22 + claude as SANDBOX_USER (root, once)

    sudo -u "${SANDBOX_USER}" bash -c '
      export NVM_DIR=/opt/ai-tools/.nvm
      export HOME=/opt/ai-tools
      curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
      source /opt/ai-tools/.nvm/nvm.sh
      nvm install 22
      nvm alias default 22
      npm install -g @anthropic-ai/claude-code
    '

    # Create bin dir and initial claude symlink (src/home/user/.local/bin/nvm-update.sh maintains this going forward)
    sudo -u "${SANDBOX_USER}" bash -c '
      source /opt/ai-tools/.nvm/nvm.sh
      mkdir -p /opt/ai-tools/bin
      ln -sf "/opt/ai-tools/.nvm/versions/node/$(nvm version default)/bin/claude" \
             /opt/ai-tools/bin/claude
    '

## 4. Run the install script (root, once)

Steps 4–12 are fully automated by `install.sh`. After completing steps 1–3
above, run:

    sudo ./install.sh install

The script substitutes your username into sudoers and the chown validator,
creates the approved-projects allowlist with format documentation, installs the
`ai-tools` project CLI and the `/var/opt/ai-tools` sandbox area, and enables the
systemd timer. It is idempotent — safe to re-run after updates. The install
directory is never auto-registered as a project.

Register projects with the `ai-tools` CLI, run as your own user (no sudo):

    ai-tools --project-create /path/to/project    # a real project
    ai-tools --sandbox-create /path/to/repo       # an isolated shallow clone
    ai-tools --lockdown /path/to/project          # revoke agent access to secrets (sudo)

`ai-tools --lockdown` wraps the root `ai-tools-lockdown` helper (it prompts for
your sudo password) and `ai-tools --sandbox-create` offers to run it right after a
clone. A sandboxed project is a shallow clone under `/var/opt/ai-tools/sandbox-projects/`
that the agent works in without ever reading the original repo's full git
history. See `/var/opt/ai-tools/README.md` for that workflow.

To remove everything installed by this script:

    sudo ./install.sh uninstall

---

The steps below document what the install script does and serve as a reference
for manual installation or RPM spec authoring.

## 4a. Install ai-tools scripts (root, once)

    # /opt/ai-tools/bin is locked: owned by ${PROJECTS_USER} (NOT ${SANDBOX_USER}), mode 550, so
    # ${SANDBOX_USER} can execute but never write it -- the agent cannot tamper with the
    # updater or swap the claude symlink. The symlink is created/repointed only by
    # the root helper below.
    sudo install -o "${PROJECTS_USER}" -g "${SANDBOX_GROUP}" -m 550 \
        src/opt/ai-tools/bin/nvm-update.sh /opt/ai-tools/bin/nvm-update.sh
    sudo chown "${PROJECTS_USER}:${SANDBOX_GROUP}" /opt/ai-tools/bin
    sudo chmod 550 /opt/ai-tools/bin

    # All root sudo-helpers live under one dir (install does not create parents).
    sudo mkdir -p /usr/local/sbin/ai-tools
    sudo install -o root -g root -m 750 \
        src/usr/local/sbin/ai-tools/ai-tools-chown.sh /usr/local/sbin/ai-tools/ai-tools-chown

    # Root helper: at session start, sets group ${SANDBOX_GROUP} + setgid on the project's
    # dirs (allowlist-validated) so files you create inherit the shared group.
    sudo install -o root -g root -m 750 \
        src/usr/local/sbin/ai-tools/ai-tools-setgid.sh /usr/local/sbin/ai-tools/ai-tools-setgid

    # Root helper: the only writer of the locked bin. Repoints the stable claude
    # symlink at a validated versioned binary (used by the updater on upgrades).
    sudo install -o root -g root -m 750 \
        src/usr/local/sbin/ai-tools/ai-tools-claude-symlink.sh /usr/local/sbin/ai-tools/ai-tools-claude-symlink

## 5a. Install sudoers drop-in (root, once)

    # Substitute the tokens first (or use ./install.sh, which does this for you):
    #   @PROJECTS_USER@  -> your login username
    #   @SANDBOX_USER@/@SANDBOX_GROUP@ -> the sandbox account (default: ai-tools)
    sudo install -o root -g root -m 0440 \
        src/etc/sudoers.d/ai-tools-claude /etc/sudoers.d/ai-tools-claude

    # Verify syntax
    sudo visudo -c -f /etc/sudoers.d/ai-tools-claude

The drop-in configures, beyond the basic NOPASSWD rules:

- **`env_keep`** (scoped to `nvm-update.sh`) — passes `NVM_*` and
  `AI_TOOLS_GLOBAL_TOOLS` through sudo so the `${SANDBOX_USER}` invocation of
  `nvm-update.sh` sees the same values the systemd service resolved.
- **`umask=0007`** (scoped to `claude`) — Claude Code creates files with
  `660`/`770` instead of `600`/`700`, making both the projects user and
  `${SANDBOX_USER}` natural co-writers on project files across sessions. World bits
  are still stripped (`o=0`). A stricter `0027` would give group read-only after
  handback, blocking the Edit tool's in-place patching on previously handed-back
  files. Both Defaults use `Defaults!<command>` so they apply only to those
  commands, not to every command the projects user runs via sudo.
- **`ai-tools-chown` rule** — allows `${SANDBOX_USER}` to call
  `/usr/local/sbin/ai-tools/ai-tools-chown` as root. That script validates the target
  path against the approved-projects allowlist, and acts only on agent-written
  (`${SANDBOX_USER}`-owned) paths, before running `chown ${PROJECTS_USER}:${SANDBOX_GROUP}`.
- **`ai-tools-setgid` rule** — allows `${SANDBOX_USER}` to call
  `/usr/local/sbin/ai-tools/ai-tools-setgid` as root (from the `SessionStart` hook). It
  re-validates the path against the allowlist, then sets group `${SANDBOX_GROUP}`
  and the setgid bit on the project's directories so files you create inherit the
  shared group — letting you stay a non-member of `${SANDBOX_GROUP}` (defense in
  depth) while the agent can still read/write project files.
- **`ai-tools-claude-symlink` rule** — allows `${SANDBOX_USER}` to call
  `/usr/local/sbin/ai-tools/ai-tools-claude-symlink` as root to repoint the stable
  `/opt/ai-tools/bin/claude` symlink. The helper validates its argument is a real
  versioned-claude path (its own check, not the sudoers glob) before acting. This
  is the only way the updater can touch the locked `bin` dir.

Both `${PROJECTS_USER}` NOPASSWD rules *drop* privilege (run as the lower-privileged `${SANDBOX_USER}`);
the agent runs as `${SANDBOX_USER}` and cannot invoke a `${PROJECTS_USER}` rule, so neither grants it
anything new.

## 6a. Install wrapper and update script (normal user)

    install -d -m 700 ~/.local/bin

    install -m 750 src/home/user/.local/bin/claude.sh ~/.local/bin/claude
    install -m 750 src/home/user/.local/bin/nvm-update.sh ~/.local/bin/nvm-update.sh

    # PATH ordering is handled by path_dedup.sh (step 1).
    # No manual export PATH line needed here.

## 7a. Install global Claude Code settings (once)

After every `Write` or `Edit` tool call, `post-tool-hook.sh` checks whether
ownership needs restoring and, only if it does, calls `ai-tools-chown` via
sudo. When ownership is already `${PROJECTS_USER}:${SANDBOX_GROUP}` the hook exits immediately
without invoking sudo or generating a PAM session entry. The hook also walks the
written file's parent directories and hands back each one the agent created
(world bits stripped, group `rwx` kept), stopping at the first pre-existing
user-owned dir. Files and directories excluded via `!` entries in the allowlist
are never touched. `ai-tools-chown` acts only on agent-written (ai-tools-owned)
paths, so a pre-existing user file or directory — including a user's own
secret — is never modified or flagged.

`claude-settings.json` also configures git command permissions:

| Category | Commands | Behaviour |
|---|---|---|
| Auto-allowed | `git status`, `git diff` (working tree, `--staged`, `--cached`), `git branch` | no prompt |
| Confirmation required | `git log`, `git show`, `git mv`, `git add`, `git commit`, `git push` | prompts user |
| Denied | `git push --force`, `git reset --hard`, `git clean -f` | always blocked |

`git mv` is available once `safe.directory` is configured (step 8) and
preserves file history. It requires confirmation rather than running silently.

Requires `jq` for JSON parsing in the hook:

    sudo dnf install -y jq

Install into `${SANDBOX_USER}`'s Claude config directory. The directory holds both
mutable agent state (sessions, history — `${SANDBOX_USER}`-owned) and the
root-of-trust control files (the hook and its config). To stop the agent from
rewriting its own guardrails, the control files are owned by the **projects user**
(not `${SANDBOX_USER}`), and the directory itself is owned by the projects user with
**setgid + sticky** (`3770`): `${SANDBOX_USER}` stays a group-writer for its own
state but cannot unlink or replace files it does not own.

    sudo mkdir -p /opt/ai-tools/.claude
    sudo chown "${PROJECTS_USER}:${SANDBOX_GROUP}" /opt/ai-tools/.claude
    sudo chmod 3770 /opt/ai-tools/.claude         # setgid + sticky, group-writable
    sudo install -o "${PROJECTS_USER}" -g "${SANDBOX_GROUP}" -m 750 \
        src/opt/ai-tools/.claude/post-tool-hook.sh /opt/ai-tools/.claude/post-tool-hook.sh
    sudo install -o "${PROJECTS_USER}" -g "${SANDBOX_GROUP}" -m 640 \
        src/opt/ai-tools/.claude/settings.json /opt/ai-tools/.claude/settings.json

## 8a. Create the approved-projects allowlist (once)

The allowlist controls where Claude Code is permitted to run and where the
ownership-restoration hook is allowed to act. Owned `${PROJECTS_USER}:${PROJECTS_GROUP} 600` — `${SANDBOX_USER}`
cannot read or modify it; root reads it inside `ai-tools-chown` on `${SANDBOX_USER}`'s
behalf.

    mkdir -p ~/.config/ai-tools
    touch ~/.config/ai-tools/allowed-projects
    chmod 600 ~/.config/ai-tools/allowed-projects

**Allowlist format** — document inline as comments in the file itself:

    # Syntax:
    #   /path/to/project      allow: Claude Code may run here; chown is active
    #   !/path/to/file        exclude: this file's ownership is never changed
    #   !/path/to/dir         exclude directory and all contents
    #   !/path/to/*.ext       exclude by glob (* matches any characters)
    #
    # Exclusions (!) override allows and are checked first.
    # Plain paths cover their contents automatically; no trailing /* needed.

    # Example:
    /path/to/AllowedProject
    !/path/to/AllowedProject/secrets
    !/path/to/Disallowed

**Register with git** so `${SANDBOX_USER}` can run `git mv` and other git commands inside
the project (git refuses to operate on repos owned by a different user):

    sudo git config --file /opt/ai-tools/.gitconfig --add safe.directory /path/to/project

Repeat both the `allowed-projects` entry and the `safe.directory` command for
each additional project.

**Effect of the allowlist:**

| Scenario | Wrapper | Hook |
|---|---|---|
| Allowlist does not exist | blocked, helpful message | exits without acting |
| CWD in allowlist | allowed | ownership restored only if needed |
| CWD not in allowlist | blocked, helpful message | exits without acting |
| `!` exclusion matches | blocked when it is the CWD | skipped when it is the written file |

Both the wrapper and the chown hook honor `!` exclusions, and check them before
allows. The wrapper check fails fast at startup. The chown script is the
security boundary — it validates the target path independently, so even if the
wrapper is bypassed, the hook cannot act outside approved paths or on excluded
files.

### Protecting secrets from unlink/replace

`ai-tools-chown` chowns a secret-named file to `${PROJECTS_USER}:${PROJECTS_GROUP} 600`, removing `${SANDBOX_USER}`'s
**read** access. `${SANDBOX_USER}` is a group-writer on the project dir, not its owner,
so it can still **unlink or replace** the path: directory write permission, not
the file's mode, governs that. A replacement is itself agent-written and
re-triggers the same handling; the audit log is root-owned.

A project-wide sticky bit (`chmod +t`) does not apply: `${SANDBOX_USER}` is a
group-writer and handed-back files are owned by the projects user, so a sticky root would block
the agent's atomic-rename re-edits. To prevent unlink/replace of a secret, place
it in a directory the agent cannot write and `!`-exclude that directory:

    mkdir -p /path/to/project/secrets
    chmod 700 /path/to/project/secrets        # ${PROJECTS_USER}:${PROJECTS_GROUP}, no ${SANDBOX_USER} access

    # in ~/.config/ai-tools/allowed-projects:
    !/path/to/project/secrets

`700 ${PROJECTS_USER}:${PROJECTS_GROUP}` removes `${SANDBOX_USER}`'s search and write on the directory, so it cannot
read, create, unlink, or replace anything inside; the `!` entry keeps
`ai-tools-chown` off it if the mode later changes.

## 9a. Install systemd user units (normal user)

    install -d -m 700 ~/.config/systemd/user

    install -m 644 src/home/user/.config/systemd/user/nvm-update.service ~/.config/systemd/user/nvm-update.service
    install -m 644 src/home/user/.config/systemd/user/nvm-update.timer   ~/.config/systemd/user/nvm-update.timer

    systemctl --user daemon-reload
    systemctl --user enable --now nvm-update.timer

    # Confirm timer is scheduled
    systemctl --user list-timers nvm-update.timer

## 10a. Enable linger so timer fires without an active login session

    loginctl enable-linger "${PROJECTS_USER}"

## 11a. Customise tool lists

Two separate environment variables control what goes where. Both installs
are pinned to the same Node version resolved by `src/home/user/.local/bin/nvm-update.sh`.

    systemctl --user edit nvm-update.service

### Your dev tools (the projects user)

    [Service]
    Environment="NVM_GLOBAL_TOOLS=npm typescript yarn grunt your-extra-tool"

### SANDBOX_USER sandbox tools

    [Service]
    Environment="AI_TOOLS_GLOBAL_TOOLS=npm @anthropic-ai/claude-code other-ai-tool"

Any package can go in `AI_TOOLS_GLOBAL_TOOLS` — not just `@anthropic-ai/*`.
Add claude dependencies, additional AI SDKs, or any other tool that should
run sandboxed as `${SANDBOX_USER}` rather than as the projects user.

    systemctl --user daemon-reload

## 12a. Verify

    # Run update manually (updates both your tools and /opt/ai-tools)
    systemctl --user start nvm-update.service
    journalctl --user -u nvm-update.service -f

    # Confirm wrapper resolves and executes as ${SANDBOX_USER}
    which claude                     # -> ~/.local/bin/claude
    claude --version                 # executes as ${SANDBOX_USER} uid

    # Confirm process uid at runtime
    ps -eo pid,user,cmd | grep claude

    # Confirm the claude symlink is in place and points at the versioned binary
    ls -la /opt/ai-tools/bin/claude
    readlink /opt/ai-tools/bin/claude   # -> .../node/<ver>/bin/claude (one hop)

## Upgrade behaviour

When nvm installs a new Node version under `/opt/ai-tools`:
- The sudoers glob `/opt/ai-tools/.nvm/versions/node/*/bin/claude` matches
  the new versioned path automatically.
- `src/opt/ai-tools/bin/nvm-update.sh` repoints the `/opt/ai-tools/bin/claude` symlink
  at the new versioned binary via the root helper `ai-tools-claude-symlink`
  (`bin` is locked `550`, so the ${SANDBOX_USER} updater cannot write it directly; the
  helper validates the versioned path and is the only writer of that dir).
- The wrapper resolves that symlink **one hop** via `readlink` before calling
  `sudo`, yielding the versioned `.../node/<ver>/bin/claude` path the sudoers
  rule matches. It deliberately does *not* use `realpath`/`readlink -f`: the
  versioned `bin/claude` is itself an npm symlink into the package, and
  following it would produce a path sudoers cannot match (and one the invoking
  user cannot even traverse, since the package dir is mode 700).
- Old Node versions are pruned in both nvm installs (any version not
  referenced by a named alias is removed).
- `src/home/user/.local/bin/nvm-update.sh` resolves the latest version once, updates your `~/.nvm`,
  then invokes `src/opt/ai-tools/bin/nvm-update.sh` as ${SANDBOX_USER} via sudo with the pinned
  version so both installs land on the same Node build.

## SELinux

If AVC denials appear after install:

    ausearch -m avc -ts recent | audit2why

Common cause: directories or binaries under `/opt/ai-tools` carry a wrong
label after creation. Fix:

    sudo restorecon -Rv /opt/ai-tools

If `${SANDBOX_USER}`'s home needs a custom label:

    sudo semanage fcontext -a -t usr_t '/opt/ai-tools(/.*)?'
    sudo restorecon -Rv /opt/ai-tools

For the wrapper in `~/.local/bin`:

    restorecon -Rv ~/.local/bin
