# SELinux confinement

[System](index.md) · [Logs](logs.md) · **SELinux** · [Entrypoint
verification](entrypoint-verification.md) · [Reading a record
stream](record-streams.md) — [all docs](../index.md)

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

## What a launch requires

```bash
sudo sed -i 's/^#\?AI_TOOLS_REQUIRE_SELINUX=.*/AI_TOOLS_REQUIRE_SELINUX=no/' /etc/ai-tools/operator.conf   # declare a DAC-only host
```

A launch requires the confinement by default: SELinux enforcing, the policy
loaded, the session's domain enforced, and the Booleans listed
in `AI_TOOLS_SELINUX_BOOLEANS` at the values the list names. A host that has
the policy and has drifted from any of that — permissive mode, a module
installed and not loaded, a Boolean switched on — refuses the launch and names
the fix. A host that has no confinement by its own configuration, SELinux
disabled or the policy never installed, launches with file permissions alone
and warns at every launch until `AI_TOOLS_REQUIRE_SELINUX=no` declares
that on purpose. The requirement is in force while the key is absent, so only
an explicit `no` turns it off. Every option is
in [`ai-tools-operator.conf(5)`](../../src/usr/local/share/man/man5/ai-tools-operator.conf.5).

The supported host runs the **targeted** policy on Enterprise Linux 9 or 10
with operators logging in unconfined, the EL default. The policy grants
the operator's access to claimed projects through an attribute,
`ai_tools_operator_domain`, with `unconfined_t` as its shipped member,
so a host that confines its operators to a login domain of their own —
`staff_t`, `user_t`, or a site-written domain — can add that domain
to the attribute and give it the same file access. Launching a session
from such a login is not validated yet: the launch path is measured
for unconfined logins only, and a read denied there refuses the launch instead
of running the session unconfined. An `ai-tools-admin selinux` command
that declares the domain is planned.

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

## Denials a healthy session raises <a id="ref-section-g7c5"></a>

A session logs a few refusals that do not need any action. Each is a probe
a tool makes and answers another way, so the command you ran still succeeded:

```bash
sudo ausearch -m avc -su ai_tools_t -ts recent    # what a session was refused
```

- **The login shell asks the host its name.** `/etc/profile` tries
  `hostnamectl`, then `hostname`, then `uname -n`. The first two are refused
  and the third answers. Three records when a session starts, and none
  per command after that.
- **A search walks out of the project.** `ripgrep` reads the `.gitignore` file
  of every parent directory of the one it is searching, and a parent in your
  home is outside what a session may read. The search still honours
  the project's own ignore rules.
- **A file copy sets its own label.** `install` labels the file it just
  created; the label it asks for is the one the file already has, so the copy
  exits 0.
- **Codex watches for changes under its home.** A Codex session arms
  a filesystem watch on the sandbox account's home directory when it starts,
  and is refused. Nothing in a turn waits on that watch.

What does not belong on this list is a refusal that **stopped** you: a tool
call that failed. Read that against [what the policy
covers](#what-the-policy-covers), and raise it if it looks like a gap
in the policy and not a boundary it draws.

## What the policy covers

The policy ships a core module that every session needs, plus optional groups
for the capabilities a particular workload needs. The optional groups are
off until an operator loads one:

```bash
sudo ai-tools-admin selinux groups                  # the core module and every optional group
sudo ai-tools-admin selinux groups enable <name>    # load one
```

### The `tmpmap` group and the `domain_can_mmap_files` Boolean

```bash
sudo ai-tools-admin selinux groups enable tmpmap   # let a session memory-map its own temporary files
```

A .NET restore memory-maps files it creates under `/tmp`, and a session is
refused that until the `tmpmap` group is loaded. The SELinux Boolean
`domain_can_mmap_files` would allow it too, but for every process on the host
and every file type, so the two look related and are not interchangeable: load
the group and leave the Boolean off. A launch refuses while that Boolean is
on, unless `AI_TOOLS_SELINUX_BOOLEANS` declares it,
as [`ai-tools-operator.conf(5)`](../../src/usr/local/share/man/man5/ai-tools-operator.conf.5)
describes. A mistake in that list — a misspelled Boolean, a value that is not
`on` or `off` — costs a launch, never confinement: the launch refuses until
the line is fixed, and no entry in it changes a Boolean on the host.

Policy layout, the optional groups, and the bring-up loop for a new denial are
in [`selinux/README.md`](../../selinux/README.md). What the domain guarantees
and where it stops is
in [confinement](../../.claude/rules/confinement.rule.md).
