---
paths:
  - "src/usr/share/ai-tools/**"
  - "src/usr/local/lib/ai-tools/managed-assets.lib.sh"
---

# Shipped assets: shared skills and subagents

The project ships two kinds of asset, and both are agent-agnostic **content**, so both are shared
rather than copied per agent:

- **Skills** — prose that shapes how an agent works (how to write documentation, how to weigh a
  design).
- **Subagents** — delegate role definitions an agent dispatches to. "Subagent" is this project's
  word; Claude Code calls them "agents" and reads them from `<config dir>/agents/`, which is why
  the manifest maps the two (`subagents_dir=agents`). See `docs/naming-conventions.md`.

Each kind is seeded ONCE into its own shared root — `/opt/ai-tools/skills` and
`/opt/ai-tools/subagents`, both owned by `ai-tools-base` along with the pristine copies — and
every agent gets a **symlink** per asset into the directory its own product reads. One file to
author, one to update, however many agents read it. The formats are Claude Code's (`SKILL.md`,
subagent frontmatter) and are not standardized across products, so an agent that cannot read a
kind simply declares no directory for it and takes no links of that kind.

Ships now: the `ai-tools-reference-architect` agent, the `ai-tools-docs-*`
documentation skills (`reference`, `usage`, `comments`, `changelog`),
`ai-tools-engineering-principles`, and `ai-tools-capable-systems-governance`.

An asset is a **tree**, not a file: a skill may carry supporting material beside its `SKILL.md`
(`ai-tools-capable-systems-governance/references/framework.md` is the normative text its `SKILL.md`
defers to, so the working guidance stays short and the long text loads only when it is needed). The
seeder copies a directory asset whole (`cp -rT`) and applies the modes recursively, and the linker
places one symlink for the asset's top directory, so nesting needs nothing of either.

## Placement: one rule, four hops

`src/` mirrors the install tree. A file installed **verbatim** lives at its literal path
(`src/opt/ai-tools/agents/claude-code/settings.json`); a file that is **seeded** — rpm ships a read-only
pristine copy and provisioning places an editable live one — lives in `src/` at its **pristine**
path, because that is the path the package installs. Every shipped asset is seeded, so all of
them live under `src/usr/share/ai-tools/`, and the directory name is the same at every hop:

```text
src/usr/share/ai-tools/<kind>/     authoritative source, in this repo
   ──▶ /usr/share/ai-tools/<kind>/            pristine: rpm-owned, read-only, world-readable
   ──▶ /opt/ai-tools/<kind>/                  LIVE: operator-editable, agent-readable, NOT rpm-owned
   ──▶ <agent config>/<kind-dir>/<name>       a symlink into live, per agent that declares one
```

The live tree has no `src/` counterpart on purpose: it is runtime state, like `.nvm`, the sandbox
clones, and the logs.

One clause completes the rule, for the files whose destination is **manifest data** rather than a
fixed path: an agent's own payload (its `settings.json` and hooks) installs verbatim into the
directory its manifest declares, so in `src/` it is grouped by the agent that owns it —
`src/opt/ai-tools/agents/<manifest-name>/`. The destination is not knowable from the tree, so the
tree mirrors ownership instead; a second agent adds a sibling directory named for its manifest.

Each kind's `README.md` is the operator guide, shipped with the pristine copy and **symlinked**
into the live root and into each agent's directory (`ai_tools_link_asset_readme`) — the doc is
found where the assets are, and there is exactly one file to keep current.

## Linking (`ai_tools_link_shared_assets`)

`ai_tools_link_shared_assets <shared_root> <agent_dir> <group> [readme_source]` places one
symlink per shared asset, for either kind, and is idempotent and non-displacing:

- a name absent from the agent's directory → linked;
- a link already pointing at that shared asset → untouched; a stale one → repointed;
- a link into the shared root whose asset no longer ships → removed;
- **anything real** (a directory or file) → kept and reported. That is how an agent-specific
  asset, or an operator's override of a shared one, wins: same name, real file, no link. The one
  exception is a copy that is **both** `x-ai-tools-managed` **and** byte-identical to the shared
  asset: that is this project's own copy from the layout before these assets were shared, so it
  is replaced by a link (nothing is lost). A managed copy that *differs* is kept and reported —
  the difference is an operator edit or version drift, and the linker is not the place to
  resolve either.

Which agents take links of which kind comes from `ai_tools_agent_asset_dirs <manifest-field>`
(`control-plane.lib.sh`), which reads each enabled agent's `config_dir` plus the field naming
that kind's directory (`skills_dir`, `subagents_dir`) — the seeder names no path itself. The
links are root-owned inside the agent's setgid+sticky config directory, so a session reads and
invokes them but cannot repoint one.

**Assumption to hold:** the agent follows a symlinked asset. Claude Code scans its skills and
agents directories and reads the file beneath, which follows links transparently;
`tests/integration/perms.sh` asserts a shipped asset of each kind arrives as a link, so a
regression to per-agent copies (which would silently fork the content) fails there.

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

Seeded copies are `root:SANDBOX_GROUP`, files `640` and dirs `750` — in each kind's shared root. The agent reads and invokes
them but cannot rewrite one, so what every session reads stays what the operator installed —
across the account's sessions *and* across agents. The pristine source is
`/usr/share/ai-tools/{agents,skills}` (the datadir reseed source, shared by every seeding path);
the live copies are **not** rpm-owned, so an erase or upgrade preserves an operator-updated
version. The seeder is bash and source-only; its consumers run as root.

Three paths provision, all root, and each resolves its destinations through
`ai_tools_agent_config_dirs` / `ai_tools_agent_asset_dirs` (`control-plane.lib.sh`) rather than
naming them: `install.sh` (stages the datadir, seeds each kind into its shared root, then links)
and `ai-tools-bootstrap` (`seed_managed_assets_step`, gated on the control plane being present)
reuse the lib directly and offer the interactive version update; in the RPM the split follows
package ownership — **base**'s `%post` seeds both shared roots, the **agent package**'s `%post`
links them into the directories that agent reads. Both scriptlets reuse the
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

This rule is coupled to `src/usr/share/ai-tools/{skills,agents}/README.md` (the operator-facing
orientation) and the
`managed-assets.lib.sh` header (the seeder contract); changing the seeding
behavior, the namespace, or the versioning scheme obligates reconciling all three against the
code. Adding a shipped asset obligates keeping this rule's `paths:` and the shipped-set list above
current.
