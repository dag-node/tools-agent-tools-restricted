# ai-tools agents

Subagent definitions the installer provisions into the sandbox account, so the sandboxed
agent can invoke them on any project you launch it in.

## What installs where

```text
src/opt/ai-tools/.claude/agents/ai-tools-*.md  ──▶  /opt/ai-tools/.claude/agents/
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
in frontmatter, RFC-draft style — a monotonic `x-ai-tools-version` bumped on every change,
plus the `x-ai-tools-updated` date. On install or bootstrap a newer shipped version is offered
as an update and an unchanged one is a no-op; overwriting an existing managed asset asks first
and defaults to keep, so a copy you tuned on the host is never discarded silently.

Mechanism and invariants: `.claude/rules/shipped-claude-assets.rule.md`.
