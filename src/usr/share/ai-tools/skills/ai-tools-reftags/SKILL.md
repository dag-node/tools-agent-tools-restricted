---
name: ai-tools-reftags
# ai-tools managed asset — provenance/versioning (RFC-draft lifecycle); the frontmatter name is stable.
x-ai-tools-managed: true
x-ai-tools-status: draft
x-ai-tools-version: 1
x-ai-tools-updated: 2026-10-06
description: >
  Cross-reference grammar for a documentation tree: a section, table, listing, function doc,
  comment note, runtime message, or URI that another file cites carries a reftag (`ref-section-h3b7`,
  `MSG-F6Z3`), and the citation is a link whose text is the reftag, never a line number, a heading
  anchor, or a position. Ships `ref-index.py`, which mints an id, writes the index, checks every
  reference against where its target now is, rewrites stale destinations, and retires an id
  the tree dropped. Use when adding a cross-reference between files, labelling a referent another
  document or test cites, minting or retiring a message code, regenerating the index, or reading
  a `check` finding (duplicate, undefined, same-file, misplaced, missing, stale, resurrected,
  malformed, link). Trigger on "reftag", "ref-section", "message code", a `MSG-` token,
  "cross-reference", "references.md", or a stale link between documents. Prose style is the
  `ai-tools-technical-docs` skill's.
---

# Cross-reference reftags

A reference between files names a reftag; the tool resolves the reftag to where the target now is. This skill states
the grammar and the tool; how the sentence around a reference is written is the `ai-tools-technical-docs` skill's.

## A reference names a reftag, not a position <a id="ref-section-h9b7"></a>

A table, a diagram, a listing, or a section that prose in another file refers to carries a reftag, and the reference is
a link whose text is the reftag: `the owner rule [ref-section-j5r7](../cli.rule.md#ref-section-j5r7)`. The sentence
states the fact in its own words, the reftag says where the full statement lives, and the name lives at the target
and in the index. A path, a line number, a heading anchor, and a position in the document are the things that move,
so the prose carries none of them: the link's destination is generated, checked against where the target now is,
and rewritten when it moves. Print manuals and papers apply the same rule to figures and tables: a reference names
the numbered caption, not the place on the page.

A reftag is a prefix, a dash, and an id of the form letter, digit, letter, digit: `w7a7`, which keeps a plain word
or number out of the id position. The id is drawn at random, so a reader does not read an order into it, and one id
names one thing across all families, whatever the prefix; two things are never related by sharing one. A match is always
the full reftag, prefix and dash included: an id alone is a shape generated names and key material take too. Lowercase
names a place in a document, which renders as a link; UPPERCASE names a key that lives in code, in output,
or in a registry and is found by a search on the token. The target carries the reftag as an anchor and the reference is
a link, the split every markup system makes:

| Family | Reftag | Target |
|---|---|---|
| a place in a document, by kind | `ref-section-h3b7`, `ref-table-z4m9` | a heading closed by an anchor, `## Two project models <a id="ref-section-h3b7"></a>`, or an anchor and a bold caption on the line before the block, `<a id="ref-table-z4m9"></a>**Altitudes and who owns which fact**` |
| function doc, comment note | `FN-Q2H8`, `NOTE-A5H9` | a comment line, `FN-Q2H8: <function name>` |
| runtime message | `MSG-F6Z3` | the emit call: the token as the command's first argument, then the quoted message it labels, `die MSG-F6Z3 "not a claimed project"`, the message read off the next line where a backslash breaks the call between them. A code in a later argument, or before a string opening with an expansion, cites the message instead — which is how a test names the code it expects |
| resource identifier | `URI-Q4Q6` | one link definition line, `[URI-Q4Q6]: https://… "name"` |

The kinds a document reftag may name, and what each one is, are declared in `ref-index.py` and printed by `kinds`,
so a writer picks one without reading the tool; `section`, `table`, `diagram`, and `listing` cover a documentation tree.
A target's name is its heading text, its bold caption, the text after the colon, or the message's first line. A document
cites any family as `[reftag](destination)`, where the destination is the relative path and anchor for a document
target, the file alone for a code target, and the URI itself; a source comment cites by the bare reftag.

## Message codes name a situation

A message code names a **situation**: a refusal that exits non-zero, a warning a test asserts, a guidance screen,
the outcome a question produced. A question itself, a flow headline, and a per-tick progress line are renderings,
and take none. The code is the identity a test asserts and the token a user types into a search engine when the message
is on their screen, so it stays fixed through every rewording of the message: a rewrite keeps the code, and a new code
is minted only for a new situation, with the old one retired. The index records the message's current first line beside
the code and the word that emits it. Runtime output carries a reftag and no URL, Markdown link, or HTML anchor: a link
in a log line is unresolvable in `journalctl` and ages faster than the code, where the reftag resolves
through the index. A quoted string that opens with an expansion (`assert_msg MSG-F6Z3 "$out"`) does not name a message,
so that site is a reference, which is how a test cites a code beside the output it captured.

