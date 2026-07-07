# Agent Tools Restricted

[![CI](https://github.com/dag-node/ai-tools/actions/workflows/ci.yml/badge.svg)](https://github.com/dag-node/ai-tools/actions/workflows/ci.yml)
[![License: AGPL v3](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)

Run coding agents sandboxed — under their own locked-down system user.

Agent Tools Restricted runs an autonomous coding agent under a dedicated, unprivileged
service account (`SANDBOX_USER`, the account created as `ai-tools`) with a tightly scoped set
of privileges, and keeps its Node.js toolchain and CLI current automatically. **Claude Code is
the first supported agent**; the confinement, ownership-handback, and toolchain machinery are
agent-agnostic. Targets Enterprise Linux 9 and 10 — RHEL and its rebuilds (Rocky, AlmaLinux,
Oracle Linux/UEK).

## Quick start

```bash
# 1. Install the full stack in one transaction. The build produces a metapackage
#    (ai-tools) and three subpackages (ai-tools-base, ai-tools-nodejs,
#    claude-code-restricted); pass dnf all of them at once so it resolves the
#    inter-package deps from the local files and orders the install itself.
#    (Or run `sudo ./install.sh install` from a source checkout.)
sudo dnf install ./*.rpm

# 2. Provision the sandbox account's Node toolchain + claude (network, once)
sudo ai-tools-bootstrap

# 3. Enrol yourself as an operator (ai-ops membership, allowlist seed)
sudo ai-tools-admin operator add "$(id -un)"

# 4. Register a project, then launch
ai-tools --project-create ~/myproject
cd ~/myproject && claude
```

Order *within* step 1 is dnf's job — it installs `ai-tools-base`, then
`ai-tools-nodejs`, then `claude-code-restricted` from the dependency graph, so a
single transaction is all that matters. Steps 2 and 3 are independent of each
other but must both run before step 4.

`claude` resolves to the system wrapper `/usr/local/bin/claude`, which runs as you,
checks your `ai-ops` membership and the project allowlist, then drops to `${SANDBOX_USER}`
via `sudo` and wraps the session in a confined `systemd --user` service. `ai-tools-bootstrap`
installs nvm, Node, and `@anthropic-ai/claude-code` under `/opt/ai-tools` and enables the
daily `nvm-update.timer` in `${SANDBOX_USER}`'s own `--user` instance, which keeps them
current; `ai-tools-admin operator add` grants a login user access. The manual steps below
are the from-source equivalents of steps 1–2.

## Why

A coding agent like Claude Code reads, writes, and runs commands autonomously. Run as
your own user it inherits everything you can touch — SSH keys, browser profiles,
every project, your full sudo rights. This project gives the agent its own UID
with a tightly scoped set of privileges instead:

- **Separate identity** — `${SANDBOX_USER}` is a system account with no login shell
  and no password. Claude executes under that UID via `sudo`, not as you.
- **Launches only in approved projects** — a wrapper refuses to start Claude
  unless the working directory is listed in `~/.config/ai-tools/allowed-projects`
  (with `!` exclusions to carve out subdirectories or secrets).
- **Minimal sudo surface** — `${SANDBOX_USER}` has **no** sudo rights. Root operations
  (ownership handback, setgid normalisation, symlink repoint) go through a dedicated
  socket daemon (`ai-tools-handback`, started at boot) that authenticates callers via
  `SO_PEERCRED`. The one `%ai-ops` rule that drops to `${SANDBOX_USER}` runs only
  `claude-run` — a fixed-path sudo target, not a glob, which wraps the session in a
  systemd `--user --pty` service before exec'ing the versioned binary. Nothing else.
- **Ownership hand-back** — files Claude writes are chowned back to
  `${PROJECTS_USER}:${SANDBOX_GROUP}` (group-readable, world-closed) inside approved paths only, along
  with any directories Claude created on the way (world bits stripped, group
  `rwx` kept; only dirs the agent itself made are touched). Secret-named files
  (`.env`, `*.key`, `*.pem`, SSH keys, `kubeconfig`, …) are chowned to
  `${PROJECTS_USER}:${PROJECTS_GROUP} 600` instead, removing `${SANDBOX_USER}`'s read access; a `NOTICE` is written to
  the session and the operation log (root-only `/var/log/ai-tools/chown.log` plus
  journald — see *Operation logging* below).
- **Collaborative access** — a POSIX default ACL on each approved tree makes you and
  Claude co-writers without `${PROJECTS_USER}` joining `${SANDBOX_GROUP}`:
  `g:${SANDBOX_GROUP}:rwX` grants Claude access to your files and
  `user:${PROJECTS_USER}:rwX` grants you access to Claude's, both umask-independent;
  world access stays closed. Applied at `ai-tools --project-claim`.
- **Operation logging** — the `sudo` helpers, the lifecycle hooks, the `ai-tools`
  CLI, and `install.sh` log through one library to **journald** (always, leveled and
  tagged: `journalctl -t ai-tools-chown`) and, for the root writers only, to
  root-only files under **`/var/log/ai-tools/`**.
- **Auto-updating** — a `systemd --user` timer in `${SANDBOX_USER}`'s own instance keeps
  Node and `@anthropic-ai/claude-code` current under `/opt/ai-tools`, and a root-side
  watcher relabels the new entrypoint for SELinux after each upgrade.

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

The package and `install.sh` resolve these automatically — you never type them. The
`@…@` token form is what the shipped templates carry; the RPM `%prep` and `install.sh`
substitute it to `ai-tools` at build/deploy time, and the RPM creates the account from a
`sysusers.d` entry (`u ai-tools …`) with no prompt, so the name is **not** an install-time
choice today. `SANDBOX_USER`/`SANDBOX_GROUP` name the account (`ai-tools`); the literal
`ai-tools` is also kept in paths (`/opt/ai-tools`), SELinux types (`ai_tools_t`), the `ai-tools`
CLI, and helper names (`ai-tools-chown`) — those are fixed and do not track the account name.

The variables matter only if you install **from source** by running the manual steps below
(the `install.sh` and RPM paths need none of this). Set them once, in the shell you run those
steps in, so the commands paste verbatim:

    export PROJECTS_USER="$(id -un)"
    export PROJECTS_GROUP="$(id -gn)"
    export PROJECTS_HOME="${HOME}"
    export SANDBOX_USER=ai-tools
    export SANDBOX_GROUP=ai-tools

Every manual command below expands these in your shell; run them in that same shell. Each
critical step also re-states the sandbox name inline, so a step pasted on its own still works.

## Architecture at a glance

```
you type `claude`
  └─ /usr/local/bin/claude                    (wrapper, runs as the invoking operator)
       ├─ caller ∈ ai-ops group?              refuse a non-operator with a framed message
       ├─ CWD ∈ allowed-projects?             refuse if not, or if !-excluded
       ├─ resolve /opt/ai-tools/bin/claude    (one readlink hop; export as CLAUDE_EXEC)
       ├─ export CWD as CLAUDE_PROJECT_DIR    (validated project dir → unit WorkingDirectory)
       └─ exec sudo -u "${SANDBOX_USER}" -- /opt/ai-tools/bin/claude-run
            └─ systemd transient service      (--pty; RestrictNamespaces=yes, UMask=0007,
                                               WorkingDirectory=project, NODE_COMPILE_CACHE pinned)
                 └─ claude runs as ${SANDBOX_USER} in ai_tools_t (SELinux)
                      └─ on Write/Edit → PostToolUse hook (or Stop/SessionStart sweep)
                           └─ ai-tools-handback-client CHOWN <file>   (socket, no sudo)
                                └─ ai-tools-handback daemon (root, SO_PEERCRED auth)
                                     └─ ai-tools-chown <file>   (allowlist-checked)
                                          └─ chown ${PROJECTS_USER}:${SANDBOX_GROUP}, strip world bits
```

## Files

| File | Deploy path |
|---|---|
| src/etc/profile.d/path_dedup.sh | /etc/profile.d/path_dedup.sh (root) |
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

---

## 1. Install PATH deduplication script (root, once)

    sudo install -o root -g root -m 644 \
        src/etc/profile.d/path_dedup.sh /etc/profile.d/path_dedup.sh

nvm must be sourced **before** path_dedup in both init files. nvm prepends
its versioned bin dir to `$PATH`; path_dedup then restructures it into Tier 4,
keeping it behind the T1 system bins — which include `/usr/local/bin/claude`,
the wrapper, so it shadows the nvm-managed `claude` — and T2 `~/.local/bin`.
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

    # The sandbox account name is fixed at ai-tools (see "Identities and naming"). Set it here
    # so this block works even pasted on its own -- an unset SANDBOX_USER makes useradd fail
    # with "invalid user name ''".
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

Steps 4–12 are fully automated by `install.sh`. **Complete steps 2 and 3 first** — the
account must exist (else the script stops with `ai-tools user not found`) and
`/opt/ai-tools/bin` must exist (step 3 creates it; the script writes `nvm-update.sh` into it).
`sudo ai-tools-bootstrap` does both in one idempotent command. Then run:

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

`ai-tools --lockdown` wraps the root `ai-tools-lockdown` helper (it prompts for
your sudo password) and `ai-tools --sandbox-create` offers to run it right after a
clone. A sandboxed project is a shallow clone under `/var/opt/ai-tools/sandbox-projects/`
that the agent works in without ever reading the original repo's full git
history. See `/var/opt/ai-tools/README.md` for that workflow.

A project nested inside your home needs one extra grant — traverse-only access for the
sandbox account on the directories above it. `ai-tools --project-claim` detects this and
offers it as a default-NO prompt; the equivalent by hand is:

    setfacl -m u:ai-tools:--x ~

The session runs as the sandbox account, which must *traverse* the path to the project; a
private home (`drwx------`) blocks that, so `claude-run` reports the project as "not an
existing directory" even though the claim succeeded. `--x` (execute, no read) lets the
account *enter* a directory to reach the claimed project but never *list* or *read* it — the
same least-privilege traverse the agent already has on `/opt/ai-tools`. The claim grants it
only on directories you own and never on a system directory; for a project under a path you do
not own, or to leave your home untouched, use a sandbox clone instead — it lives under
`/var/opt/ai-tools/sandbox-projects/`, which the account already traverses.

To remove everything installed by this script:

    sudo ./install.sh uninstall

## Upgrade behaviour

`nvm-update.timer` fires daily in `${SANDBOX_USER}`'s `--user` instance and runs
`/opt/ai-tools/bin/nvm-update.sh`, which resolves the latest LTS in the `NVM_NODE_MAJOR`
series, installs it under `/opt/ai-tools/.nvm`, refreshes the global tools, prunes, and:

- repoints the `/opt/ai-tools/bin/claude` symlink at the new versioned binary via the
  handback socket bridge (`SYMLINK` verb → `ai-tools-claude-symlink`). `bin` is locked
  `0551`, so the `${SANDBOX_USER}` updater cannot write it directly; the helper validates
  the versioned path and is the only writer of that dir.
- prunes old Node versions (any not referenced by a named alias) — **except** a version a
  live process still runs from. The prune scans `/proc/<pid>/exe` and defers such a
  version to the next cycle, so an update never deletes the toolchain out from under a
  running Claude session.

The `ai-tools-relabel.path` watcher sees the symlink repoint and runs
`ai-tools-relabel-entrypoint` (root) to restore `ai_tools_exec_t` on the new `claude.exe`,
so the SELinux domain transition keeps firing. Until the entrypoint is relabelled,
`claude-run` fail-closes (refuses to launch rather than run unconfined); `ai-tools
--relabel` is the manual fallback.

On launch the wrapper resolves the symlink **one hop** via `readlink` (not
`realpath`/`readlink -f`: the versioned `bin/claude` is itself an npm symlink into the
package dir, mode 700 `${SANDBOX_USER}`-owned, which the invoking user cannot traverse —
EACCES) and exports it as `CLAUDE_EXEC`. `claude-run` re-validates `CLAUDE_EXEC` against
the nvm versioned-binary pattern and exec's it directly; the only sudoers rule dropping to
`${SANDBOX_USER}` targets the fixed path `/opt/ai-tools/bin/claude-run`, never the
versioned binary.

> **Rationale — what the mode-700 package dir does and doesn't do.** The npm package dir
> (`…/node_modules/@anthropic-ai/claude-code/`) is `700` and `${SANDBOX_USER}`-owned. That
> keeps the agent's toolchain **private** to the sandbox account and root — no other login
> user can read the package internals. It is **not** a tamper barrier against the agent:
> `${SANDBOX_USER}` owns that tree and may write within it. The integrity of *what
> executes* rests elsewhere — on `/opt/ai-tools/bin` being `0551 root:ai-tools` (only root,
> through the `ai-tools-claude-symlink` helper, writes the stable `bin/claude` symlink the
> wrapper trusts) and on `claude-run` re-validating `CLAUDE_EXEC` against the nvm path
> pattern before exec. The **one-hop `readlink`** is a consequence of that mode: a
> full `realpath`/`readlink -f` would traverse the `700` dir *as the invoking operator* and
> hit EACCES — a silent abort under `set -e` — so the wrapper reads only the root-owned
> symlink and validates its target by string. Trust comes from the root-owned `bin/` and
> `claude-run`'s re-validation, not from resolving into a directory the agent controls.

After an update, **new** Claude sessions resolve the repointed `bin/claude` symlink and use
the new Node version. A **running** session stays pinned to the version it launched with for
its whole lifetime by design.

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

For the wrapper in `/usr/local/bin`:

    restorecon -v /usr/local/bin/claude

## License

All source in this repository is published under the GNU Affero General
Public License v3.0 — free and open, with no gated tier. You may use, copy,
modify, and distribute it subject to that license's terms. The most
important one: if you run a modified version as a network service, you must
make your modified source available to that service's users. Full text:
[`LICENSE`](LICENSE), or <https://www.gnu.org/licenses/agpl-3.0.html>.

dag-node's commercial/enterprise offerings (fleet management, centralized
audit/policy reporting, SSO integration, support contracts) are built on top
of this open core rather than gating any part of it. See
[github.com/dag-node](https://github.com/dag-node) for those.
