# Operator documentation

What an operator does with `ai-tools`: install the stack, enrol an operator,
claim a project, run an agent session in it, and reverse any of it.

A new host is set up in four steps, in this order — install the packages, enrol
the account that drives the sandbox, claim a project for it, and start
a session inside that project. Every other page here is reference for a host
that already runs.

- [About](about/index.md) — why an agent runs under its own account, and [what
  this project does not do](about/scope.md).
- [Install](install/index.md) — requirements, the `dnf` install, and what each
  package puts on a host.
- [Operators](operators/index.md) — enrolling the accounts that may launch
  a session, service accounts among them.
- [Projects](projects/index.md) — claiming a tree, what each prompt grants,
  and how every step reverses.
- [Sessions](sessions/index.md) — starting a session, what it may reach,
  and ending one that is already running.
- [Agents](agents/index.md) — which agent a session starts, and the options one
  agent takes.
- [System](system/index.md) — whether this host is healthy: status, the logs,
  SELinux, and the entrypoint pin.
- [Tests](tests/index.md) — what the suite proves, and what it needs before it
  runs.
- [Development](development/index.md) — working on the project itself:
  packaging, branches, and releases.

Three pages sit at this level, because more than one category reaches each:
[Naming conventions](naming-conventions.md) fixes which name denotes
an operator, the sandbox account, and an allowlist; [Option
spellings](option-spellings.md) maps every option onto the command it belongs
to; and [RPM packaging](rpm-packaging.md) covers the package set itself.
