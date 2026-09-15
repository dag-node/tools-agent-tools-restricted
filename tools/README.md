# Repository tools

Development tooling for this checkout. The RPM does not package any of it,
and every tool runs from a working tree.

```bash
bash tools/formatters/format.sh
bash tools/generators/ref-index.sh check
```

`format.sh` fills the paragraphs a diff touched, each at its own column,
and `ref-index.sh check` reports every reference finding in the tree.
`CONTRIBUTING.md` states where each one belongs in a change, and each file's
own header states what that file does.

## Where a new tool goes

The directories split on what a run leaves behind.

**`formatters/`** rewrite the tree's own text in place. Each reads and writes
through `text_file.py`, which refuses what is not plain text, so a formatter
rewrites only what it read whole. `verify-reflow.py` belongs here as the gate
that proves a reflow moved only line breaks.

**`generators/`** derive a committed artifact from a source of truth that lives
in another file. Each carries a `generate` verb and a `stale` verb that exits 1
when the committed copy differs from its source, which is what the pre-commit
hook and the unit suite run.

A tool that reports findings and writes nothing has no directory yet; the first
one founds `checkers/`.

## Conventions

A Python file reached by an `import` statement is named with underscores, since
a hyphen is not a valid identifier; every other tool is named with hyphens.
`text_file.py` is the one file imported today.

A tool that drives a script shipped inside a skill stays thin and names this
repository's paths, leaving the script itself argument-driven. `ref-index.sh`
over the `ai-tools-technical-docs` skill's `ref-index.py` is the worked
example.