## When to mint, and when the id stays

Mint a reftag the first time another file refers to the referent, and not before: a reftag exists for a fact whose home
is another file, so reftags stay rarer than links to a file as a whole. Within one file, cite a section by its title
as a jump link, `[Title](#its-slug)`, and a table by what it lists: a reader takes a file in one pass, and a reftag
inside it is a detour, which the tool reports. The tool reports the jump link too once its heading has left the file,
with the hint to cite the reftag, which is how a file follows a section that moved out. A reference to something without
a reftag is fixed by minting one, and a paragraph carrying more than one reference is the shape to refuse: the sentence
reads complete without following the link. A shipped standard whose sections other projects cite is the one exception:
its sections carry reftags ahead of a citation.

**A reftag belongs to the principle a referent states, not to its wording.** A rewrite that keeps the principle keeps
the reftag: rewording the prose, reflowing it, moving the section within its file or to another file, and retitling it
all leave the id alone, because every citation and every log line already naming it goes on resolving. **Whether
the principle survived is a judgement the writer makes**, by reading the old referent against the new one — a changed
title is evidence and not the test, and a title reformulated over the same principle is no change at all.

Retire an id when the referent leaves the tree, or when what it states has changed substantially enough that a reader
following an old citation would land on a different claim; that is a new referent, and it takes a new id. A retirement
recorded beside a live row stating the same principle is the shape to look for: the id churned under a referent
that survived, which spends the retired id and strands every reference made before the change. Where a draft mints an id
and the writer reaches for the minter again over the same principle, the first id stands.

A document's own navigation does not take a reftag. A contents line and a jump to one of the document's sections are
ordinary links, `[Upgrade behaviour](#upgrade-behaviour)`, whose text is the title and whose fragment is the heading's
own slug; a link to another file as a whole, `[launch](launch.rule.md)`, is the same. Both are checked with the reftags,
since a renamed heading breaks a contents line silently.

- In style: `The umask rule [ref-section-m7g9](../cli.rule.md#ref-section-m7g9) re-runs the create and clone rows.`
- Off style: `The section below re-runs the create and clone rows.`

## The tool

`ref-index.py` ships beside this file. `kinds` prints the registry, `new <family>` mints a reftag, `generate` writes
the index, `where <reftag>` prints the target's live `file:line`, `relink` rewrites every destination
from where the targets are, and `check` reports a reftag defined twice, an id shared by two kinds, a reference with no
target or to a target in its own file, a caption with no block after it, a destination that is missing or stale,
an ordinary link whose file or heading is gone, a retired reftag defined again, and a reftag whose id is malformed:

```bash
python3 /opt/ai-tools/skills/ai-tools-reftags/ref-index.py check <file>...
```

A malformed reftag is a prefix followed by anything but a four-character id (`ref-section-k7q`, `MSG-12`): a search
for the token does not find a target, so `check` reports it at the prefix. Write the id in full, or drop the reftag
shape where the token names an argument, as `MSG-CODE` in a usage line does. A source file contributes its comment lines
alone, since a code line carries the bare prefix as a pattern or a string; the bare `ref-` prefix is not read anywhere,
since it opens ordinary words.

A fenced block and a backticked span are not read, so a document may show a reftag it does not define; the index lists
such a reftag as an example, which reserves its id. A line carrying `ref-index: ignore` is not read either, and a file
carrying `ref-index: ignore-file` as a whole comment line is not read at all, which is how a test holds its fixtures.

A reftag that leaves the tree is retired, and its id stays taken. `retire` appends each index row the tree no longer
defines to a retired file, with the date and the release the tree is at, and `new` reads that file as well as the index;
`generate` is stateless, so a repository runs `retire` ahead of it. A message code lands in a durable audit trail,
and an id drawn again for another situation would make an old journal line resolve to the wrong one. The release column
is what a row's age is counted in: a repository drops a row once its release is a few stable releases behind, by hand.
The retired file is history: a session reads the index for current state and does not read the retired file.

A repository wraps the tool in a script of its own that names the files it reads and the index it writes, so the tool
stays argument-driven and the paths are stated once, for a pre-commit hook, a test, and a developer's run alike.

### When the tool is the defect

A `check` finding that names a shape this grammar allows, or a hint that points to the wrong fix, is a bug
in `ref-index.py`, not in the tree. Do not silence it with `ref-index: ignore` or a reword that only dodges the pattern;
that hides the evidence and leaves the cost for everyone else. **Measure first**: run `check` on the whole tree
and report how many findings a reviewer would keep against how many are noise, then propose the change to the tool
and to this grammar together. A proposal without a count is a preference; a proposal with a count is evidence.
