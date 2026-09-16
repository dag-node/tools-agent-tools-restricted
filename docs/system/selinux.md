# SELinux confinement

[System](index.md) · [Logs](logs.md) · **SELinux** · [Entrypoint
verification](entrypoint-verification.md) — [all docs](../index.md)

What the optional policy adds on top of file permissions, the one case
an operator meets in practice — a stale label after a toolchain update —
and the command that clears it.

```bash
sudo ai-tools-admin system entrypoints relabel   # relabel every enabled agent's entrypoint and config directory
```

The confinement layer puts each session in its own SELinux domain,
`ai_tools_t`, on top of the file permissions that already isolate it. The RPM
ships the policy **compiled and enforcing**, so a package install loads it
without a policy toolchain; a source install compiles it instead and needs
`selinux-policy-devel`. It is a second boundary rather than the only one —
a host without it is still confined by file permissions.

## A stale label after a toolchain update

A freshly installed agent binary is born with the filesystem's default type,
so executing it does not enter the session's domain. Rather than run
the session unconfined, the launch **refuses** and says so. The post-upgrade
watcher normally relabels the new binary for you
([Upgrade](../install/upgrade.md)); when it has not, the command above is
the fix, and it is idempotent.

Two things are worth knowing before reaching for `restorecon` yourself:

- Each agent's entrypoint and config directory are labelled from rules **that
  agent's own manifest** declares,
  so `sudo ai-tools-admin system entrypoints relabel` —
  or `sudo selinux/install-selinux.sh relabel` from a checkout — applies them
  in the right order.
- A bare recursive `restorecon` over `/opt/ai-tools` can leave a hardlinked
  entrypoint mislabelled, which the next launch then refuses.

To inspect a denial:

```bash
sudo ausearch -m avc -ts recent | audit2why
```

## What the policy covers

The policy ships a core module that every session needs, plus optional groups
for the capabilities a particular workload needs. The optional groups are
off until an operator loads one:

```bash
sudo ai-tools-admin selinux groups                  # the core module and every optional group
sudo ai-tools-admin selinux groups enable <name>    # load one
```

Policy layout, the optional groups, and the bring-up loop for a new denial are
in [`selinux/README.md`](../../selinux/README.md). What the domain guarantees
and where it stops is
in [confinement](../../.claude/rules/confinement.rule.md).
