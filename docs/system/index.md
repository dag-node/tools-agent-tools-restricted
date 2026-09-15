# System

**System** · [Entrypoint verification](entrypoint-verification.md) — [all
docs](../index.md)

Whether this host is healthy and what to read when it is not: the status
commands, the audit over both log trails, confinement, and the entrypoint pin.

`ai-tools status` answers the question as yourself
and `sudo ai-tools-admin status` answers it as root, on the same host, adding
the readings that need root — the sandbox account's own `systemd --user` units,
the entrypoint pin, and the live SELinux label. Both report the installed
version, whether the toolchain is provisioned, the managed systemd units,
and, per enabled agent, whether its binary is pinned to a checksum its vendor
signed. Both exit non-zero when something needs attention, so either runs
from `cron` or a monitor without its output being parsed.

`sudo ai-tools audit` is the other starting point — it reads the trails
and reports what refused, was rejected, was stranded, or was flagged
over a window you give it. There are two trails, and the audit keeps them apart
on purpose: journald carries what a session itself logs, and the root-only
files under `/var/log/ai-tools` carry what the privileged helpers wrote,
which is the trail the sandbox account cannot write to.

Confinement is optional to install and fail-closed once a host expects it.
The SELinux policy ships as its own subpackage, the launch probes the domain
transition before starting a session, and an operator can require it outright,
which turns a host without a working transition into a refused launch rather
than an unconfined one.

[Entrypoint verification](entrypoint-verification.md) covers the last of these
readings: how the agent binary is checked against the checksum its vendor
signed, what the root-owned pin records, and what each failure means.
