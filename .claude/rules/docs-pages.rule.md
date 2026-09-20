---
paths:
  - "README.md"
  - "docs/**/*.md"
---

# Operator pages: `README.md` and `docs/**`

The front page and the pages under `docs/` are written for a human operator or admin — never for an agent. They state
what a reader can **do** and what happens when they do it; the mechanism behind it belongs to the rule that owns
the component. This rule holds the register, the tree, and the navigation contract. How prose is written at all is
the shipped `ai-tools-technical-docs` skill's, and `CLAUDE.md`'s documentation register names which artifact takes
which one: these pages are **usage prose**, so a section leads with a runnable example and the prose glosses it.

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
| a section, table or diagram in **another** file | a reftag, minted at the first citation | `[ref-section-y2t3](../install/from-source.md#ref-section-y2t3)` |

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
python3 /opt/ai-tools/skills/ai-tools-technical-docs/prose-check.py --all --wrap docs/<page>.md
bash tools/formatters/format.sh docs/<page>.md
```
