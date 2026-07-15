# ai-tools skills

Skills the installer provisions into the sandbox account, so the sandboxed agent carries the
same engineering judgment and documentation conventions into any project you launch it in.

## What installs where

```text
src/opt/ai-tools/.claude/skills/ai-tools-*/  ──▶  /opt/ai-tools/.claude/skills/
```

`install.sh` and `ai-tools` bootstrap copy each `ai-tools-*/` skill directory into the live
control plane as `root:ai-tools` (files `640`, dirs `750`), under the setgid+sticky `.claude`
— the agent reads and invokes them but cannot rewrite one. This `README.md` is source
documentation only; the seed copies the `ai-tools-*/` directories, never this file.

Shipped now: `ai-tools-docs-reference`, `ai-tools-docs-usage`, `ai-tools-docs-comments`,
`ai-tools-docs-changelog` (the documentation family), and `ai-tools-engineering-principles`.
Each is invoked as `/ai-tools-<name>`.

## It never touches your own skills

Every shipped skill lives in an `ai-tools-<name>/` directory whose `name:` matches. The
installer acts only on a directory that matches that prefix **and** whose `SKILL.md` carries
`x-ai-tools-managed: true`; any other skill in `/opt/ai-tools/.claude/skills/` is left
untouched. A skill you author yourself neither collides nor gets overwritten.

## Updating: stable name, version in frontmatter

```yaml
x-ai-tools-managed: true
x-ai-tools-status: draft
x-ai-tools-version: 1
x-ai-tools-updated: 2026-07-15
```

Each skill's invocation name stays stable; the version and date ride in `SKILL.md` frontmatter,
RFC-draft style — a monotonic `x-ai-tools-version` bumped on every change, plus the
`x-ai-tools-updated` date. On install or bootstrap a newer shipped version is offered as an
update and an unchanged one is a no-op; overwriting an existing managed asset asks first and
defaults to keep. Cross-references between shipped skills use the stable `ai-tools-*` names, so
they always resolve to the installed copy.

Mechanism and invariants: `.claude/rules/shipped-claude-assets.rule.md`.
