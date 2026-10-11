# Ship a skill in the base package

[Development](index.md) · [Release](release.md) · **Shipped assets** — [all
docs](../index.md)

How to add a skill or a subagent to a package of this repository, change it,
and withdraw it, so a host seeds it once and links it into every agent.

```bash
mkdir src/usr/share/ai-tools/skills/ai-tools-<name>
$EDITOR src/usr/share/ai-tools/skills/ai-tools-<name>/SKILL.md
sudo ./install.sh install
```

Most skills belong in an asset set of `dag-node/ai-tools-assets`, which a host
installs as a package and enables by name. Ship one here only where it belongs
to a package of this repository: `ai-tools-typesafe-filter` describes
the command `ai-tools-integration-typesafe` installs, so it rides
with that package.

## Add a skill

A skill is a directory named `ai-tools-<name>` holding a `SKILL.md` that starts
with this frontmatter:

```yaml
---
name: ai-tools-<name>
description: When to use this skill -- the agent reads this to decide.
x-ai-tools-managed: true
x-ai-tools-status: draft
x-ai-tools-version: 1
x-ai-tools-updated: YYYY-MM-DD
---
```

- The `ai-tools-` prefix is the shipped namespace: the directory name
  and the `name:` field carry it, so a shipped skill does not collide with one
  an operator wrote.
- `x-ai-tools-managed: true` is what lets the seeder place and update the live
  copy; a file without it is the operator's own and is left as it is.
- Supporting material sits in subdirectories beside `SKILL.md`, which points
  at it; the directory is seeded and linked whole.
- A skill a provider package ships adds `x-ai-tools-integration: <name>`,
  and is on a host only while that integration is installed
  ([ref-section-k4q2](../../.claude/rules/shipped-assets.rule.md#ref-section-k4q2)).
  The provider's package lists the directory in its `%files`, and base's
  `%files` excludes it.

A subagent is one file, `src/usr/share/ai-tools/subagents/ai-tools-<name>.md`,
with the same frontmatter.

After the install, the skill is seeded into `/opt/ai-tools/skills/` and linked
into each enabled agent's skills directory, the route the placement diagram
[ref-diagram-p2p8](../../.claude/rules/shipped-assets.rule.md#ref-diagram-p2p8)
draws; invoke it in a session as `/ai-tools-<name>`.

## Change a skill

Bump `x-ai-tools-version` and set `x-ai-tools-updated` once per release
in which the skill changed, at its first edit in that cycle. On upgrade
the seeder replaces a live copy whose version is older, so a host takes the new
text without a prompt.

## Withdraw a skill

1. Remove the directory from `src/`.
2. Add its `<kind>/<name>` to `AI_TOOLS_MANAGED_ASSETS__RETIRED`
   in `managed-assets.lib.sh`. Where an asset set takes it over, map the entry
   to its successor's identifier in `AI_TOOLS_MANAGED_ASSETS__SUCCESSORS`.
3. Repoint every reference to it: a shipped asset does not name one the project
   does not ship.

On upgrade the package moves the live copy to `/opt/ai-tools/retired/`;
what an operator then sees and runs for an entry with a successor is the 0.24.0
move ([ref-section-y5t4](../install/upgrade.md#ref-section-y5t4)). An entry
stays on the list through the 0.x line.

`tests/unit/managed-assets.sh` holds the seeder, the withdrawal
and the successor map, and parses every shipped skill's frontmatter as YAML.
The mechanism behind each step is
in [shipped-assets](../../.claude/rules/shipped-assets.rule.md).
