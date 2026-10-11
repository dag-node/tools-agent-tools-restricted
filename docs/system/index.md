# System

**System** · [Logs](logs.md) · [SELinux](selinux.md) · [Entrypoint
verification](entrypoint-verification.md) · [Reading a record
stream](record-streams.md) — [all docs](../index.md)

Whether this host is healthy and what to read when it is not: the status
commands, the audit over both log trails, confinement, and the entrypoint pin.

```bash
ai-tools status              # as yourself
sudo ai-tools-admin status   # as root, the same host with the readings you cannot make
```

Both report the installed version, whether the toolchain is provisioned, every
managed systemd unit, and — per enabled agent whose package declares a release
manifest — whether a verified checksum is on record for its binary
and what the last relabel recorded for its paths. Each prints `?` where its
caller cannot reach the answer, so running the second as root fills
in the sandbox account's own `systemd --user` units, the entrypoint pin,
whether the installed binary still matches that pin, the SELinux label each
path carries now, and whether the sandbox account's own systemd unit directory
is still closed to the agent. Both exit 4 when something needs attention and 5
when a reading could not be made, so either runs from `cron` or a monitor
without its output being parsed. The exit codes are in `man ai-tools`
and `man ai-tools-admin`. The root report's Assets section, which can run long,
ends with a line naming its own findings and the status it sets:

```text
    Summary: 1 finding needs attention in this section (exit 4)
```

After the 0.24.0 upgrade that section names `successor-unenabled` until
the asset set `core` is enabled or turned
off ([ref-section-y5t4](../install/upgrade.md#ref-section-y5t4)).

## What is cleaned, and when

```text
Caches
  .npm/_cacache                OK cleaned 4.2 GiB, 9 hours ago
  .npm/_npx                    OK cleaned 22 MiB, 3 days ago
  .cache/node-compile-cache    SKIPPED (sessions), 2 hours ago -- last cleaned 5 days ago
```

The sandbox account's caches are emptied for you, and the Caches section
of both status reports shows what each last cleanup did. npm's download cache
is emptied by every toolchain update. The packages `npx` installed and node's
compile cache are in use while a session runs, so a session launch empties
them, at most once a week and only while no other session is running,
and prints one line naming what it removed. `SKIPPED (sessions)` is that rule
at work, and the next launch with no other session running cleans them.

Two lines ask you to act, and each names what to do: `FAILED`, a cleanup
that could not run or finish, and `LINKS`, a cache holding symbolic links its
producer does not write. `OVERDUE` is for your information: a cache no launch
has cleaned for two weeks, because another session was always running
or a launch could not tell whether one was. It does not change the exit status.
Where an `OVERDUE` line reads `SKIPPED (sessions)`, end every session — let
each finish, or `ai-tools stop` ends them all — and the next session start
cleans it. `sudo ai-tools-admin status` also shows how much each cache holds
now.

`sudo ai-tools audit` is the other starting point — it reads the trails
and reports what refused, was rejected, was stranded, or was flagged
over a window you give it. There are three trails, and the audit keeps them
apart on purpose: journald carries what a session itself logs, the root-only
files under `/var/log/ai-tools` carry what the privileged helpers wrote,
which is the trail the sandbox account cannot write to, and the kernel's audit
log records an agent started from inside a session. [Logs](logs.md) covers each
of them, and the per-tool-call record of what a session ran.

Confinement is optional to install and fail-closed once a host expects it.
The SELinux policy ships as its own subpackage, the launch probes the domain
transition before starting a session, and an operator can require it outright,
which turns a host without a working transition into a refused launch rather
than an unconfined one. The one case an operator meets in practice — a stale
label after a toolchain update — and its one-command fix are
on [SELinux](selinux.md).

[Entrypoint verification](entrypoint-verification.md) covers the last of these
readings: how the agent binary is checked against the checksum its vendor
signed, what the root-owned pin records, and what each failure means.
