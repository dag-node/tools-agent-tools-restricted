# nvm-updater + ai-tools sandbox -- RHEL 9 setup

## Files

| File | Deploy path |
|---|---|
| nvm-update.sh | ~/.local/bin/nvm-update.sh |
| nvm-update.service | ~/.config/systemd/user/nvm-update.service |
| nvm-update.timer | ~/.config/systemd/user/nvm-update.timer |
| claude-wrapper.sh | ~/.local/bin/claude |
| sudoers-ai-tools-claude | /etc/sudoers.d/ai-tools-claude (root) |

---

## 1. Create ai-tools OS user (root, once)

    sudo useradd \
        --system \
        --shell /sbin/nologin \
        --home-dir /var/lib/ai-tools \
        --create-home \
        --comment "AI tools sandbox user" \
        ai-tools

    # Lock password (system users have no password by default, but be explicit)
    sudo passwd -l ai-tools

    # Create project secrets dir owned by normal user, no access for ai-tools
    # (do this per-project; example only)
    # chmod 700 ~/project/.secrets
    # chmod 700 ~/project/.env

## 2. Install sudoers drop-in (root, once)

    # Replace 'dag' with your username in the file first
    sudo install -o root -g root -m 0440 \
        sudoers-ai-tools-claude /etc/sudoers.d/ai-tools-claude

    # Verify syntax
    sudo visudo -c -f /etc/sudoers.d/ai-tools-claude

## 3. Install wrapper and update script (normal user)

    install -d -m 700 ~/.local/bin

    install -m 750 claude-wrapper.sh ~/.local/bin/claude
    install -m 750 nvm-update.sh     ~/.local/bin/nvm-update.sh

    # Ensure ~/.local/bin is first in PATH (before nvm shims)
    # Add to ~/.bashrc BEFORE the nvm init block:
    #
    #   export PATH="${HOME}/.local/bin:${PATH}"

## 4. Install systemd user units (normal user)

    install -d -m 700 ~/.config/systemd/user

    install -m 644 nvm-update.service ~/.config/systemd/user/nvm-update.service
    install -m 644 nvm-update.timer   ~/.config/systemd/user/nvm-update.timer

    systemctl --user daemon-reload
    systemctl --user enable --now nvm-update.timer

    # Confirm timer is scheduled
    systemctl --user list-timers nvm-update.timer

## 5. Enable linger so timer fires without an active login session

    loginctl enable-linger "${USER}"

## 6. Customise tool list

Edit the Environment= line in nvm-update.service:

    systemctl --user edit nvm-update.service

Add an override:

    [Service]
    Environment=NVM_GLOBAL_TOOLS=npm typescript yarn grunt @anthropic-ai/claude-code your-extra-tool

    systemctl --user daemon-reload

## 7. Verify

    # Run update manually
    systemctl --user start nvm-update.service
    journalctl --user -u nvm-update.service -f

    # Confirm wrapper resolves and executes as ai-tools
    which claude                     # -> ~/.local/bin/claude
    claude --version                 # executes as ai-tools uid

    # Confirm process uid at runtime
    ps -eo pid,user,cmd | grep claude

## PATH order requirement

~/.bashrc must set PATH before nvm initialisation:

    # --- PATH: local wrappers first ---
    export PATH="${HOME}/.local/bin:${PATH}"

    # --- nvm init (after PATH) ---
    export NVM_DIR="${HOME}/.nvm"
    [ -s "${NVM_DIR}/nvm.sh" ] && source "${NVM_DIR}/nvm.sh"

## Upgrade behaviour

When nvm installs a new Node version:
- The sudoers glob  /home/dag/.nvm/versions/node/*/bin/claude  matches
  the new versioned path automatically.
- The wrapper uses realpath to resolve the nvm symlink to the versioned
  path before calling sudo, so sudoers matching is not affected by symlinks.
- Old versions are pruned by nvm-update.sh (any version not referenced by
  a named alias is removed).

## SELinux

If AVC denials appear after install:

    ausearch -m avc -ts recent | audit2why

Common cause: the wrapper or nvm directories carry wrong labels after
creation. Fix:

    restorecon -Rv ~/.local/bin ~/.nvm

If the ai-tools user's home needs a custom label:

    semanage fcontext -a -t user_home_dir_t '/var/lib/ai-tools(/.*)?'
    restorecon -Rv /var/lib/ai-tools
