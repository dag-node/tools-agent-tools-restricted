# AI on RHEL - Limited Tools-User for running ClaudeCode

Key design decisions worth noting:
Version resolution in `nvm-update.sh`

When multiple v22 versions exist, nvm ls-remote | sort -V | tail -1 always selects the highest semver — not "first match" or "currently active". Prune logic collects all versions referenced by any named alias into an associative array before removing anything, so you can't accidentally delete a version another alias points to.

Wrapper safety check
After realpath resolves the symlink, the wrapper validates the result is under $NVM_DIR before calling sudo. This blocks path-injection if something tampers with PATH or the nvm symlinks.
sudoers glob + realpath interaction

The glob `*/bin/claude` matches the real versioned path. Without realpath in the wrapper, sudo would receive the nvm symlink path (e.g. ~/.nvm/alias/default) which sudoers would reject. The two are coupled — don't change one without the other.

`loginctl enable-linger`
Without this, the user systemd instance exits on logout and the 10:05 timer never fires unless you're logged in. Required for headless/unattended operation.

**One thing to do manually after deploy:** add `export PATH="HOME/.local/bin:{HOME}/.local/bin:
HOME/.local/bin:{PATH}"` to `~/.bashrc` *before* the `nvm.sh` source line, or the wrapper is shadowed by the nvm shim.

### The sudoers rule is very specific

`ai-tools ALL=(dag) NOPASSWD: /home/dag/.nvm/versions/node/*/bin/claude`

- ai-tools can only run claude
- It cannot run sudo rm -rf / or sudo cat /etc/shadow
- It cannot run other binaries in /usr/bin

