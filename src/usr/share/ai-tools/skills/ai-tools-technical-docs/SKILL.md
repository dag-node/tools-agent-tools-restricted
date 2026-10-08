---
name: ai-tools-technical-docs
# ai-tools managed asset — provenance/versioning (RFC-draft lifecycle); the frontmatter name is stable.
x-ai-tools-managed: true
x-ai-tools-status: draft
x-ai-tools-version: 9
x-ai-tools-updated: 2026-10-06
description: >
  Technical writing standard for every software engineering artifact. Use when writing or
  editing README and usage guides, `CLAUDE.md` / `AGENTS.md`, `*.rule.md`, file and module headers,
  design notes, architecture docs and ADRs, method/function/XML doc-comments and docstrings,
  changelogs, release notes, migration guides, man pages, git commit messages, pull requests,
  issue descriptions, error messages, and log messages. Enforces concrete, present-tense,
  mechanism-named prose about observable behaviour, written for a named reader: example-first
  for usage docs, current-state specification for reference docs, contract-only for doc
  comments, operator-gain framing for changelogs, and short pointer-style commit messages.
  Trigger on any request to write or edit documentation, comments, commit messages, or change
  records. Cross-reference reftags and their tool are the `ai-tools-reftags` skill's.
---

# Technical writing standard

One standard covers every artifact the description names. The universal rules hold everywhere; each artifact type adds
its own structure, altitude, and reader.

The detail sits beside this file, read when the task calls for it: [Rewriting existing prose](references/rewriting.md)
before editing a sentence someone else wrote, [Artifact rules](references/artifacts.md) for the full form of each
artifact with its examples, [The figures in detail](references/figures.md) for the cases each rule turns on, [Running
the checker](references/checks.md) for `prose-check.py`'s modes and widths, and `references/man-pages.md` before writing
a man page.

## Core principle

Describe **observable behaviour** in concrete technical language: what happens, when, from which inputs, producing
which outputs and state changes.

Write as an experienced software engineer. The register is that of a specification or a good API reference — not a legal
document, a policy memo, an essay, or a product page.

**These rules exist to make prose plainer, so the plain version wins.** Where following a rule makes a sentence harder
to read than the obvious wording, write the obvious wording. Two rules that pull against each other are resolved
the same way, rather than by satisfying both at once — a sentence shaped to clear every rule in this file is the failure
this tiebreaker exists to prevent.

The **load-bearing** rules outrank plainness, because breaking one changes what the prose claims rather than how it
reads. They are named here by their own titles, so the set resolves without a paraphrase to interpret:

