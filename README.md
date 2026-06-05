# Claude CR

Claude Code Restricted, run sessions as sandboxed user.

Run Anthropic's **Claude Code as a dedicated, unprivileged system user
(`SANDBOX_USER`, the account created as `ai-tools`)** instead of as your
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
  allowlist- or argument-validated). You may run only `claude-run` (and the pinned
  updater) as `${SANDBOX_USER}` — `claude-run` is a fixed-path sudo target, not a
  glob, and it wraps the session in a systemd `--user --pty` service before exec'ing
  the versioned binary. Nothing else.
- **Ownership hand-back** — files Claude writes are chowned back to
  `${PROJECTS_USER}:${SANDBOX_GROUP}` (group-readable, world-closed) inside approved paths only, along
  with any directories Claude created on the way (world bits stripped, group
  `rwx` kept; only dirs the agent itself made are touched). Secret-named files
  (`.env`, `*.key`, `*.pem`, SSH keys, `kubeconfig`, …) are chowned to
  `${PROJECTS_USER}:${PROJECTS_GROUP} 600` instead, removing `${SANDBOX_USER}`'s read access; a `NOTICE` is written to
  the session and the operation log (root-only `/var/log/ai-tools/chown.log` plus
  journald — see *Operation logging* below).
- **Operation logging** — the `sudo` helpers, the lifecycle hooks, the `ai-tools`
  CLI, and `install.sh` log through one library to **journald** (always, leveled and
  tagged: `journalctl -t ai-tools-chown`) and, for the root writers only, to
  root-only files under **`/var/log/ai-tools/`**.
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
       ├─ resolve /opt/ai-tools/bin/claude    (one readlink hop; export as CLAUDE_EXEC)
       └─ exec sudo -u "${SANDBOX_USER}" -- /opt/ai-tools/bin/claude-run
            └─ systemd transient service      (--pty; RestrictNamespaces=yes, PrivateTmp, UMask=0007)
                 └─ claude runs as ${SANDBOX_USER} in ai_tools_t (SELinux)
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
| src/opt/ai-tools/bin/claude-run.sh | /opt/ai-tools/bin/claude-run |
| src/opt/ai-tools/.claude/post-tool-hook.sh | /opt/ai-tools/.claude/post-tool-hook.sh |
| src/opt/ai-tools/.claude/session-hook.sh | /opt/ai-tools/.claude/session-hook.sh |
| src/opt/ai-tools/.claude/settings.json | /opt/ai-tools/.claude/settings.json |
| src/home/user/.config/systemd/user/nvm-update.service | ~/.config/systemd/user/nvm-update.service |
| src/home/user/.config/systemd/user/nvm-update.timer | ~/.config/systemd/user/nvm-update.timer |
| src/etc/sudoers.d/ai-tools-claude | /etc/sudoers.d/ai-tools-claude (root) |
| install.sh | run in place via sudo |

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

`/home` is mounted `nosuid`, which would prevent the `sudo` UID-switch from taking
effect. `/opt/ai-tools` has no `nosuid` restriction, so the switch to `${SANDBOX_USER}`
actually takes effect.

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

## Upgrade behaviour

When nvm installs a new Node version under `/opt/ai-tools`:
- `src/opt/ai-tools/bin/nvm-update.sh` repoints the `/opt/ai-tools/bin/claude`
  symlink at the new versioned binary via the root helper `ai-tools-claude-symlink`
  (`bin` is locked `550`, so the `${SANDBOX_USER}` updater cannot write it directly;
  the helper validates the versioned path and is the only writer of that dir).
- The wrapper resolves that symlink **one hop** via `readlink` and exports the result
  as `CLAUDE_EXEC`. It deliberately does *not* use `realpath`/`readlink -f`: the
  versioned `bin/claude` is itself an npm symlink into the package dir (mode 700,
  `${SANDBOX_USER}`-owned), which the invoking user cannot traverse — EACCES.
- `claude-run` re-validates `CLAUDE_EXEC` against the nvm versioned-binary pattern
  and exec's it directly. No sudoers glob matches the versioned path; the `<you>`
  sudoers rule targets the fixed path `/opt/ai-tools/bin/claude-run` only.
- Old Node versions are pruned in both nvm installs (any version not referenced by
  a named alias is removed).
- `src/home/user/.local/bin/nvm-update.sh` resolves the latest version once, updates
  your `~/.nvm`, then invokes `src/opt/ai-tools/bin/nvm-update.sh` as
  `${SANDBOX_USER}` via sudo with the pinned version so both installs land on the
  same Node build.

## Operation logging

Two sinks — **journald** (all components) and **`/var/log/ai-tools/`** (root helpers
only, `700 root:root`). Query journald by component:

    sudo journalctl -t ai-tools-chown            # the ownership-restore helper
    sudo journalctl -t ai-tools-lockdown -p warning
    sudo journalctl -t ai-tools-hook             # the lifecycle hooks
    sudo journalctl -t ai-tools                  # the CLI (project/sandbox created, …)

Root-only log files: `chown.log`, `setgid.log`, `symlink.log`, `lockdown.log`,
`install.log`. After editing the SELinux source, rebuild with
`sudo selinux/install-selinux.sh rebuild`.

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
