---
paths:
  - "src/opt/ai-tools/.claude/settings.json"
---

# Claude Code settings (`settings.json`)

`settings.json` is the agent session's Claude Code configuration. It declares the
ownership hooks (covered in [ownership-and-hooks](ownership-and-hooks.rule.md)) and the
Bash-tool permission rules. This rule covers the **permission rules** and how they couple
to the SELinux policy.

## Permission rules — three outcomes

The two arrays sort a Bash command into one of three observable outcomes: **runs
without asking** (`allow`), **asks first** (unlisted — the default), or **refused**
(`deny`). None of this is a capability boundary — whatever runs still executes as
`SANDBOX_USER` confined by `ai_tools_t`, and a tool absent from the host simply fails
to resolve. The lists manage the **operator-visibility surface**: what is silent, what
is mediated by a prompt, and what the agent must raise with the operator in
conversation. JSON carries no comments, so the per-entry rationale lives here.

### Runs without asking (`allow`)

An entry earns its place by being **frequent** and **inspection-only**: it discloses
nothing beyond what the harness's dedicated read tools (Read/Grep/Glob) already access
without any Bash prompt, or it processes data already in hand.

**Project VCS state** — the working set every session touches:

| Entry | Why |
|---|---|
| `git status`, `git status *` | Working-tree state — the agent's most frequent check. |
| `git diff`, `git diff --staged*`, `git diff --cached*` | Pending and staged changes. Only these forms; other `git diff` arguments still prompt. |
| `git branch`, `git branch *` | Branch listing and context. The starred form also covers create/delete — accepted: branches are project-tree state the agent already fully writes. |

**Filesystem inspection and lint**:

| Entry | Why |
|---|---|
| `git log`, `git log *`, `git show`, `git show *`, `git blame *` | Project history — what changed, when, in which commit. |
| `shellcheck *`, `rpmlint *`, `yamllint *` | Lint project sources in-session instead of pushing the first lint to CI. Host-provided (EPEL packages all three on EL; `install.sh` suggests whichever the enabled repos offer, print-only — it never installs them or enables a repo). |
| `jq *` | Filter/inspect JSON already in hand (tool output, configs). |
| `ls`, `ls *`, `tree`, `tree *` | Listings with owner/mode — the ownership model's primary observable. |
| `stat *`, `getfacl *` | Per-path owner/mode/context and the collaborative-ownership ACL grants — diagnose handback and claim state ([ownership-and-hooks](ownership-and-hooks.rule.md)). |
| `head *`, `tail *`, `wc *`, `sort`, `sort *`, `uniq`, `uniq *`, `grep *` | Pipeline staples that bound and filter the output of the commands above. |
| `file *` | Identify a file's type before reading it. |

### Asks first (everything unlisted)

The default for a command in neither list — mutations (`chmod`, `git push`, …) and
one-off tools. One caveat bounds what "unlisted" buys: the harness's own command
analysis auto-approves commands it classifies as safe reads, **past both the allow list
and the prompt** (verified empirically: `df` ran silently in a session whose local
settings layers were empty, while `ls > file` in the same session prompted — the same
analysis reclassifies a redirect as a write). An unlisted safe-read therefore does
**not** reliably prompt; a read that must stay operator-visible needs a `deny` entry,
which is why the host-survey group below is denied rather than merely unlisted.

### Refused (`deny`)

Two groups with distinct criteria.

**Categorical dead-ends** — the core posture refuses these regardless of arguments or
target, so a deny stops the agent spending a tool call, and emitting an AVC, on an
action the kernel refuses anyway:

- `sudo`, `su` — SUID is inoperative under the session's `PR_SET_NO_NEW_PRIVS` (see
  below), so both fail by construction.
- `journalctl`, `systemctl` — the SELinux core module denies talking to the
  user/system manager and reading the journal.
