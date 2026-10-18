---
paths:
  - "README.md"
  - "docs/**/*.md"
  - "tools/generators/diagrams.py"
---

# Operator pages: `README.md` and `docs/**`

The front page and the pages under `docs/` are written for a human operator or admin — never for an agent. They state
what a reader can **do** and what happens when they do it; the mechanism behind it belongs to the rule that owns
the component. This rule holds the register, the tree, and the navigation contract. How prose is written at all is
the `ai-tools-technical-writing` skill's, from the asset set `core`, and `CLAUDE.md`'s documentation register names
which artifact takes which one: these pages are **usage prose**, so a section leads with a runnable example
and the prose glosses it.

## The tier each fact belongs to

| Tier | Reader | The question it answers | Where it lives |
|---|---|---|---|
| Front page | someone deciding whether to adopt | what this does, and the first command | `README.md` |
| Operator page | someone with `sudo` on their own host | what do I do, and what happens when I do it | `docs/**` |
| Rule | a contributor, a security reviewer, a coding agent | what the system does now, and the guarantee it provides | `.claude/rules/*.rule.md` |
| Header | whoever opens this file | that file's local mechanism | source headers |
| Doc comment | the caller | the contract, in concrete types | function comments |

**The triage test, applied per paragraph rather than per page.** The first `yes` decides where the paragraph goes:

1. Does it tell the reader something to **do** or **decide**? → an operator page.
2. Does it state a **mechanism or a guarantee** someone checks against the code? → a rule; the operator page states
   the effect and links to it.
3. Is it a **mode, a path, a verdict token, a `file:line`, or a test name**? → a rule. `prose-check.py` reports each
   of them in an always-loaded file, and the same mark applies here.
4. Does it describe an **external condition rather than this system** — a platform behaviour, an upstream defect,
   a superseded shape a supported host still carries — at a named version? → the rule that owns the component.
5. Is it **why a decision went the way it did**, or a design set aside? → the wip repo, or the changelog.

A paragraph answering `no` to all five does not carry any fact the reader needs, and the razor applies: cut it.

## The stability contract

An operator page states **principles, the CLI surface, and the properties an operator can observe**. A rule states
how the code produces them. The two tiers then move at different speeds, which is the point: a rule is rewritten
as the implementation changes without a docs page going stale, because no docs page repeats a mechanism.

| A docs page states | A docs page links to a rule for |
|---|---|
| the guarantee as an operator experiences it — "files the agent writes come back to you" | which inode is acted on, the race-safe re-check, the refusal on a symlink |
| the command, its arguments, and what it does — `ai-tools projects claim DIRECTORY` | the ACL entries the claim writes, and the mode each path ends at |
| the configuration key and its effect — `AI_TOOLS_AGENTS`, `CLAUDE_SYSTEM_PROMPT_FILE` | the trust predicate a manifest passes, and the fail-closed resolution behind it |
| the shape of a refusal, and what to do about it | the verdict tokens, the exit codes, the branch that decides each |
| what the project is not, and the boundary it does not draw | the SELinux types and the DAC modes that draw the one it does |

**The test for a sentence.** A sentence belongs on a docs page when it stays true across a refactor that does not change
a command, a configuration key, or a guarantee. A sentence naming a library function, a file mode, a label,
or a `file:line` fails that test, and its home is the rule.

**The obligation that creates.** A change altering a command, adding or removing a configuration key, or changing
a guarantee updates the docs page in the same commit. A change to a mechanism does not, and does not have to be checked
against `docs/` at all.

## The tree, and where a new page goes

A category is **a goal an operator has**, not a component of the system. `CLAUDE.md`'s component map is the agent's
index and does not mirror this one.

```text
docs/
├── index.md                     the categories, and the path a new operator takes through them
├── naming-conventions.md        the glossary every category reaches
├── option-spellings.md          generated
├── rpm-packaging.md             the package set
├── about/                       why an agent is sandboxed at all, and what this is not
├── install/                     requirements, the dnf install, from source, upgrade, uninstall
├── operators/                   enrolling an operator; service accounts and --for
├── projects/                    claiming, what a claim grants, and how each step reverses
├── sessions/                    starting a session, what it reaches, stopping one
├── agents/                      what an agent package is, and one agent's own options
├── system/                      host health: status, logs, SELinux, the entrypoint pin
├── tests/                       what the suite proves, and the drills
└── development/                 packaging, branches, releases
```

Naming follows the command surface, so a reader who knows `ai-tools projects claim` reads the tree the same way:

- **A directory's default document is `index.md`**, in every category. A category gaining a child therefore never turns
  a page into a directory, which is the redirect this convention avoids.
- **Plural names a collection** (`operators`, `projects`, `sessions`, `agents`, `tests`), where the pages under it are
  instances of one kind. **Singular names a singleton** (`about`, `install`, `system`, `development`),
  where the children are aspects of one topic. `system` takes its name from the CLI's own singleton domain
  (`ai-tools-admin system bootstrap`).
- **A name is a noun or a bare verb, never a gerund**: `install/` rather than `installing/`, `stop.md` rather than
  `stopping.md`. The path is what a search engine prints.
- **Under `projects/`, a page is named for the command it documents**, so `/docs/projects/remove` maps
  onto `ai-tools projects remove`. A new verb is a new page rather than a new heading in a long one.
- **A page name may not match a secret pattern.** `ai-tools-chown` quarantines a secret-named file the agent writes (see
  [secret-handling](secret-handling.rule.md)), and a page named for the topic matches the same globs a credential does:
  `secrets.md` matches `secrets.*` and is chowned to `<you>:<you> 600` the moment a session writes it, which leaves
  the page unreadable to every later session. The verb name is the one to reach for — `lockdown.md` documents
  `ai-tools projects lockdown` and does not match any pattern — and the same stems [authoring](authoring.rule.md) names
  for rule files are the ones to steer clear of here.

