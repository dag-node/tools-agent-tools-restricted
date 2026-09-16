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

## The agent toolchain updates on its own

Node and each enabled agent's npm package are updated on a daily timer running
in the sandbox account's own systemd instance. That is a separate mechanism
from `dnf upgrade`, which moves this project's own packages: the timer moves
the toolchain they run the agent with. Each run installs the current release
under `/opt/ai-tools`, verifies the toolchain's npm registry signatures,
and repoints each agent's launcher at the new binary only once
that verification passes — so a toolchain that does not verify leaves
the previous, verified one in place.

Two consequences reach an operator:

- **A session already running stays on the version it launched with**,
  for the whole of its lifetime. The next session you start resolves
  the repointed launcher and runs the new Node.
- **A Node version some live process is still running from is kept.** The prune
  defers it to the next cycle rather than removing a toolchain tree
  out from under a running session.

`ai-tools status` reports when the update last ran and how it ended
([System](../system/index.md)).

## A new entrypoint is relabelled before it is launched

A freshly installed agent binary is born with the filesystem's default SELinux
type, so starting it would not enter the session's own domain. Rather than run
the session unconfined, the launch **refuses** and says so. A root-side watcher
relabels each new entrypoint after an update, and where it has not, one command
does it:

```bash
sudo ai-tools-admin system entrypoints relabel
```

That is the one SELinux case an operator meets in practice;
[SELinux](../system/selinux.md) covers it and the rest of the confinement
layer.
