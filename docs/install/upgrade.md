# Upgrade the stack

[Install](index.md) · [From source](from-source.md) · **Upgrade** — [all
docs](../index.md)

Upgrading the packages with `dnf`, the one package an older host has to add
by hand, and what the daily toolchain update does to a session already running.

```bash
sudo dnf upgrade --refresh 'ai-tools*'
```

Upgrade in place, without a `dnf remove` first. `--refresh` forces a metadata
refresh: root's DNF cache is separate from your user's and can predate
a just-published release, so a plain `dnf upgrade` may report "Nothing to do"
on a stale cache even when `dnf list` — reading a newer cache — already shows
the new version. The command moves every **installed** ai-tools package
to the new version, and a host running `dnf-automatic` does the same unattended
once its cache refreshes on schedule.

## Add a package the upgrade will not

An upgrade does not add a package you do not already have, because DNF leaves
a new weak dependency off an existing install. So a host first installed
before 0.10.0 — when the SELinux policy split into its own `ai-tools-selinux`
package — keeps upgrading *without* confinement until you add it once:

```bash
rpm -q ai-tools-selinux || sudo dnf install ai-tools-selinux
```

An `ai-tools` command spelled as an option in an earlier release
(`--project-claim`) still runs and prints a notice naming the preferred
collection form; [option spellings](../option-spellings.md) lists each one.

Installing offline from a release archive, and what an upgrade preserves, are
in [ref-section-f5q2](../rpm-packaging.md#ref-section-f5q2).

## Every installed path is restored to its owner, mode and ACL

```bash
atr admin system layout
```

The command lists every path the stack installs with the owner, mode, ACL
and SELinux type it carries now and names each that drifted. An upgrade,
a source install, the provisioning run and the entrypoint relabel each run
`atr admin system layout reconcile`, which restores a drifted entry and logs
every change under the journal tag `ai-tools-layout`. A mode an upgrade
or a hand edit changed is restored by the next of those runs, without a step
of yours. A file whose content is not the package's, or that another account
owns or can write, is reported and left as it is, with the command
that restores it. `man ai-tools-admin` lists every state the reconcile leaves
to you.

## 0.24.0: the skills move to the asset set core <a id="ref-section-y5t4"></a>

From 0.24.0 the writing standard, the reftags, engineering and governance
skills and the reference subagent ship as the asset set `core`, a package
released apart from the base packages. The command that enables a set arrives
with 0.24.0, so install the set first, upgrade, and enable it right after:

```bash
sudo dnf install ai-tools-assets-sets-core
sudo dnf upgrade --refresh 'ai-tools*'
atr admin assets enable --set core
```

On a 0.23 host the set's package only places its files, which 0.24.0 is
the first release to read. A session that starts between the upgrade
and the enable loads none of the set's skills; the upgrade's output
and `atr admin status` both name the enable until it runs.

An `operator.conf` written before 0.24.0 has no `AI_TOOLS_ASSETS` line
for the enable to take, so the enable appends one and says so. To have it land
under its header instead, run `atr admin system post-upgrade` first and adopt
the merge it offers.

What the move gives you:

- **A skill update reaches your host on its own.**
  `sudo dnf upgrade ai-tools-assets-sets-core` brings a newer text without
  a base release. A host that installed the set under its former name,
  `ai-tools-assets-core`, moves to `ai-tools-assets-sets-core`
  on `sudo dnf upgrade`; the plugin the set carries keeps the name
  `ai-tools-assets-core`.
- **You choose each asset by name.** `AI_TOOLS_ASSETS`
  in `/etc/ai-tools/operator.conf` lists what sessions load;
  `assets enable --set core` writes the whole set, and `AI_TOOLS_ASSETS=[]`
  keeps every set asset off.
- **An asset links only after its set verifies.** The set's file list is signed
  with the key the packages are; a copy that does not match it is not linked,
  and `atr admin status` says why.
- **Your own copy wins.** A root-owned entry in an agent's own directory is
  loaded in place of the set's, and a set copy of your own is read ahead
  of the packaged one; `man 5 ai-tools-assets` names the directories.

The upgrade moves the copies the base packages shipped
to `/opt/ai-tools/retired/`; the enable links the set's in their place.
What `atr admin status` reports after the upgrade, and what ends it:

| On the host | `status` after the upgrade | What ends it |
|---|---|---|
| the shipped skills, as installed | names the enable, exit 4 | `assets enable --set core`, after `dnf install ai-tools-assets-sets-core`; or `AI_TOOLS_ASSETS=[]` |
| a shipped skill edited in place | names the enable, exit 4; the edited copy is under `/opt/ai-tools/retired/` | the same; carry the edit into an agent's own directory |
| a skill of your own under a shipped name, without the managed marker | names it as foreign; kept, and loaded by codex alone | move it into an agent's own directory, or remove it |

`man ai-tools-admin` names the token the first two lines carry,
and `man 5 ai-tools-assets` the third's.

A fresh install pulls `core` as a weak dependency and does not enable it,
so an install runs the enable once ([Install](index.md)).

## The agent toolchain updates on its own

Node and each enabled agent's npm package are updated on a daily timer running
in the sandbox account's own systemd instance. That is a separate mechanism
from `dnf upgrade`, which moves this project's own packages: the timer moves
the toolchain they run the agent with. Each run installs the current release
under `/opt/ai-tools` with every package's install scripts held back, verifies
the toolchain's npm registry signatures, and only once that verification passes
runs those scripts and repoints each agent's launcher at the new binary —
so a toolchain that does not verify leaves the previous, verified one in place,
and no code from the unverified one has run.

Two consequences reach an operator:

- **A session already running stays on the version it launched with**,
  for the whole of its lifetime. The next session you start resolves
  the repointed launcher and runs the new Node.
- **A Node version some live process is still running from is kept.** The prune
  defers it to the next cycle rather than removing a toolchain tree
  out from under a running session.

`atr status` reports when the update last ran and how it ended
([System](../system/index.md)).

## Labels under the sandbox's own trees wait for idle sessions

```text
ai-tools-selinux: WARNING left the labels under /opt/ai-tools and the sandbox clones as they were: ...
ai-tools-selinux:   sudo restorecon -R /opt/ai-tools /var/opt/ai-tools/sandbox-projects
```

An upgrade of `ai-tools-selinux` restores the SELinux labels of the trees it
covers. The ones the agent's account writes into — the toolchain, its caches,
each agent's config directory, the sandbox clones — are restored only while no
session of that account and no toolchain update is running
([ref-section-e6c6](../../.claude/rules/cli.rule.md#ref-section-e6c6)).
An upgrade made while one runs completes and prints that warning once. Let each
session end with `/exit` and the update finish, or end them all
with `atr stop`, then run the command it names. A label left as it was is
the one the tree already carried, so a session started before you run it is
confined as before.

## A new entrypoint is relabelled before it is launched

A freshly installed agent binary is born with the filesystem's default SELinux
type, so starting it would not enter the session's own domain. Rather than run
the session unconfined, the launch **refuses** and says so. A root-side watcher
relabels each new entrypoint after an update, and where it has not, one command
does it:

```bash
atr admin system entrypoints relabel
```

That is the one SELinux case an operator meets in practice;
[SELinux](../system/selinux.md) covers it and the rest of the confinement
layer.