- [Rewriting existing prose](references/rewriting.md) and its rule *Carry four things through every edit*
- *Name the fail direction from the branch that decides it*
- *Label every example of prose this standard rules out*
- [One home per fact, and a pointer everywhere else](#one-home-per-fact-and-a-pointer-everywhere-else)

Everything else in this file is style, and yields to the plain version.

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

Mechanism belongs to the developer surfaces. An operator surface states the effect and links to the mechanism.

# Universal rules

## Concrete subjects and verbs

### Name a subject that can act

The grammatical subject is a component, command, function, file, or person — something with an implementation a reader
can open. Abstractions describe; they do not act.

- In style: `register() does not write an entry when an existing one already covers the path.`
- Off style: `A registration that can add nothing leaves nothing recorded.`

### State the mechanism, not the definition

A sentence shaped *"an X that ⟨property⟩ is not an X"* restates a definition, which a reader cannot check
against the code. Write what the code does and what follows from it.

- In style:
  `stop() does not take a target and enumerates every process in the account's cgroup, so a task cannot exclude itself from the sweep.`
- Off style: `A stop path the monitored system can put itself outside of is not a stop path.`

A document may carry **one** such formulation as its stated binding rule, where the compression earns its place.
Everywhere else, describe the mechanism.

### Back an absolute with its check <a id="ref-section-d7n6"></a>

"Never", "always", and "cannot" are claims about the implementation. Name the guard that makes each one true,
in the same sentence.

- In style: `launch() exits non-zero when the service account appears in the admin group.`
- Off style: `The service account is never an administrator.`

Where no guard exists, describe the behaviour without the absolute. **The fix is to name the guard, not to delete
the absolute** — an absolute a guard does back is the claim, and dropping it to `not` swaps a universal for a single
instance. Which of the two applies is decided by what the sentence is about:

| The absolute is about | Do | Why |
|---|---|---|
| this system, with a guard in the code | keep it, and name the guard beside it | it states the guarantee; `never a glob` and `not a glob` are different claims about a sudoers rule |
| the conduct required of a reader or an agent | keep it | a prohibition is the content of the sentence |
| what a person will do | drop it | `never run dnf remove first` predicts a human action; `upgrade in place, without a dnf remove first` is the instruction |
| what a third-party tool does | drop it | `DNF never pulls a new weak dependency` is a claim about someone else's code; `DNF leaves a new weak dependency off an existing install` states the behaviour |

**A claim about cost is the same shape.** "cheap", "negligible", "near-zero cost" state how often something runs
or how much work it does. Name the frequency or the bounded operation, which the code answers; a measurement is
host-dependent and is rarely what the sentence meant.

- In style: `runs once per (re)start, not per connection`
- Off style: `adds no meaningful overhead`

### Name the absent input rather than writing "nothing"

- In style: `The helper does not take a path argument, so the path validator is not loaded.`
- Off style: `There is nothing left to check, and nothing to trust.`

The defect is the hiding, not the word: `nothing is exempt` in a file that terminates processes leaves the reader
to work out the scope of a sweep, where `no cgroup under the account is exempt` states it. Name the thing, and the same
goes for `everything`, `anything`, and `all of them`.

Where `nothing` is the object of an output verb — `prints nothing when the set in force matches the baseline` — it names
an empty result and is the right word; `grants nothing`, `returns nothing` and `runs nothing` are not
of that kind, and a person who has nothing to do keeps the word under a `prose-check: ignore` marker. The cases are
in [The figures in detail](references/figures.md).

**Name the party behind a pronoun that a clause has separated from it.** The defect is the distance, not the pronoun:
once a clause stands between pronoun and party, `them` leaves the reader to work out which party is meant.

- In style: `The agent reads messages from the inbox, so an agent that freezes leaves the messages unread.`
- Off style: `The agent reads messages from the inbox, so an agent that freezes leaves them unread.`

Do not stack vague references in one clause. A `that`, an `it`, and a `them` together turn one unclear word
into an unclear sentence.

### Domain vocabulary points at a mechanism

`grant`, `claim`, `authority`, and `privilege` are correct when they name something in the code — a sudoers rule,
a POSIX ACL entry, a `claim` subcommand. Used as metaphor for what code merely does, they read as legal prose. The same
test applies to any borrowed vocabulary: point at the mechanism it names, or choose a plainer word.

Prefer plain verbs — returns, creates, loads, stores, deletes, parses, validates, caches, retries, logs, skips, reads,
writes, starts, stops, maps, serializes, emits, forwards. A verb chosen for its register rather than its meaning takes
the plain one: *verified against* `systemd.exec(5)`, not *corroborated from* it. A reader scans technical prose, often
in a second language, and the formal word costs them without adding precision. `prose-check.py` does not report this
class, so the final pass reads for it.

**A term of art in the reader's domain is a domain term, however ordinary it looks** — *maintenance*, *permission*,
*mask*, *traverse*, *weak dependency* — and stays fixed. **Some verbs name no operation**: *convey*, *leverage*,
*utilize*, *facilitate*, *handle* describe an unspecified relationship, so say which operation it is — *permits*
for an access decision, *sends* for a message, *renders* for output, *states* for an explanation. `admit` is the same
defect in a formal register: a policy or a permission **allows**, a parser or a check **accepts**, a later release
**adds**. Both lists are in [The figures in detail](references/figures.md).

### Name real mechanisms

- In style: `Uses IMemoryCache.` `Writes to Redis.` `Calls HttpClient.SendAsync().`
- Off style: `Uses the caching subsystem.` `Uses the network layer.` `Uses a helper.`

## Framing

### Lead with what the system does

Open with the behaviour. Where a reader benefits from knowing what the behaviour prevents, that comes second.

- In style:
  `chown() resolves the path once and acts on the pinned inode, so the change stays inside the tree even when the path is swapped mid-operation.`
- Off style: `Without this check a symlink could redirect the chown outside the tree.`

### Affirmative framing is structural

State what the reader can rely on. Prefer "X is available when ⟨condition⟩" to "X fails unless ⟨condition⟩" where both
state the same fact.

That condition bounds the rule. A negation carrying something the positive form does not — a prohibition, a refusal,
a defect to avoid — stays negative, because turning it around costs the reader an inference to recover the instruction
that was already there: "Do not copy a row into a header" says it, where "A copied row goes stale" leaves them to work
out what to do about it.

Turning a negation positive is sound over a set provably disjoint from the one the negation excluded, and nowhere else;
where that does not hold, keep the negation and write it with `does not`. Editing prose that already exists is governed
by [Rewriting existing prose](references/rewriting.md), which is the file to read before touching a sentence someone
else wrote.

Keep this structural: no praise, no intensifiers, no tone words, and never overstate a guarantee. No single sentence
looks upbeat; across a corpus the effect accumulates, and the documentation reads as capable and dependable.

**Write a negation with `does not`.** Fronting the quantifier instead — `writes no entry`, `takes no argument` —
attaches the negative to the object instead of the verb, which is the determiner statutes are built from. The rule
in one line: write `X does not Y`, or `X has no Y`; avoid `X Ys no Z`. A stative claim takes it too
(`a checkout has no compiled module`, not `carries no compiled module`), and the object's number follows the code, since
`does not take any path arguments` and `does not take a path argument` are different claims about arity. The cases are
in [The figures in detail](references/figures.md).

- In style: `does not write any entries`, `does not take a path argument`
- Off style: `writes no entries`, `takes no path argument`

### Keep severity proportionate

A routine check reads as a routine check. Reserve the vocabulary of failure and risk for genuine failure and risk,
so that when it appears a reader takes it seriously.

Avoid the military register — arm, fire, target, abort, kill, defend — where a plain verb carries the meaning: a timer
is *enabled* and *runs*, a unit is *stopped*, a check *refuses*.

### A term of art describes, it does not judge

Where a technical term also reads as an assessment, say which sense applies. A *weak dependency* is an RPM relation, not
a statement about the quality of what it pulls in.

### Plain register

Leave out legal phrasing (hereby, pursuant to, thereunder, entitlement, standing, void), aphorisms and slogans,
philosophical framing, and marketing language.

- In style: `Returns 401 when the request is unauthenticated.`
- Off style: `A caller lacking identity receives no authorization.`

## Sentence craft

### Rationale is the payload — state it as a mechanism, not as a figure <a id="ref-section-j4m2"></a>

Purpose is what prose exists to carry. The code already shows what happens, so a header earns its place by recording
why: the constraint that forced the choice, the alternative rejected, the foot-gun avoided. Write that freely — it is
the content worth keeping.

Write it in the same register as everything else, because this is the register that slips. Explaining why attracts every
figure the table of figures [ref-section-r3a2](references/figures.md#ref-section-r3a2) names: contrast ("rather than",
"instead of"), metaphor ("spends the signal"), definition ("a check that cannot fail is not a check"). Each states
the reason as a figure instead of a mechanism, so a reader cannot check it against the code.

Name the mechanism the reason rests on, and the constraint behind it — an external requirement, a kernel quirk,
an ordering dependency. A "so that ⟨outcome⟩" clause is the usual join. A because-, so-that-, or rather-than-sentence is
the cue to re-read it against that table. Run the check while drafting.

This governs how a reason is **phrased**, not the mood: a passage whose job is to tell the next writer what to do opens
with the instruction, and the reason follows it.

**Attach purpose where the reason is non-obvious, and nowhere else.** A named construction turns into a slot a writer
fills, and a document whose every sentence makes a causal claim reads as though none of them does. Three tests
before a purpose clause stays:

- **It says something the first half did not.** `The file is 0644, so it is world-readable` restates the mode. Cut
  the clause.
- **A reader would miss it.** Where the consequence follows from the fact for anyone who knows the domain, the fact
  stands alone.
- **The consequent names a mechanism.** `so it takes the same report` is vague;
  `so the commit-msg hook runs the checker over the message` is the same claim, checkable.

Purpose also lands without the join: as its own sentence, or as a paragraph's whole job. Where a paragraph already makes
one causal claim, check whether the next sentence earns a second.

### One fact per sentence, in one direction

Keep sentences short and single-idea. Avoid mirrored clauses that a reader must unpick to recover one fact.

- In style: `A task whose project cannot be read shows as unknown, and is terminated like any other.`
- Off style: `A missing one costs you a label rather than costing the sweep a target.`

### Present tense, active voice <a id="ref-section-a2e9"></a>

Describe current behaviour: "Returns the current session", "Loads the configuration". Use the passive only where it is
substantially clearer, and "will" only for genuinely future or conditional behaviour. Changelogs are the exception;
the changelog rule [ref-section-y8q9](references/artifacts.md#ref-section-y8q9) covers them.

### Consistent domain terms, varied ordinary nouns <a id="ref-section-g2r3"></a>

Domain terms stay fixed — a reader who learns a term once meets it unchanged. Ordinary words repeated inside one
sentence get rewritten: `own/owner/owned` piling up becomes *holds*, *belongs to*, *foreign*.

### Leave out filler

basically, simply, obviously, clearly, naturally, effectively, actually, essentially, robust, elegant, powerful,
flexible — unless the word is technically required.

## Placement

### One home per fact, and a pointer everywhere else <a id="ref-section-m8t7"></a>

Every principle gets exactly one canonical home; every other mention is a brief reference to it. The same fact in five
places is five places to update.

Restating in full is warranted only when the **perspective** changes:

| Perspective | Surface |
|---|---|
| operator, operational | README, man page, `docs/*.md`, changelog |
| security or devops reviewer | reference docs, commit messages |
| developer or coding agent | `*.rule.md`, file headers, doc comments |

The same perspective covered twice means one copy is redundant. Choose the surface whose reader needs the detail, write
it there, and point at it from the others.

**Keep a declared registry in one place.** Where code declares a table — of groups, verdicts, options, or exit codes —
name the registry in prose and leave the rows in that declaration. Do not copy a row into a header or a rule file:
a copied row goes stale the moment the table changes, and the table changes in the other file.

### Prose covers purpose and why; the code shows what

A reader should follow *how* something works from the code alone. Prose carries the intent and the non-obvious trade-off
a name, type, or signature cannot hold. Restating what the code does adds a second copy that drifts.

### Occam's razor — the fewest words that carry the full fact

Use the fewest words that still carry the full fact. The starting point for any explanation is none. A sentence earns
its place only when it carries something the code cannot: purpose, an external constraint, a rejected alternative,
or a foot-gun.

Where the code can say it instead, prefer that fix: rename a variable or function so the name itself states what it
holds or does (full words, following the language's conventions); extract a function; strengthen a type.

Two habits do most of the work:

- Merge sentences that share a subject.
- Cut any fact already carried by this file, by the code it heads, or by the domain rule that owns it. Each fact has one
  home.

**Write the shape, not the count.** A count of what the code declares — four log levels, two buckets, seven options —
goes stale on the next addition, and it goes stale in a file far from the one that changed. Name the set instead: *the
log levels the writer emits* holds however many the code grows to. **A word that implies a count is a count**: *both*,
*the two*, *either*, *the pair*, *neither* fix the size of a set as firmly as a numeral and fail more quietly, since
*both* reads as a pronoun. Name what is counted — *seeds the operator's config files* — and keep the closed-set word
only where the set is closed **by construction** and named in the same sentence, as *both halves of a pinned-fd check*
is by the check having a before and an after.

**Length is a symptom, never a budget.** Prose that approaches the size of the code it describes usually means the code
has stopped being self-descriptive; the fix is to make the code say it. Short prose is not automatically finished prose
either: the only test is whether every remaining sentence still carries a fact. A longer header is correct precisely
when the code cannot be made clearer — a kernel quirk, an ordering constraint, a workaround for a defect elsewhere —
and the point of the prose is to name that constraint. Judge each file on its own: a header at a good altitude stays
as it is, and a change that merely touches a file edits only the passages it invalidates.

### Self-contained

Prose is read without the conversation that produced it. Name the concrete mechanism; leave out session shorthand,
internal labels, ticket tags, and "as discussed" back-references.

### A reference names its target, not a position

A sentence that refers to another file's section, table, or listing names the target by a stable label, and the link's
destination is generated from where the target now is. A path, a line number, a heading anchor, and a position
in the document are the things that move, so the prose carries none of them. The positional words are for measurements
(`a load above 80%`, `a count below zero`); a placement on the screen takes another word (`under the box`,
`the parent directory`). `prose-check.py` excuses a number after the word and reports every other use.

The label is a **reftag**, and the grammar — the families, the message codes a runtime message carries, when an id is
minted and when it is retired — and `ref-index.py`, which mints, indexes, checks and relinks them, are
the `ai-tools-reftags` skill's. Within one file, cite a section by its title as a jump link, `[Title](#its-slug)`.
The sections of this standard carry reftags ahead of a citation, as the one exception: they are general principles,
cited from other files and other projects.

- In style: `The umask rule [ref-section-m7g9](../cli.rule.md#ref-section-m7g9) re-runs the create and clone rows.`
- Off style: `The section below re-runs the create and clone rows.`

### Resolve a doc/code conflict while writing, in the right direction <a id="ref-section-p6c5"></a>

Where a doc and the code disagree, resolve it then — do not default to either side, and do not commit a known
inconsistency. Which side moves depends on what the prose is doing:

- **A description of behaviour** — a file header, a doc comment, most rule prose. The code decides what it says,
  and the stale side is not reliably the prose.
- **An invariant** — a `CLAUDE.md` guarantee, a stated MUST, a security property. The prose stands and the code is
  the defect: raise it. Rewriting the invariant to match retires a guarantee by editing prose.
- **A migration in progress** — the prose leads and the code follows: describe the target state as current, and record
  the dependency where that forces a mention of something not yet built. The gap is expected, so it is recorded rather
  than resolved away in either direction.

Ask when which of the three applies is genuinely unclear, rather than committing a guess.

## The three axes

Purpose (*what to include*: the guarantee a behaviour provides), spec style (*how to phrase it*: terse, factual,
normative where it prescribes) and current state (*tense and frame*: what is, rather than what changed) constrain
different things, and compose. RFCs are full of purpose: "receivers MUST ignore unknown fields *so that* the format
stays forward-compatible" is purpose, spec style, and present tense at once. Friction appears only when purpose is
written as **history** or as a **predicted human action**. A "so that ⟨invariant⟩" clause on a fact about what the code
does is one way to attach it — see the limit on it under [Rationale is
the payload](#rationale-is-the-payload--state-it-as-a-mechanism-not-as-a-figure).

# Rewriting existing prose

Every writing rule in this standard governs a first draft. Editing prose that already exists is a different operation:
the claim is already in the sentence, and the job of the edit is to keep it. **A rewrite changes the wording, not
the claim** — same subject, same set, same number, same modality, every fact and no new ones — and where the new wording
cannot carry the claim, the sentence stays as it is; one stating a security boundary, an invariant in an always-loaded
layer, or a disclosure claim stays and the conflict is raised as a finding. The procedure, the four things an edit
carries, and the checks a rewrite runs are in [Rewriting existing prose](references/rewriting.md); read it
before the first edit of a pass.

# Pick the artifact

| Artifact | It is right when |
|---|---|
| **Usage / README** | a reader meets a working example before any prose, and every following sentence names the exact type, call, or option |
| **Reference / `*.rule.md` / header** | every sentence states what the system is or does now, and rationale appears as the invariant a behaviour guarantees |
| **Doc comment** | the summary names what the member does and the concrete type it does it with, and reads as a tooltip |
| **Changelog** | each entry names what an operator gains or must change on upgrade, grouped so breaking changes are found in one pass |
| **Commit** | the subject states what the change achieves, and the body is shorter than the diff |
| **Error / log** | it states what happened and, for an error, what to do next |

The full rule for each, with its examples, is in [Artifact rules](references/artifacts.md). Three of them are
load-bearing wherever the artifact appears: a literal a reader types or pastes is backticked and a command begins
with its binary; a reference doc **names the fail direction from the branch that decides it** and whether access widens
or narrows, with a root `CLAUDE.md` at invariant altitude, the domain mechanism in its rule and the file's mechanism
in its header, the three reconciled whenever one is touched; and a commit message follows Conventional Commits, its
subject stating what the change achieves, its body the why and where the detail lives, and its trailers the repository's
`CONTRIBUTING`, read before the first commit in that repository.

# Anti-patterns

**Label every example of prose this standard rules out.** A document that has to contain bad prose marks it as bad —
an *Off style* prefix, a ✗ column, or the imperative it violates stated first. Never leave a defect standing
as a neutral description of what some wording achieves: read without the surrounding argument, an unlabelled example is
followed as an instance of the standard.

Name the figure and it becomes greppable: definitional negation, abstraction as subject, chiasmus, "nothing"
as a quantifier, the unbacked absolute, metaphor for a mechanism, negation as framing. Each is a *shape*, not a word,
so a vocabulary filter cannot see it; the table of figures [ref-section-r3a2](references/figures.md#ref-section-r3a2)
gives each one its example, why it fails, and the plain form, and the artifact-level table closes [Artifact
rules](references/artifacts.md).

# Final pass

Scan the finished text for each of these, since every one is checkable:

1. A sentence whose subject is an abstract noun rather than a component, command, or person.
2. `is not a` / `is no` used to define rather than to describe.
3. A clause mirrored on "rather than" or "not … but", where one plain sentence carries the fact.
4. "nothing" — or "everything", "anything" — as the subject or object of a verb, where naming the thing would state
   the scope.
5. "never", "always", or "cannot" with no guard named in the same sentence; "cheap", "negligible", or "near-zero cost"
   with no frequency or bounded operation named in it.
6. A behaviour introduced by what it prevents rather than by what it does.
7. History in reference prose: "now", "used to", "previously", "was changed", a date.
8. A fact stated in full in more than one place from the same perspective.
9. Filler and intensifiers.
10. A sentence carrying no fact the code, this file, or the domain rule lacks — cut it. Two sentences sharing a subject
    — merge them. (Length is the symptom, not the test: prose the size of its code says the code stopped being
    self-descriptive, and prose that is merely short has not thereby passed.)
11. A person predicted rather than a system described: "if you want", "you should", "users will", "a host that wants it
    enforced".
12. Domain mechanism in the always-loaded layer: a file mode, a test path, or a `file:line` reference in a root
    `CLAUDE.md` or `AGENTS.md`.
13. A count of what the code declares, including the words that imply one — "both", "the two", "the pair" —
    where the set can grow. Name the set instead.
14. A command, an option, a placeholder, a variable, or a filepath standing bare in prose where a reader would type
    or paste it. Backtick it, and give a command its binary.

**Before committing, name the file each behavioural sentence was read from.** Not as a citation in the prose —
as a check made while editing. Open the code during this edit, and do not let a recollection stand for a reading.

**An absence is a claim about your search.** "There is no rationale for this mode", "no standard covers this", "the
reason is documented nowhere" — each asserts that a fact is missing from every place it could live, which is a far
larger claim than finding one. Before writing or acting on it, name the tiers that could hold it and check each:
the router, the domain rule, the file header, the inline comment, the **tests**, the packaging, and the external
convention the artifact belongs to. Two of those are the ones that get skipped. A **boundary test** is where a project
records that a state is unreachable, so a mode or a refusal with no rule explaining it may be justified there
and nowhere else. And **this standard is itself one of the tiers** — a question about how to write a changelog entry,
a doc comment, or a commit message is answered here before it is answered anywhere else. An absence claim that has not
covered them reports where you looked, not what is there.

**A finding names a symptom. Fix the claim, not the token** — the procedure is the rewrite-from-source rule
[ref-section-e8b7](references/rewriting.md#ref-section-e8b7), and it applies to a first draft's own findings as much
as to a rewrite pass.

**Run the checkable ones.** `prose-check.py` ships beside this file and reports items 2, 3, 4, 5, 7, 9, 11, 12 and 14
plus the `does not` rule, so the pass is a command rather than an act of attention:

```bash
python3 /opt/ai-tools/skills/ai-tools-technical-docs/prose-check.py <file>...
```

It reads rejoined sentences, reports, and does not block; `--all` adds the shape checks that want a reader on each hit.
A check that mostly flags correct prose is a bug in the check, not in the text: measure it and propose the change rather
than silencing it. The modes, the `prose-check: ignore` markers, the wrap widths each kind of file is held to,
and `--new`, which reports only what a change added, are in [Running the checker](references/checks.md).

When in doubt: describe what the code does, name the mechanism that does it, and use fewer words.

Design judgement belongs to `ai-tools-engineering-principles`; the oversight and governance model belongs
to `ai-tools-capable-systems-governance`. This skill governs how any of it is written down, and cross-reference reftags
are `ai-tools-reftags`'s.
