---
paths:
  - "src/opt/ai-tools/.claude/settings.json"
---

# Claude Code settings (`settings.json`)

`settings.json` is the agent session's Claude Code configuration. It declares the
ownership hooks (covered in [ownership-and-hooks](ownership-and-hooks.rule.md)) and the
Bash-tool permission rules. This rule covers the **permission rules** and how they couple
to the SELinux policy.

## `permissions.deny` mirrors the SELinux core module's denied surface

The `deny` array lists Bash invocations the tooling refuses before running them: `sudo`,
`journalctl`, `systemctl`, and the audit CLIs (`ausearch`/`auditctl`/`aureport`). Each
names a command the SELinux **core** module (`ai_tools_t`) already denies — reading the
audit log, talking to the user/system manager, escalating through `sudo`. The list is
matched to that core surface so the agent does not spend a tool call, and emit an AVC, on
an action the kernel refuses anyway.

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

## Deferred

The deny list and optional-group enablement are kept in sync **by hand** — nothing links
`enable-group` to relaxing the matching deny entry, so a group enabled on its own has no
effect at the tooling layer. A durable fix derives the deny set from the loaded policy
groups, or has `enable-group` adjust `settings.json`, so the two layers cannot drift.