**An `index.md` carries prose, not a link list.** It opens with what the category covers and when a reader wants it,
states the facts that hold across every page under it, then links each child with a phrase saying what it answers.
A reader who stops at the index still learns something.

## Navigation

Every page under `docs/` opens with one line under its `H1`, naming its category and every sibling page that exists,
with the current page in bold and not a link:

```markdown
# Claim a project

[Projects](index.md) · [Create](create.md) · **Claim** · [Clone](clone.md) — [all docs](../index.md)
```

A category's own `index.md` carries the same line without the self-reference, leading with the category name in bold.
`docs/index.md` carries none, since it is what the line points back to. This is the only navigation furniture a page
carries: a `## See also` tail is removed where the breadcrumb and the inline links already reach the destinations.
`docs/index.md` ends with a feedback footer pointing at the issue tracker, which stays as written and which a leaf page
does not repeat.

The three link forms are not interchangeable:

| The target is | Form | Example |
|---|---|---|
| another file as a whole | ordinary link, text is the page's title | `[Project lifecycle](../projects/index.md)` |
| a section in **this** file | jump link on the heading's own slug | `[Upgrade behaviour](#upgrade-behaviour)` |
| a section, table or diagram in **another** file | a reftag, minted at the first citation; a diagram carries its own from the start | `[ref-section-y2t3](../install/from-source.md#ref-section-y2t3)` |

A page moves by `git mv`, then `bash tools/generators/ref-index.sh relink`, `check`, and `generate`: `relink` rewrites
every reftag destination from where the targets now are, and `check` reports a stale destination and an ordinary link
whose file or heading is gone. Repair the link graph with the tool rather than by hand.

## What every page owes a reader who arrives from a search

Four rules, applied while the page is written:

- **One `H1`, naming the task**, under 60 characters, and a heading tree under it that does not skip a level.
- **A lead sentence of 120–160 characters** under the `H1` and before any code block, stating what the page answers.
  The example-first rule still holds: the lead sentence is one line, and the runnable block follows it.
- **No orphan pages.** Every page is linked from its category `index.md` and links back through its breadcrumb.
- **`alt` text on any image.** The ASCII diagrams in fenced blocks need none.

Prose here wraps at **79** columns, the width configured for `README.md` and `docs/`, which a person reads:

```bash
python3 "$(bash tools/lib/assets.sh path core)/skills/ai-tools-technical-writing/scripts/prose-check.py" --all --wrap docs/<page>.md
bash tools/format.sh docs/<page>.md
```

## Diagrams

A diagram states only what its page states. A Mermaid block follows the prose that states its facts, since a reader
without a renderer sees the fenced source; an SVG pair's `<img alt>` states its claims in prose, which a reader without
the image gets in its place. Each label is a claim read against the code, as a sentence is, and a diagram stays
at the altitude of its page: an overview leaves out a branch its prose leaves out, such as the path a launch takes only
on a terminal.

**A label states an invariant**: a property this project holds for every coding agent and across releases — the account
a session runs as, which gate decides a launch and which a read, where a written file's ownership returns, the toolchain
a session runs from. A tunable value and a schedule stay in the prose and the rule that own them, as does a mechanism
one coding agent has and another lacks: no test reads a label against the code, so a label naming one goes stale
on the next change to it unreported.

**A label names a coding agent and its parts generically.** The program an operator starts is a *coding agent*,
and what a coding agent runs is a *subagent*, so a label does not use *agent* bare. A coding agent's command is
`{coding-agent-name}`, and a path that would otherwise be read as one file is written `/path/to/the/{file-or-concept}`.

**Every diagram carries a caption and a reftag from the start**, ahead of a citation: a published page is cited
from outside this tree, where a citation does not reach the index. The caption is a bold line naming the diagram, opened
by its anchor, `<a id="ref-diagram-{id}"></a>**The two gates**`, minted
with `bash tools/generators/ref-index.sh new diagram`, and a blank line separates it from the block, so the prose
checker does not read a `<picture>` block as a sentence; the caption is the name the index records. A citing sentence
states the fact in its own words with the reftag as the link text. The `alt` text does not take a reftag of its own.

A diagram goes on a page GitHub renders, `README.md` or one under `docs/`, and not in a man page or a plain-text file.
It takes one of two forms, held to the same rules:

- **A Mermaid block** for a flow or a sequence.
- **An SVG pair** for a layout Mermaid does not place. `tools/generators/diagrams.py` draws each diagram once and writes
  its light and dark variants under `docs/static/diagrams/`, which `REUSE.toml` releases under CC-BY-4.0 so a page
  elsewhere may reuse a diagram with attribution; the generator stays under the project licence. The page embeds
  the pair through `<picture>` with a `prefers-color-scheme` source. `tools/format.sh` fills the `<picture>` block
  as one paragraph, which stays valid HTML.

**A colour says whose a thing is**, and means the same on every SVG pair: you, the sandbox account and the coding agent,
the shared tree, root and what stays out of the coding agent's reach, your own group, and what is outside or leaves
the host. The theme table in `tools/generators/diagrams.py` states each colour key's meaning once, and a new layout
picks a key by that meaning. A Mermaid block keeps GitHub's theme, since a colour set in the block does not switch
between the light and dark themes.

A diagram is dropped or renamed in one change on every side it has: the block, or the layout with its SVGs and the page
embedding them, an SVG leaving through `git rm` and a renamed one through `git mv`. `tests/unit/diagrams.sh` reports
the side left behind and a diagram without its caption.
