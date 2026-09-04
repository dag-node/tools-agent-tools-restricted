---
name: ai-tools-technical-docs
# ai-tools managed asset — provenance/versioning (RFC-draft lifecycle); the name above is stable.
x-ai-tools-managed: true
x-ai-tools-status: draft
x-ai-tools-version: 2
x-ai-tools-updated: 2026-09-04
description: >
  Technical writing standard for every software engineering artifact. Use when writing or
  editing README and usage guides, CLAUDE.md / AGENTS.md, *.rule.md, file and module headers,
  design notes, architecture docs and ADRs, method/function/XML doc-comments and docstrings,
  changelogs, release notes, migration guides, man pages, git commit messages, pull requests,
  issue descriptions, error messages, and log messages. Enforces concrete, present-tense,
  mechanism-named prose about observable behaviour, written for a named reader: example-first
  for usage docs, current-state specification for reference docs, contract-only for doc
  comments, operator-gain framing for changelogs, and short pointer-style commit messages.
  Trigger on any request to write or edit documentation, comments, commit messages, or change
  records.
---

# Technical writing standard

One standard covers every artifact. The universal rules hold everywhere; each artifact type
adds its own structure, altitude, and reader.

Applies to: README and usage guides; CLAUDE.md, AGENTS.md, `*.rule.md`, file and module
headers; design notes, architecture docs, ADRs; doc comments and docstrings; changelogs,
release notes, migration guides; man pages; commit messages, pull requests, issue
descriptions; error messages and log messages.

## Core principle

Describe **observable behaviour** in concrete technical language: what happens, when, from
which inputs, producing which outputs and state changes.

Write as an experienced software engineer. The register is that of a specification or a good
API reference — not a legal document, a policy memo, an essay, or a product page.

## Know the reader before writing

Name the reader first; it sets altitude more than any other choice.

| Artifact | Reader | What they want |
|---|---|---|
| README, usage guide, man page | operator or new user | a working example, then the essentials |
| Changelog, release notes | operator deciding whether to upgrade | what they gain, what breaks |
| Reference docs, `*.rule.md`, headers | developer and security reviewer | current behaviour and the guarantee it provides |
| Doc comment | the caller, reading a tooltip | the contract, in concrete types |
| Commit message | a specialist scanning history | what the change achieves, and where the detail lives |
| Error, notice, log line | whoever is at the terminal now | what happened and what to do |

Mechanism belongs to the developer surfaces. An operator surface states the effect and links
to the mechanism.

---

# Universal rules

## Concrete subjects and verbs

### Name a subject that can act

The grammatical subject is a component, command, function, file, or person — something with
an implementation a reader can open. Abstractions describe; they do not act.

- In style: `register() does not write an entry when an existing one already covers the path.`
- Off style: `A registration that can add nothing leaves nothing recorded.`

### State the mechanism, not the definition

A sentence shaped *"an X that ⟨property⟩ is not an X"* restates a definition, which a reader
cannot check against the code. Write what the code does and what follows from it.

- In style: `stop() does not take a target and enumerates every process in the account's cgroup, so a task cannot exclude itself from the sweep.`
- Off style: `A stop path the monitored system can put itself outside of is not a stop path.`

A document may carry **one** such formulation as its stated binding rule, where the compression
earns its place. Everywhere else, describe the mechanism.

### Back an absolute with its check

"Never", "always", and "cannot" are claims about the implementation. Name the guard that makes
each one true, in the same sentence.

- In style: `launch() exits non-zero when the service account appears in the admin group.`
- Off style: `The service account is never an administrator.`

Where no guard exists, describe the behaviour without the absolute.

### Name the absent input rather than writing "nothing"

- In style: `The helper does not take a path argument, so the path validator is not loaded.`
- Off style: `There is nothing left to check, and nothing to trust.`

### Domain vocabulary points at a mechanism

