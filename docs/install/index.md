# Install

**Install** · [From source](from-source.md) — [all docs](../index.md)

What a host needs before the stack goes on it, what `dnf install ai-tools` puts
there, and how to reach the same result from a checkout.

The target is Enterprise Linux 9 or 10 — RHEL and its rebuilds — with systemd,
`sudo`, and a filesystem carrying POSIX ACLs on the projects you claim. SELinux
in enforcing mode with the targeted policy is where the session's own domain
applies; a host without it runs in a DAC-only posture instead. The install
itself needs the network once, for `sudo ai-tools-admin system bootstrap`,
which fetches the Node toolchain and the agent; after that a systemd timer
keeps both current.

Two properties hold across every install:

- **Every dependency comes from the distribution.** The base package requires
  `systemd`, `sudo`, `acl`, `python3`, `coreutils`, `policycoreutils`,
  and `shadow-utils`, all of which ship in EL. The stack is served from its own
  signed repository, every package it depends on comes from the distribution's,
  and the install does not add a `pip` or a host-level `npm` step.
- **The agent toolchain is installed into the sandbox account, not
  onto the host.** Node and the agent live under `/opt/ai-tools`, which your
  own account cannot traverse, so your `PATH` is unchanged and a second Node
  does not appear for any other user.

Each optional piece is a weak dependency, so a host installs the base and drops
what it does not want: the agent packages, the integrations, and the SELinux
policy are all `Recommends`. Naming `ai-tools-selinux` on the `dnf` command
line is what guarantees confinement on a minimal image, which installs without
weak dependencies.

The package install, the setup steps that follow it, and upgrades are
on the [front page](../../README.md). [From source](from-source.md) is
the manual path: the four root steps a checkout installs with, for a host
that builds rather than consumes the RPM.
