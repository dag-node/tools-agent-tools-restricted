# Install from source

The manual path — four root steps a checkout installs with, no RPM. The package install
(see the README) automates all of it; `sudo ai-tools-bootstrap` automates steps 2–3 once
`install.sh` has deployed it, and `install.sh` automates everything from step 4 on.

Set the recurring identities once, in the shell you run these steps in, so every command
pastes verbatim (the full naming spec is in
[naming-conventions.md](naming-conventions.md)):

    export PROJECTS_USER="$(id -un)"
    export PROJECTS_GROUP="$(id -gn)"
    export PROJECTS_HOME="${HOME}"
    export SANDBOX_USER=ai-tools
    export SANDBOX_GROUP=ai-tools

Each critical step also re-states the sandbox name inline, so a step pasted on its own
still works.

## 1. Install PATH dedup fragment (root, once)

    sudo install -d -o root -g root -m 751 /usr/local/lib/ai-tools
    sudo install -o root -g root -m 644 \
        src/usr/local/lib/ai-tools/path-dedup.sh /usr/local/lib/ai-tools/path-dedup.sh

(The lib directory's group becomes `ai-tools` once the account exists —
`install.sh` and the RPM re-assert `root:ai-tools 0751`.)

path-dedup deduplicates the shell's existing `$PATH` and orders it
root-owned-first, so `/usr/local/bin/claude` — the wrapper that launches
claude restricted — always resolves ahead of the nvm-managed `claude`. It is
sourced per-account: only the operator shells wired for it get the ordering,
and every other account on the host keeps its stock PATH.

`sudo ai-tools-admin operator add <user>` offers to wire the source line into your
`~/.bashrc` and `~/.bash_profile`. To wire it by hand, add it to **both** files
(non-login interactive shells read only `~/.bashrc`, login shells `~/.bash_profile`),
after your nvm init:

    export NVM_DIR="${HOME}/.nvm"
    [ -s "${NVM_DIR}/nvm.sh" ] && source "${NVM_DIR}/nvm.sh"

    # ai-tools PATH dedup (must follow nvm init)
    [[ -f /usr/local/lib/ai-tools/path-dedup.sh ]] && source /usr/local/lib/ai-tools/path-dedup.sh

nvm must be sourced **before** path-dedup: nvm prepends its versioned bin dir
to `$PATH`, and path-dedup then restructures it into Tier 4, behind the T1
system bins (which include the wrapper) and T2 `~/.local/bin`. path-dedup.sh
is idempotent — sourcing it again in the same shell produces the same PATH.

## 2. Create the SANDBOX_USER OS account at /opt (root, once)

    # The sandbox account name is fixed at ai-tools (see "Identities and naming" in the
    # README). Set it here so this block works even pasted on its own -- an unset
    # SANDBOX_USER makes useradd fail with "invalid user name ''".
    SANDBOX_USER=ai-tools
    SANDBOX_GROUP=ai-tools

    sudo useradd \
        --system \
        --shell /sbin/nologin \
        --home-dir /opt/ai-tools \
        --no-create-home \
        --comment "AI tools sandbox user" \
        "${SANDBOX_USER}"
    sudo install -d -o "${SANDBOX_USER}" -g "${SANDBOX_GROUP}" -m 755 /opt/ai-tools

    # Lock password (system users have no password by default, but be explicit)
    sudo passwd -l "${SANDBOX_USER}"

The `install -d` creates `/opt/ai-tools` owned by the account with `+x` for all, so
`${PROJECTS_USER}` can traverse into `bin/`. The RPM ships this account via `sysusers.d`, so
this step applies only to the from-source path.

`/home` is mounted `nosuid`, which would prevent the `sudo` UID-switch from taking
effect. `/opt/ai-tools` has no `nosuid` restriction, so the switch to `${SANDBOX_USER}`
actually takes effect.

## 3. Install nvm + Node + claude as SANDBOX_USER (root, once)

`ai-tools-bootstrap` does steps 2 and 3 in one idempotent command once the package is
installed — it creates the account, installs the toolchain, seeds the symlink, and enables
the `nvm-update.timer`. The manual equivalent:

    # cd first: the block runs as ${SANDBOX_USER}, which cannot occupy your home as cwd
    sudo -u "${SANDBOX_USER}" bash -c '
      cd /opt/ai-tools
      export NVM_DIR=/opt/ai-tools/.nvm
      export HOME=/opt/ai-tools
      curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
      source /opt/ai-tools/.nvm/nvm.sh
      nvm install 22
      nvm alias default 22
      npm install -g @anthropic-ai/claude-code
    '

    # Create bin dir and initial claude symlink (nvm-update.sh maintains it going forward)
    sudo -u "${SANDBOX_USER}" bash -c '
      cd /opt/ai-tools
      source /opt/ai-tools/.nvm/nvm.sh
      mkdir -p /opt/ai-tools/bin
      ln -sf "/opt/ai-tools/.nvm/versions/node/$(nvm version default)/bin/claude" \
             /opt/ai-tools/bin/claude
    '

Once `install.sh` (step 4) has run, `/opt/ai-tools/bin` is locked `0551 root:ai-tools` and
only root maintains the symlink: instead of the `ln` above, run `sudo ai-tools-bootstrap`
(idempotent -- it provisions whatever is missing and seeds the symlink through the root
helper), or re-run `sudo ./install.sh install`.

## 4. Run the install script (root, once)

