---
paths:
  - "src/usr/share/ai-tools/**"
  - "src/usr/local/lib/ai-tools/managed-assets.lib.sh"
  - "src/usr/local/lib/ai-tools/assets.lib.sh"
  - "src/usr/local/lib/ai-tools/assets-verify.lib.sh"
  - "src/usr/local/lib/ai-tools/assets-bindings.d/**"
  - "src/usr/local/lib/ai-tools/keys/dag-node-package-signing.asc"
---

# Shipped assets: shared skills, subagents, and the orientation text

The project ships three kinds of asset, and all are agent-agnostic **content**, so one copy of each serves every agent.
Base seeds its own copies; the skills and subagents of a published asset set reach the same shared roots as links ([The
view and each agent's links](#the-view-and-each-agents-links-assetslibsh)):

- **Skills** — prose that shapes how an agent works (how to write documentation, how to weigh a design).
- **Subagents** — delegate role definitions an agent dispatches to. "Subagent" is this project's word; Claude Code calls
  them "agents" and reads them from `<config dir>/agents/`, which is why the manifest maps the two
  (`subagents_dir=agents`). See `docs/naming-conventions.md`.
- **Orientation** — one file, `AGENTS.md`, stating what the sandbox refuses. It is the only asset loaded
  **unconditionally in every session in every project**, which is what shapes it (see [The orientation
  text](#the-orientation-text)).

Each kind is seeded ONCE into its own shared root under `/opt/ai-tools` — one per kind, named in `control-plane.lib.sh`
(`CP_SHARED_SKILLS`, `CP_SHARED_SUBAGENTS`, `CP_SHARED_ORIENTATION`) and owned by `ai-tools-base`
along with the pristine copies of the assets base ships — and every agent gets a **symlink** per asset
into the directory its own product reads. An integration package may ship a skill of its own into the same pristine
root; it owns that directory, and places and withdraws the live copy itself (see
[Seeding](#seeding-managed-assetslibsh)). One file to author, one to update, however many agents read it. The formats
are Claude Code's (`SKILL.md`, subagent frontmatter) and are not standardized across products, so an agent that cannot
read a kind leaves that field unset, and does not take links of that kind.

The shipped set is the `ai-tools-reference-architect` subagent; the skills `ai-tools-technical-docs` (the writing
standard for every artifact, with `prose-check.py` and its `references/` beside the entry file), `ai-tools-reftags` (the
cross-reference grammar and `ref-index.py`, which this repository's own tooling drives
through `tools/generators/ref-index.sh`), `ai-tools-engineering-principles`, and `ai-tools-capable-systems-governance`;
and the orientation text. `ai-tools-typesafe-filter` is the one skill a provider package ships rather than base: it
belongs to `ai-tools-integration-typesafe` ([typesafe](typesafe.rule.md)) and is bound to it ([An asset bound
to an integration](#an-asset-bound-to-an-integration)).

## The orientation text

A session launched in a project that is not this repository gets that project's memory and no statement that it is
confined, so it learns each boundary by hitting it — and a denial reads as a broken environment rather than as an edge,
which costs the turns spent working around it. The file states the boundaries a session cannot derive from its
environment before wasting a turn discovering them.

Three properties follow from it loading in every session, forever, beside each project's own memory, and they are
what keep it from growing:

- **Every line names a loop it removes**, measured from the session transcripts rather than predicted. A fact that does
  not end a loop does not earn its tokens.
- **It routes nowhere.** No "see also", no skill to invoke, no path to read — a route out spends the tokens the file
  exists to save.
- **It does not carry conduct.** How an agent behaves at a boundary lives in `CLAUDE.md`, the README's agent section,
  and the governance skill. The one exception is where the *action* a boundary invites is itself the problem: recording
  an exec bit with `git update-index --chmod=+x` defers an escalation to the operator's next checkout, so the line
  that names the failed `chmod` names that too, and says to surface it instead.

**It is not a security control**, and is not argued for as one: an agent inclined to probe is not deterred by a file it
can read. The enforced invariants hold either way; this saves work.

Its provenance markers ride in an **HTML comment** rather than YAML frontmatter, and it carries `x-ai-tools-managed`
and `x-ai-tools-version` alone. Every byte is read by the model in every session, so a status field and a date would be
paid for in every one of them; the seeder's greps are line-anchored and see the markers either way. The kind ships no
`README.md` — the asset is one short file whose content is its own documentation.

An asset is a **tree**, not a file: a skill may carry supporting material beside its `SKILL.md`
(`ai-tools-capable-systems-governance/references/framework.md` is the normative text its `SKILL.md` defers
to, so the working guidance stays short and the long text loads only when it is needed). The seeder copies a directory
asset whole (`cp -rT`) and applies the modes recursively, and the reconcile places one symlink for the asset's top
directory, so nesting is handled by both without a special case.

## Placement: one rule, four hops

`src/` mirrors the install tree. A file installed **verbatim** lives at its literal path
(`src/opt/ai-tools/agents/claude-code/settings.json`); a file that is **seeded** — rpm ships a read-only pristine copy
and provisioning places an editable live one — lives in `src/` at its **pristine** path, because that is the path
the package installs. Every shipped asset is seeded, so all of them live under `src/usr/share/ai-tools/`,
and the directory name is the same at every hop:

```text
src/usr/share/ai-tools/<kind>/     authoritative source, in this repo
   ──▶ /usr/share/ai-tools/<kind>/            pristine: rpm-owned, read-only, world-readable
   ──▶ /opt/ai-tools/<kind>/                  LIVE: operator-editable, agent-readable, NOT rpm-owned
   ──▶ <agent config>/<kind-dir>/<name>       a symlink into live, per agent that declares one
```

The live tree has no `src/` counterpart on purpose: it is runtime state, like `.nvm`, the sandbox clones, and the logs.

One clause completes the rule, for the files whose destination is **manifest data** rather than a fixed path: an agent's
own payload (its `settings.json` and hooks) installs verbatim into the directory its manifest declares, so in `src/` it
is grouped by the agent that owns it — `src/opt/ai-tools/agents/<manifest-name>/`. The destination is not knowable
from the tree, so the tree mirrors ownership instead; a second agent adds a sibling directory named for its manifest.

The skills and subagents kinds each ship a `README.md`, the operator guide, with the pristine copy; it is **symlinked**
into the live root and into each agent's directory (`ai_tools_link_asset_readme`) — the doc is found where the assets
are, and there is exactly one file to keep current.

## The view and each agent's links (`assets.lib.sh`)

An **asset set** is published apart from base, installed by a package under `/usr/share/ai-tools-assets/<set>/`,
and linked into the same shared roots the seeder writes: `/opt/ai-tools/<kind>` is the **view**, and every link in it
that points into a set is the resolver's. `AI_TOOLS_ASSETS` in `operator.conf` is the one input that enables an asset,
as `<set>/<kind>/<name>`, so installing a set does not change any session until an operator names its assets
(`ai-tools-admin assets enable`). The roots, the identifier, the reason tokens and the binding file are
`ai-tools-assets(5)`'s; this section states what the code guarantees.

**Every reader fails toward an unlinked asset, reported.** The library reads each set from the first root holding it --
the local root, the packaged root, then base's own `/usr/share/ai-tools/` as the set `ai-tools` -- in a fixed order:
the trust walk (every entry root-owned, none but a link group- or other-writable), the file-shape walk, the set
verifier, then the subset of format 1 base enforces, under the format's rule ids. Each step's failure resolves every
entry it covers to one reason token and the run goes on; a copy refused at any step does not fall through to a lower
root. An untrusted `operator.conf` and an invalid list enable no asset, so the next run removes every resolver link.
Every requirement is read: `requires_base`, an unknown capability and an integration that is off each leave the asset
unlinked. A view or agent directory the plan cannot list is an `error` row and is not planned that run, so no link in it
is placed or removed: a failed listing read as an empty one would leave a stale link in place and no row naming it.

**Compatibility is a profile question.** An asset requires its kind's base profile and each capability it declares;
an agent's manifest lists the profiles it implements in `asset_profiles`, defaulting to each kind's base profile
for the directories it declares, and receives a kind by declaring its directory or listing one of its profiles
([providers](providers.rule.md)). A required profile one enabled receiving agent lacks leaves the asset out of the view
for every agent, since codex reads the view whole and an asset cannot be narrowed per agent there. The load-time command
substitution is one such profile, `skills.dynamic.v1`: an asset carrying it without the declaration is refused, because
the substitution runs as a step of reading the file and skips the `PreToolUse` filter and `permissions.deny`. A receiver
set read from a failed discovery -- a provider reader exiting non-zero, or an empty enabled set
`ai_tools_agents_empty_verdict` classifies as a fault -- is `receivers-unknown` rather than the empty set, which would
support every profile: the enable list reads as empty for that run and no agent's directory is planned. A refused
`operator.conf` is the exception: it refuses the enable list too (`enable-list-untrusted`), so no entry asks
for a capability, and its empty agent set is read as it was printed, every installed agent losing its resolver links.

**The transaction holds a lock and plans before it writes.** `ai_tools_assets_reconcile` takes an exclusive `flock`
before it reads an input, computes every change (`ai_tools_assets_plan`, which writes nothing and which `status` runs
alone), then applies them: each view link is placed by a `rename(2)` over its name, so a session listing the directory
sees the old target or the new one; a resolver link no input justifies is removed, with no last-good fallback; anything
else at an enabled asset's name is `view-occupied` and left as it is. A resolver link is told from every other entry
by its target alone, so the seeder's managed copies share the directory without a marker, and the three sites that read
a managed copy's marker (`ai_tools_withdraw_asset`, `_ai_tools_asset_is_stale_copy`, `system post-upgrade`'s version
check) skip a symlink. A link is staged at `.<name>.ai-tools-assets.tmp` beside its name, and an entry already there is
removed only when it is a link the library leaves; any other is kept and the placement refused as `write-failed`.
The lock is `/run/lock/ai-tools/assets.lock`, a `0600` file in a `0700` root directory: `flock(2)` takes an exclusive
lock through a read-only descriptor, so a file another account can open is one it can hold. A run that waits longer than
`AI_TOOLS_ASSETS_LOCK_WAIT` (120 seconds) for it refuses under `MSG-M8T9` rather than hold a package transaction. Every
writer of the shared roots holds it, through the reentrant pair `ai_tools_assets_lock`/`ai_tools_assets_unlock`
in `managed-assets.lib.sh`, which every provisioning path already sources: the `assets` verbs before their first read
of `operator.conf`, to their exit; `install.sh`, `ai-tools-bootstrap`, base's `%post` and the typesafe package's
scriptlets across the seed, the retire pass and the reconcile. A reconcile run as a child of a holder adopts
the descriptor it inherits once it names the lock file, rather than wait on its parent. The seeder itself does not take
the lock.

**The view decides what every agent links.** For each enabled agent and each kind its manifest declares a directory
for, the view's resolver links and base's seeded copies are linked, and no other entry: a seeded copy is a real entry
in the seeder's `ai-tools-` namespace, of its kind's shape, root-owned with everything under it, carrying the managed
marker (an operator's edit of it in place included). Every other entry is `view-foreign`, reported and kept, and not
linked into an agent's directory, though codex, reading the view whole, still loads it; an operator's own skill reaches
one agent from that agent's own directory, where a real entry wins. In an agent's directory, a link into the view
whose name the view no longer holds as either is removed; a real entry is kept and reported, and one not root-owned
along its path is `agent-entry-untrusted`, since the sandbox account could rewrite what every later session loads there;
a link elsewhere is the host's and is not repointed. An installed agent that `AI_TOOLS_AGENTS` does not name loses its
resolver links and keeps its seeded copies' links. Every directory a link is written in -- the home root, a view,
an agent's config and kind directory -- is checked before the plan acts in it and again in the apply, after an absent
one is created where no entry stands at its name: root-owned and not a symlink, the config directory sticky where it is
group-writable as it ships, the others writable by neither group nor other. One that fails is `view-dir-untrusted`
or `agent-dir-untrusted`, no action under it runs, and it is not repaired, since a repair would keep what was placed
inside it. Why a path check suffices against these modes is `_ai_tools_as_destination_trusted`'s doc comment.
The reconcile is the one function that writes these links, so every provisioning path that placed or linked an asset
ends with it: base's `%post` after the seeder, two transaction file triggers on `/usr/share/ai-tools-assets` (a set
placed, upgraded or erased, base's own transaction included), each agent and the typesafe package's scriptlets,
`install.sh` and `ai-tools-bootstrap`.

The verbs are `ai-tools-admin assets enable|disable|reconcile`, each root-only and each ending with the reconcile;
the record stream and the exit fold are [records](records.rule.md)'s contract. `ai_tools_assets_validate_set` runs
the same subset over a tree as data, without the trust walk or the signature, for the conformance job that holds base's
reading to the publisher's fixtures.

### Verifying a set (`assets-verify.lib.sh`)

An asset set reaches a host as a signed package of `dag-node/ai-tools-assets` (or a publisher built on the same tools),
installed under `/usr/share/ai-tools-assets/<set>/` with the inventory `SHA256SUMS` its build wrote and the signature
`SHA256SUMS.asc` its release made. The resolver that links a set's assets into the view calls
`ai_tools_assets_verify_set <set-directory> <set-name>` as root before it reads a file of the set, and does not link any
asset of a set the verifier refuses. The verdict follows the status contract the toolchain gates share
([ref-section-b8h3](updater.rule.md#ref-section-b8h3)), with one difference: a set is refused at `2` as well as at `1`,
since proceeding would link content no signature covers into every session. The resolver reports `1` (`MSG-T3M3`)
as `set-tampered` and `2` (`MSG-Q6Y8`) as `set-unverified`; the library's function docs name which input yields which.
`ai_tools_assets_verify_inventory <set-directory>` is the inventory half alone, which the conformance job runs
over the `ai-tools-assets-tools` fixtures.

What may sign a set is a **binding**, one root-owned file per set name
under `/usr/local/lib/ai-tools/assets-bindings.d/<set>.conf`, in the shared `KEY=value` grammar
([providers](providers.rule.md)) and read as data: `set`, `signers` (typed primary fingerprints) and `keyring` (the
binary keyring `gpgv` reads), and a line outside those keys refuses the binding. Base ships the bindings `core`
and `ai-tools`, both naming the dag-node package-signing primary — the key `rpm.dagnode.com` serves and the key
that signs this project's own RPMs, so one trust anchor covers the package and the sets it reads — and the keyring
`keys/dag-node-package-signing.gpg`, which the spec's `%install` and `install.sh` write from the armored key beside it
with `ai_tools_assets_write_binary_keyring`. The signer is asserted against `gpgv`'s `VALIDSIG` primary, so a keyring
swapped for another valid key is refused, as is a signature by a key the keyring holds but no binding names. Every path
of a set, listed in the inventory or found by the walk, is held to `ai_tools_conf_portable_name_valid`
([providers](providers.rule.md)) component by component. The directory, each binding and the keyring are `644 root:root`
under `755 root:root` and must pass `ai_tools_conf_is_trusted`, file and directory both, or the set is unverified:
the sandbox account cannot change what signs a set, which `tests/boundary/assets.sh` asserts from that account's
vantage, while `tests/unit/assets-verify.sh` drives every refusal over a set signed in the run by a throwaway key,
through the root-only hook `AI_TOOLS_ASSETS_BINDINGS_DIR`.

This release reads the shipped bindings alone: an operator binding under `/etc/ai-tools/assets-bindings.d/`
and an operator key are outside it.

### Linking the orientation (`ai_tools_link_agent_memory`)

The orientation text is one file, and the name it lands under is **not its own**: each product reads user-scope
instructions from one hardcoded filename (`CLAUDE.md` for Claude Code, `AGENTS.md` for one following that spelling),
so the manifest's `memory_file` supplies it and `ai_tools_agent_memory_targets` resolves `<config_dir>/<memory_file>`
per enabled agent. The product does not read a link under any other name, so the per-asset links, which keep each
asset's name, do not reach it.

Same non-displacing rule otherwise: a correct link is left alone, a stale one repointed, and a **real file wins and is
reported**, with one exception the reconcile also makes for a seeded copy — a real file that is both
`x-ai-tools-managed` and byte-identical to the shared text is this project's own copy (a tree copied with its links
dereferenced leaves one) and becomes the link, with no content lost. The real-file case is how an operator keeps their
own user-scope instructions; the shared text is then not loaded at all, since the path holds one file. An agent
that declares no `memory_file` is given no link, exactly as one declaring no `skills_dir` is given no skills.

**Assumption to hold:** the agent follows a symlinked asset. Claude Code scans its skills and agents directories
and reads the file beneath, which follows links transparently; `tests/integration/perms.sh` asserts a shipped asset
of each kind arrives as a link, so a regression to per-agent copies (which would silently fork the content) fails there.

### Linking a whole kind at a path outside the agent (`ai_tools_link_shared_root`)

An agent may read a kind from one fixed path outside its config directory rather than from a directory the manifest
names inside it — codex reads skills at its admin scope, `/etc/codex/skills` — and that path is one a host may already
hold, with its own skills in it. `ai_tools_link_shared_root <shared_root> <path> <group> [readme_source]` points such
a path at the shared root without displacing anything, on the state the path is in: **absent** → a symlink to the shared
root; **a symlink to the shared root** → current; **a symlink elsewhere** → the host's, left alone and reported; **a
real directory** → the host's own assets, kept exactly as they are (owner, mode and entries untouched), with the shared
assets linked into it one per free name and a name the host holds left to the host and reported — the per-asset rule
the reconcile applies, minus the repointing of a link, which inside a host-owned directory is left to the host; **a
regular file** → kept and reported. A link into the shared root whose asset no longer ships is removed, as the reconcile
removes one from an agent's directory; the kind's README is linked only under a free name. The reverse for a package
being erased, `ai_tools_unlink_shared_root`, removes the link to the shared root or the managed links inside the host's
directory and no other entry. Neither function re-owns or re-modes what it finds, and the relabel that follows a link
covers the links that run placed rather than the directory holding them, so what a host put there keeps its own label
too — which is also what lets `tests/unit/shared-root.sh` drive every state without root. Which agent takes this shape,
and why the path is not in that package's file list, is in [agent-codex](agent-codex.rule.md).

## Namespace

Every shipped asset's name is prefixed `ai-tools-`: an agent's filename and `name:` frontmatter, and a skill's directory
and `name:`. The prefix is a distinct namespace, so a shipped asset never collides with an agent or skill the operator
authored. The orientation text is the one exception, and does not need the namespace: its name is fixed on both ends —
the seeder knows the source filename and the manifest supplies the destination one — so there is no set for it
to collide within, and the managed marker still decides what may be claimed. Shipped assets are self-contained —
a cross-reference names a sibling by its `ai-tools-` id (the docs skills and the agent reference each other this way),
so every reference resolves on a host that has only the shipped copies. A shipped asset carries **no** reference
to a skill the project does not ship.

## Versioning (RFC-draft)

Provenance and version ride in frontmatter, not the name, so the invocation name is stable and cross-references never
churn:

```yaml
x-ai-tools-managed: true
x-ai-tools-status: draft
x-ai-tools-version: 1
x-ai-tools-updated: 2026-07-15
```

`x-ai-tools-version` is a monotonic integer, bumped **once per repository release in which the asset changed**, together
with `x-ai-tools-updated`. A development cycle that edits an asset several times ships one increment: a host installs
released packages only, so the version the seeder compares against a live copy tracks releases, and the first edit
of a cycle is the one that bumps it. `x-ai-tools-managed: true` is the provenance marker the seeder gates on.
`x-ai-tools-status` tracks the RFC-draft lifecycle (`draft` while an asset is still being refined). A single version is
installed at a time, so the stable name always resolves to the latest. `x-ai-tools-integration: <name>` ties an asset
to an integration ([An asset bound to an integration](#an-asset-bound-to-an-integration)).

## Withdrawing an asset

Dropping a name from `src/` withdraws it from **new** installs only. The seeder adds and updates, and moves a live copy
aside only for an asset [bound to an integration](#an-asset-bound-to-an-integration) the host does not have; the live
roots are not rpm-owned, so an upgraded host keeps a withdrawn asset — and keeps offering it to every session — until it
is named in `AI_TOOLS_RETIRED_ASSETS` (`managed-assets.lib.sh`) as a `<kind>/<name>` entry. A renamed asset is withdrawn
under its old name the same way, with the new name seeded beside it.

`ai_tools_remove_retired_assets` runs after the seeder in all three provisioning paths (`install.sh`,
`ai-tools-bootstrap`, base's `%post`). It gates on the same `x-ai-tools-managed` marker the seeder claims
by, so an operator's own asset under a withdrawn name is kept and reported. Each agent's symlink is handled by the next
assets reconcile, which drops a link into the shared root once its target is gone.

**The list gates both passes, so neither depends on the order they run in.** The seeder skips a withdrawn name outright,
because the source root it reads is not guaranteed to be final: in base's `%post` it is not, rpm installing the new
package's files first and removing the old package's only at the end of the transaction. The seeder therefore sees
the *previous* version's copy of an asset this version withdrew, and without the gate would report it against a file rpm
is about to delete — or seed it, on a host whose live root lacks it — for the withdrawal pass to undo moments later.

The asset is **moved, not deleted**, to `/opt/ai-tools/retired/<name>.<YYYYMMDD>-<N>.retired` —
`ai_tools_conf_sidecar_path` (`conf.lib.sh`) is the single home of that stamp, shared with the config sidecars,
and the kind token names the event that produced the copy. Withdrawal is the one path with no prompt and no baseline,
so it fails toward keeping: an asset that cannot be moved is left in place and reported rather than destroyed.

`retired/` sits **beside** the shared roots, not inside one. The reconcile links every entry of a shared root and would
otherwise symlink the sidecar into an agent's directory, where whether it loads comes down to how that product decides
what a skill is — a rule this project does not set. It is `0700 root:root`: operator recovery material, unreachable
from the sandbox account.

An entry stays listed for as long as a host may still carry that asset from an older package. Withdrawing therefore
lands in the same change as the removal from `src/`, together with repointing every cross-reference the asset had —
a shipped asset may not name one this project does not ship.

## Seeding (`managed-assets.lib.sh`)

`ai_tools_seed_managed_assets <src_root> <live_root> <group> <kind>...` seeds the named kinds from the pristine root
into the live root (`/opt/ai-tools`, under which each kind's shared root is a subdirectory). `AI_TOOLS_ASSET_KINDS`
in the same library is the one declaration of the kinds the project ships: the seeder and the withdrawal pass refuse
an empty list or a name outside it with a reason on stderr, `install.sh` and base's `%post` iterate it rather than
spelling the names, and a kind added to it without a source layout in the seeder is refused the same way — so a rename
or an addition surfaces at the first call instead of seeding less than asked. It acts on an asset **only** when its name
matches the kind's glob — `ai-tools-*` for skills and subagents, the fixed `AGENTS.md` for orientation — **and** its
frontmatter carries `x-ai-tools-managed: true`, so an operator's own agent/skill is never claimed or overwritten:

- **absent** in the live tree → seeded;
- **present + managed + a newer shipped `x-ai-tools-version`** → a keep/update confirm defaulting to **update**,
  so Enter and any non-interactive run (a scriptlet has no tty) take the new version. The replace does not keep
  a sidecar: the live copy is the previous version and differs from the incoming one by definition, so there is no
  baseline an edit could be detected against, and a copy per upgrade would bury the withdrawal copies that do carry
  something unrecoverable;
- **present + unmanaged** (no marker) → left untouched (the operator's own file);
- **an empty directory** at a directory asset's name → seeded, as absent: it holds nothing an operator wrote, and read
  as theirs it would leave the asset missing from every session with nothing to fill it;
- **present + same-or-older version** → the content is left as it is, and the ownership and modes a seeded copy has
  (`root:SANDBOX_GROUP`, files `640`, directories `750`, an inherited setgid cleared) are applied again where they
  drifted, which the report names — the same on a kept older version;
- **bound to an integration** (`x-ai-tools-integration`) → seeded by the other cases while that integration's manifest
  is installed and trusted, and otherwise skipped with a live managed copy moved aside (see [An asset bound
  to an integration](#an-asset-bound-to-an-integration));
- **a withdrawn name** → skipped outright, before any of the other cases (see [Withdrawing
  an asset](#withdrawing-an-asset)).

Base's `%post` pre-answers the update confirm with `AI_TOOLS_ASSUME_YES=1` rather than letting it fall through to its
default. The outcome is identical, but the prompt is written to `/dev/tty`, which *succeeds* when `dnf` runs
on a terminal — so without it the operator is shown a question no one can answer and which is then decided without them.
Pre-answering skips drawing it, and the decision audits as `assume-yes` rather than `default`, which is what happened.
It leaves the surface unchanged: the variable fast-tracks a question whose default is already yes and never flips
a default-NO one ([messaging](messaging.rule.md)).

Seeded copies are `root:SANDBOX_GROUP`, files `640` and dirs `750` — in each kind's shared root. The agent reads
and invokes them but cannot rewrite one, so what every session reads stays what the operator installed —
across the account's sessions *and* across agents. The pristine source is `/usr/share/ai-tools/<kind>` (the datadir
reseed source, shared by every seeding path); the live copies are **not** rpm-owned, so an erase or upgrade preserves
an operator-updated version. The seeder is bash and source-only; its consumers run as root.

Three paths provision, all root, and each resolves its destinations through `ai_tools_agent_config_dirs`
(`control-plane.lib.sh`): `install.sh` (stages the datadir, seeds each kind into its shared root, then runs the assets
reconcile) and `ai-tools-bootstrap` (`seed_managed_assets_step`, gated on the control plane being present) reuse the lib
directly and offer the interactive version update; in the RPM **base**'s `%post` seeds each shared root and then
reconciles, and the **agent package**'s `%post` reconciles, which links the shared roots into the directories each
enabled agent reads. The scriptlets reuse the same lib under an explicit `bash` (a scriptlet is `/bin/sh`) and, being
non-interactive, place only what is absent. A **provider package that ships a skill** seeds the shared root in its own
`%post` and reconciles, because on a first install base's and the agents' scriptlets run before that package's files are
on disk; its `%postun` on final erase withdraws the live copy with `ai_tools_withdraw_asset`, the per-asset step
the retired-list pass is built from, and reconciles so each agent's link to the gone target is dropped. This mirrors
the `.gitignore`/`.gitconfig` reseed (see [ownership-and-hooks](ownership-and-hooks.rule.md) for the control-plane
ownership model).

### An asset bound to an integration <a id="ref-section-k4q2"></a>

An asset a provider package ships declares `x-ai-tools-integration: <name>`, and the host holds it exactly where it
holds that integration. The seeder places it through the other cases while the manifest `integrations.d/<name>.conf`
and its directory pass `ai_tools_conf_is_trusted`; otherwise it skips the asset and moves a live managed copy aside
with `ai_tools_withdraw_asset`, so the marker gate and the `retired/` copy are the withdrawal's. An absent manifest,
an untrusted one and a name outside the provider charset each read as not installed, which removes the asset and does
not place one.

The manifest decides because the pristine copy is present on hosts without the integration: a from-source install copies
the whole pristine root, and a host that moved from a source install to packages keeps a pristine copy no package owns.
The seeder reads the directory the provider resolver reads, under the same root-only override
(`AI_TOOLS_INTEGRATIONS_DIR`), so `install.sh`, `ai-tools-bootstrap` and the scriptlets reach one answer.

## SELinux

The live assets need no per-asset file-context rule: the shared root has a static rule in `ai_tools.fc` (one per shared
root, e.g. `/opt/ai-tools/skills(/.*)?` → `ai_tools_home_t`) and an agent's config directory is labelled the same type
from its own manifest, so the seeder's `restorecon -R` gives every seeded file and link the label the agent
(`ai_tools_t`) already reads as home state. The datadir copies stay `usr_t` and are read by root, like the gitignore
datadir. See [confinement](confinement.rule.md).

## Coupling

This rule is coupled to `src/usr/share/ai-tools/{skills,subagents}/README.md` (the operator-facing orientation)
and the `managed-assets.lib.sh` header (the seeder contract); changing the seeding behavior, the namespace,
or the versioning scheme obligates reconciling all three against the code. Adding a shipped asset obligates keeping this
rule's `paths:` and its shipped-set list current.

The view couples to `ai-tools-assets(5)` (the roots, the identifier, each reason token and the binding file),
to the `assets` entries of `ai-tools-admin(8)`, to `asset_profiles` in `ai-tools-providers(5)`, and to the conformance
job, whose list of the fixtures base refuses follows the rules `assets.lib.sh` enforces: a rule added to or dropped
from the subset changes all four.

The orientation kind couples further, because its destination is manifest data: the `memory_file` field
([providers](providers.rule.md), [agent-claude-code](agent-claude-code.rule.md)), `ai_tools_agent_memory_targets`
(`control-plane.lib.sh`), and the boundaries the text itself states — each line describes an enforced behavior
documented elsewhere ([launch](launch.rule.md), [ownership-and-hooks](ownership-and-hooks.rule.md),
[secret-handling](secret-handling.rule.md), [claude-settings](claude-settings.rule.md)), so changing one of those
behaviors obligates re-reading the line that describes it. A line that goes stale is worse than an absent one: it is
believed.
