# Naming conventions — user/group/home identities

This codebase coordinates several distinct identities that a bare "user" would
conflate: an operator that drives the sandbox, that operator's group or home, the
operator a given path's ownership resolves to, the unprivileged sandbox service
account the agent runs as, and the generic POSIX notion of any host user. This file
is the single source of truth for which name denotes which identity, so a reader can
tell from the name alone which one is meant. Every functional identifier and every
reference in prose MUST use exactly one of these.

## The identities

### Operators — the login accounts that drive the sandbox

The login accounts that own projects and drive the sandbox through the one shared
sandbox account. A host has one or more; typically a human plus rootless service
accounts (e.g. a CI runner). They are the **operators**: listed in
`/etc/ai-tools/operator.conf` (`OPERATORS="alice bob svc-ci"`) and members of the
`ai-ops` group. Each owns the project trees in its own approved-projects allowlist.
Deliberately **not** "human user": an operator may be an automation. They share the
sandbox account's agent state and reach — a trusting team, no kernel isolation between
their sessions.

| Facet | Shell variable | Prose term |
|-------|----------------|------------|
| the list | `AI_TOOLS_OPERATORS` (array) | "the operators" |
| operators group | literal `ai-ops` | "the operators group" / `ai-ops` |

Being an operator is those two facts and nothing else: `ai-ops` membership and a name in
`OPERATORS`. **A general sudo grant is a separate host-level axis, not part of the term** — the
host's own sudoers decides it, and this project neither writes nor records it. Both shapes are
operators, and prose distinguishes them by naming the grant rather than by inventing a role:

- an operator **with** a general sudo grant claims and unclaims projects, locks down secrets, and
  reclaims files — the verbs whose root helpers carry no NOPASSWD rule. A host needs at least one
  (root cannot substitute; see the security model in `CLAUDE.md`), and it may be a purpose-made
  provisioning account rather than a person.
- an operator **without** one launches sessions and reads the reports. Projects are claimed for it
  by the first shape, with `ai-tools --project-claim --for <operator>`. A passwordless service
  account that runs an agent is this shape, and "service account" describes its intent — the host
  records nothing that distinguishes it from any other grant-less operator.

`operator.conf` is managed in place at runtime by `ai-tools-admin operators add|remove`. Its
source template carries one substitution token, `OPERATORS="@PROJECTS_USER@"`, and the two
install paths treat it differently: the RPM rewrites the line to `OPERATORS=""` at build
(`packaging/ai-tools.spec`), so a packaged host ships with nobody enrolled, while `install.sh`
substitutes the one operator it enrols — the account named at its prompt, defaulting to the
invoking `SUDO_USER`. **Nothing else about an operator is substituted** — home and primary group
are derived per name at runtime via `getent`/`id`, so a name added to the list takes effect
without touching any other file.

### The owner — the operator a path resolves to

The sandbox restores an agent-written file to the operator that **owns** it: the operator
whose allowlist covers the path (when several do, the nearest ancestor directory's on-disk
owner wins). `operator.lib.sh` resolves an operator into the `PROJECTS_*` globals:

| Facet | Shell variable | Prose term |
|-------|----------------|------------|
| the resolved operator | `PROJECTS_USER` | "the owner" / "the operator" |
| its home dir | `PROJECTS_HOME` | "the owner's home" |
| its primary/private group | `PROJECTS_GROUP` | "the owner's group" |
| its numeric uid | `PROJECTS_UID` | — |

- `ai_tools_resolve_owner <path>` sets them to the **owner of that path** — the handback
  helpers that restore ownership use this.
- `ai_tools_load_operator` sets them to the **primary operator** (`OPERATORS[0]`) — for the
  components that need "an operator" rather than a per-path owner (the launch path, the CLI,
  the symlink/relabel helpers).

The owner's private group is always written `PROJECTS_USER:PROJECTS_GROUP`. Do not spell it
`PROJECTS_USER:PROJECTS_USER` even though RHEL User-Private-Groups make the two coincide.

### The invoker and the acting operator — who ran a command, and for whom

`ai-tools --for <operator>` separates two identities the other components never tell apart: a
root helper resolves the owner from the path it is handed, while the CLI decides before there is
a path. Both names live in `ai-tools.sh` alone.

| Facet | Shell variable | Prose term |
|-------|----------------|------------|
| the account that ran the command | `INVOKING_USER` | "the invoking user" |
| the `--for` target, empty without the flag | `FOR_OPERATOR` | "the target operator" |
| the operator the run acts for | `OWNER_USER` / `OWNER_GROUP` | "the acting operator" |

`OWNER_USER` is `FOR_OPERATOR` where the flag is given and `INVOKING_USER` otherwise. Every
message naming the account a file ends up with, and every scan matching on that account, reads
`OWNER_USER`; the gates deciding who may run a verb read `INVOKING_USER`.

