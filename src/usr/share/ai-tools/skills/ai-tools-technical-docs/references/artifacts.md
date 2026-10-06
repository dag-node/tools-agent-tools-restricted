# Artifact rules

The structure, altitude and reader each artifact adds on top of the universal rules. `SKILL.md` carries the table
that picks an artifact; this file carries the full rule for each, with its examples.

## Usage docs, READMEs, man pages

A usage doc teaches by example. Lead a section with a minimal runnable block, then explain it in terse present-tense
prose naming the exact mechanism. The example is the topic sentence; the prose is the gloss. A section that opens
with preamble before the reader sees code is off style.

Explanation is connected prose. Bullets are for genuine enumerations — supported formats, options, exit codes.

**README shape** — thin and link-forward:

1. One-line capability statement (a confident tagline register is fine, kept to one line).
2. The smallest example that demonstrates the core value end to end.
3. One paragraph naming what the example does and the exact types involved.
4. Install and usage essentials.
5. Links to full docs, support, and source.

~~~markdown
# <Library>

<One-line capability statement.>

## Quick start

```bash
<install command>
```

```<lang>
<smallest end-to-end example>
```

<One paragraph naming what the example does and the exact types involved.>

## Docs

Read the full docs at <docs-url>.
Support: <issues link> | Source: <repo-url>
~~~

**Man pages** carry the operator-facing contract: options, arguments, exit codes, files, examples. Internal mechanics
belong in reference docs, and installation paths that apply to one distribution channel stay out. Read `man-pages.md`
beside this file before writing one — it covers section numbering, heading order, `an`-macro form,
and which well-maintained pages to read for calibration.

**A literal a reader types or pastes is backticked** — a command, an option, a placeholder, a variable or config key,
a filepath — wherever prose appears: a document, a rule, a file header, a comment. A command is written as the whole
line and begins with its binary, which is what separates it from a phrase that reads like one: `projects claim` is
a phrase, `ai-tools projects claim` is a command. The span closes after the **whole** literal, instance marker
and extension included (`ai-tools-handback@.service`), since a reader pastes what the backticks hold and a rename
searches for it.

A **doc comment's contract line** is already code — `name <arg>... -- what it does`, and the `args:`/`stdout:` fragment
beside it — so its tokens stay bare. A doc-comment format that has literal markup of its own takes that mark in place
of backticks — `<c>` and `<see cref="…"/>` in a C# XML doc comment, `{@code …}` in Javadoc — since backticks there put
a second markup language in one comment, which an IDE renders as neither; `prose-check.py` reads past each as it reads
past a backticked span. A **man page** takes the fonts `man-pages.md` states instead, and a **runtime message** is
a string rather than prose.

**Shell commands a reader will copy** go on a single line. Backslash continuations do not survive a copy
out of a terminal, so anything longer than one line ships as a script file the reader runs in one command.

**An example longer than 60 columns goes in a fenced block carrying its language** —
` ```bash ` for a command line, ` ```text ` for output the reader reads rather than runs, the language's own name
for source. Under 60 columns a command is a backticked span **inside the sentence that introduces it**, and two commands
joined by `&&` take the same measure: the width decides, not the count.

The inline form holds **one** command. A second command shown beside it joins the first in a block whatever either
measures, and so does an example of more than one line: a reader copying a sequence copies one block, and a stack
of backticked lines one after another is not a display form at all — it is a paragraph the renderer will reflow.

The fence is what states the language, and it bounds the block explicitly, where an indented block is a code block only
by its indentation — a nested list continuation at the same depth is prose, and which one a renderer sees depends
on what precedes it.

**Diagrams and tables** are ASCII, at most 80 columns wide.

UTF-8 icons are allowed sparingly in human-facing prose where they carry meaning — a section marker, a check or cross
in a do/don't table, a warning glyph. Source files stay ASCII.

## Reference docs: `CLAUDE.md`, `AGENTS.md`, `*.rule.md`, headers, design notes, ADRs