`grant`, `claim`, `authority`, and `privilege` are correct when they name something in the
code — a sudoers rule, a POSIX ACL entry, a `claim` subcommand. Used as metaphor for
what code merely does, they read as legal prose. The same test applies to any borrowed
vocabulary: point at the mechanism it names, or choose a plainer word.

Prefer plain verbs — returns, creates, loads, stores, deletes, parses, validates, caches,
retries, logs, skips, reads, writes, starts, stops, maps, serializes, emits, forwards.

### Name real mechanisms

- In style: `Uses IMemoryCache.` `Writes to Redis.` `Calls HttpClient.SendAsync().`
- Off style: `Uses the caching subsystem.` `Uses the network layer.` `Uses a helper.`

## Framing

### Lead with what the system does

Open with the behaviour. Where a reader benefits from knowing what the behaviour prevents,
that comes second.

- In style: `chown() resolves the path once and acts on the pinned inode, so the change stays inside the tree even when the path is swapped mid-operation.`
- Off style: `Without this check a symlink could redirect the chown outside the tree.`

### Affirmative framing is structural

State what the reader can rely on. Prefer "X is available when ⟨condition⟩" to "X fails unless
⟨condition⟩" where both state the same fact. Describe what a component does rather than what it
does not do.

Keep this structural: no praise, no intensifiers, no tone words, and never overstate a
guarantee. No single sentence looks upbeat; across a corpus the effect accumulates, and the
documentation reads as capable and dependable.

**Write a negation with `does not`.** Fronting the quantifier instead — `writes no entry`,
`takes no argument` — attaches the negative to the object instead of the verb. It reads formal
to archaic, and it is the determiner statutes are built from (*no person shall*, *no warranty is
given*). It is also the shorter form, and clarity outranks brevity: the razor takes the fewest
words that stay clear.

- In style: `does not write any entries`, `does not take any path arguments`
- Off style: `writes no entry`, `takes no path argument`

Pluralize an indefinite object under `any`. A single instance takes its article — `does not
write an entry` — and so does a definite one: `does not increment the counter`.

The same applies to `nothing` as a subject or object, which the checklist already catches: name
the absent input instead.

### Keep severity proportionate

A routine check reads as a routine check. Reserve the vocabulary of failure and risk for
genuine failure and risk, so that when it appears a reader takes it seriously.

Avoid the military register — arm, fire, target, abort, kill, defend — where a plain verb
carries the meaning: a timer is *enabled* and *runs*, a unit is *stopped*, a check *refuses*.

### A term of art describes, it does not judge

Where a technical term also reads as an assessment, say which sense applies. A *weak
dependency* is an RPM relation, not a statement about the quality of what it pulls in.

### Plain register

Leave out legal phrasing (hereby, pursuant to, thereunder, entitlement, standing, void),
aphorisms and slogans, philosophical framing, and marketing language.

- In style: `Returns an empty collection when no items match.`
- Off style: `An empty request cannot produce a result.`
- In style: `Returns 401 when the request is unauthenticated.`
- Off style: `A caller lacking identity receives no authorization.`

## Sentence craft

### Rationale is the payload — state it as a fact

Purpose is what prose exists to carry. The code already shows what happens, so a header earns
its place by recording why: the constraint that forced the choice, the alternative rejected, the
foot-gun avoided. Write that freely — it is the content worth keeping.

