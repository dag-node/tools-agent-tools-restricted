---
paths:
  - "src/opt/ai-tools/.claude/agents/**"
  - "src/opt/ai-tools/.claude/skills/**"
  - "src/usr/local/lib/ai-tools/managed-assets.lib.sh"
---

# Shipped Claude assets (agents and skills)

The project ships a set of Claude Code **agents** and **skills** and provisions them into the
sandbox account's global config (`/opt/ai-tools/.claude/{agents,skills}`), so the sandboxed
agent carries them into every project a session runs in. The source tree under
`src/opt/ai-tools/.claude/{agents,skills}` is authoritative; the live path is the install
target. Ships now: the `ai-tools-reference-architect` agent, the `ai-tools-docs-*` documentation
skills (`reference`, `usage`, `comments`, `changelog`), and `ai-tools-engineering-principles`.

## Namespace

Every shipped asset's name is prefixed `ai-tools-`: an agent's filename and `name:`
frontmatter, and a skill's directory and `name:`. The prefix is a distinct namespace, so a
shipped asset never collides with an agent or skill the operator authored. Shipped assets are
self-contained — a cross-reference names a sibling by its `ai-tools-` id (the docs skills and the
agent reference each other this way), so every reference resolves on a host that has only the
shipped copies. A shipped asset carries **no** reference to a skill the project does not ship.

## Versioning (RFC-draft)

Provenance and version ride in frontmatter, not the name, so the invocation name is stable and
cross-references never churn:

```yaml
x-ai-tools-managed: true
x-ai-tools-status: draft
x-ai-tools-version: 1
x-ai-tools-updated: 2026-07-15
```

`x-ai-tools-version` is a monotonic integer; **every change to a shipped asset bumps it and sets
`x-ai-tools-updated`**. `x-ai-tools-managed: true` is the provenance marker the seeder gates on.
`x-ai-tools-status` tracks the RFC-draft lifecycle (`draft` while an asset is still being refined).
A single version is installed at a time, so the stable name always resolves to the latest.

## Seeding (`managed-assets.lib.sh`)

`ai_tools_seed_managed_assets <src_root> <live_.claude> <group>` seeds the managed assets.
It acts on an asset **only** when its name matches `ai-tools-*` **and** its frontmatter carries
`x-ai-tools-managed: true`, so an operator's own agent/skill is never claimed or overwritten:

- **absent** in the live tree → seeded;
- **present + managed + a newer shipped `x-ai-tools-version`** → a keep/update confirm defaulting
  to keep, so Enter and any non-interactive run leave an operator-tuned copy intact;
- **present + unmanaged** (no marker) → left untouched (the operator's own file);
- **present + same-or-older version** → no-op.

Seeded copies are `root:SANDBOX_GROUP`, files `640` and dirs `750`, under the setgid+sticky
`.claude` — the agent reads and invokes them but cannot rewrite one, so a single session cannot
poison the instructions shared across the account's sessions. The pristine source is
`/usr/share/ai-tools/{agents,skills}` (the datadir reseed source, shared by every seeding path);
the live copies are **not** rpm-owned, so an erase or upgrade preserves an operator-updated
version. The seeder is bash and source-only; its consumers run as root.

Three paths seed, all root: `install.sh` (stages the datadir, then seeds) and
`ai-tools-bootstrap` (`seed_managed_assets_step`, gated on the control plane being present) reuse
the lib directly and offer the interactive version update; the RPM `%post` reuses the same lib
under an explicit `bash` (its scriptlet is `/bin/sh`) and, being non-interactive, seeds only what
is absent. This mirrors the `.gitignore`/`.gitconfig` reseed (see
[ownership-and-hooks](ownership-and-hooks.rule.md) for the control-plane ownership model).

## SELinux

The live assets need no file-context rule of their own: `/opt/ai-tools/.claude(/.*)?` already
labels everything under `.claude` `ai_tools_home_t`, which the agent (`ai_tools_t`) reads as its
home state, so the seeder's `restorecon -R` gives the seeded files the label the agent already
reads. The datadir copies stay `usr_t` and are read by root, like the gitignore datadir. See
[confinement](confinement.rule.md).

## Coupling

This rule is coupled to `src/opt/ai-tools/.claude/{agents,skills}/README.md` (the operator-facing
orientation) and the `managed-assets.lib.sh` header (the seeder contract); changing the seeding
behavior, the namespace, or the versioning scheme obligates reconciling all three against the
code. Adding a shipped asset obligates keeping this rule's `paths:` and the shipped-set list above
current.
