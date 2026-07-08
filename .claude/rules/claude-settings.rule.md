---
paths:
  - "src/opt/ai-tools/.claude/settings.json"
---

# Claude Code settings (`settings.json`)

`settings.json` is the agent session's Claude Code configuration. It declares the
ownership hooks (covered in [ownership-and-hooks](ownership-and-hooks.rule.md)) and the
Bash-tool permission rules. This rule covers the **permission rules** and how they couple
to the SELinux policy.

## `permissions.allow` — three tiers, two shipped

The `allow` array pre-approves Bash invocations so routine checks cost no permission
prompt. JSON carries no comments, so the per-entry rationale lives here. Entries are
grouped in three hardening tiers; the shipped `settings.json` carries tiers 1 and 2,
tier 3 is a documented opt-in. No tier is a capability boundary — an allowed command
still runs as `SANDBOX_USER` confined by `ai_tools_t`, and a tool absent from the host
simply fails to resolve. What the tiering manages is the **prompt surface**: which
actions are silent and which remain operator-visible.

### Tier 1 — minimal: project VCS state

| Entry | Why |
|---|---|
| `git status`, `git status *` | Working-tree state — the agent's most frequent check. |
| `git diff`, `git diff --staged*`, `git diff --cached*` | Pending and staged changes. Only these forms; other `git diff` arguments still prompt. |
| `git branch`, `git branch *` | Branch listing and context. The starred form also covers create/delete — accepted: branches are project-tree state the agent already fully writes. |

### Tier 2 — recommended: nothing beyond the harness read baseline

Criterion: the command discloses only file content/metadata that the harness's dedicated
read tools (Read/Grep/Glob) already access **without any Bash prompt**, or processes data
already in hand — pre-approving it adds no disclosure surface the session does not
already have.

| Entry | Why |
|---|---|
| `git log`, `git log *`, `git show`, `git show *`, `git blame *` | Project history — what changed, when, in which commit. |
| `shellcheck *`, `rpmlint *`, `yamllint *` | Lint project sources in-session instead of pushing the first lint to CI. Host-provided (EPEL packages all three on EL; `install.sh` suggests whichever the enabled repos offer, print-only — it never installs them or enables a repo). |
| `jq *` | Filter/inspect JSON already in hand (tool output, configs). A shell redirect can write a file — no new capability; the Write tool already writes freely. |
| `ls`, `ls *`, `tree`, `tree *` | Listings with owner/mode — the ownership model's primary observable. |
| `stat *`, `getfacl *` | Per-path owner/mode/context and the collaborative-ownership ACL grants — diagnose handback and claim state ([ownership-and-hooks](ownership-and-hooks.rule.md)). |
| `head *`, `tail *`, `wc *`, `sort`, `sort *`, `uniq`, `uniq *`, `grep *` | Pipeline staples that bound and filter the output of the commands above. |
| `file *` | Identify a file's type before reading it. |

### Tier 3 — extended: host-state queries (documented, NOT shipped)

Criterion: the command queries system state through an interface **beyond** the file-read
baseline. Project work rarely needs these, so their permission prompt is kept as a
**tripwire**: the first prompt for one is a human-visible tell that the agent pivoted
from project work to host survey — the shape of prompt-injection-driven reconnaissance.
A host that wants any of them silent opts in by adding the entry to
`/opt/ai-tools/.claude/settings.json` (or additively in a project settings layer).

| Entry | What it discloses |
|---|---|
| `id`, `id *`, `getent *` | Account and group enumeration — NSS can reach a directory service (sssd/LDAP), beyond local file reads. |
| `rpm -q*` | Installed-package inventory (query forms only) — a classic reconnaissance target. |
| `ps`, `ps *` | Host-wide process survey. |
| `df`, `df *`, `du *` | Mount/storage topology and tree-size survey of arbitrary paths. |
| `readlink *` | Runtime layout via `/proc` magic links. |
| `getenforce`, `matchpathcon *` | Security-posture probing — whether enforcement is on, which labels are expected. Useful when diagnosing confinement *with* the operator; approve per-call then. |

## `permissions.deny` mirrors the SELinux core module's denied surface

The `deny` array lists Bash invocations the tooling refuses before running them. Each
names a command the core posture refuses **categorically** — regardless of arguments or
target — so the agent does not spend a tool call, and emit an AVC, on an action the
kernel refuses anyway:

- `sudo`, `su` — SUID is inoperative under the session's `PR_SET_NO_NEW_PRIVS` (see
  below), so both fail by construction.