Write it in the same register as everything else, because this is the register that slips.
Explaining why attracts every figure in *Rhetorical figures* below: contrast ("rather than",
"instead of"), metaphor ("spends the signal"), definition ("a check that cannot fail is not a
check"). Each states the reason as a figure instead of a mechanism, so a reader cannot check it
against the code.

State the reason as a fact about the code, and name the constraint behind it — an external
requirement, a kernel quirk, an ordering dependency. A "so that ⟨outcome⟩" clause is the usual
join. A because-, so-that-, or rather-than-sentence is the cue to re-read it against that table.
Run the check while drafting.

**Attach purpose where the reason is non-obvious, and nowhere else.** A named construction turns
into a slot a writer fills, and a document whose every sentence makes a causal claim reads as
though none of them does. Three tests before a purpose clause stays:

- **It says something the first half did not.** `The file is 0644, so it is world-readable`
  restates the mode. Cut the clause.
- **A reader would miss it.** Where the consequence follows from the fact for anyone who knows
  the domain, the fact stands alone.
- **The consequent names a mechanism.** `so it takes the same report` is vague; `so the
  commit-msg hook runs the checker over the message` is the same claim, checkable.

Purpose also lands without the join: as its own sentence, or as a paragraph's whole job. Where a
paragraph already makes one causal claim, check whether the next sentence earns a second.

### One fact per sentence, in one direction

Keep sentences short and single-idea. Avoid mirrored clauses that a reader must unpick to
recover one fact.

- In style: `A task whose project cannot be read shows as unknown, and is terminated like any other.`
- Off style: `A missing one costs you a label rather than costing the sweep a target.`

### Present tense, active voice

Describe current behaviour: "Returns the current session", "Loads the configuration". Use the
passive only where it is substantially clearer, and "will" only for genuinely future or
conditional behaviour. Changelogs are the exception and are covered below.

### Consistent domain terms, varied ordinary nouns

Domain terms stay fixed — a reader who learns a term once meets it unchanged. Ordinary words
repeated inside one sentence get rewritten: `own/owner/owned` piling up becomes *holds*,
*belongs to*, *foreign*.

### Leave out filler

basically, simply, obviously, clearly, naturally, effectively, actually, essentially, robust,
elegant, powerful, flexible — unless the word is technically required.

## Placement

### One home per fact, and a pointer everywhere else

Every principle gets exactly one canonical home; every other mention is a brief reference to
it. The same fact in five places is five places to update.

Restating in full is warranted only when the **perspective** changes:

| Perspective | Surface |
|---|---|
| operator, operational | README, man page, `docs/*.md`, changelog |
| security or devops reviewer | reference docs, commit messages |
| developer or coding agent | `*.rule.md`, file headers, doc comments |

The same perspective covered twice means one copy is redundant. Choose the surface whose
reader needs the detail, write it there, and point at it from the others.

### Prose covers purpose and why; the code shows what

A reader should follow *how* something works from the code alone. Prose carries the intent and
the non-obvious trade-off a name, type, or signature cannot hold. Restating what the code does
adds a second copy that drifts.

### Occam's razor — the fewest words that carry the full fact

Use the fewest words that still carry the full fact. The starting point for any explanation is
none. A sentence earns its place only when it carries something the code cannot: purpose, an
external constraint, a rejected alternative, or a foot-gun.

Where the code can say it instead, prefer that fix: rename a variable or function so the name
itself states what it holds or does (full words, following the language's conventions); extract
a function; strengthen a type.

Two habits do most of the work:

- Merge sentences that share a subject.
- Cut any fact already carried by this file, by the code below it, or by the domain rule that
  owns it. Each fact has one home.

**Length is a symptom, never a budget.** Prose that approaches the size of the code it describes
usually means the code has stopped being self-descriptive; the fix is to make the code say it.
Short prose is not automatically finished prose either: the only test is whether every remaining
sentence still carries a fact. A longer header is correct precisely when the code cannot be made
clearer — a kernel quirk, an ordering constraint, a workaround for a defect elsewhere — and the
point of the prose is to name that constraint.

Judge each file on its own. A header at a good altitude stays as it is, and a change that merely
touches a file edits only the passages it invalidates. On a header that has grown past its
purpose, expand it first to surface what actually matters, then reduce to purpose and the
load-bearing why.

### Self-contained

Prose is read without the conversation that produced it. Name the concrete mechanism; leave out
session shorthand, internal labels, ticket tags, and "as discussed" back-references.

### Resolve conflicts against the code, while writing

Where a doc and the code disagree, resolve it then, against the code — do not default to
either side, and do not commit a known inconsistency. Ask when the correct behaviour is
genuinely unclear.

While a migration is in progress, describe the target state as current. Where that forces a
mention of something not yet built, record the dependency and keep writing to the target.

## The three axes

Purpose, style, and tense constrain different things, and compose:

- **Purpose** — *what to include*: the guarantee a behaviour provides.
- **Spec style** — *how to phrase it*: terse, factual, normative where it prescribes.
- **Current state** — *tense and frame*: what is, rather than what changed.

RFCs are full of purpose: "receivers MUST ignore unknown fields *so that* the format stays
forward-compatible" is purpose, spec style, and present tense at once. Friction appears only
when purpose is written as **history** or as a **predicted human action**. A "so that
⟨invariant⟩" clause on a fact about what the code does is one way to attach it — see the limit
on it under *Rationale is the payload*.

---

# Pick the artifact

| Artifact | It is right when |
|---|---|
| **Usage / README** | a reader meets a working example before any prose, and every following sentence names the exact type, call, or option |
| **Reference / rule.md / header** | every sentence states what the system is or does now, and rationale appears as the invariant a behaviour guarantees |
| **Doc comment** | the summary names what the member does and the concrete type it does it with, and reads as a tooltip |
| **Changelog** | each entry names what an operator gains or must change on upgrade, grouped so breaking changes are found in one pass |
| **Commit** | the subject states what the change achieves, and the body is shorter than the diff |
| **Error / log** | it states what happened and, for an error, what to do next |

---

# Artifact rules

## Usage docs, READMEs, man pages

A usage doc teaches by example. Lead a section with a minimal runnable block, then explain it
in terse present-tense prose naming the exact mechanism. The example is the topic sentence; the
prose is the gloss. A section that opens with preamble before the reader sees code is off style.

Explanation is connected prose. Bullets are for genuine enumerations — supported formats,
options, exit codes.

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

**Man pages** carry the operator-facing contract: options, arguments, exit codes, files,
examples. Internal mechanics belong in reference docs, and installation paths that apply to one
distribution channel stay out. Read `references/man-pages.md` beside this file before writing
one — it covers section numbering, heading order, `an`-macro form, and which well-maintained
pages to read for calibration.

**Shell commands a reader will copy** go on a single line. Backslash continuations do not
survive a copy out of a terminal, so anything longer than one line ships as a script file the
reader runs in one command.

**Diagrams and tables** are ASCII, at most 80 columns wide.

UTF-8 icons are allowed sparingly in human-facing prose where they carry meaning — a section
marker, a check or cross in a do/don't table, a warning glyph. Source files stay ASCII.

## Reference docs: CLAUDE.md, AGENTS.md, `*.rule.md`, headers, design notes, ADRs

Write a specification of the **current** system: present tense, terse, factual, and normative
(MUST / SHOULD / MAY) where it prescribes. Use *should* rather than *is* where the document is
advisory.

- State current behaviour. Leave out history — "used to", "now", "gained", "fixed",
  "previously", and dates of discovery. Git carries that.
- Attach purpose as the guarantee a behaviour provides.
- Describe the system, rather than predicting what a person will do with it.
- Where the system acts on its own, name the visibility or override path — log, notice,
  confirmation, review point — in the same place, and say who confirms an irreversible or
  outward-facing action.

**Altitude across tiers.** A root `CLAUDE.md` holds global invariants and routes to the rest. A
`*.rule.md` holds the principles common to its domain plus the cross-file story. A file header
holds that file's local mechanism.

**The code is true for behaviour, and invariants have to hold.** Code, header, and rule describe
one system at three altitudes, each in the present tense, and touching any of them obligates
reconciling the others at the time of writing.

Where a description disagrees with the code, the code decides what the description says — the
stale side is not reliably the prose. Where the **code** contradicts an invariant a `CLAUDE.md`
or a rule states, that is a defect in the code: raise it, and leave the invariant standing.
Rewriting the invariant to match would retire a guarantee by editing prose. Ask when the correct
behaviour is genuinely unclear, rather than committing a guess.

Each tier states the system as it now is. What changed belongs to the changelog and to git.

Directives aimed at a person belong in runtime output, not in descriptive prose.

## Doc comments, XML docs, docstrings

State the **contract**: what the member does or returns, in concrete named types, terse enough
to read as a tooltip.

- One line by default. A second sentence carries a real precondition, side effect, or
  null-or-throw case.
- Document the contract, not the implementation. The body says how.
- Parameter and return notes are fragments: "The id to look up", "The matching rows in table
  order".
- Detail — ordering, thread safety, business rules — goes to a second tier (`<remarks>`, an
  extended docstring body) only where a caller needs it.
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

## Changelogs, release notes, migration guides

An entry records what an operator gains and what changes for them on upgrade. History is the
subject here, so the current-state rule above does not apply.

- **Operator-facing, not commit-facing.** "Command output is filtered by default, which saves
  tokens" over "narrow command output through root-owned rule sets". Mechanism belongs in the
  commit and the rule file.
- **One or two sentences per entry.** Depth comes from a link to the issue, PR, or doc.
- **Grouped so a scan works** — Added, Changed, Deprecated, Removed, Fixed, Security, or the
  project's established headings. Breaking changes appear in one place.
- **Internal churn does not produce an entry** — tests, formatting, CI, version bumps.
- **Present the gain plainly.** A reader should finish an entry knowing what they get, without
  the entry sounding like it is being sold.

A **migration guide** is task-shaped: what changed, what to edit, in what order. Show before and
after side by side, state the minimum that makes an upgrade build and run, then the optional
follow-ups.

## Commit messages

Conventional Commits grammar: `type(scope): description`, an optional body, and a
`BREAKING CHANGE:` footer where it applies.

- **The subject states what the change achieves**, in the imperative — not what was wrong in an
  earlier attempt, and not a summary of the files touched.
- **The body carries the why and what the change achieves**, rather than a walk through the
  implementation. Length follows from that rather than setting it: one subtle line can warrant a
  paragraph explaining the condition it fixes, while a large mechanical refactor may need a
  sentence. A body that reads as a description of the diff is off style at any length.
- **Point, rather than repeat.** Detail lives in `*.rule.md`, the file header, or a code
  comment; name where it lives instead of restating it here.
- **One reviewable, revertable concern per commit.**
- No local filesystem paths, no design notes, no enumerated implementation steps.

```
fix(stop): keep an unpassed count from abandoning the confirmation

A zero count read as a parse failure and skipped the prompt, so a run with no
matching session went straight to the sweep. The counting contract is in
cli.rule.md.
```

## Pull requests and issues

A PR states the summary, the changes, how it was tested, and any breaking change, in terms of
observable behaviour.

An issue states the observable problem, the expected behaviour, and concrete reproduction
steps, naming exact types, status codes, and log lines.

## Error messages and notices

Runtime output is where directives to a person belong. State what happened and what to do,
briefly.

```
Configuration file '/etc/app/config.json' was not found.
Create the file or set APP_CONFIG_PATH.
```

Off style: `Configuration integrity requirements were not satisfied.`

A refusal names the condition and the path forward: `<path> is not in allowed projects for the
current operator. Claim it with: ai-tools --project-claim <path>`.

## Log messages

A log line records an **event at a time**, which is a different claim from the standing
behaviour reference prose describes. Name the concrete subject, and leave off the terminal
period.

- In style: `Token validation failed for user Id {UserId}`
- Off style: `Authorization process could not establish identity ownership.`

Use structured templates so fields survive into the journal or the log store.

---

# Anti-patterns

## Rhetorical figures

Name the figure and it becomes greppable. Each of these is a *shape*, not a word, so a
vocabulary filter cannot see any of them.

| Figure | Example | Why it fails | Instead |
|---|---|---|---|
| **Definitional negation** — "an X that fails a test is not an X" | "A threshold nobody acts on is not a threshold" | A tautology dressed as a finding | "An unacknowledged threshold does not raise any alert, so each one names the person who receives it" |
| **Abstraction as subject** | "A claim *leaves* nothing registered" | The subject cannot be opened in the code | "`claim()` does not write an entry when one already covers the path" |
| **Chiasmus** — mirrored clauses | "costs you a label rather than costing the sweep a target" | The reader unpicks a mirror to get one fact | Two plain sentences, or one fact stated once |
| **"Nothing" as a quantifier** | "there is nothing left to gate" | Hides *which* input is missing | "The helper does not take a path argument, so the path check is skipped" |
| **Unbacked absolute** | "The service account is never an administrator" | A claim about the code with no check named | "`start()` exits non-zero when the service account holds the admin role" |
| **Metaphor for a mechanism** | "spends the strict-mode signal" | Does not name any operation a reader can find | "does not increment any counter, so it stays out of the summary" |
| **Negation as framing** | "a host with nothing wrong" | States the absence of a fault instead of the state | "a host in a supported configuration" |

## Artifact-level

| Off style | In style |
|---|---|
| Paragraph of preamble, then code | Code block, then one paragraph naming the mechanism |
| `Arming the timer so it does not fail to fire` | `Enabling the timer so the update runs daily` |
| `Entries are pruned from the walk` | `Entries on the skip list are omitted from the walk, which keeps the sweep fast` |
| `The framework was updated to support async` | `The async handler takes precedence when both are defined` |
| `Improved reliability / Various fixes` | `Fixed HttpClient retry on 429; corrected timezone parsing in date fields` |
| Changelog entry describing the mechanism | Entry describing what the caller or operator gains |
| Commit body as long as the diff | Two short paragraphs: the why, and where the detail lives |
| Rambling multi-sentence doc comment | One-line contract; a second sentence for a real precondition |
| Bulleted list narrating each behaviour | Connected prose; bullets for true enumerations |
| Slogan or abstract principle | The observable outcome, or the concrete rule that produces it |

---

# Final pass

Scan the finished text for each of these, since every one is checkable:

1. A sentence whose subject is an abstract noun rather than a component, command, or person.
2. `is not a` / `is no` used to define rather than to describe.
3. A clause mirrored on "rather than" or "not … but", where one plain sentence carries the fact.
4. "nothing" as the subject or object of a verb.
5. "never", "always", or "cannot" with no guard named in the same sentence.
6. A behaviour introduced by what it prevents rather than by what it does.
7. History in reference prose: "now", "used to", "previously", "was changed", a date.
8. A fact stated in full in more than one place from the same perspective.
9. Filler and intensifiers.
10. A sentence carrying no fact the code, this file, or the domain rule lacks — cut it. Two
    sentences sharing a subject — merge them. (Length is the symptom, not the test: prose the
    size of its code says the code stopped being self-descriptive, and prose that is merely
    short has not thereby passed.)

**Run the checkable ones.** `prose-check.py` ships beside this file and reports items 2, 3, 4, 5,
7 and 9 plus the `does not` rule, so the pass is a command rather than an act of attention:

```bash
python3 /opt/ai-tools/skills/ai-tools-technical-docs/prose-check.py <file>...
```

It reads rejoined sentences, reports, and does not block. Items 4 and 9 and the `does not` rule
run by default and are near-exact. `--all` adds the shape checks, each of which greps a sub-shape
of its rule, because the rules themselves are about meaning: a word stem repeated across the pivot
is the mirror in item 3 and the restated head noun in item 2, and an absolute in a sentence with
no subordinating conjunction has nowhere for item 5's guard clause to be. Those four still want a
reader on every hit. Quoted, backticked, and fenced spans are skipped, so a document may quote the
prose it warns against; mark anything else deliberate with `prose-check: allow` on the line. Run
it before committing prose, and on the commit message too — the universal rules cover that
artifact like any other.

When in doubt: describe what the code does, name the mechanism that does it, and use fewer
words.

---

Design judgement belongs to `ai-tools-engineering-principles`; the oversight and governance
model belongs to `ai-tools-capable-systems-governance`. This skill governs how any of it is
written down.
