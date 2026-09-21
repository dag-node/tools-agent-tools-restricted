# System

**System** · [Logs](logs.md) · [SELinux](selinux.md) · [Entrypoint
verification](entrypoint-verification.md) — [all docs](../index.md)

Whether this host is healthy and what to read when it is not: the status
commands, the audit over both log trails, confinement, and the entrypoint pin.

```bash
ai-tools status              # as yourself
sudo ai-tools-admin status   # as root, the same host with the readings you cannot make
```

Both report the installed version, whether the toolchain is provisioned, every
managed systemd unit, and — per enabled agent whose package declares a release
manifest — whether a verified checksum is on record for its binary and what
the last relabel recorded for its paths. Each prints `?` where its caller
cannot reach the answer, so running the second as root fills in the sandbox
account's own `systemd --user` units, the entrypoint pin, whether the installed
binary still matches that pin, and the SELinux label each path carries now.
Both exit non-zero
when something needs attention, so either runs from `cron` or a monitor without
its output being parsed. The exit codes are in `man ai-tools`
and `man ai-tools-admin`.

`sudo ai-tools audit` is the other starting point — it reads the trails
and reports what refused, was rejected, was stranded, or was flagged
over a window you give it. There are three trails, and the audit keeps them
apart on purpose: journald carries what a session itself logs, the root-only
files under `/var/log/ai-tools` carry what the privileged helpers wrote,
which is the trail the sandbox account cannot write to, and the kernel's audit
log records an agent started from inside a session. [Logs](logs.md) covers
each of them, and the per-tool-call record of what a session ran.

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