- `journalctl`, `systemctl` — the SELinux core module denies talking to the
  user/system manager and reading the journal.
- `ausearch`/`auditctl`/`aureport` — the core module denies the audit surface.
- `dnf`, `yum` — package management is the `pkgmgmt` optional group, disabled by
  default; with it off the core module refuses the package-manager stack.
- `mount *`, `umount` — mounting needs `CAP_SYS_ADMIN`, and `RestrictNamespaces=yes`
  closes the user-namespace route to it. Bare `mount` stays undenied: it only lists the
  mount table (a tier-3-shaped disclosure, so it still prompts — see `allow` above).
- `setenforce`/`semodule`/`semanage` — root-only SELinux management; label repair flows
  through the root-side relabel path, never the agent.

The criterion is *categorical*: a command that fails only situationally does not belong
here (see Why not).

This layer is a **tooling hint, not a boundary.** The enforced isolation is SELinux type
enforcement plus DAC (see [confinement](confinement.rule.md)); a `deny` entry only keeps
the agent from attempting a denied action. Removing an entry re-exposes the attempt to the
SELinux floor — it does not by itself grant the capability.

`sudo` is a special case: it is structurally inoperative under the session's
`PR_SET_NO_NEW_PRIVS`, which drops the SUID bit (see [confinement](confinement.rule.md)),
so its deny entry corresponds to a capability no policy change can restore — it is pure
noise suppression.

## Coupling to optional SELinux groups

The deny list is matched to the **core** policy alone. Enabling an optional SELinux group
(`install-selinux.sh enable-group <name>` — `systemd`, `pkgmgmt`, `netadmin`, `podman`,
all disabled by default; see [confinement](confinement.rule.md)) widens what `ai_tools_t`
may do, but a `deny` entry here still blocks the matching command **before** SELinux is
consulted. A capability a group newly grants stays unreachable until its deny entry is
relaxed in the same change.

For example, enabling the `systemd` group so the agent can drive its own services has no
effect while `Bash(systemctl*)` and `Bash(journalctl*)` remain in `deny`: the tool
refuses the command first. An operator who enables a group relaxes the corresponding deny
entry alongside it. The audit CLIs map to no optional group today; granting them needs a
new policy module, and the same relax-the-deny-entry step applies.

## Control-plane integrity

`settings.json` is root-owned (`root:SANDBOX_GROUP`, no group write) and lives under
the setgid+sticky `.claude` directory, so the agent cannot edit or replace it from inside
a session (see [ownership-and-hooks](ownership-and-hooks.rule.md)). The deny rules and the
hook declarations hold for the whole session.

## Why not

- **Denying `chmod`/`chown` and other target-dependent refusals**: they succeed on
  agent-owned files (the routine case — making a generated script executable) and fail
  only on operator-owned ones; a deny rule matches the command string, not the target's
  owner, so it would break the valid majority to suppress an occasional EPERM — and that
  EPERM is informative (it names the file as the operator's; the agent asks instead of
  retrying). A deny here also reduces no surface: mode changes are reachable through
  `install -m`, `cp -p`, `setfacl`, `os.chmod`, …, and the abuse-shaped forms
  (`777`/`o+w`/`+s`) are already reverted by the handback's world-bit stripping while
  setuid on a sandbox-owned file escalates nothing. The same reasoning keeps a
  "safe subset" like `chmod +x *` out of `allow`: the tiers stay inspection-only so
  their criterion stays crisp.
- **Filtering `allow` to the host's installed tools** (at install or after): an entry for
  an absent tool is inert — the command fails to resolve — and *removing* it makes the
  interaction worse (the operator gets prompted for a tool that then fails anyway). A
  filtered file also drifts from the package (`rpm -V` flags the root-of-trust file), goes
  stale the moment an admin installs a tool afterwards, and the keep-existing install
  prompt then preserves the stale filter across reinstalls. Host- or project-specific
  tuning layers **additively** via Claude Code's settings merge; the shipped baseline
  stays byte-identical on every host.
- **Shipping tier 3 by default**: no capability is at stake either way (DAC + `ai_tools_t`
  decide), but pre-approving host-state queries would silence the one human-visible
  tripwire for reconnaissance-shaped behaviour, for marginal convenience in sessions that
  rarely need those commands.

## Deferred

The deny list and optional-group enablement are kept in sync **by hand** — nothing links
`enable-group` to relaxing the matching deny entry, so a group enabled on its own has no
effect at the tooling layer. A durable fix derives the deny set from the loaded policy
groups, or has `enable-group` adjust `settings.json`, so the two layers cannot drift.
