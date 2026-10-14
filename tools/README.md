# Repository tools

Development tooling for this checkout. The RPM does not package any of it,
and every tool runs from a working tree.

```bash
bash tools/lib/assets.sh fetch
bash tools/format.sh
bash tools/generators/ref-index.sh check
```

`fetch` downloads the two releases this repository pins its prose checker, its
reftags tool and its formatters to, verifies each against its pin and its
signature, and unpacks it into your own cache. Run it once per checkout
and again after a pin changes. `format.sh` fills the paragraphs a diff touched,
each at its own column, and `ref-index.sh check` reports every reference
finding in the tree. `CONTRIBUTING.md` states where each one belongs
in a change, and each file's own header states what that file does.

## The pinned tools

No copy of the checker, the reftags tool or the formatters lives in this tree.
Each comes from a signed release that a pin under `lib/` names:

| Pin | Release | What this repository reads from it |
|---|---|---|
| `lib/assets-core.pin` | the asset set `core` of `dag-node/ai-tools-assets` | `prose-check.py` and `ref-index.py`, inside its skills |
| `lib/assets-tools.pin` | `dag-node/ai-tools-assets-tools` | the formatters and the conformance fixtures |

`lib/assets.sh` resolves each tool from your cache,
`${XDG_CACHE_HOME:-$HOME/.cache}/ai-tools-dev/`. A command that needs a tool
the cache does not hold exits 1 with the `fetch` command, and the git hooks
print it and let the commit through. To work against a checkout of either
repository instead, name it:

```bash
AI_TOOLS_DEV_ASSETS_CORE=../ai-tools-assets bash tools/generators/ref-index.sh check
AI_TOOLS_DEV_ASSETS_TOOLS=../ai-tools-assets-tools bash tools/format.sh
```

The run then prints a `BYPASS` line naming the checkout and its commit,
suffixed `-dirty` while the checkout holds an uncommitted edit.

### Bumping a pin

Edit `tag` and `archive_sha256` together from the release page, in a commit
of its own, then run `fetch` and `verify`:

```bash
bash tools/lib/assets.sh fetch
bash tools/lib/assets.sh verify
```

CI runs both before anything reads a pinned tool, so a pin whose sha256
or signature does not hold fails the build. A `tools` bump that changes
the reflower lands with the tree refilled at the new pin and checked
by the pinned `verify-reflow.py --against`; a `core` bump that changes
the checker lands with the prose check over the tree.

## Where a new tool goes

The directories split on what a run leaves behind.

**`format.sh`** is the front door to the pinned formatter, holding the scope
this repository formats.

**`generators/`** derive a committed artifact from a source of truth that lives
in another file. Each carries a `generate` verb and a `stale` verb that exits 1
when the committed copy differs from its source, which is what the pre-commit
hook and the unit suite run.

**`checkers/`** report findings and write nothing. `assets-conformance.sh`
holds base's asset-set validator to the conformance fixtures of the pinned
`ai-tools-assets-tools` release; CI runs it.

**`lib/`** holds what the other tools source: `assets.sh` and its pins,
and `format-scope.sh`, the path patterns `format.sh` formats
and `tests/unit/prose-width.sh` holds to their columns.

## Conventions

A tool that drives a script shipped inside a skill stays thin and names this
repository's paths, leaving the script itself argument-driven. `ref-index.sh`
over the `ai-tools-reftags` skill's `ref-index.py` is the worked example.