Write a specification of the **current** system: present tense, terse, factual, and normative (MUST / SHOULD / MAY)
where it prescribes. Use *should* rather than *is* where the document is advisory.

- State current behaviour. Leave out history — "used to", "now", "gained", "fixed", "previously", and dates
  of discovery. Git carries that.
- Attach purpose as the guarantee a behaviour provides.
- Describe the system, rather than predicting what a person will do with it.
- **Name the fail direction from the branch that decides it.** State what happens when an input is missing, unreadable,
  or untrusted, and whether that outcome increases or decreases access. Do not write "fails closed" from the shape
  of a sentence — over code that defaults open, it documents a property the implementation lacks. Where access
  increases, record the reason the code or the design already gives, never one composed to fit: an opening with no
  reason on record, or one contradicting a guarantee stated elsewhere, is a finding to raise with the operator,
  and the doc/code conflict rule [ref-section-p6c5](../SKILL.md#ref-section-p6c5) has which side moves.
- Where the system acts on its own, name the visibility or override path — log, notice, confirmation, review point —
  in the same place, and say who confirms an irreversible or outward-facing action.

**Altitude across tiers.** A root `CLAUDE.md` holds global invariants and routes to the rest. A `*.rule.md` holds
the principles common to its domain plus the cross-file story. A file header holds that file's local mechanism.

Put a fact in the always-loaded layer only where it holds across the whole project and a reader needs it in every
session. Send a domain's mechanism to that domain's document **even where it qualifies an invariant the router states**
— write the qualification at invariant altitude and point at the document that carries how it works. A file mode, a test
path, a `file:line` reference, or a verdict token is the mark of a domain document rather than of a router,
and `prose-check.py` reports each of them there.

State that boundary inside the router itself. A rule scoped to `*.rule.md` paths does not load while the router is open,
so a constraint on the router must be written in the router to be present in the sessions that edit it.

**Code, header, and rule describe one system at three altitudes**, each in the present tense, so touching any of them
obligates reconciling the others at the time of writing — in the direction the doc/code conflict rule sets.

Each tier states the system as it now is. What changed belongs to the changelog and to git.

Directives aimed at a person belong in runtime output, not in descriptive prose.

## Doc comments, XML docs, docstrings

State the **contract**: what the member does or returns, in concrete named types, terse enough to read as a tooltip.

- One line by default. A second sentence carries a real precondition, side effect, or null-or-throw case.
- Document the contract, not the implementation. The body says how.
- Parameter and return notes are fragments: "The id to look up", "The matching rows in table order".
- Detail — ordering, thread safety, business rules — goes to a second tier (`<remarks>`, an extended docstring body)
  only where a caller needs it.
- ASCII only. Identifiers spelled out in full, without abbreviations.

```csharp
/// <summary>Returns the authenticated user for the current request, or null when unauthenticated</summary>
```

```python
def select(predicate):
    """Return rows matching the predicate, in table order."""
```

```bash
# select_rows: print rows matching the awk predicate, in file order.
# args: $1 awk predicate  stdout: matching rows
```

```javascript
/** Returns the cached response for the request, or null on a miss. */
```

## Changelogs, release notes, migration guides <a id="ref-section-y8q9"></a>

An entry records what an operator gains and what changes for them on upgrade. History is the subject here,
so the current-state rule [ref-section-a2e9](../SKILL.md#ref-section-a2e9) does not apply.

- **Operator-facing, not commit-facing.** "Command output is filtered by default, which saves tokens" over "narrow
  command output through root-owned rule sets". Mechanism belongs in the commit and the rule file.
- **One entry per change the reader experiences, not per commit.** A feature built over nine commits is one entry;
  a commit that only moved code is none. Reconcile the set once, before a release, from what the version gained
  as a whole.
- **One or two sentences per entry.** Depth comes from a link to the issue, PR, or doc.
- **Grouped so a scan works** — Keep a Changelog's six categories (ADDED, CHANGED, DEPRECATED, REMOVED, FIXED,
  SECURITY), or the project's established headings mapped onto them. Breaking changes appear in one place. SECURITY is
  a category rather than a severity note: an entry belongs there because a reader's exposure changes, whether the change
  opens or closes it.
- **Internal churn does not produce an entry** — tests, formatting, CI, version bumps.
- **Present the gain plainly.** A reader should finish an entry knowing what they get, without the entry sounding like
  it is being sold.

A **migration guide** is task-shaped: what changed, what to edit, in what order. Show before and after side by side,
state the minimum that makes an upgrade build and run, then the optional follow-ups.

## Commit messages

Conventional Commits grammar: `type(scope): description`, an optional body, and a `BREAKING CHANGE:` footer where it
applies.

- **The subject states what the change achieves**, in the imperative — not what was wrong in an earlier attempt, and not
  a summary of the files touched.
- **The body carries the why and what the change achieves**, rather than a walk through the implementation. Length
  follows from that rather than setting it: one subtle line can warrant a paragraph explaining the condition it fixes,
  while a large mechanical refactor may need a sentence. A body that reads as a description of the diff is off style
  at any length.
- **Point, rather than repeat.** Detail lives in `*.rule.md`, the file header, or a code comment; name where it lives
  instead of restating it here.
- **One reviewable, revertable concern per commit.**
- **The trailers follow the repository's `CONTRIBUTING`.** Read it before the first commit in a repository: where it
  states a DCO sign-off, `git commit -s` adds the `Signed-off-by` trailer, and where it governs a co-author trailer, its
  rule decides over any default the tooling adds.
- No local filesystem paths, no design notes, no enumerated implementation steps.

```
fix(stop): keep an unpassed count from abandoning the confirmation

A zero count read as a parse failure and skipped the prompt, so a run with no
matching session went straight to the sweep. The counting contract is in
cli.rule.md.
```

## Pull requests and issues

A PR states the summary, the changes, how it was tested, and any breaking change, in terms of observable behaviour.

An issue states the observable problem, the expected behaviour, and concrete reproduction steps, naming exact types,
status codes, and log lines.

## Error messages and notices

Runtime output is where directives to a person belong. State what happened and what to do, briefly.

```
Configuration file '/etc/app/config.json' was not found.
Create the file or set APP_CONFIG_PATH.
```

Off style: `Configuration integrity requirements were not satisfied.`

A refusal names the condition and the path forward:
`<path> is not in allowed projects for the current operator. Claim it with: ai-tools projects claim <path>`.

## Log messages

A log line records an **event at a time**, which is a different claim from the standing behaviour reference prose
describes. Name the concrete subject, and leave off the terminal period.

- In style: `Token validation failed for user Id {UserId}`
- Off style: `Authorization process could not establish identity ownership.`

Use structured templates so fields survive into the journal or the log store.

## Artifact-level anti-patterns

| Off style | In style |
|---|---|
| Paragraph of preamble, then code | Code block, then one paragraph naming the mechanism |
| `Arming the timer so it does not fail to fire` | `Enabling the timer so the update runs daily` |
| `Entries are pruned from the walk` | `Entries on the skip list are omitted from the walk, which keeps the sweep fast` |
| `The framework was updated to support async` | `The async handler takes precedence when both are defined` |
| `Improved reliability / Various fixes` | `Fixed HttpClient retry on 429; corrected timezone parsing in date fields` |
| Changelog entry describing the mechanism | Entry describing what the caller or operator gains |
| Commit body as long as the diff | Two short paragraphs: the why, and where the detail lives |
| Correcting the flagged token and committing the sentence | Rewriting the whole sentence from the source it describes |
| Rambling multi-sentence doc comment | One-line contract; a second sentence for a real precondition |
| Bulleted list narrating each behaviour | Connected prose; bullets for true enumerations |
| Slogan or abstract principle | The observable outcome, or the concrete rule that produces it |
