---
name: ai-tools-docs-usage
# ai-tools managed asset — provenance/versioning (RFC-draft lifecycle); the name above is stable.
x-ai-tools-managed: true
x-ai-tools-status: draft
x-ai-tools-version: 1
x-ai-tools-updated: 2026-07-15
description: "Use when writing or editing README files, getting-started guides, quickstarts, usage and how-to documentation, or any docs that teach a reader how to use a library or tool. Enforces an example-first, terse, present-tense style: lead with a runnable example, gloss it in concrete prose that names the exact mechanism, keep the README thin and link to canonical docs. For CLAUDE.md, file headers, design notes, and normative reference prose use ai-tools-docs-reference instead. For method/function/XML doc-comment and docstring form use ai-tools-docs-comments instead. For changelogs, release notes, and migration guides use ai-tools-docs-changelog instead. Trigger on 'write a README', 'getting-started docs', 'usage guide', 'quickstart', or 'document how to use this'."
---

# Usage docs

A usage doc teaches by example. Lead a section with a minimal runnable code block, then explain it in terse present-tense prose that names the exact mechanism. The example is the topic sentence; the prose is the gloss.

## Scope and routing

This skill governs READMEs, getting-started/quickstart guides, and usage/how-to docs. If the task is a different artifact, stop and use the matching skill:

- CLAUDE.md, file/module headers, design notes, reference docs -> `ai-tools-docs-reference`
- A doc/summary comment on a method, function, or class (any language) -> `ai-tools-docs-comments`
- Changelog, release notes, migration guide -> `ai-tools-docs-changelog`

## One-line test

A reader meets a working example before any prose, and every sentence after it names what the code does and the exact type, property, or call that does it. The doc carries no preamble, no hedging, and no history.

## Core properties

**Example first.** Lead with a minimal, runnable code block, then explain it. A section that opens with a paragraph of preamble before the reader sees code is out of style.

**Name the mechanism exactly.** Prose refers to the concrete artifact by its real name — the method, the option, the status code it returns — not vague paraphrase ("the helper", "the thing that runs"). Specificity is the tone.

**Present tense, indicative.** "Returns all rows", "limits access to GET", "runs once on startup." Avoid "will" except for genuine future/conditional behavior; avoid history.

**Terse and dense.** Use the fewest words that carry the full information. Short declarative sentences, no filler intensifiers. Chain related facts with semicolons or em dashes rather than padding.

**Flowing prose over bullets.** Explanation is connected paragraphs. Bullets are for genuine enumerations (supported formats, options), not for narrating behavior.

**Consistent vocabulary.** Reach for one consistent set of domain terms rather than inventing synonyms for the same concept; a reader who learns a term once should meet it unchanged throughout.

**Cite sources when useful.** Link to the canonical docs, the spec, or the issue/PR a behavior derives from, rather than restating them — a link is shorter than a paraphrase and stays correct.

## UTF-8 icons

Usage docs are read by humans, so sparing UTF-8 icons are allowed where they carry meaning — a section marker, a check/cross in a do/don't table, a warning glyph. Keep them functional, not decorative; one per idea at most. (Doc comments and bash headers stay ASCII-only; this allowance is specific to human-facing usage prose.)

## README shape

A README in this style is thin and link-forward: it orients and points at the canonical docs rather than duplicating them. In order: a one-line capability statement (a confident tagline register is allowed, kept to one line); the smallest example that demonstrates the core value end-to-end; install/usage essentials; links to docs, support, and source. It stays current by pointing at the docs, not restating them.

Skeleton:

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
Support: <forum/issues link> | Source: <repo-url>
~~~

Within any usage section, the code block precedes the prose. Example:

~~~markdown
## Define a handler

```python
@app.get("/contacts")
def get_contacts():
    return db.select(Contact)
```

`get_contacts` returns every row of the `Contact` table via `db.select`. The route
is registered for GET only; other verbs to `/contacts` return 405 Method Not Allowed.
~~~

The prose names the exact mechanism (`db.select`, the 405), so the reader learns the behavior and the call that produces it in the same breath.

## Anti-patterns

| Out of style | In style |
|---|---|
| Paragraph of preamble, then code | Code block, then one paragraph explaining it |
| "This handy method will basically fetch the data" | "Returns all rows matching the filter via `db.select`" |
| "The framework was updated to support async" | "The async handler takes precedence when both are defined" |
| Bulleted list narrating each behavior | Connected prose; bullets only for true enumerations |
| README restating the full docs | README with one example and a link to the docs |
