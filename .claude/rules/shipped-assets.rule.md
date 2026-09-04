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
kind leaves that field unset, and does not take links of that kind.

Ships now: the `ai-tools-reference-architect` agent and three skills —
`ai-tools-technical-docs` (the writing standard for every artifact),
`ai-tools-engineering-principles`, and `ai-tools-capable-systems-governance`.

An asset is a **tree**, not a file: a skill may carry supporting material beside its `SKILL.md`
(`ai-tools-capable-systems-governance/references/framework.md` is the normative text its `SKILL.md`
defers to, so the working guidance stays short and the long text loads only when it is needed). The
seeder copies a directory asset whole (`cp -rT`) and applies the modes recursively, and the linker
places one symlink for the asset's top directory, so nesting is handled by both without a special case.

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
  is replaced by a link, with no content lost. A managed copy that *differs* is kept and reported —
  the difference is an operator edit or version drift, and the linker is not the place to
  resolve either.

Which agents take links of which kind comes from `ai_tools_agent_asset_dirs <manifest-field>`
(`control-plane.lib.sh`), which reads each enabled agent's `config_dir` plus the field naming
that kind's directory (`skills_dir`, `subagents_dir`) — the seeder does not name a path itself. The
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

`x-ai-tools-version` is a monotonic integer, bumped **once per repository release in which the
asset changed**, together with `x-ai-tools-updated`. A development cycle that edits an asset
several times ships one increment: a host installs released packages only, so the version the
seeder compares against a live copy tracks releases, and the first edit of a cycle is the one that
bumps it. `x-ai-tools-managed: true` is the provenance marker the seeder gates on.
`x-ai-tools-status` tracks the RFC-draft lifecycle (`draft` while an asset is still being refined).
A single version is installed at a time, so the stable name always resolves to the latest.

## Withdrawing an asset

Dropping a name from `src/` withdraws it from **new** installs only. The seeder adds and updates
and never removes, and the live roots are not rpm-owned, so an upgraded host keeps a withdrawn
asset — and keeps offering it to every session — until it is named in
`AI_TOOLS_RETIRED_ASSETS` (`managed-assets.lib.sh`) as a `<kind>/<name>` entry.

`ai_tools_remove_retired_assets` runs after the seeder in all three provisioning paths
(`install.sh`, `ai-tools-bootstrap`, base's `%post`). It gates on the same `x-ai-tools-managed`
marker the seeder claims by, so an operator's own asset under a withdrawn name is kept and
reported. Each agent's symlink is handled by the linker: the linker drops a link into the
shared root once its target is gone.

**The list gates both passes, so neither depends on the order they run in.** The seeder skips a
withdrawn name outright, because the source root it reads is not guaranteed to be final: in base's
`%post` it is not, rpm installing the new package's files first and removing the old package's only
at the end of the transaction. The seeder therefore sees the *previous* version's copy of an asset
this version withdrew, and without the gate would report it against a file rpm is about to delete —
or seed it, on a host whose live root lacks it — for the withdrawal pass to undo moments later.

The asset is **moved, not deleted**, to `/opt/ai-tools/retired/<name>.<YYYYMMDD>.retired` —
`ai_tools_conf_sidecar_path` (`conf.lib.sh`) is the single home of that stamp, shared with the
config sidecars, and the kind token names the event that produced the copy. Withdrawal is the one
path with no prompt and no baseline, so it fails toward keeping: an asset that cannot be moved is
left in place and reported rather than destroyed.

`retired/` sits **beside** the shared roots, not inside one. The linker iterates a shared root and
would otherwise symlink the sidecar into an agent's directory, where whether it loads comes down to
how that product decides what a skill is — a rule this project does not set. It is `0700
root:root`: operator recovery material, unreachable from the sandbox account.

An entry stays listed for as long as a host may still carry that asset from an older package.
Withdrawing therefore lands in the same change as the removal from `src/`, together with
repointing every cross-reference the asset had — a shipped asset may not name one this project
does not ship.

## Seeding (`managed-assets.lib.sh`)

`ai_tools_seed_managed_assets <src_root> <live_.claude> <group>` seeds the managed assets.
It acts on an asset **only** when its name matches `ai-tools-*` **and** its frontmatter carries
`x-ai-tools-managed: true`, so an operator's own agent/skill is never claimed or overwritten:

- **absent** in the live tree → seeded;
- **present + managed + a newer shipped `x-ai-tools-version`** → a keep/update confirm defaulting
  to **update**, so Enter and any non-interactive run (a scriptlet has no tty) take the new
  version. The replace does not keep a sidecar: the live copy is the previous version and differs from
  the incoming one by definition, so there is no baseline an edit could be detected against, and a
  copy per upgrade would bury the withdrawal copies that do carry something unrecoverable;
- **present + unmanaged** (no marker) → left untouched (the operator's own file);
- **present + same-or-older version** → no-op;
- **a withdrawn name** → skipped outright, before any of the above (see *Withdrawing an asset*).

Base's `%post` pre-answers the update confirm with `AI_TOOLS_ASSUME_YES=1` rather than letting it
fall through to its default. The outcome is identical, but the prompt is written to `/dev/tty`,
which *succeeds* when `dnf` runs on a terminal — so without it the operator is shown a question
no one can answer and which is then decided without them. Pre-answering skips drawing it, and the
decision audits as `assume-yes` rather than `default`, which is what happened. It leaves the surface unchanged:
the variable fast-tracks a question whose default is already yes and never flips a default-NO one
([messaging](messaging.rule.md)).

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
