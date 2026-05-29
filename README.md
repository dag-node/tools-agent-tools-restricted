# nvm-updater + ai-tools sandbox -- RHEL 9 setup

## Files

| File | Deploy path |
|---|---|
| path_dedup.sh | /etc/profile.d/path_dedup.sh (root) |
| nvm-update.sh | ~/.local/bin/nvm-update.sh  and  /opt/ai-tools/bin/nvm-update.sh |
| nvm-update.service | ~/.config/systemd/user/nvm-update.service |
| nvm-update.timer | ~/.config/systemd/user/nvm-update.timer |
| claude-wrapper.sh | ~/.local/bin/claude |
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
        path_dedup.sh /etc/profile.d/path_dedup.sh

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

    # Create bin dir and initial claude symlink (nvm-update.sh maintains this going forward)
    sudo -u ai-tools bash -c '
      source /opt/ai-tools/.nvm/nvm.sh
      mkdir -p /opt/ai-tools/bin
      ln -sf "/opt/ai-tools/.nvm/versions/node/$(nvm version default)/bin/claude" \
             /opt/ai-tools/bin/claude
    '

## 4. Install the ai-tools copy of nvm-update.sh (root, once)

The same script handles both contexts: it detects whether it is running as
xd or as ai-tools and behaves accordingly.

    sudo install -o ai-tools -g ai-tools -m 750 \
        nvm-update.sh /opt/ai-tools/bin/nvm-update.sh

## 5. Install sudoers drop-in (root, once)

    # Replace 'xd' with your username in the file first if different
    sudo install -o root -g root -m 0440 \
        sudoers-ai-tools-claude /etc/sudoers.d/ai-tools-claude

    # Verify syntax
    sudo visudo -c -f /etc/sudoers.d/ai-tools-claude

## 6. Install wrapper and update script (normal user)

    install -d -m 700 ~/.local/bin

    install -m 750 claude-wrapper.sh ~/.local/bin/claude
    install -m 750 nvm-update.sh     ~/.local/bin/nvm-update.sh

    # PATH ordering is handled by path_dedup.sh (step 1).
    # No manual export PATH line needed here.

## 7. Install systemd user units (normal user)

    install -d -m 700 ~/.config/systemd/user

    install -m 644 nvm-update.service ~/.config/systemd/user/nvm-update.service
    install -m 644 nvm-update.timer   ~/.config/systemd/user/nvm-update.timer

    systemctl --user daemon-reload
    systemctl --user enable --now nvm-update.timer

    # Confirm timer is scheduled
    systemctl --user list-timers nvm-update.timer

## 8. Enable linger so timer fires without an active login session

    loginctl enable-linger "${USER}"

## 9. Customise tool lists

All packages live in a single `NVM_GLOBAL_TOOLS` list in `nvm-update.service`.
The script routes them automatically: packages matching `@anthropic-ai/*` go
to the ai-tools sandbox in `/opt/ai-tools/.nvm`; everything else goes to
xd's `~/.nvm`. Both installs are pinned to the same resolved Node version.

    systemctl --user edit nvm-update.service

Add an override:

    [Service]
    Environment="NVM_GLOBAL_TOOLS=npm typescript yarn grunt @anthropic-ai/claude-code your-extra-tool"

    systemctl --user daemon-reload

To add a sandboxed tool, use an `@anthropic-ai/` package name or extend the
`is_sandbox_package()` function in `nvm-update.sh` with additional routing
rules.

## 10. Verify

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
- `nvm-update-ai-tools.sh` updates the `/opt/ai-tools/bin/claude` symlink to
  point at the new versioned binary.
- The wrapper resolves that symlink via `realpath` before calling `sudo`, so
  sudoers matching is not affected by the symlink indirection.
- Old Node versions are pruned in both nvm installs (any version not
  referenced by a named alias is removed).
- `nvm-update.sh` resolves the latest version once, updates xd's `~/.nvm`,
  then re-invokes itself as ai-tools via `sudo -u ai-tools /opt/ai-tools/bin/nvm-update.sh "${version}"`
  so both installs land on the same Node build.

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
