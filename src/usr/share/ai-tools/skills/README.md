# ai-tools skills — one place, every agent

Skills are agent-agnostic content: prose that tells a coding agent how to write documentation,
how to weigh a design, what this project's conventions are. Nothing in them is specific to
Claude Code, so they are **not** stored per agent. They live once, and every agent that can read
them gets a symlink:

```text
src/usr/share/ai-tools/skills/ai-tools-*/     the source of truth, in this repo
   ──▶  /usr/share/ai-tools/skills/           pristine copy the package installs (read-only)
   ──▶  /opt/ai-tools/skills/<name>/          THE live skill, seeded once, yours to edit
   ──▶  /opt/ai-tools/.claude/skills/<name>   a symlink, per agent that reads skills
```

Edit a skill in one file and every agent sees the change. Add one and every agent gets it. No
copy is ever forked per agent — `tests/integration/perms.sh` fails if one is.

## Add a skill

1. Create `src/usr/share/ai-tools/skills/ai-tools-<name>/SKILL.md` with the frontmatter below (copy a
   sibling; the `ai-tools-` prefix is the shipped namespace and must match the `name:` field).
2. Reinstall (`sudo ./install.sh install`) or `sudo ai-tools-bootstrap`. The skill is seeded into
   `/opt/ai-tools/skills/` and linked into each agent's own skills directory.
3. Invoke it in a session as `/ai-tools-<name>`.

```yaml
---
name: ai-tools-<name>
description: When to use this skill — the agent reads this to decide.
x-ai-tools-managed: true
x-ai-tools-status: draft
x-ai-tools-version: 1
x-ai-tools-updated: 2026-07-28
---
```

Shipped now: `ai-tools-technical-docs` (the writing standard for every artifact — docs, comments,
changelogs, commit messages, runtime output), `ai-tools-engineering-principles`, and
`ai-tools-capable-systems-governance`.

A skill may be more than one file. Put supporting material in a subdirectory beside `SKILL.md` and
point at it from there — `ai-tools-capable-systems-governance/references/framework.md` is its full
normative text, kept out of `SKILL.md` so the guidance stays short and the long text is read only
when the task calls for it. The whole directory is seeded and linked as one asset.

## Agent-specific skills

A skill that only makes sense for one agent is a **real directory** in that agent's own skills
directory (`/opt/ai-tools/.claude/skills/<name>/` for Claude Code) rather than in the shared
root. A real directory always wins: the linker never displaces one, so a name that exists there stays
exactly as you left it. This is also how an agent-specific *override* of a shared skill works —
same name, real directory, no link. (The one thing that is converted to a link is an
`x-ai-tools-managed` copy that is byte-identical to the shared skill: that is the project's own
copy from the older per-agent layout, so no content is lost. An edited one is kept.)

## Versioning: stable name, RFC-draft frontmatter

A skill's invocation name never changes; its revision rides in the `SKILL.md` frontmatter shown
above, in the RFC-draft form every shipped asset shares — `x-ai-tools-managed` is the provenance
marker (this one is maintained by the project), `x-ai-tools-status` the lifecycle stage (`draft`
while it is still being refined), and `x-ai-tools-version` a monotonic integer.

A shipped skill takes one version bump per release in which it changed, along with a new
`x-ai-tools-updated`. On the
next install or bootstrap a newer version is **offered** as an update (default: keep, so Enter
leaves your copy as it is) and an unchanged one is a quiet no-op. One version is installed at a
time, so the stable name always resolves to the current text and cross-references between skills
never churn.

## Your own skills stay yours

The seeder acts on a directory only when it matches `ai-tools-*` **and** its `SKILL.md` carries
`x-ai-tools-managed: true`. Anything else — in the shared root or in an agent's directory — is
yours: left exactly as written, never claimed, never overwritten. Drop a skill of your own next
to the shipped ones and it simply works.

The shipped skills are `root:ai-tools` (files `640`, dirs `750`) and the links are root-owned
inside a setgid+sticky directory: every session reads the same text, and changing it is a
deliberate operator action through the installer. That is what makes a skill a dependable shared
convention — improve it once, and every session and every agent picks it up.

Mechanism and invariants: `.claude/rules/shipped-assets.rule.md`.
