# nvm-updater + ai-tools sandbox -- RHEL 9 setup

## Files

| File | Deploy path |
|---|---|
| scripts/path_dedup.sh | /etc/profile.d/path_dedup.sh (root) |
| scripts/nvm-update.sh | ~/.local/bin/nvm-update.sh |
| scripts/nvm-update-ai-tools.sh | /opt/ai-tools/bin/nvm-update.sh |
| scripts/ai-tools-chown.sh | /usr/local/sbin/ai-tools-chown (root) |
| scripts/claude-wrapper.sh | ~/.local/bin/claude |
| scripts/post-write-hook.sh | /opt/ai-tools/.claude/post-write-hook.sh |
| scripts/claude-settings.json | /opt/ai-tools/.claude/settings.json |
| services/nvm-update.service | ~/.config/systemd/user/nvm-update.service |
| services/nvm-update.timer | ~/.config/systemd/user/nvm-update.timer |
| sudoers-ai-tools-claude | /etc/sudoers.d/ai-tools-claude (root) |

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

## 4. Install ai-tools scripts (root, once)

    sudo install -o ai-tools -g ai-tools -m 750 \
        scripts/nvm-update-ai-tools.sh /opt/ai-tools/bin/nvm-update.sh

    sudo install -o root -g root -m 755 \
        scripts/ai-tools-chown.sh /usr/local/sbin/ai-tools-chown

## 5. Install sudoers drop-in (root, once)

    # Replace 'xd' with your username in the file first if different
    sudo install -o root -g root -m 0440 \
        sudoers-ai-tools-claude /etc/sudoers.d/ai-tools-claude

    # Verify syntax
    sudo visudo -c -f /etc/sudoers.d/ai-tools-claude

The drop-in configures three things beyond the basic NOPASSWD rules:

- **`env_keep`** — passes `NVM_*` and `AI_TOOLS_GLOBAL_TOOLS` through sudo so
  the ai-tools invocation of `nvm-update.sh` sees the same values the systemd
  service resolved.
- **`umask=0027`** — applied to all commands xd runs via sudo. Claude Code
  creates files with `640`/`750` instead of `600`/`700`, keeping them
  group-readable (ai-tools) without exposing them to others.
- **`ai-tools-chown` rule** — allows ai-tools to call
  `/usr/local/sbin/ai-tools-chown` as root. That script validates the target
  path against the approved-projects allowlist before running `chown
  xd:ai-tools`, so ai-tools can only restore ownership inside explicitly
  approved project directories.

## 6. Install wrapper and update script (normal user)

    install -d -m 700 ~/.local/bin

    install -m 750 scripts/claude-wrapper.sh ~/.local/bin/claude
    install -m 750 scripts/nvm-update.sh     ~/.local/bin/nvm-update.sh

    # PATH ordering is handled by path_dedup.sh (step 1).
    # No manual export PATH line needed here.

## 7. Install global Claude Code settings (once)

After every `Write` or `Edit` tool call, `post-write-hook.sh` checks whether
ownership needs restoring and, only if it does, calls `ai-tools-chown` via
sudo. When ownership is already `xd:ai-tools` the hook exits immediately
without invoking sudo or generating a PAM session entry.

Requires `jq` for JSON parsing in the hook:

    sudo dnf install -y jq

Install into ai-tools' Claude config directory:

    sudo -u ai-tools mkdir -p /opt/ai-tools/.claude
    sudo install -o ai-tools -g ai-tools -m 750 \
        scripts/post-write-hook.sh /opt/ai-tools/.claude/post-write-hook.sh
    sudo install -o ai-tools -g ai-tools -m 640 \
        scripts/claude-settings.json /opt/ai-tools/.claude/settings.json

## 8. Create the approved-projects allowlist (once)

The allowlist controls where Claude Code is permitted to run and where the
ownership-restoration hook is allowed to act. Files in `allowed-projects` own
`xd:xd 600` so ai-tools cannot read or modify it directly — root reads it
inside `ai-tools-chown` on ai-tools' behalf.

    mkdir -p ~/.config/ai-tools
    touch ~/.config/ai-tools/allowed-projects
    chmod 600 ~/.config/ai-tools/allowed-projects

Add one absolute project path per line:

    echo "/home/xd/Development/NDF26/RHEL-AI-LimitedToolsUser-ClaudeCode" \
        >> ~/.config/ai-tools/allowed-projects

Format rules:
- One absolute directory path per line.
- Lines starting with `#` are treated as comments and ignored.
- Subdirectories are covered automatically: listing `/home/xd/projects/foo`
  also covers `/home/xd/projects/foo/src`, etc.

**Effect of the allowlist:**

| Scenario | Wrapper | Hook |
|---|---|---|
| Allowlist does not exist | blocked, helpful message | exits without acting |
| CWD in allowlist | allowed | ownership restored only if needed |
| CWD not in allowlist | blocked, helpful message | exits without acting |

The wrapper check fails fast at startup with a clear message directing the user
to the allowlist. The chown script is the actual security boundary — it
validates the target path independently so that even if the wrapper is bypassed,
the hook cannot act outside approved directories.

## 9. Install systemd user units (normal user)

    install -d -m 700 ~/.config/systemd/user

    install -m 644 services/nvm-update.service ~/.config/systemd/user/nvm-update.service
    install -m 644 services/nvm-update.timer   ~/.config/systemd/user/nvm-update.timer

    systemctl --user daemon-reload
    systemctl --user enable --now nvm-update.timer

    # Confirm timer is scheduled
    systemctl --user list-timers nvm-update.timer

## 10. Enable linger so timer fires without an active login session

    loginctl enable-linger "${USER}"

## 11. Customise tool lists

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

## 12. Verify

    # Run update manually (updates both xd's tools and /opt/ai-tools)
    systemctl --user start nvm-update.service
    journalctl --user -u nvm-update.service -f

    # Confirm wrapper resolves and executes as ai-tools
    which claude                     # -> ~/.local/bin/claude
    claude --version                 # executes as ai-tools uid

    # Confirm process uid at runtime
    ps -eo pid,user,cmd | grep claude

    # Confirm the claude symlink is in place
    ls -la /opt/ai-tools/bin/claude
    realpath /opt/ai-tools/bin/claude

## Upgrade behaviour

When nvm installs a new Node version under `/opt/ai-tools`:
- The sudoers glob `/opt/ai-tools/.nvm/versions/node/*/bin/claude` matches
  the new versioned path automatically.
- `scripts/nvm-update-ai-tools.sh` updates the `/opt/ai-tools/bin/claude` symlink to
  point at the new versioned binary.
- The wrapper resolves that symlink via `realpath` before calling `sudo`, so
  sudoers matching is not affected by the symlink indirection.
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
