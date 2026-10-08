# The figures in detail

`SKILL.md` states each rule in a paragraph; this file carries the table of figures and the cases a rule turns
on, with the exemptions the checker applies and the shapes it does not exempt.

## Rhetorical figures <a id="ref-section-r3a2"></a>

Name the figure and it becomes greppable. Each of these is a *shape*, not a word, so a vocabulary filter cannot see any
of them.

| Figure | Example | Why it fails | Instead |
|---|---|---|---|
| **Definitional negation** — "an X that fails a test is not an X" | "A threshold nobody acts on is not a threshold" | A tautology dressed as a finding | "An unacknowledged threshold does not raise any alert, so each one names the person who receives it" |
| **Abstraction as subject** | "A claim *leaves* nothing registered" | The subject cannot be opened in the code | "`claim()` does not write an entry when one already covers the path" |
| **Chiasmus** — mirrored clauses | "costs you a label rather than costing the sweep a target" | The reader unpicks a mirror to get one fact | Two plain sentences, or one fact stated once |
| **"Nothing" as a quantifier** | "there is nothing left to gate" | Hides *which* input is missing | "The helper does not take a path argument, so the path check is skipped" |
| **Unbacked absolute** | "The service account is never an administrator" | A claim about the code with no check named | "`start()` exits non-zero when the service account holds the admin role" |
| **Metaphor for a mechanism** | "spends the strict-mode signal" | Does not name any operation a reader can find | "does not increment any counter, so it stays out of the summary" |
| **Negation as framing** | "a host with nothing wrong" | States the absence of a fault instead of the state | "a host in a supported configuration" |

## `nothing`: what the output-verb exemption covers

**Where `nothing` is the object of an output verb, it names an empty result and is the right word.**
`Prints nothing when the set in force matches the baseline` states what a caller reads; there is no absent *input*
to name. The exempt verbs are the ones whose object **is** the output — `prints`, `writes`, `emits`, `reports`,
`renders`, `says`, `yields`, `outputs` — and the exemption reaches only the verb that governs the word.

- In style: `Prints nothing when the set in force matches the baseline.`
- Off style: `The sweep prints a summary, and nothing is exempt.` — the output verb is in the other clause, so the scope
  is still unnamed: `no cgroup under the account is exempt`.

Three shapes sit outside the exemption, and each is a claim to write differently:

- **`grants nothing`** reads like the others and is not one of them. What is granted is an authority over some scope,
  which the sentence still owes the reader.
- **`returns nothing`** says what a caller gets *back*, which in shell is a status and in most languages is `void` —
  so the phrase is seldom true and never states what was written. Name the stream: `prints nothing`.
- **`runs nothing`, `loading nothing`** name an empty *effect* rather than an empty output. Write the effect:
  `is not executed`, `without loading a module`.

**Where the actor is a person, `nothing` is often the right word and the replacement is not.** "what you have to do
about it (almost always nothing)" is an action the reader takes; `none` reads as a count of some set the sentence never
named. Keep the sentence and mark the line
`prose-check: ignore` — in Markdown as `<!-- prose-check: ignore -->`, which the checker reads and
the rendered page does not show.

## Verbs that name no operation

*convey*, *leverage*, *utilize*, *facilitate*, *handle* describe an unspecified relationship, so a reader cannot check
them against the code. Say which operation it is: **permits** or **grants** for an access decision, **transmits**,
**sends**, or **routes** for a message, **displays**, **renders**, or **shows** for output, **states**, **describes**,
or **specifies** for an explanation. `--x` on a directory *permits traversal*; it does not *convey* anything. A word
with a settled meaning in one domain keeps it there — `convey` is the GPL's own term for distributing a work,
and licensing prose is where it belongs.

`admit` is the same defect in a formal register, and `prose-check.py` reports every inflection of it by default:
a deployment policy or a permission **allows** a tag or an account, a parser or a check **accepts** a shape, a later
release **adds** a kind, and a sanitizer **keeps** the characters it does not replace. Name the operation the code does;
the gate that `admits` a name in a charset *accepts* it.

*attribution* is the same case as a noun: name the thing. An **audit trail** or **provenance** records who acted,
a **root cause** explains why something failed, an **attribute** or **field** is data on an object, and a **label** is
what a row in a report carries.

**A term of art in the reader's domain is a domain term, however ordinary it looks.** *maintenance*, *permission*,
*mask*, *grant*, *traverse*, *weak dependency* have settled meanings in systems and operations prose, so they stay fixed
under the domain-terms rule [ref-section-g2r3](../SKILL.md#ref-section-g2r3). Keep them: substituting a near-synonym
(*upkeep* for *maintenance*) costs the reader a term they already know.

## The fronted quantifier

**Write a negation with `does not`.** Fronting the quantifier instead — `writes no entry`, `takes no argument` —
attaches the negative to the object instead of the verb. It reads formal to archaic, and it is the determiner statutes
are built from (*no person shall*, *no warranty is given*). The fronted form is the shorter one, and the longer one wins
anyway: the razor takes the fewest words that stay clear.

- In style: `does not write any entries`, `does not take a path argument`
- Off style: `writes no entries`, `takes no path argument`

**The rule in one line: write `X does not Y`, or `X has no Y`; avoid `X Ys no Z`.** `has no` is the plain existential
and does not need a rewrite — it is one of the four verbs the check leaves alone, with `is`, `was` and `had` —
so a stative claim has two ordinary forms and no reason to reach for the third.

**A stative claim takes the rule too, and is where it is missed.** `writes no entries` and `takes no path argument` are
actions with a caller-supplied object, which is the easy case; the shape that survives a redraft describes
what an artifact *has* — `a checkout carries no compiled module`, `the header registers no entry`. Fronting reads
as natural there. It is the same figure, in a declarative rather than a procedural sentence.

- In style: `a checkout has no compiled module`, `the header does not register an entry`
- Off style: `a checkout carries no compiled module`, `the header registers no entry`

**The object's number follows the code, not a preference.** `does not take any path arguments`
and `does not take a path argument` are different claims about arity — a variadic parameter against a single one —
so the signature decides which is true. A definite object keeps its article: `does not increment the counter`.

The same applies to `nothing` as a subject or object, which the checklist already catches: name the absent input
instead.
