---
paths:
  - "src/opt/ai-tools/.claude/agents/**"
  - "src/opt/ai-tools/skills/**"
  - "src/usr/local/lib/ai-tools/managed-assets.lib.sh"
---

# Shipped assets: shared skills and per-agent agents

The project ships two kinds of asset, and they are placed differently because their **content**
differs in how agent-specific it is:

- **Skills** are agent-agnostic prose (how to write documentation, how to weigh a design). They
  are seeded ONCE into the shared root `/opt/ai-tools/skills` — `ai-tools-base` owns that
  directory and the pristine copies — and every agent that reads skills gets a **symlink** per
  skill into its own skills directory. One file to author, one to update, however many agents
  read it. The format is Claude Code's `SKILL.md`, which is not standardized across agents; an
  agent that cannot read it declares no `skills_dir` and takes no links.
- **Agents** (subagent definitions) are Claude Code-format files, so they are **copied** into
  that agent's config directory and `ai-tools-agents-claude-code-restricted` owns both them and
  the directory.

The source tree — `src/opt/ai-tools/skills/` and `src/opt/ai-tools/.claude/agents/` — is
authoritative. Ships now: the `ai-tools-reference-architect` agent, the `ai-tools-docs-*`
documentation skills (`reference`, `usage`, `comments`, `changelog`), and
`ai-tools-engineering-principles`.

## Linking (`ai_tools_link_shared_skills`)

`ai_tools_link_shared_skills <shared_root> <agent_skills_dir> <group>` places one symlink per
shared skill, and is idempotent and non-displacing:

- a name absent from the agent's directory → linked;
- a link already pointing at that shared skill → untouched; a stale one → repointed;
- a link into the shared root whose skill no longer ships → removed;
- **anything real** (a directory or file) → kept and reported. That is how an agent-specific
  skill, or an operator's override of a shared one, wins: same name, real directory, no link.

Which agents take links comes from `ai_tools_agent_skills_dirs` (`control-plane.lib.sh`), which
reads each enabled agent's `config_dir` + `skills_dir` — the seeder names no path itself. The
links are root-owned inside the agent's setgid+sticky config directory, so a session reads and
invokes them but cannot repoint one.

**Assumption to hold:** the agent follows a symlinked skill directory. Claude Code scans its
skills directory and reads `SKILL.md` beneath it, which follows links transparently;
`tests/integration/perms.sh` asserts the shipped skill arrives as a link, so a regression to
per-agent copies (which would silently fork the content) fails there.

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

Seeded copies are `root:SANDBOX_GROUP`, files `640` and dirs `750` — in the shared root for
skills, in the agent's setgid+sticky config directory for agents. The agent reads and invokes
them but cannot rewrite one, so what every session reads stays what the operator installed —
across the account's sessions *and* across agents. The pristine source is
`/usr/share/ai-tools/{agents,skills}` (the datadir reseed source, shared by every seeding path);
the live copies are **not** rpm-owned, so an erase or upgrade preserves an operator-updated
version. The seeder is bash and source-only; its consumers run as root.

Three paths seed, all root, and each resolves its destinations through
`ai_tools_agent_config_dirs` / `ai_tools_agent_skills_dirs` (`control-plane.lib.sh`) rather than
naming them: `install.sh` (stages the datadir, then seeds skills → shared root, agents → the
agent, then links) and `ai-tools-bootstrap` (`seed_managed_assets_step`, gated on the control
plane being present) reuse the lib directly and offer the interactive version update; in the RPM
the split follows package ownership — **base**'s `%post` seeds the shared skills, the **agent
package**'s `%post` seeds its agents and links the shared skills in. Both scriptlets reuse the
same lib under an explicit `bash` (a scriptlet is `/bin/sh`) and, being non-interactive, place
only what is absent. This mirrors the `.gitignore`/`.gitconfig` reseed (see
[ownership-and-hooks](ownership-and-hooks.rule.md) for the control-plane ownership model).

## SELinux

The live assets need no per-asset file-context rule: the shared root has a static rule in
`ai_tools.fc` (`/opt/ai-tools/skills(/.*)?` → `ai_tools_home_t`) and an agent's config directory
is labelled the same type from its own manifest, so the seeder's `restorecon -R` gives every
seeded file and link the label the agent (`ai_tools_t`) already reads as home state. The datadir copies stay `usr_t` and are read by root, like the gitignore datadir. See
[confinement](confinement.rule.md).

## Coupling

This rule is coupled to `src/opt/ai-tools/skills/README.md` and
`src/opt/ai-tools/.claude/agents/README.md` (the operator-facing orientation) and the
`managed-assets.lib.sh` header (the seeder contract); changing the seeding
behavior, the namespace, or the versioning scheme obligates reconciling all three against the
code. Adding a shipped asset obligates keeping this rule's `paths:` and the shipped-set list above
current.
