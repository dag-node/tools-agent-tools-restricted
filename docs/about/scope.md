# The boundary, and what is out of scope

[About](index.md) · **Scope** — [all docs](../index.md)

Where the enforced boundary sits, why the allowlist is not that boundary,
what the confinement stops covering, and the three cases this project leaves
out.

The enforced isolation boundary is ordinary file permissions plus
the `ai_tools_t` SELinux type. Once a session runs as `ai-tools`, those decide
which files it can open — the same boundary the kernel draws between any two
accounts on the host.

## The allowlist gates a launch, not a read

`~/.config/ai-tools/allowed-projects` decides where a session may start
and which written files get ownership handed back. It does not decide
what a running session may read. The directory you launch in is canonicalized
before it is matched, so a symlink or a `..` resolves to its real target
and cannot slip a path past the gate; past the gate, file permissions govern.

That is why every flow granting the agent access locks secret-named files
down first, and why declining a lockdown stops the claim
([Lockdown](../projects/lockdown.md)). A per-session `bubblewrap` mount
namespace, which would make the allowlist a read boundary too, is proposed
rather than built.

## Code the agent wrote runs as you

The confinement bounds the agent while it runs. It does not make what the agent
left behind safe to execute: a build script, a git hook, a test fixture
or a built artifact in a claimed project runs as you, unconfined, the moment
you build or run that project. Review a change before you run it, as you would
a patch from anyone else.

Restricting one path does not help here, because the set of files you
eventually execute is the project itself — so the control is review rather than
permissions. The trees the sweeps skip (`.git`, `node_modules`, `.venv`) do not
carry an ownership signal worth trusting either: regenerate them instead
of adopting what is there.

## Out of scope by design

These are scope decisions rather than gaps, so a reader can tell bounded design
from an oversight:

- **All operators share one sandbox account.** Ownership of a project returns
  to the operator that project was claimed for, and two sessions running
  under that one account are not kernel-isolated from each other. The scratch
  state a session keeps outside the project is shared between them.
- **Operators are trusted.** The model defends the host and its other users
  from the *agent*, not from an operator, who already holds the launch grant.
  `ai-tools projects claim --for <operator>` rests on that: one operator writes
  an entry into another's allowlist, so a human can claim a project
  for a passwordless service account ([Service
  accounts](../operators/service-accounts.md)).
- **The npm registry's signing key is not pinned.** Each toolchain update
  verifies the published checksums and the registry signatures and fails closed
  on a mismatch, which answers a tampered download; a fully compromised
  registry is the case pinning would answer, and it is deferred.

The full trust model, the non-goals, and the deferred hardening are
in [ref-section-x6a9](../../CLAUDE.md#ref-section-x6a9).
