# Man pages

Read this before writing or editing a man page. The universal rules in `SKILL.md` apply
throughout; this file carries the form, the section order, and the altitude that a man page
uses and no other artifact does.

## Provenance

This file is original prose written for this project. It **points at** the normative standard
rather than reproducing it: the naming conventions, section numbering, and heading order it
summarises are long-standing interface conventions, documented independently by `man-pages(7)`,
BSD `mdoc(7)`, and the GNU coding standards.

`man-pages(7)` itself is part of the Linux man-pages project and carries its own copyright and
licence, which differ from this project's. Quote it only with attribution, and prefer sending a
reader to the installed page over copying text out of it.

## The standard to follow

`man-pages(7)` is the normative convention for Linux man pages and is installed on the host.
Read it directly whenever a question is not answered here — it is authoritative and this file
is not:

```bash
man 7 man-pages
```

Companion pages: `man(7)` for the `an.tmac` macros themselves, and `groff_man(7)` for the full
macro reference. Write new pages with the `an` macros — `.TH`, `.SH`, `.SS`, `.TP`, `.B`, `.I`,
`.IR` — because effectively every existing Linux man page uses them.

## Read a well-maintained page before writing one

The fastest calibration is reading a page maintained by people who care. These are on a RHEL or
Rocky host already:

| Page | Worth reading for |
|---|---|
| `man 5 sshd_config` | a long option list that stays scannable; one `.TP` per keyword, defaults stated inline |
| `man 5 systemd.exec` | dense configuration reference with cross-references done well |
| `man 5 sudoers` | a complex grammar explained without turning into a design document |
| `man 1 ssh` | SYNOPSIS conventions and the split between DESCRIPTION and OPTIONS |
| `man 8 semanage-fcontext` | a short admin command page with useful EXAMPLES |

Prefer the shape of the page closest to what is being written: a section 1 command page, a
section 5 file-format page, a section 8 administration page.

## Section number

| Section | Contents |
|---|---|
| 1 | user commands runnable from a shell |
| 5 | file formats and configuration files |
| 7 | overviews, conventions, miscellany |
| 8 | system administration commands, typically root-only |

A CLI that an operator runs is section 1. Its configuration file is section 5, as a separate
page. A helper that only root invokes is section 8.

## Section order

Command and configuration pages in this project use the traditional headings in this order,
keeping only those that carry content. `man-pages(7)` lists the complete set, including the
headings that apply to library and syscall pages:

```
NAME
SYNOPSIS
DESCRIPTION
OPTIONS
EXIT STATUS
ENVIRONMENT
FILES
NOTES
CAVEATS
BUGS
EXAMPLES
SEE ALSO
```

Traditional headings beat invented ones: a reader who knows where EXIT STATUS lives finds it
without reading the page. Where a section needs internal structure, add `.SS` subsections under
the traditional heading rather than a new top-level heading.

- **NAME** — `name \- one-line description`, all lowercase apart from proper nouns and
  terminology. This line feeds `apropos` and `whatis`, so it states what the thing is rather
  than a slogan.
- **SYNOPSIS** — the grammar. Bold for literal text, italic for replaceable arguments, `[]`
  around optional arguments, `|` between alternatives, `...` for repetition.
- **DESCRIPTION** — what the program or format does, how it interacts with files, standard
  input, standard output, and standard error. Describe the usual case; options belong to
  OPTIONS.
- **EXIT STATUS** — every code the command returns and what each means.
- **FILES** — the paths the command reads and writes, with what each holds.
- **EXAMPLES** — real invocations that work as written.
- **SEE ALSO** — related pages as `name(section)`, comma-separated, alphabetical.

## Altitude: the operator's contract, not the mechanism

A man page states the **interface**: what to run, what the options do, what comes back, which
files are touched, and which exit codes to branch on. Internals stay out unless an operator
needs one to use the command correctly; `man-pages(7)` sets the same expectation for its
DESCRIPTION section.

Mechanism belongs in the reference tier (`*.rule.md`, file headers). Where an operator needs to
know that a mechanism exists — because it changes what they should do — state the consequence
and leave the mechanism out.

- Off style: `Because the unit runs inside the sandbox account's own user instance, its state cannot be queried directly, so all commands are routed through root over the machine transport.`
- In style: `Reports the unit as unknown when its state cannot be read. Re-run as root for a full report.`

Keep out anything that applies to one distribution channel rather than to the installed
command — a source-tree layout, a build path, a developer workflow.

## Form

- **Semantic newlines.** Start each sentence on a new line, and split long sentences at clause
  boundaries. Diffs then land on the sentence that changed rather than reflowing a paragraph.
  `man-pages(7)` describes this convention under that name.
- **Source lines under about 75 characters**, the width `man-pages(7)` asks for.
- **Bold for what the reader types, italic for what they substitute.** `.B --project-claim`,
  `.I path`. Mixed forms use `.BR`, `.IR`, `.BI`.
- **One `.TP` per option**, tag first, description following. Note the default in the
  description.
- **Cross-reference as `name(section)`** — `ai-tools(1)`, `operator.conf(5)` — with `.BR` markup
  so the section number renders unbolded.
- **ASCII only**, including in examples.

## Keeping a page current

A man page is part of the same coupled set as the CLI it documents: an added flag, a changed
default, or a new exit code lands in the same change as the page. Where a page and the command
disagree, the command decides what the page says.

State the current interface. A page does not carry a changelog; what changed belongs to the changelog
and to git.

## Check before finishing

```bash
man --warnings -E UTF-8 -l <page> >/dev/null    # macro and formatting warnings
MANWIDTH=80 man -l <page> | less                # read it as an operator will
```

Then read the rendered page top to bottom once: NAME says what it is, SYNOPSIS shows the
grammar, every option in OPTIONS appears in SYNOPSIS, every exit code the command returns is
listed, and the EXAMPLES run as written.
