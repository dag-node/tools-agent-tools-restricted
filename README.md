# Agent Tools Restricted

[![CI](https://github.com/dag-node/tools-agent-tools-restricted/actions/workflows/ci.yml/badge.svg)](https://github.com/dag-node/tools-agent-tools-restricted/actions/workflows/ci.yml)
[![License: AGPL v3](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)
[![Platform: EL 9 | EL 10](https://img.shields.io/badge/platform-EL%209%20%7C%20EL%2010-blue.svg)](#requirements)

Run coding agents sandboxed — under their own locked-down system user.

Agent Tools Restricted runs an autonomous coding agent under a dedicated, unprivileged
service account (`SANDBOX_USER`, the account created as `ai-tools`) with a tightly scoped set
of privileges, and keeps its Node.js toolchain and CLI current automatically. **Claude Code is
the first supported agent**; the confinement, ownership-handback, and toolchain machinery are
agent-agnostic.

**Contents**: [Requirements](#requirements) · [Package install](#package-install) · [Why](#why) ·
[Identities and naming](#identities-and-naming) ·
[Architecture at a glance](#architecture-at-a-glance) · [Files](#files) ·
[From-source install (steps 1–4)](#1-install-path-dedup-fragment-root-once) ·
[Upgrade behaviour](#upgrade-behaviour) · [Operation logging](#operation-logging) ·
[SELinux](#selinux) · [Community](#community) · [License](#license)

## Requirements

- **Enterprise Linux 9 or 10** — RHEL and its rebuilds (Rocky, AlmaLinux, Oracle
  Linux/UEK). Other distributions are untested; the design assumes systemd, sudo,
  and EL filesystem conventions.
- **systemd** (system instance plus user instances with lingering) and **POSIX ACL**
  support on the filesystem holding your projects.
- **SELinux targeted policy, enforcing** — recommended; the session is confined in
  `ai_tools_t`. With SELinux disabled the system runs in a documented DAC-only
  posture.
- **Network access once** for `ai-tools-bootstrap` (fetches nvm, Node, and the agent
  npm package); day-to-day operation and updates run from a systemd timer.
- Optional: **podman** to run the container test harness (`packaging/README.md`).

## Package install

Install from the signed DNF repository (recommended). One `.repo` file serves EL 9 and
EL 10 — `$releasever`/`$basearch` select the right tree — and `gpgcheck`/`repo_gpgcheck`
verify both the packages and the repo metadata against the dag-node org signing key:

```bash
sudo tee /etc/yum.repos.d/dagnode.repo >/dev/null <<'EOF'
[dagnode]
name=DagNode RPM Repository
baseurl=https://rpm.dagnode.com/el/$releasever/$basearch/
gpgkey=https://rpm.dagnode.com/RPM-GPG-KEY-dag-node
gpgcheck=1
repo_gpgcheck=1
enabled=1
metadata_expire=6h
EOF
sudo dnf install ai-tools          # the metapackage pulls the whole stack
```

Or install a release archive directly (offline / air-gapped). The zip bundles the four RPMs
(metapackage + `ai-tools-base`, `ai-tools-nodejs`, `claude-code-restricted`) plus the public
key; they extract flat and dnf orders them itself:

```bash
unzip ai-tools-el10-vX.Y.Z.zip                 # ai-tools-el9-... to match your platform
sudo rpm --import RPM-GPG-KEY-dag-node         # then omit --nogpgcheck below
sudo dnf install ./*.rpm
# An unsigned or older archive ships no key: `sudo dnf install --nogpgcheck ./*.rpm`.
```

Then finish setup — steps 1 and 2 here are independent of each other but both run before
step 3:

```bash
# 1. Install Node.js, nvm, and Claude Code (from npm) and enable the update timer (network).
sudo ai-tools-bootstrap

# 2. Enrol yourself as an operator: records you in /etc/ai-tools/operator.conf and grants
#    ai-ops membership (the sudo rules and ownership hand-back).
sudo ai-tools-admin operator add "$(id -un)"

# 3. Register a project and launch. `ai-tools --help` lists every command. Run inside a
#    project, `claude` (the wrapper) walks you through claiming it; the claim refuses system
#    paths and home roots.
ai-tools --project-create ~/myproject
cd ~/myproject && claude
```

**Upgrading — upgrade in place, never `dnf remove` first.** From the repo, `sudo dnf upgrade
'ai-tools*'`; from a downloaded archive, `sudo dnf install ./*.rpm` (a higher version upgrades
each subpackage). Removing the packages moves your edited `/etc/ai-tools/operator.conf` to
`operator.conf.rpmsave` and the fresh install writes an empty one, dropping your operator list
(re-add with `ai-tools-admin operator add`); an in-place upgrade keeps it via
`%config(noreplace)`. `dnf reinstall` needs the *same* version already installed and is not the
way to move between versions.

`claude` resolves to the system wrapper `/usr/local/bin/claude`, which runs as you,
checks your `ai-ops` membership and the project allowlist, then drops to `${SANDBOX_USER}`
via `sudo` and wraps the session in a confined `systemd --user` service. Launched in an
unclaimed project it prompts you to claim it first; the claim and every elevated helper
refuse system directories and home roots (the
[safe-paths backstop](.claude/rules/safe-paths.rule.md)). The from-source install below
is the manual equivalent of the package install plus `ai-tools-bootstrap`.

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
  socket daemon (`ai-tools-handback`) that verifies the caller's identity with a kernel
  credential the caller cannot forge. The one `%ai-ops` rule that drops to `${SANDBOX_USER}`
  runs only `claude-run` — a fixed-path sudo target, not a glob, which wraps the session in a
  confined systemd `--user --pty` service. Nothing else. See the
  [handback bridge](.claude/rules/handback-bridge.rule.md).
- **Ownership hand-back** — files Claude writes are chowned back to
  `${PROJECTS_USER}:${SANDBOX_GROUP}` (group-readable, world-closed) inside approved paths only, along
  with any directories Claude created on the way (world bits stripped, group
  `rwx` kept; only dirs the agent itself made are touched).
- **Secrets stay out of reach** — a secret-named file Claude writes (`.env`, `*.key`,
  `*.pem`, SSH keys, `kubeconfig`, …) is instead chowned to
  `${PROJECTS_USER}:${PROJECTS_GROUP} 600`, removing `${SANDBOX_USER}`'s read access entirely; a `NOTICE`
  lands in the session and the operation log. `ai-tools --lockdown` applies the same over an
  existing tree. See [secret handling](.claude/rules/secret-handling.rule.md).
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
  watcher relabels the new entrypoint for SELinux after each upgrade. Each update verifies the
  toolchain's npm registry signatures and fails closed on a tamper before activating it.

> **On the boundary.** The allowlist gates where Claude *launches* and which
> files get ownership restored — it is not a kernel-enforced read boundary. The CWD is
> canonicalized before it is checked, so a symlink cannot slip a path past it. Once running
> as `${SANDBOX_USER}`, ordinary Unix permissions plus the `ai_tools_t` SELinux type govern
> access; that is what actually isolates the agent from other users' files. A per-session
> `bubblewrap` mount namespace to make the allowlist a true access boundary is proposed but
> not yet implemented.

The enforced isolation boundary is DAC plus the `ai_tools_t` SELinux type. A few things are
**out of scope by design**, not oversights: all operators share one `${SANDBOX_USER}` account
(sessions are not kernel-isolated from each other), and `ai-ops` operators are trusted — the
model defends the host from the *agent*, not from an operator. The full trust model, the
non-goals, and the deferred hardening (per-operator isolation, registry-key pinning) are
in [`CLAUDE.md`](CLAUDE.md#boundaries-and-non-goals).

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
            │                                  (DROPS privilege to the unprivileged sandbox
            │                                   account — the wrapper never runs as root)
            └─ systemd transient service      (--pty; RestrictNamespaces=yes, UMask=0007,
                                               WorkingDirectory=project, NODE_COMPILE_CACHE pinned)
                 └─ claude runs as ${SANDBOX_USER} in ai_tools_t (SELinux)
                      └─ on Write/Edit → PostToolUse hook (or Stop/SessionStart sweep)
                           └─ ai-tools-handback-client CHOWN <file>   (socket, no sudo)
                                └─ ai-tools-handback daemon            (root; authenticated caller)
                                     └─ ai-tools-chown <file>          (allowlist-checked)
                                          └─ chown ${PROJECTS_USER}:${SANDBOX_GROUP}, strip world bits
```

The privilege model and every guard above are specified in
[`CLAUDE.md`](CLAUDE.md) (trust chain and invariants) and the per-component
[`.claude/rules/`](.claude/rules/).

## Files

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

---

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

`ai-tools-admin operator add` (step 3 of *Package install*) offers to wire the
source line into your `~/.bashrc` and `~/.bash_profile`. To wire it by hand,
add it to **both** files (non-login interactive shells read only `~/.bashrc`,
login shells `~/.bash_profile`), after your nvm init:

    export NVM_DIR="${HOME}/.nvm"
    [ -s "${NVM_DIR}/nvm.sh" ] && source "${NVM_DIR}/nvm.sh"

    # ai-tools PATH dedup (must follow nvm init)
    [[ -f /usr/local/lib/ai-tools/path-dedup.sh ]] && source /usr/local/lib/ai-tools/path-dedup.sh

nvm must be sourced **before** path-dedup: nvm prepends its versioned bin dir
to `$PATH`, and path-dedup then restructures it into Tier 4, behind the T1
system bins (which include the wrapper) and T2 `~/.local/bin`. path-dedup.sh
is idempotent — sourcing it again in the same shell produces the same PATH.

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
    sudo journalctl -t ai-tools-handback         # the privilege bridge (one line per request)
    sudo journalctl -t ai-tools                  # the CLI (project/sandbox created, …)

The handback daemon keeps a per-request audit line — the peer PID, the verb, the path, and
the helper result — plus a `WARNING` for every rejected peer or malformed request, so each
privileged action is attributable at the socket layer. Root-only log files: `chown.log`,
`setgid.log`, `symlink.log`, `lockdown.log`, `handback.log`, `install.log`. After editing the
SELinux source, rebuild with `sudo selinux/install-selinux.sh rebuild`.

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

## Community

- **Bugs and feature requests** — [GitHub issues](https://github.com/dag-node/tools-agent-tools-restricted/issues);
  the templates ask for the environment details and journald excerpts that make a
  report actionable.
- **Security vulnerabilities** — never a public issue; see [`SECURITY.md`](SECURITY.md)
  for private reporting channels and what's in scope.
- **Contributing** — [`CONTRIBUTING.md`](CONTRIBUTING.md): development setup, the test
  categories, the lint baseline, and the branch/PR conventions.
- **Conduct** — [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) (Contributor Covenant 2.1).

## License

All source in this repository is published under the GNU Affero General
Public License v3.0 — free and open, with no gated tier. You may use, copy,
modify, and distribute it subject to that license's terms. The most
important one: if you run a modified version as a network service, you must
make your modified source available to that service's users. Full text:
[`LICENSE`](LICENSE), or <https://www.gnu.org/licenses/agpl-3.0.html>.

**Claude Code is separate.** This license covers only this repository's own
source — the sandboxing, install, and CLI machinery. `ai-tools-bootstrap`
installs Claude Code itself (`@anthropic-ai/claude-code`) fresh from npm at
your own bootstrap step; it is a separate proprietary Anthropic product
under its own license and terms, never vendored or redistributed by this
project. See [Anthropic's Claude Code](https://github.com/anthropics/claude-code)
for its own terms.

dag-node's commercial/enterprise offerings (fleet management, centralized
audit/policy reporting, SSO integration, support contracts) are built on top
of this open core rather than gating any part of it. See
[github.com/dag-node](https://github.com/dag-node) for those.
