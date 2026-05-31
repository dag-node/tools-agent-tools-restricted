# Claude Code on RHEL 9 — sandboxed `ai-tools` user + nvm auto-updater

Run Anthropic's **Claude Code as a dedicated, unprivileged system user
(`ai-tools`)** on RHEL 9 instead of as your own login account, and keep Node.js
and the `claude` CLI current automatically.

## Why

Claude Code is an autonomous agent that reads, writes, and runs commands. Run as
your own user it inherits everything you can touch — SSH keys, browser profiles,
every project, your full sudo rights. This project gives the agent its own UID
with a tightly scoped set of privileges instead:

- **Separate identity** — `ai-tools` is a system account with no login shell and
  no password. Claude executes under that UID via `sudo`, not as you.
- **Launches only in approved projects** — a wrapper refuses to start Claude
  unless the working directory is listed in `~/.config/ai-tools/allowed-projects`
  (with `!` exclusions to carve out subdirectories or secrets).
- **Minimal sudo surface** — `ai-tools` may run exactly one root command
  (`ai-tools-chown`, which validates against the allowlist). You may run only
  `claude` (and the pinned updater) as `ai-tools`. Nothing else.
- **Ownership hand-back** — files Claude writes are chowned back to
  `you:ai-tools` (group-readable, world-closed) inside approved paths only, along
  with any directories Claude created on the way (world bits stripped, group
  `rwx` kept; only dirs the agent itself made are touched). Secret-named files
  (`.env`, `*.key`, `*.pem`, SSH keys, `kubeconfig`, …) are chowned to
  `you:you 600` instead, removing ai-tools' read access; a `NOTICE` is written to
  the session and an audit log.
- **Auto-updating** — a systemd user timer keeps Node v22 and
  `@anthropic-ai/claude-code` current for both you and the sandbox user, pinned
  to the same build.

> **On the boundary.** The allowlist gates where Claude *launches* and which
> files get ownership restored — it is not a kernel-enforced read boundary. Once
> running as `ai-tools`, ordinary Unix permissions govern access; that is what
> actually isolates the agent from other users' files. A per-session
> `bubblewrap` mount namespace to make the allowlist a true access boundary is
> proposed but not yet implemented.

## Architecture at a glance

```
you type `claude`
  └─ ~/.local/bin/claude                      (wrapper, runs as you)
       ├─ CWD ∈ allowed-projects?             refuse if not, or if !-excluded
       ├─ resolve /opt/ai-tools/bin/claude    (one readlink hop)
       └─ exec sudo -u ai-tools -- <versioned claude>
            └─ claude runs as ai-tools
                 └─ on Write/Edit → PostToolUse hook
                      └─ sudo ai-tools-chown <file>   (root; allowlist-checked)
                           └─ chown you:ai-tools, strip world bits
```

## Files

| File | Deploy path |
|---|---|
| scripts/path_dedup.sh | /etc/profile.d/path_dedup.sh (root) |
| scripts/nvm-update.sh | ~/.local/bin/nvm-update.sh |
| scripts/nvm-update-ai-tools.sh | /opt/ai-tools/bin/nvm-update.sh |
| scripts/ai-tools-chown.sh | /usr/local/sbin/ai-tools-chown (root) |
| scripts/ai-tools-claude-symlink.sh | /usr/local/sbin/ai-tools-claude-symlink (root) |
| scripts/claude-wrapper.sh | ~/.local/bin/claude |
| scripts/post-tool-hook.sh | /opt/ai-tools/.claude/post-tool-hook.sh |
| scripts/claude-settings.json | /opt/ai-tools/.claude/settings.json |
| services/nvm-update.service | ~/.config/systemd/user/nvm-update.service |
| services/nvm-update.timer | ~/.config/systemd/user/nvm-update.timer |
| sudoers-ai-tools-claude | /etc/sudoers.d/ai-tools-claude (root) |
| install.sh | run in place via sudo |

---

## Why /opt/ai-tools, not /home/xd

`/home` is mounted `nosuid`. The kernel refuses to honour the setuid bit when
a process doing a UID-switch executes a binary on a `nosuid` filesystem.
`sudo` can switch UIDs, but the target binary (`claude`) still runs as the
_invoking_ user because the exec happens on `nosuid` storage.

