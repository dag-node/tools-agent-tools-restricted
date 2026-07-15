---
name: ai-tools-docs-comments
# ai-tools managed asset — provenance/versioning (RFC-draft lifecycle); the name above is stable.
x-ai-tools-managed: true
x-ai-tools-status: draft
x-ai-tools-version: 1
x-ai-tools-updated: 2026-07-15
description: "Use when writing or editing doc/summary comments on a method, function, class, or module in any language — C# XML docs (///<summary>), Python docstrings, JSDoc/TSDoc, or a bash function header block. Enforces a terse, present-tense summary that states the contract and names the mechanism in concrete types, short enough to read as IDE intellisense. For README files and usage guides use ai-tools-docs-usage instead. For CLAUDE.md, file headers, design notes, and reference prose use ai-tools-docs-reference instead. For changelogs and release notes use ai-tools-docs-changelog instead. Trigger on 'document this function/method', 'add docstrings', 'write XML docs', 'add Javadoc/JSDoc', or 'comment these functions'."
---

# Doc comments

A doc comment states the **contract** of a member: what it does or returns, named in concrete types, terse enough to read as an IDE tooltip. The summary is present-tense and usually one line; it extends to a second sentence only when the contract genuinely needs it — a precondition, a side effect, a null-or-throw case. The principle is one and the same across languages; only the comment syntax changes. The voice is terse, present-tense, mechanism-named; `ai-tools-docs-usage` carries the same voice at document scale.

## Scope and routing

This skill governs the doc/summary comment on a method, function, class, or module, in any language. If the task is a different artifact, stop and use the matching skill:

- README, getting-started, usage guide -> `ai-tools-docs-usage`
- CLAUDE.md, file/module header prose, design notes, reference docs -> `ai-tools-docs-reference`
- Changelog, release notes, migration guide -> `ai-tools-docs-changelog`

## One-line test

The summary names what the member does and the concrete type, property, or call it does it with. A caller reads it as a tooltip and knows the outcome without opening the source.

## The principle

**Lead with the contract, terse by default.** State the outcome: "Returns the authenticated user, or null when unauthenticated." Not "This method is used to basically get the user." One line is the default; a second sentence is fine when it carries a precondition or side effect the caller must know, but a rambling multi-sentence summary is not.

**Document the contract, not the implementation.** Say what the member returns or guarantees, in concrete named types. The body says how; the comment says what. (Content rule shared with `ai-tools-docs-reference`: a rationale, if included, is phrased as the guarantee the behavior provides — never as history.)

**Name the mechanism exactly.** Refer to real types, properties, and calls by name, not vague paraphrase.

**No history, no story.** Present tense only; never "we added", "now supports", "used to".

**Detail goes to the long form, sparingly.** A second tier (`<remarks>`, an extended docstring body, a JSDoc paragraph) carries preconditions, ordering, or thread-safety only when a caller genuinely needs it. Parameter and return notes are sentence fragments, not sentences: "The filter applied to each row", "The matching rows in table order".

**ASCII only inside source files.** Unicode stays out of comments in code.

## Per-language form

The summary and contract rule are identical; the syntax differs.

```csharp
/// <summary>Returns the authenticated user for the current request, or null when unauthenticated</summary>
public IUserSession GetSession() => default;
```

```python
def select(predicate):
    """Return rows matching the predicate, in table order."""
```

```bash
# select_rows: print rows matching the awk predicate, in file order.
# args: $1 awk predicate  stdout: matching rows
select_rows() { awk "$1"; }
```

```javascript
/** Returns the cached response for the request, or null on a miss. */
function tryGet(request) {}
```

For C# XML-doc specifics — `<remarks>` for business rules, `<example>`, `<exception>` documented only when meaningful to a caller, and documenting data-transfer/contract types more heavily than the methods that act on them.

## Anti-patterns

| Out of style | In style |
|---|---|
| "This method is used to basically get the data." | "Returns all rows matching the filter." |
| Rambling multi-sentence summary restating the body | One line; a second sentence only for a real precondition or side effect |
| "We added this to configure stuff at startup." | "Configures the host; runs once at startup." |
| `<param>` written as a full sentence with a period | Fragment: "The id to look up" |
