# Operator documentation

What an operator does with `ai-tools`: install the stack, enrol an operator,
claim a project, run an agent session in it, and reverse any of it.

A new host is set up in four steps, in this order — install the packages, enrol
the account that drives the sandbox, claim a project for it, and start
a session inside that project. Every other page here is reference for a host
that already runs.

- [About](about/index.md) — why an agent runs under its own account.
  - [Scope](about/scope.md) — where the enforced boundary sits, and what this
    project does not do.
- [Install](install/index.md) — requirements, the `dnf` install, and what each
  package puts on a host.
  - [From source](install/from-source.md) — the manual install from a checkout,
    without the RPM.
  - [Upgrade](install/upgrade.md) — upgrading with `dnf`, and what the daily
    toolchain update does to a running session.
- [Operators](operators/index.md) — enrolling the accounts that may launch
  a session, service accounts among them.
  - [Service accounts](operators/service-accounts.md) — an operator without
    a password, and claiming projects for it with `--for`.
- [Projects](projects/index.md) — claiming a tree, what each prompt grants,
  and how every step reverses.
  - [Create](projects/create.md) — a new directory, claimed from the start.
  - [Claim](projects/claim.md) — register a tree you already have,
    and what each question grants.
  - [Clone](projects/clone.md) — a shallow clone under the sandbox area,
    with the history out of reach.
  - [Push](projects/push.md) — send a clone's commits to the branch it tracks.
  - [List](projects/list.md) — what each line of the project registry is,
    and the cleanup it suggests.
  - [Disable](projects/disable.md) — park a project so no session starts there.
  - [Enable](projects/enable.md) — lift a disable.
  - [Unclaim](projects/unclaim.md) — take the agent's access away and keep
    the files.
  - [Remove](projects/remove.md) — unregister a project and delete its
    directory.
  - [Lockdown](projects/lockdown.md) — keep secret-named files
    out of the agent's reach.
  - [Handback](projects/handback.md) — return what the agent wrote to you,
    on demand.
  - [Permissions](projects/permissions.md) — who owns a file the agent wrote,
    and how you both keep write access.
- [Sessions](sessions/index.md) — starting a session, what it may reach,
  and ending one that is already running.
  - [Stop](sessions/stop.md) — terminate every running session and what it
    spawned.
  - [Decide](sessions/decide.md) — hand a long listing to TypeSafe,
    and what a call sends off the host.
- [Agents](agents/index.md) — which agent a session starts, and the options one
  agent takes.
  - [Claude Code](agents/claude-code.md) — the settings and environment
    variables that shape a session.
  - [Codex](agents/codex.md) — what the package adds, turning it
    on, and the files you may edit.
  - [Setting names](agents/setting-names.md) — settings whose names say
    the opposite of what they do.
- [System](system/index.md) — whether this host is healthy: status, the logs,
  SELinux, and the entrypoint pin.
  - [Logs](system/logs.md) — the command that answers whether anything went
    wrong, and the two sinks behind it.
  - [SELinux](system/selinux.md) — what the policy adds, and the stale label
    after a toolchain update.
  - [Entrypoint verification](system/entrypoint-verification.md) —
    how the agent binary is proved to be the vendor's.
  - [Reading a record stream](system/record-streams.md) — the rows a report
    writes for a program to read.
- [Tests](tests/index.md) — what the suite proves, and what it needs before it
  runs.
- [Development](development/index.md) — working on the project itself:
  packaging, branches, and releases.
  - [Release](development/release.md) — from a feature branch to a signed RPM.
  - [Shipped assets](development/shipped-assets.md) — add, change or withdraw
    a skill or a subagent a package ships.

Three pages sit at this level, because more than one category reaches each:
[Naming conventions](naming-conventions.md) fixes which name denotes
an operator, the sandbox account, and the project registry; [Option
spellings](option-spellings.md) maps every option onto the command it belongs
to; and [RPM packaging](rpm-packaging.md) covers the package set itself.

---

*Something missing or wrong on these pages? [Open
an issue](https://github.com/dag-node/tools-agent-tools-restricted/issues/new/choose)
— reports and suggestions need no CLA. Security issues go to [private
reporting](https://github.com/dag-node/tools-agent-tools-restricted/security/policy)
only.*
