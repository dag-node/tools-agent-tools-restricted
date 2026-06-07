---
paths:
  - "**/*.rule.md"
---

# Writing `.claude/rules/*.rule.md` files

Conventions for the path-scoped component rules in this directory. This guideline is
itself scoped to `**/*.rule.md`, so it loads whenever a rule file is open.

## Domains are fluid, shaped by the code

A rule is a lens onto a *domain* — a cluster of files that share one mechanism or story.
Domains emerge from how the code is organised; they are not a fixed taxonomy and not a
one-file-per-rule mapping.

- **A rule's shape mirrors its domain.** `paths:` is a precise named-file set where the
  domain is a few specific files (the handback daemon/client/units), a recursive tree
  where the domain is a directory (`.claude/**`), or a single file where the domain is one
  library (`log.lib.sh`). There is no uniform template to force.
- **`paths:` matches what the rule actually describes** — neither over-claiming (a broad
  glob that also sweeps in unrelated files: audit logs, build artifacts, generated output)
  nor pointing at a file that does not exist in the repo.
- **A file may belong to several domains.** Its path then appears in several rules, and
  opening it loads them all — that overlap is a feature (richer context at a boundary),
  not duplication to remove.
- **Not every file needs a rule.** A file fully explained by its own header — a leaf
  config, a seed, a self-contained library — can stay uncovered. A rule exists only where
  there are domain-common principles or a cross-file story worth stating beyond the
  per-file headers. New code can grow a new domain; add a rule when that story appears.

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

- **What goes where (three tiers).** Root `CLAUDE.md` holds global invariants + the
  router. A rule holds the principles common to its whole domain (those not already in
  `CLAUDE.md`) plus the cross-component overview. The source file's header holds that
  file's local mechanism.
- **Register: reference-docs — the same skill as `CLAUDE.md` and source file/module
  headers.** Present-tense spec of current behaviour; no history ("removed", "now", "used
  to"). The register is applied independently of where content is split — always write to
  it, whatever tier you are editing. (Method/function/class doc-comments use the
  `doc-comments` skill instead; a file/module *header block* is reference-docs.)
- **Rule and source header are bidirectionally coupled — reconcile at write time.** A rule
  and its header are paired by the rule's `paths:` frontmatter. When you touch either and
  the other disagrees, resolve it then and there against the actual code behaviour and make
  both sides match: do not write a known inconsistency, do not default to one side, and do
  not guess which is current (the stale side is not always the rule). When the correct
  behaviour is genuinely unclear, ask immediately rather than committing a guess.
- **Keep load-bearing security invariants in the root `CLAUDE.md`, not here.** Path-scoped
  rules do not load unless a matching file is open and do not survive `/compact`; an
  invariant that must always hold belongs in the always-loaded root file.
- Cross-link sibling rules as `[topic](topic.rule.md)`, and register each rule in the
  component map in the root `CLAUDE.md`.

## Sections

A rule stays free-form prose (overview + mechanism), and may add any of these sections when
the domain has that content — none mandatory, rules stay fluid:

- **`## Design notes`** — why the domain is shaped this way (rationale as present-tense
  guarantees).
- **`## Quirks`** — domain-specific surprising behaviour / foot-guns (e.g. `PrivateTmp` is a
  no-op for a `--user` manager; a rule named `secrets.*` is auto-quarantined).
- **`## Why not`** — rejected alternatives + the reason (e.g. `user_u` → breaks the
  ai-tools→root sudo; per-session `/tmp` → needs a `--system` manager).
- **`## Deferred`** — domain-scoped, not-yet-built proposals, marked as such (e.g.
  bubblewrap for confinement; ACL automation for the CLI).