Everything from here on is fully automated by `install.sh`. **Complete steps 2 and 3
first** — the account must exist (else the script stops with `ai-tools user not found`)
and `/opt/ai-tools/bin` must exist (step 3 creates it; the script writes `nvm-update.sh`
into it). `sudo ai-tools-bootstrap` does both in one idempotent command. Then run:

    sudo ./install.sh install

The script deploys the static `%ai-ops` sudoers drop-in, the helpers and the system
units, creates the approved-projects allowlist with format documentation, installs the
`ai-tools` project CLI and the `/var/opt/ai-tools` sandbox area, enables the
`nvm-update.timer` in `${SANDBOX_USER}`'s `--user` instance, and enables the
`ai-tools-relabel.path` watcher. It is idempotent — safe to re-run after updates. The
install directory is never auto-registered as a project.

Enrol each login user as an operator (ai-ops membership, allowlist seed):

    sudo ai-tools-admin operator add <user>     # defaults to $SUDO_USER

Register projects with the `ai-tools` CLI, run as your own user (no sudo):

    ai-tools --project-create /path/to/project    # a real project
    ai-tools --sandbox-create /path/to/repo       # an isolated shallow clone
    ai-tools --lockdown /path/to/project          # revoke agent access to secrets (sudo)

[project-lifecycle.md](project-lifecycle.md) covers registering in depth — claim vs
sandbox clone, what each consent prompt grants (including the traverse-only parent grant
a home-nested project needs), and every recovery/reversal path.

To remove everything installed by this script:

    sudo ./install.sh uninstall

## Files

The source→deploy map `install.sh` applies (the authoritative per-artifact
owner/group/mode list is `tests/integration/perms.sh`, which
`sudo ./install.sh check-perms` runs):

| File | Deploy path |
|---|---|
| src/usr/local/lib/ai-tools/path-dedup.sh | /usr/local/lib/ai-tools/path-dedup.sh (root) |
| src/opt/ai-tools/bin/nvm-update.sh | /opt/ai-tools/bin/nvm-update.sh |
| src/usr/local/sbin/ai-tools/ai-tools-chown.sh | /usr/local/sbin/ai-tools/ai-tools-chown (root) |
| src/usr/local/sbin/ai-tools/ai-tools-setgid.sh | /usr/local/sbin/ai-tools/ai-tools-setgid (root) |
| src/usr/local/sbin/ai-tools/ai-tools-claude-symlink.sh | /usr/local/sbin/ai-tools/ai-tools-claude-symlink (root) |
| src/usr/local/sbin/ai-tools/ai-tools-relabel-entrypoint.sh | /usr/local/sbin/ai-tools/ai-tools-relabel-entrypoint (root) |
| src/usr/local/sbin/ai-tools/ai-tools-bootstrap.sh | /usr/local/sbin/ai-tools/ai-tools-bootstrap (root) |
| src/usr/local/sbin/ai-tools/ai-tools-admin.sh | /usr/local/sbin/ai-tools/ai-tools-admin (root) |
| src/usr/local/sbin/ai-tools/ai-tools-lockdown.sh | /usr/local/sbin/ai-tools/ai-tools-lockdown (root) |
| src/usr/local/sbin/ai-tools/ai-tools-handback.py | /usr/local/sbin/ai-tools/ai-tools-handback (root) |
| src/usr/local/bin/ai-tools-handback-client.py | /usr/local/bin/ai-tools-handback-client (root:ai-tools) |
| src/usr/lib/systemd/system/ai-tools-handback.socket | /usr/lib/systemd/system/ai-tools-handback.socket (root) |
| src/usr/lib/systemd/system/ai-tools-handback@.service | /usr/lib/systemd/system/ai-tools-handback@.service (root) |
| src/usr/local/lib/ai-tools/secret-patterns.lib.sh | /usr/local/lib/ai-tools/secret-patterns.lib.sh (root) |
| src/usr/local/lib/ai-tools/skip-dirs.lib.sh | /usr/local/lib/ai-tools/skip-dirs.lib.sh (root) |
| src/usr/local/bin/claude.sh | /usr/local/bin/claude (root) |
| src/opt/ai-tools/bin/claude-run.sh | /opt/ai-tools/bin/claude-run |
| src/opt/ai-tools/.claude/post-tool-hook.sh | /opt/ai-tools/.claude/post-tool-hook.sh |
| src/opt/ai-tools/.claude/session-hook.sh | /opt/ai-tools/.claude/session-hook.sh |
| src/opt/ai-tools/.claude/settings.json | /opt/ai-tools/.claude/settings.json |
| src/usr/lib/systemd/user/nvm-update.service | /usr/lib/systemd/user/nvm-update.service (root) |
| src/usr/lib/systemd/user/nvm-update.timer | /usr/lib/systemd/user/nvm-update.timer (root) |
| src/usr/lib/systemd/system/ai-tools-relabel.path | /usr/lib/systemd/system/ai-tools-relabel.path (root) |
| src/usr/lib/systemd/system/ai-tools-relabel.service | /usr/lib/systemd/system/ai-tools-relabel.service (root) |
| src/etc/sudoers.d/ai-tools-claude | /etc/sudoers.d/ai-tools-claude (root) |
| src/etc/ai-tools/operator.conf | /etc/ai-tools/operator.conf (root; seeded once, then operator-maintained) |
| install.sh | run in place via sudo |