Installing nvm and claude under `/opt/ai-tools` (which has no `nosuid`
restriction) fixes this: the UID switch via `sudo` works, and the binary is
owned by `ai-tools` so the kernel is satisfied.

---

## 1. Install PATH deduplication script (root, once)

    sudo install -o root -g root -m 644 \
        scripts/path_dedup.sh /etc/profile.d/path_dedup.sh

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

## 2. Create ai-tools OS user at /opt (root, once)

    sudo mkdir -p /opt/ai-tools
    sudo useradd \
        --system \
        --shell /sbin/nologin \
        --home-dir /opt/ai-tools \
        --no-create-home \
        --comment "AI tools sandbox user" \
        ai-tools
    sudo chown ai-tools:ai-tools /opt/ai-tools
    sudo chmod 755 /opt/ai-tools       # xd needs +x to traverse into bin/

    # Lock password (system users have no password by default, but be explicit)
    sudo passwd -l ai-tools

## 3. Install nvm + Node v22 + claude as ai-tools (root, once)

    sudo -u ai-tools bash -c '
      export NVM_DIR=/opt/ai-tools/.nvm
      export HOME=/opt/ai-tools
      curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
      source /opt/ai-tools/.nvm/nvm.sh
      nvm install 22
      nvm alias default 22
      npm install -g @anthropic-ai/claude-code
    '

    # Create bin dir and initial claude symlink (scripts/nvm-update.sh maintains this going forward)
    sudo -u ai-tools bash -c '
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
creates the approved-projects allowlist with format documentation, registers
this project directory in the allowlist and git `safe.directory`, and enables
the systemd timer. It is idempotent — safe to re-run after updates.

To add further projects to the approved list:

    sudo ./install.sh add-project /path/to/project

To remove everything installed by this script:

    sudo ./install.sh uninstall

---

The steps below document what the install script does and serve as a reference
for manual installation or RPM spec authoring.

## 4a. Install ai-tools scripts (root, once)

    # /opt/ai-tools/bin is locked: owned by you (NOT ai-tools), mode 550, so
    # ai-tools can execute but never write it -- the agent cannot tamper with the
    # updater or swap the claude symlink. The symlink is created/repointed only by
    # the root helper below.
    sudo install -o "${USER}" -g ai-tools -m 550 \
        scripts/nvm-update-ai-tools.sh /opt/ai-tools/bin/nvm-update.sh
    sudo chown "${USER}:ai-tools" /opt/ai-tools/bin
    sudo chmod 550 /opt/ai-tools/bin

    sudo install -o root -g root -m 750 \
        scripts/ai-tools-chown.sh /usr/local/sbin/ai-tools-chown

    # Root helper: the only writer of the locked bin. Repoints the stable claude
    # symlink at a validated versioned binary (used by the updater on upgrades).
    sudo install -o root -g root -m 750 \
        scripts/ai-tools-claude-symlink.sh /usr/local/sbin/ai-tools-claude-symlink

## 5a. Install sudoers drop-in (root, once)

    # Replace 'xd' with your username in the file first if different
    sudo install -o root -g root -m 0440 \
        sudoers-ai-tools-claude /etc/sudoers.d/ai-tools-claude

    # Verify syntax
    sudo visudo -c -f /etc/sudoers.d/ai-tools-claude

The drop-in configures, beyond the basic NOPASSWD rules:

- **`env_keep`** (scoped to `nvm-update.sh`) — passes `NVM_*` and
  `AI_TOOLS_GLOBAL_TOOLS` through sudo so the ai-tools invocation of
  `nvm-update.sh` sees the same values the systemd service resolved.
- **`umask=0027`** (scoped to `claude`) — Claude Code creates files with
  `640`/`750` instead of `600`/`700`, keeping them group-readable (ai-tools)
  without exposing them to others. Both Defaults use `Defaults!<command>` so they
  apply only to those commands, not to every command xd runs via sudo.
