# AI on RHEL - Limited Tools-User for running ClaudeCode

Key design decisions worth noting:
Version resolution in `nvm-update.sh`

When multiple v22 versions exist, nvm ls-remote | sort -V | tail -1 always selects the highest semver — not "first match" or "currently active". Prune logic collects all versions referenced by any named alias into an associative array before removing anything, so you can't accidentally delete a version another alias points to.

Wrapper safety check
The wrapper resolves `/opt/ai-tools/bin/claude` with a single `readlink` hop, then validates the target is an absolute, `..`-free path matching `${AI_TOOLS_NVM_DIR}/versions/node/*/bin/claude` before calling sudo. This blocks path-injection if the symlink is tampered with, using string checks only (no filesystem traversal beyond the symlink).

sudoers glob + symlink resolution — IMPORTANT
The glob `*/bin/claude` matches the versioned path `/opt/ai-tools/.nvm/versions/node/<ver>/bin/claude`. The wrapper must resolve the stable symlink **exactly one hop** (`readlink`, not `realpath`/`readlink -f`). The versioned `bin/claude` is itself an npm symlink into the package (`-> .../@anthropic-ai/claude-code/bin/claude.exe`); fully resolving it would (a) produce a path the sudoers rule cannot match — so sudo denies/prompts and claude never launches — and (b) require traversing the package dir (mode 700, ai-tools), which the invoking user cannot enter (EACCES). The one-hop readlink and the sudoers glob are coupled — don't change one without the other.

`loginctl enable-linger`
Without this, the user systemd instance exits on logout and the 10:05 timer never fires unless you're logged in. Required for headless/unattended operation.

**One thing to do manually after deploy:** add `export PATH="HOME/.local/bin:{HOME}/.local/bin:
HOME/.local/bin:{PATH}"` to `~/.bashrc` *before* the `nvm.sh` source line, or the wrapper is shadowed by the nvm shim.

### The sudoers rule is very specific

`ai-tools ALL=(dag) NOPASSWD: /home/dag/.nvm/versions/node/*/bin/claude`

- ai-tools can only run claude
- It cannot run sudo rm -rf / or sudo cat /etc/shadow
- It cannot run other binaries in /usr/bin

