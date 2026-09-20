# Operators

**Operators** · [Service accounts](service-accounts.md) — [all
docs](../index.md)

Who may launch an agent session on a host, what enrolling an account records,
and how one operator claims a project on another's behalf.

An operator is two facts, and `sudo ai-tools-admin operators add <name>` writes
both: membership of the `ai-ops` group, which the sudoers rules and the launch
wrapper check, and a name in `OPERATORS` in `/etc/ai-tools/operator.conf`,
from which each path's owner is resolved. An account holding the group
and the entry runs sessions on the projects claimed for it. `operators list`
reports who is enrolled, and `operators remove` reverses the enrolment.

Claiming is a separate authority. Claim, unclaim, lockdown, reclaim,
and sandbox-create reach root helpers that carry no passwordless rule, so each
also needs a general `sudo` grant — a third axis this project does not install,
does not record, and cannot infer from the other two. **A host needs at least
one operator holding that grant**, because without one no project can be
claimed on it by anyone, root included: every mutating command refuses root,
to keep an operator's registries out of root's ownership. That operator
provisions, and the others run sessions on what it claimed for them.

Operators are trusted with respect to each other. One operator can write
an entry into another's allowlist with `ai-tools --for <operator>`, which is
what makes a passwordless account usable: a human claims the project,
and the account runs the session. Every such mutation is logged with both
the caller and the target.

[Service accounts](service-accounts.md) is the worked case — enrolling
`svc-ci`, claiming for it, and the commands that take `--for`.