- **`ai-tools-chown` rule** — allows ai-tools to call
  `/usr/local/sbin/ai-tools-chown` as root. That script validates the target
  path against the approved-projects allowlist, and acts only on agent-written
  (ai-tools-owned) paths, before running `chown xd:ai-tools`.
- **`ai-tools-claude-symlink` rule** — allows ai-tools to call
  `/usr/local/sbin/ai-tools-claude-symlink` as root to repoint the stable
  `/opt/ai-tools/bin/claude` symlink. The helper validates its argument is a real
  versioned-claude path (its own check, not the sudoers glob) before acting. This
  is the only way the updater can touch the locked `bin` dir.

Both `xd` NOPASSWD rules *drop* privilege (run as the lower-privileged ai-tools);
the agent runs as ai-tools and cannot invoke an xd rule, so neither grants it
anything new.

## 6a. Install wrapper and update script (normal user)

    install -d -m 700 ~/.local/bin

    install -m 750 scripts/claude-wrapper.sh ~/.local/bin/claude
    install -m 750 scripts/nvm-update.sh     ~/.local/bin/nvm-update.sh

    # PATH ordering is handled by path_dedup.sh (step 1).
    # No manual export PATH line needed here.

## 7a. Install global Claude Code settings (once)

After every `Write` or `Edit` tool call, `post-tool-hook.sh` checks whether
ownership needs restoring and, only if it does, calls `ai-tools-chown` via
sudo. When ownership is already `xd:ai-tools` the hook exits immediately
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

Install into ai-tools' Claude config directory. The directory holds both mutable
agent state (sessions, history — ai-tools-owned) and the root-of-trust control
files (the hook and its config). To stop the agent from rewriting its own
guardrails, the control files are owned by **you** (not ai-tools), and the
directory itself is owned by you with **setgid + sticky** (`3770`): ai-tools stays
a group-writer for its own state but cannot unlink or replace files it does not
own.

    sudo mkdir -p /opt/ai-tools/.claude
    sudo chown "${USER}:ai-tools" /opt/ai-tools/.claude
    sudo chmod 3770 /opt/ai-tools/.claude         # setgid + sticky, group-writable
    sudo install -o "${USER}" -g ai-tools -m 750 \
        scripts/post-tool-hook.sh /opt/ai-tools/.claude/post-tool-hook.sh
    sudo install -o "${USER}" -g ai-tools -m 640 \
        scripts/claude-settings.json /opt/ai-tools/.claude/settings.json

## 8a. Create the approved-projects allowlist (once)

The allowlist controls where Claude Code is permitted to run and where the
ownership-restoration hook is allowed to act. Owned `xd:xd 600` — ai-tools
cannot read or modify it; root reads it inside `ai-tools-chown` on ai-tools'
behalf.

    mkdir -p ~/.config/ai-tools
    touch ~/.config/ai-tools/allowed-projects
    chmod 600 ~/.config/ai-tools/allowed-projects

**Allowlist format** — document inline as comments in the file itself:

    # /home/xd/Development/NDF26/RHEL-AI-LimitedToolsUser-ClaudeCode
    #
    # Syntax:
    #   /path/to/project      allow: Claude Code may run here; chown is active
    #   !/path/to/file        exclude: this file's ownership is never changed
    #   !/path/to/dir         exclude directory and all contents
    #   !/path/to/*.ext       exclude by glob (* matches any characters)
    #
    # Exclusions (!) override allows and are checked first.
    # Plain paths cover their contents automatically; no trailing /* needed.

**Register with git** so ai-tools can run `git mv` and other git commands inside
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

`ai-tools-chown` chowns a secret-named file to `you:you 600`, removing ai-tools'
**read** access. ai-tools is a group-writer on the project dir, not its owner,
so it can still **unlink or replace** the path: directory write permission, not
the file's mode, governs that. A replacement is itself agent-written and
re-triggers the same handling; the audit log is root-owned.

A project-wide sticky bit (`chmod +t`) does not apply: ai-tools is a
group-writer and handed-back files are `you`-owned, so a sticky root would block
the agent's atomic-rename re-edits. To prevent unlink/replace of a secret, place
it in a directory the agent cannot write and `!`-exclude that directory:

    mkdir -p /path/to/project/secrets
    chmod 700 /path/to/project/secrets        # you:you, no ai-tools access

    # in ~/.config/ai-tools/allowed-projects:
    !/path/to/project/secrets

