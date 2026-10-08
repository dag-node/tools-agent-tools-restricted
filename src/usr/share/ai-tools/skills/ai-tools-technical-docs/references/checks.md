# Running the checker

`prose-check.py` ships beside `SKILL.md` and reports the checkable items of the final pass. This file states its modes,
its markers, and the widths it holds a file to; the rules it checks are the standard's.

```bash
python3 /opt/ai-tools/skills/ai-tools-technical-docs/prose-check.py <file>...
```

It reads rejoined sentences, reports, and does not block. The `nothing`, filler, predicted-action, register-verb
and router-altitude items and the `does not` rule run by default and are near-exact — the predicted-action item
on a short vocabulary of person-naming subjects, the router item only in a root `CLAUDE.md` or `AGENTS.md`, where each
of its three marks names one thing — as does the cost half of the absolute item: it reports a cost word only
where the sentence does not name a frequency or a bounded operation, so one already stated concretely stays silent.
`--all` adds the shape checks, each of which greps a sub-shape of its rule, because the rules themselves are
about meaning: a word stem repeated across the pivot is the mirror and the restated head noun, an absolute in a sentence
with no subordinating conjunction has nowhere for its guard clause to be, and a count word with no noun after it and no
correlative beside it is a set left unnamed — where a following noun (`both files`) or an enumeration
(`both the manifest and the key`) names it. It also carries the checks a rewrite needs a reader for — the `does not`
rule in its past and participle inflections, and the verbs that name no operation. Every `--all` check wants a reader
on each hit. `--kept` is the rewrite mode, described under the rewrite checks
[ref-section-g5n4](rewriting.md#ref-section-g5n4).

## When the tool is the defect

A check that mostly flags correct prose is a bug in the check, not in the text. Do not silence it
with `prose-check: ignore` or a reword that only dodges the pattern. That hides the evidence and leaves the cost
for everyone else.

**Measure first.** Run the check on the whole tree and report how many hits a reviewer would keep versus how many are
noise. A proposal without a count is a preference; a proposal with a count is evidence. Rejected widenings (and
the narrowings that earned their place) are recorded next to the checks so the same mistakes are not repeated.

## Markers

Quoted, backticked, and fenced spans are skipped, so a document may quote the prose it warns
against; mark anything else deliberate with `prose-check: ignore` on the line, or
`<!-- prose-check: ignore -->` in Markdown, where the marker then stays out of the rendered page.
A **generated** file takes `prose-check: ignore-file` on a comment line of its own instead, and is
not read at all — the marker is for a file whose text is copied from the targets it indexes, where a finding names prose
that file cannot fix and the fix would edit a runtime string. It is read only as a whole line, so a document naming
the marker is still checked. Run it before committing prose, and on the commit message too — the universal rules cover
that artifact like any other.

## Widths

**Keep prose to the file's wrap width.** Source comments, docstrings and config headers are read as written — an editor
and a terminal do not reflow them — so `--wrap` enforces:

- **comment-width** — a source comment or docstring over **120** columns, this stack's code column. Override
  with `--width` where the language sets another (Black 88, PEP 8 79).
- **document-width** — a Markdown line over the reader's column: **79** for pages people read (README, `docs/`, guides),
  the column classic prose is set at, since such a page is read whole rather than grepped; **120** for pages agents
  retrieve (`CLAUDE.md`, `AGENTS.md`, `*.rule.md`, skills), which returns more of the claim per `grep` hit.

Only prose is measured: a code line, a table row, a fenced block, a single-token or URL line, and a man page are
skipped. These checks are opt-in, since a tree whose prose predates them reports every line.

A config header stays at **72** columns, the RFC text width, ragged right, and is kept to what the file is, the one rule
a reader needs before writing a line, example lines and the file's man page, since an upgrade does not rewrite a header
in an operator's file. `--config-header` reports an over-width line (`--width` overrides) and leaves a commented default
(`#KEY=value`) and a `# Default:` line alone, each stating a value that cannot wrap:

```bash
python3 /opt/ai-tools/skills/ai-tools-technical-docs/prose-check.py --config-header <file>...
```

**Where a line breaks is the formatter's, not the writer's.** Write the prose and let a formatter wrap it at the column
`--print-width` reports; these checks hold the width alone.

**Table cells must line up.** After editing a table inside a comment, align its cells: a column is as wide as its widest
cell, so a cell too wide for its column widens every row. Where a project ships a table formatter, those decisions —
column widths, number right-alignment, heading centering, rule-line placement — belong to it.

## What a run reads

**A file's extension decides how it is read, and `--prose` / `--source` override that.** A `.md` page or a man page
contributes every line; anything else contributes its comments and docstrings. A path the extension rule does not
recognize is read as source, so a **document copy whose name lost its extension** keeps only its `#` headings
and reports zero findings for a file whose body the run never read — and zero findings reads as clean. Pass `--prose`
for such a copy, `--source` for the reverse.

**`--new <revision>` reports only what the paths add**, so a pre-existing finding does not mask a new one. It is
the sibling of `--kept`: that one asks whether a rewrite kept the claim, this one asks what the rewrite introduced. It
composes with `--all` and `--wrap`.

```bash
python3 /opt/ai-tools/skills/ai-tools-technical-docs/prose-check.py --all --new develop <file>...
```

Pairing is by content rather than by line, because an edit renumbers every finding after it. Two consequences to expect:
a sentence that was **edited and still reports** counts as new, which is the wanted direction — the wording a branch
leaves behind is the wording it is answerable for — and a file the revision does not hold reports every finding in it.
Do not do this comparison by hand. Findings are two lines each, line numbers shift, and a tree reporting hundreds
under `--all` buries the two that belong to the branch.
