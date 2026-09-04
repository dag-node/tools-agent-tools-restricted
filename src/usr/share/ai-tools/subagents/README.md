# ai-tools subagents — one place, every agent

Subagent definitions: delegate roles an agent dispatches to. They are agent-agnostic content, so
they live once and every agent that dispatches to subagents gets a symlink. Claude Code calls
them "agents" and reads them from `.claude/agents/`; this project says **subagent**, because
"agent" here means a packaged coding assistant like Claude Code itself. The manifest maps the two
(`subagents_dir=agents`), so the name is unambiguous and the product still finds its files.

## What installs where

```text
src/usr/share/ai-tools/subagents/ai-tools-*.md   the source of truth, in this repo
   ──▶  /usr/share/ai-tools/subagents/           pristine copy the package installs (read-only)
   ──▶  /opt/ai-tools/subagents/<name>.md        THE live definition, seeded once, yours to edit
   ──▶  /opt/ai-tools/.claude/agents/<name>.md   a symlink, per agent that dispatches to them
```

`install.sh` and `ai-tools` bootstrap copy each `ai-tools-*.md` here into the live control
plane as `root:ai-tools` mode `640`, under the setgid+sticky `.claude` — the agent invokes
it but cannot rewrite it. This `README.md` is source documentation only; the seed copies the
`ai-tools-*.md` agent files, never this file.

## It never touches your own agents

Every shipped agent's filename and its `name:` are prefixed `ai-tools-`. The installer acts
only on a file that matches that prefix **and** carries `x-ai-tools-managed: true` in its
frontmatter; any other agent in `/opt/ai-tools/.claude/agents/` is left untouched. An agent
you author yourself neither collides nor gets overwritten.

## Updating: stable name, version in frontmatter

```yaml
x-ai-tools-managed: true
x-ai-tools-status: draft
x-ai-tools-version: 1
x-ai-tools-updated: 2026-07-15
```

The invocation name stays stable (`ai-tools-reference-architect`); the version and date ride
in frontmatter, RFC-draft style — a monotonic `x-ai-tools-version` bumped once per release in
which the subagent changed, plus the `x-ai-tools-updated` date. On install or bootstrap a newer
shipped version is offered as an update and an unchanged one is a no-op; overwriting an existing
managed asset asks first and defaults to keep, so a copy you tuned on the host survives the
upgrade.

Mechanism and invariants: `.claude/rules/shipped-assets.rule.md`.