`INVOKING_USER` denotes a host account rather than an operator: the informational verbs stay open
to a user absent from `OPERATORS`, and root reaches the read-only reports.

Both are distinct from `PROJECTS_USER` above, which a root helper resolves per path from the
allowlist covering it. The CLI sets neither of the `PROJECTS_*` globals, and a `--for` run leaves
that resolution alone — a helper's walk still resolves each path's own owner.

### Sandbox user — the unprivileged service account the agent runs as

The dedicated, no-login system account (`ai-tools`) that Claude Code executes
as. Owns nothing of an operator's; holds no sudo rights and is not in `ai-ops`.

| Facet | Shell variable | Install-time token | Prose term |
|-------|----------------|--------------------|------------|
| account | `SANDBOX_USER` | `@SANDBOX_USER@` | "the sandbox user" |
| group | `SANDBOX_GROUP` | `@SANDBOX_GROUP@` | "the sandbox group" |

`@SANDBOX_USER@`/`@SANDBOX_GROUP@` substitute to `ai-tools` at install time, so
the account name is a config knob in owner strings (`OWNER`, `EXPECTED_OWNER`,
`sudo -u`, etc.). The literal `ai-tools` is **retained** in identifiers that are
not the account itself and are coupled to other contracts:

- filesystem paths — `/opt/ai-tools`, `~/.config/ai-tools`
- SELinux types and modules — `ai_tools_t`, `ai_tools_conf_t`, `ai_tools.te`, …
- root-helper binary names — `ai-tools-chown`, `ai-tools-lockdown`,
  `ai-tools-launcher-symlink`

Renaming those would break paths, policy, and the sudoers grant; they stay
literal regardless of `SANDBOX_USER`.

### Role aliases built from the above

Both are built at runtime from the resolved owner (`PROJECTS_USER` = the owner of the
path being acted on), not from a build-time token:

- `OWNER = PROJECTS_USER:SANDBOX_GROUP` — owner restored on agent-written, non-secret
  paths (the owner via the owner bits, the sandbox user via the group bits).
- `SECRET_OWNER = PROJECTS_USER:PROJECTS_GROUP` — owner a quarantined secret is locked to
  at mode `600` (owner-only; revokes the sandbox user's read).

### No cross-group membership

No operator is a member of the sandbox group, and the sandbox user is in no operator's
group. The `PROJECTS_USER:SANDBOX_GROUP` ownership split is what makes that unnecessary:
on a restored path the owner accesses it through the **owner** bits and the sandbox user
through the **group** bits. This keeps each side to one permission tier and avoids granting
an operator blanket read of the sandbox group's files (e.g. `.claude` session state).

The sandbox user is also **not** in `ai-ops`, so it cannot hold the operators' sudoers
grant; `ai-tools-run` refuses to launch if that is ever violated.

## Agent vs subagent

Two different things are called "agent" in this space, so this project fixes the vocabulary:

- **agent** — a packaged coding assistant that runs confined in the sandbox: Claude Code today.
  It is what `ai-tools-agents-*` packages ship, what `agents.d/<name>.conf` describes, what
  `operator.conf AI_TOOLS_AGENTS` enables, and what `ai-tools --providers` lists.
- **subagent** — a delegate role definition an agent reads and dispatches to (the
  `ai-tools-reference-architect` markdown file). Shared across agents, so it lives in
  `/opt/ai-tools/subagents` beside `skills`.

Claude Code calls the second one "agents" and reads them from `<config dir>/agents/`. That is the
vendor's layout, not our vocabulary: the manifest maps between them (`subagents_dir=agents`), so
our name is unambiguous and the product still finds its files where it expects. Use "subagent"
in prose, in path names, and in identifiers everywhere this project controls the name.

## Generic / fixed terms that are NOT these identities

### Generic host user (`src/usr/local/lib/ai-tools/path-dedup.sh`)
"user", "user-tier", "user-writable", and the `~`-relative tiers refer to
**any** account wired to source the PATH dedup fragment — not the IDE user
and not the sandbox user. Left as generic "user"; the tiers resolve against
the sourcing shell's own `$HOME`.

### Fixed external identifiers — never renamed
- SELinux types/concepts: `user_home_t`, `user_home_dir_t`, `user_tmp_t`,
  `unconfined_u`, `semanage user/login` ("SELinux-user").
- `git config user.email`; the `useradd` command; systemd `--user` /
  `journalctl --user`; `unshare --user` / `create_user_ns`; `$USER`, `$HOME`,
  `loginctl`.

### Test assertion fields (`test.sh`)
`exp_owner`/`act_owner` plus `*_group`/`*_mode` are the **file's** owner/group/mode
from `stat`, parametrized — not an identity.
