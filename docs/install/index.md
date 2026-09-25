# Install

**Install** · [From source](from-source.md) · [Upgrade](upgrade.md) — [all
docs](../index.md)

What a host needs before the stack goes on it, what `dnf install ai-tools` puts
there, and how to reach the same result from a checkout.

The target is Enterprise Linux 9 or 10 — RHEL and its rebuilds (Rocky,
AlmaLinux, Oracle Linux/UEK) — with systemd, `sudo`, and a filesystem carrying
POSIX ACLs on the projects you claim. Other distributions are untested:
the design assumes systemd user instances with lingering, `sudo`, and EL
filesystem conventions. SELinux in enforcing mode with the targeted policy is
where the session's own domain applies; a host without it runs in a DAC-only
posture instead. The install itself needs the network once,
for `sudo ai-tools-admin system bootstrap`, which fetches the Node toolchain
and the agent; after that a systemd timer keeps both current
([Upgrade](upgrade.md)). `podman` is the one optional requirement, and only
to run the container test harness ([Tests](../tests/index.md)).

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

## Why the signing key is imported first

The packages come from a signed repository, and the release package carrying
that repository's definition is itself signed by the org key. `dnf` verifies
that signature at install time, so the key has to be on the host
before the release package is installed — the package that would otherwise
install the key has not run yet. Importing it by hand first satisfies
the check. One repository serves EL 9 and EL 10, and both the packages
and the repository metadata are signature-verified. Verify the key's
fingerprint out of band before you import it.

`ai-tools` is a metapackage pulling the full stack — the agents,
the integrations, and the toolchain. Name `ai-tools-selinux` on the same `dnf`
line: it is a `Recommends`, so a minimal image installing without weak
dependencies would otherwise come up unconfined. Drop it only for a deliberate
DAC-only deployment.

## After the packages are on

Two root commands finish the setup, and they are independent of each other:
`sudo ai-tools-admin system bootstrap` asks which installed agent this host
runs, installs the toolchain with that agent's package, and enables the update
timer, and `sudo ai-tools-admin operators add <account>` enrols an account
as an operator ([Operators](../operators/index.md)). No agent is on until you
pick one; an unattended provision passes the choice as `--agents agent-<name>`
([Agents](../agents/index.md)). Only then does a project get claimed
for that operator ([Projects](../projects/index.md)) —
`ai-tools projects create` for a new tree, which does not ask any questions
because a tree that did not exist has no permissions, secrets or history
to review, and `ai-tools projects claim` for one you already have,
which reviews all three before granting anything. The front page carries both
commands as a quick start.

[From source](from-source.md) is the manual path: the four root steps
a checkout installs with, for a host that builds rather than consumes the RPM.
[Upgrade](upgrade.md) covers moving an installed host to a new release.