`700 you:you` removes ai-tools' search and write on the directory, so it cannot
read, create, unlink, or replace anything inside; the `!` entry keeps
`ai-tools-chown` off it if the mode later changes.

## 9a. Install systemd user units (normal user)

    install -d -m 700 ~/.config/systemd/user

    install -m 644 services/nvm-update.service ~/.config/systemd/user/nvm-update.service
    install -m 644 services/nvm-update.timer   ~/.config/systemd/user/nvm-update.timer

    systemctl --user daemon-reload
    systemctl --user enable --now nvm-update.timer

    # Confirm timer is scheduled
    systemctl --user list-timers nvm-update.timer

## 10a. Enable linger so timer fires without an active login session

    loginctl enable-linger "${USER}"

## 11a. Customise tool lists

Two separate environment variables control what goes where. Both installs
are pinned to the same Node version resolved by `scripts/nvm-update.sh`.

    systemctl --user edit nvm-update.service

### xd's dev tools

    [Service]
    Environment="NVM_GLOBAL_TOOLS=npm typescript yarn grunt your-extra-tool"

### ai-tools sandbox tools

    [Service]
    Environment="AI_TOOLS_GLOBAL_TOOLS=npm @anthropic-ai/claude-code other-ai-tool"

Any package can go in `AI_TOOLS_GLOBAL_TOOLS` — not just `@anthropic-ai/*`.
Add claude dependencies, additional AI SDKs, or any other tool that should
run sandboxed as ai-tools rather than as xd.

    systemctl --user daemon-reload

## 12a. Verify

    # Run update manually (updates both xd's tools and /opt/ai-tools)
    systemctl --user start nvm-update.service
    journalctl --user -u nvm-update.service -f

    # Confirm wrapper resolves and executes as ai-tools
    which claude                     # -> ~/.local/bin/claude
    claude --version                 # executes as ai-tools uid

    # Confirm process uid at runtime
    ps -eo pid,user,cmd | grep claude

    # Confirm the claude symlink is in place and points at the versioned binary
    ls -la /opt/ai-tools/bin/claude
    readlink /opt/ai-tools/bin/claude   # -> .../node/<ver>/bin/claude (one hop)

## Upgrade behaviour

When nvm installs a new Node version under `/opt/ai-tools`:
- The sudoers glob `/opt/ai-tools/.nvm/versions/node/*/bin/claude` matches
  the new versioned path automatically.
- `scripts/nvm-update-ai-tools.sh` repoints the `/opt/ai-tools/bin/claude` symlink
  at the new versioned binary via the root helper `ai-tools-claude-symlink`
  (`bin` is locked `550`, so the ai-tools updater cannot write it directly; the
  helper validates the versioned path and is the only writer of that dir).
- The wrapper resolves that symlink **one hop** via `readlink` before calling
  `sudo`, yielding the versioned `.../node/<ver>/bin/claude` path the sudoers
  rule matches. It deliberately does *not* use `realpath`/`readlink -f`: the
  versioned `bin/claude` is itself an npm symlink into the package, and
  following it would produce a path sudoers cannot match (and one the invoking
  user cannot even traverse, since the package dir is mode 700).
- Old Node versions are pruned in both nvm installs (any version not
  referenced by a named alias is removed).
- `scripts/nvm-update.sh` resolves the latest version once, updates xd's `~/.nvm`,
  then invokes `scripts/nvm-update-ai-tools.sh` as ai-tools via sudo with the pinned
  version so both installs land on the same Node build.

## SELinux

If AVC denials appear after install:

    ausearch -m avc -ts recent | audit2why

Common cause: directories or binaries under `/opt/ai-tools` carry a wrong
label after creation. Fix:

    sudo restorecon -Rv /opt/ai-tools

If the ai-tools home needs a custom label:

    sudo semanage fcontext -a -t usr_t '/opt/ai-tools(/.*)?'
    sudo restorecon -Rv /opt/ai-tools

For the wrapper in `~/.local/bin`:

    restorecon -Rv ~/.local/bin