- `ausearch`/`auditctl`/`aureport` — the core module denies the audit surface.
- `dnf`, `yum` — package management is the `pkgmgmt` optional group, disabled by
  default; with it off the core module refuses the package-manager stack.
- `mount *`, `umount` — mounting needs `CAP_SYS_ADMIN`, and `RestrictNamespaces=yes`
  closes the user-namespace route to it. (Bare `mount` succeeds — it lists the mount
  table — so it is denied with the host-survey group below instead.)
- `setenforce`/`semodule`/`semanage` — root-only SELinux management; label repair flows
  through the root-side relabel path, never the agent.

`sudo` is the purest case: it is structurally inoperative under the session's
`PR_SET_NO_NEW_PRIVS`, which drops the SUID bit (see [confinement](confinement.rule.md)),
so its deny entry corresponds to a capability no policy change can restore — pure noise
suppression. A command that fails only situationally does not belong in this group (see
Why not).

**Host-survey queries** — these **succeed** but disclose system state beyond the
file-read baseline, and the harness's safe-read auto-approval means an unlisted one runs
silently (see "Asks first"). `deny` is the one settings layer that overrides that
auto-approval, so the set ships denied. This is stronger mediation than a prompt, not
weaker: the agent that genuinely needs one must ask the operator in conversation, with
its reasoning, instead of the operator approving a bare command string. A host that
wants one silent removes the deny entry in its settings layer.

| Entry | What it discloses |
|---|---|
| `id`, `id *`, `getent *` | Account and group enumeration — NSS can reach a directory service (sssd/LDAP), beyond local file reads. |
| `rpm`, `rpm *` | Installed-package inventory — a classic reconnaissance target (the write forms fail as non-root anyway). |
| `ps`, `ps *` | Host-wide process survey. |
| `df`, `df *`, `du`, `du *`, `mount` | Mount/storage topology and tree-size surveys. |
| `readlink *` | Runtime layout via `/proc` magic links; benign in-project symlink inspection is covered by the allowed `ls -l`. |
| `getenforce`, `matchpathcon *` | Security-posture probing — whether enforcement is on, which labels are expected. When diagnosing confinement *with* the operator, the operator runs them or relaxes the entry. |

This layer is a **tooling hint, not a boundary.** The enforced isolation is SELinux type
enforcement plus DAC (see [confinement](confinement.rule.md)); a `deny` entry only keeps
the agent from attempting a denied action. Removing an entry re-exposes the attempt to the
SELinux floor — it does not by itself grant the capability.

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
  "safe subset" like `chmod +x *` out of `allow`: the allow list stays inspection-only
  so its criterion stays crisp.
- **Filtering `allow` to the host's installed tools** (at install or after): an entry for
  an absent tool is inert — the command fails to resolve — and *removing* it makes the
  interaction worse (the operator gets prompted for a tool that then fails anyway). A
  filtered file also drifts from the package (`rpm -V` flags the root-of-trust file), goes
  stale the moment an admin installs a tool afterwards, and the keep-existing install
  prompt then preserves the stale filter across reinstalls. Host- or project-specific
  tuning layers **additively** via Claude Code's settings merge; the shipped baseline
  stays byte-identical on every host.
- **Leaving the host-survey reads unlisted (or allowing them) instead of denying**: no
  capability is at stake either way (DAC + `ai_tools_t` decide), but "unlisted" does not
  mean "prompted" — the harness's safe-read analysis auto-approves them silently (see
  "Asks first"), and allowing them would make that silence official. Only a deny keeps
  reconnaissance-shaped queries operator-mediated, by forcing the agent to ask in
  conversation.

## Deferred

The deny list and optional-group enablement are kept in sync **by hand** — nothing links
`enable-group` to relaxing the matching deny entry, so a group enabled on its own has no
effect at the tooling layer. A durable fix derives the deny set from the loaded policy
groups, or has `enable-group` adjust `settings.json`, so the two layers cannot drift.
