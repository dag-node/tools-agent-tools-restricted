---
paths:
  - "**/*.rule.md"
---

# Writing `.claude/rules/*.rule.md` files

Conventions for the path-scoped component rules in this directory. This guideline is
itself scoped to `**/*.rule.md`, so it loads whenever a rule file is open.

## Naming

- One file per component: `<topic>.rule.md`. The `.rule.md` suffix lets tooling and this
  guideline target every rule with the `*.rule.md` glob.
- **Avoid a stem that matches a secret pattern.** `ai-tools-chown` quarantines
  secret-named files the agent writes (see [secret-handling](secret-handling.rule.md)): a
  file whose basename matches `~/.config/ai-tools/secret-patterns` is chowned to
  `<you>:<you> 600` and becomes unreadable to the agent — which silently disables the
  rule. `secrets.rule.md` matches the `secrets.*` pattern, so the secrets rule is named
  `secret-handling.rule.md`. Steer clear of stems like `secret`, `secrets`,
  `credential(s)`, `env`, `private`, or any `*.key`/`*.pem`-style name.

## Frontmatter

- Give each rule a `paths:` list of globs over the `src/**` (and `selinux/**`) files it
  describes, so it loads only when one of those files is open. Paths match the source
  files, not the rule filename.
- A rule with **no** `paths:` loads at launch every session and costs context
  unconditionally. Use that only for a guideline scoped to `**/*.rule.md` like this one.

## Content

- **Register: reference-docs** — present-tense spec of current behavior; no history
  ("removed", "now", "used to"). See the Documentation register section in the root
  `CLAUDE.md`.
- **Self-contained, kept in sync with the source file header.** The same mechanism is
  documented in the source file's own header; on a conflict the header (next to the code)
  is authoritative for file-local mechanism, and the rule supplies the cross-component
  overview. Update both when a mechanism changes.
- **Keep load-bearing security invariants in the root `CLAUDE.md`, not here.** Path-scoped
  rules do not load unless a matching file is open and do not survive `/compact`; an
  invariant that must always hold belongs in the always-loaded root file.
- Cross-link sibling rules as `[topic](topic.rule.md)`, and register each rule in the
  component map in the root `CLAUDE.md`.
