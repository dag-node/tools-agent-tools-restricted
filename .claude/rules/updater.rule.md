---
paths:
  - "src/opt/ai-tools/bin/nvm-update.sh"
  - "src/usr/local/sbin/ai-tools/ai-tools-bootstrap.sh"
  - "src/usr/local/sbin/ai-tools/ai-tools-claude-symlink.sh"
  - "src/usr/local/sbin/ai-tools/ai-tools-relabel-entrypoint.sh"
  - "src/usr/lib/systemd/user/nvm-update.service"
  - "src/usr/lib/systemd/user/nvm-update.timer"
  - "src/usr/lib/systemd/system/ai-tools-relabel.path"
  - "src/usr/lib/systemd/system/ai-tools-relabel.service"
---

# Node/claude updater and symlink repoint

A scheduled `nvm-update` job keeps Node.js and `@anthropic-ai/claude-code` current under
`/opt/ai-tools`. After an upgrade the versioned `claude` symlink is repointed through a
root helper and the new entrypoint is relabelled for the SELinux transition.

## Toolchain provisioning (`ai-tools-bootstrap`)

`ai-tools-bootstrap` provisions the toolchain the updater then maintains: run once as root,
it creates the `SANDBOX_USER` account and its `/opt/ai-tools` home if absent, installs nvm,
Node (`AI_TOOLS_NODE_MAJOR`, default 22), and the agent's npm package as `SANDBOX_USER`,
points `/opt/ai-tools/bin/<launcher>` at the versioned binary, relabels the freshly
installed entrypoint (`ai-tools-relabel-entrypoint`, gated on that helper being deployed, so
the first launch after a fresh provision is confined without a manual `ai-tools --relabel`),
and captures the initial control plane in a root-private git repo. It is the one network
step, so it is an operator command rather than an RPM scriptlet (which must succeed
offline). It is idempotent: an
existing account, nvm install, or Node version is reused. It enables `SANDBOX_USER` linger
and the `nvm-update.timer` in that instance (best-effort), so the maintenance schedule is
live once the toolchain exists.

As a closing interactive step it offers to set the **sandbox git commit identity** in the
control-plane gitconfig — the name/email the agent authors commits with. This is the one
interactive point both install flows share: the RPM `%post` (and `install.sh`) seed a
default (`ai-tools@<domain-or-hostname>`) but `%post` cannot prompt, so the operator adopts
their own git identity, keeps the default, or edits the file by hand here. It runs only when
the control plane is present (the gitconfig exists) — a bootstrap that precedes control-plane
install has nothing to configure and skips; past that gate `msg.lib` is deployed, so the
prompt requires it and fails closed like any other, no fallback (see
[messaging](messaging.rule.md)).

## Where the update runs

`nvm-update.service` and `nvm-update.timer` ship in `%{_userunitdir}` and are enabled in
`SANDBOX_USER`'s own `systemd --user` instance, so the updater runs as `SANDBOX_USER` and
writes the shared `.nvm` tree (`%h=/opt/ai-tools`) directly. The timer fires daily; one
instance maintains the toolchain the whole team shares. `ai-tools-bootstrap` enables the
timer once it has provisioned the toolchain and `SANDBOX_USER`'s linger; `install.sh`
enables it for the dev flow.

## Version resolution

`nvm-update.sh` resolves the latest LTS in the `NVM_NODE_MAJOR` series itself
(`nvm ls-remote --lts | sort -V | tail -1` selects the highest semver, not "first match"
or "currently active"); an explicit version argument overrides the lookup. Prune logic
collects all versions referenced by any named alias into an associative array before
removing anything, so a version another alias points to is retained, as is any version a
live session still runs from.

## Symlink repoint root helper (`ai-tools-claude-symlink`)

`/opt/ai-tools/bin` is `0551` and not group-writable (see
[ownership-and-hooks](ownership-and-hooks.rule.md)), so `SANDBOX_USER` reaches the
versioned `claude` symlink only through a root helper. `ai-tools-claude-symlink` accepts
one argument, validates it is exactly a `…/node/v<MAJOR>.<MINOR>.<PATCH>/bin/claude` path
that exists (its own anchored-regex check, **not** the coarse sudoers glob, is
authoritative — argument wildcards can match `/`), then atomically repoints the symlink.
The sandbox updater and `install.sh` are the only callers; the updater reaches it through
the [handback bridge](handback-bridge.rule.md) `SYMLINK` verb. The helper repoints the
symlink but does not relabel the new entrypoint — it runs in the handback domain, which
holds no relabel rights.

## Post-upgrade entrypoint relabel

A fresh Node tree's `claude.exe` is born `bin_t`, so the `→ ai_tools_t` domain transition
fires only once the entrypoint carries `ai_tools_exec_t`. `ai-tools-relabel-entrypoint`
restores that label: it restorecons every `claude.exe` under the nvm tree and verifies
each took `ai_tools_exec_t`. It runs as root (a domain that holds relabel), is idempotent,
and no-ops when SELinux is off or the `ai_tools` module is not installed — it acts only on
entrypoints the file-context DB maps to `ai_tools_exec_t`, the same condition `claude-run`
keys on.

`ai-tools-bootstrap` runs the helper directly at provision time (above). Two further paths
run it after an upgrade, both as root, never `SANDBOX_USER`:

- **Automatically**, through the `ai-tools-relabel.path` watcher. The `.path` watches
  `/opt/ai-tools/bin/claude` — the symlink the updater repoints as its last step, atomically
  (`mv -T` over the old link), so the inode changes and the watcher fires on **every** repoint
  including a same-version reinstall that reminted `claude.exe` at `bin_t` — and triggers
  `ai-tools-relabel.service` (a root oneshot in the system instance) when it changes, so a
  Node bump relabels without operator action. The repoint is the sole trigger: the sandbox
  updater holds no relabel rights and reaches root only through the handback bridge, whose
  domain deliberately holds none either, so a repoint that does not land (handback down in a
  manual run) leaves the relabel to `claude-run`'s fail-closed preflight and the operator's
  `ai-tools --relabel`.
- **On demand**, through `ai-tools --relabel` (see [cli](cli.rule.md)), which runs the
  same helper via the `%ai-ops` NOPASSWD sudo rule (the relabel rule in
  `sudoers.d/ai-tools-claude`; see [launch](launch.rule.md)). `install-selinux.sh relabel`
  is the comprehensive source-tree sweep.

The relabel runs outside the handback domain by design: `ai_tools_handback_t` is
agent-reachable and holds no relabel rights (`ai_tools.te`), so the privilege stays off
the agent's reach. The watcher is best-effort; `claude-run`'s fail-closed preflight (see
[confinement](confinement.rule.md)) is the backstop — when SELinux is enforcing and the
module is installed, it refuses to launch a session whose entrypoint is not
`ai_tools_exec_t`, so a watcher relabel that does not land degrades to a refused launch the
operator clears with `ai-tools --relabel`, never an unconfined session.

## `loginctl enable-linger`

Linger on `SANDBOX_USER` keeps its `systemd --user` instance running without an
interactive login, so both the daily `nvm-update` timer and each `claude-run` session unit
have a live user manager. Required for headless/unattended operation.
