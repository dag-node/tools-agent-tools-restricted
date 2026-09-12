---
paths:
  - "src/usr/share/ai-tools/**"
  - "src/usr/local/lib/ai-tools/managed-assets.lib.sh"
---

# Shipped assets: shared skills, subagents, and the orientation text

The project ships three kinds of asset, and all are agent-agnostic **content**, so all are shared
rather than copied per agent:

- **Skills** — prose that shapes how an agent works (how to write documentation, how to weigh a
  design).
- **Subagents** — delegate role definitions an agent dispatches to. "Subagent" is this project's
  word; Claude Code calls them "agents" and reads them from `<config dir>/agents/`, which is why
  the manifest maps the two (`subagents_dir=agents`). See `docs/naming-conventions.md`.
- **Orientation** — one file, `AGENTS.md`, stating what the sandbox refuses. It is the only asset
  loaded **unconditionally in every session in every project**, which is what shapes it (see
  [The orientation text](#the-orientation-text)).

Each kind is seeded ONCE into its own shared root under `/opt/ai-tools` — one per kind, named in
`control-plane.lib.sh` (`CP_SHARED_SKILLS`, `CP_SHARED_SUBAGENTS`, `CP_SHARED_ORIENTATION`) and
owned by `ai-tools-base` along with the pristine copies — and
every agent gets a **symlink** per asset into the directory its own product reads. One file to
author, one to update, however many agents read it. The formats are Claude Code's (`SKILL.md`,
subagent frontmatter) and are not standardized across products, so an agent that cannot read a
kind leaves that field unset, and does not take links of that kind.

The shipped set is the `ai-tools-reference-architect` subagent; the skills
`ai-tools-technical-docs` (the writing standard for every artifact),
`ai-tools-engineering-principles`, and `ai-tools-capable-systems-governance`; and the
orientation text.

## The orientation text

A session launched in a project that is not this repository gets that project's memory and no
statement that it is confined, so it learns each boundary by hitting it — and a denial reads as a broken environment rather than
as an edge, which costs the turns spent working around it. The file states the boundaries a
session cannot derive from its environment before wasting a turn discovering them.

Three properties follow from it loading in every session, forever, beside each project's own
memory, and they are what keep it from growing:

- **Every line names a loop it removes**, measured from the session transcripts rather than
  predicted. A fact that does not end a loop does not earn its tokens.
- **It routes nowhere.** No "see also", no skill to invoke, no path to read — a route out spends
  the tokens the file exists to save.
- **It does not carry conduct.** How an agent behaves at a boundary lives in `CLAUDE.md`, the README's
  agent section, and the governance skill. The one exception is where the *action* a boundary
  invites is itself the problem: recording an exec bit with `git update-index --chmod=+x` defers
  an escalation to the operator's next checkout, so the line that names the failed `chmod` names
  that too, and says to surface it instead.

**It is not a security control**, and is not argued for as one: an agent inclined to probe is not
deterred by a file it can read. The enforced invariants hold either way; this saves work.

Its provenance markers ride in an **HTML comment** rather than YAML frontmatter, and it carries
`x-ai-tools-managed` and `x-ai-tools-version` alone. Every byte is read by the model in every
session, so a status field and a date would be paid for in every one of them; the seeder's greps
are line-anchored and see the markers either way. The kind ships no `README.md` — the asset is one
short file whose content is its own documentation.

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

The skills and subagents kinds each ship a `README.md`, the operator guide, with the pristine copy;
it is **symlinked** into the live root and into each agent's directory
(`ai_tools_link_asset_readme`) — the doc is found where the assets are, and there is exactly one
file to keep current.

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

### Linking the orientation (`ai_tools_link_agent_memory`)

The orientation text is one file, and the name it lands under is **not its own**: each product
reads user-scope instructions from one hardcoded filename (`CLAUDE.md` for Claude Code, `AGENTS.md`
for one following that spelling), so the manifest's `memory_file` supplies it and
`ai_tools_agent_memory_targets` resolves `<config_dir>/<memory_file>` per enabled agent. The
product does not read a link under any other name, which is why the asset linker — which preserves
names — cannot place it.

Same non-displacing rule otherwise: a correct link is left alone, a stale one repointed, and a
**real file wins and is reported**. That last case is how an operator keeps their own user-scope
instructions; the shared text is then not loaded at all, since the path holds one file. An agent
that declares no `memory_file` is given no link, exactly as one declaring no `skills_dir` is given
no skills.

**Assumption to hold:** the agent follows a symlinked asset. Claude Code scans its skills and
agents directories and reads the file beneath, which follows links transparently;
`tests/integration/perms.sh` asserts a shipped asset of each kind arrives as a link, so a
regression to per-agent copies (which would silently fork the content) fails there.

## Namespace

Every shipped asset's name is prefixed `ai-tools-`: an agent's filename and `name:`
frontmatter, and a skill's directory and `name:`. The prefix is a distinct namespace, so a
shipped asset never collides with an agent or skill the operator authored. The orientation text is
the one exception, and does not need the namespace: its name is fixed on both ends — the seeder
knows the source filename and the manifest supplies the destination one — so there is no set for it
to collide within, and the managed marker still decides what may be claimed. Shipped assets are
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

`ai_tools_seed_managed_assets <src_root> <live_root> <group> <kind>...` seeds the named kinds from
the pristine root into the live root (`/opt/ai-tools`, under which each kind's shared root is a
subdirectory). `AI_TOOLS_ASSET_KINDS` in the same library is the one declaration of the kinds the
project ships: the seeder and the withdrawal pass refuse an empty list or a name outside it with a
reason on stderr, `install.sh` and base's `%post` iterate it rather than spelling the names, and a
kind added to it without a source layout in the seeder is refused the same way — so a rename or an
addition surfaces at the first call instead of seeding less than asked. It acts on an asset
**only** when its name matches the kind's glob — `ai-tools-*` for skills and
subagents, the fixed `AGENTS.md` for orientation — **and** its frontmatter carries
`x-ai-tools-managed: true`, so an operator's own agent/skill is never claimed or overwritten:

- **absent** in the live tree → seeded;
- **present + managed + a newer shipped `x-ai-tools-version`** → a keep/update confirm defaulting
  to **update**, so Enter and any non-interactive run (a scriptlet has no tty) take the new
  version. The replace does not keep a sidecar: the live copy is the previous version and differs from
  the incoming one by definition, so there is no baseline an edit could be detected against, and a
  copy per upgrade would bury the withdrawal copies that do carry something unrecoverable;
- **present + unmanaged** (no marker) → left untouched (the operator's own file);
- **present + same-or-older version** → no-op;
- **a withdrawn name** → skipped outright, before any of the other cases (see
  [Withdrawing an asset](#withdrawing-an-asset)).

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
`/usr/share/ai-tools/<kind>` (the datadir reseed source, shared by every seeding path);
the live copies are **not** rpm-owned, so an erase or upgrade preserves an operator-updated
version. The seeder is bash and source-only; its consumers run as root.

Three paths provision, all root, and each resolves its destinations through
`ai_tools_agent_config_dirs` / `ai_tools_agent_asset_dirs` (`control-plane.lib.sh`) rather than
naming them: `install.sh` (stages the datadir, seeds each kind into its shared root, then links)
and `ai-tools-bootstrap` (`seed_managed_assets_step`, gated on the control plane being present)
reuse the lib directly and offer the interactive version update; in the RPM the split follows
package ownership — **base**'s `%post` seeds each shared root, the **agent package**'s `%post`
links them into the directories that agent reads. Both scriptlets reuse the
same lib under an explicit `bash` (a scriptlet is `/bin/sh`) and, being non-interactive, place
only what is absent. This mirrors the `.gitignore`/`.gitconfig` reseed (see
[ownership-and-hooks](ownership-and-hooks.rule.md) for the control-plane ownership model).

## SELinux

The live assets need no per-asset file-context rule: the shared root has a static rule in
`ai_tools.fc` (one per shared root, e.g. `/opt/ai-tools/skills(/.*)?` → `ai_tools_home_t`) and an agent's config directory
is labelled the same type from its own manifest, so the seeder's `restorecon -R` gives every
seeded file and link the label the agent (`ai_tools_t`) already reads as home state. The datadir copies stay `usr_t` and are read by root, like the gitignore datadir. See
[confinement](confinement.rule.md).

## Coupling

This rule is coupled to `src/usr/share/ai-tools/{skills,subagents}/README.md` (the operator-facing
orientation) and the
`managed-assets.lib.sh` header (the seeder contract); changing the seeding
behavior, the namespace, or the versioning scheme obligates reconciling all three against the
code. Adding a shipped asset obligates keeping this rule's `paths:` and its shipped-set list
current.

The orientation kind couples further, because its destination is manifest data: the
`memory_file` field ([providers](providers.rule.md),
[agent-claude-code](agent-claude-code.rule.md)), `ai_tools_agent_memory_targets`
(`control-plane.lib.sh`), and the boundaries the text itself states — each line describes an
enforced behavior documented elsewhere ([launch](launch.rule.md),
[ownership-and-hooks](ownership-and-hooks.rule.md), [secret-handling](secret-handling.rule.md),
[claude-settings](claude-settings.rule.md)), so changing one of those behaviors obligates
re-reading the line that describes it. A line that goes stale is worse than an absent one: it is
believed.
