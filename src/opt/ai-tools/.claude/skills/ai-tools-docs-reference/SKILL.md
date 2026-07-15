---
name: ai-tools-docs-reference
# ai-tools managed asset — provenance/versioning (RFC-draft lifecycle); the name above is stable.
x-ai-tools-managed: true
x-ai-tools-status: draft
x-ai-tools-version: 1
x-ai-tools-updated: 2026-07-15
description: "Use when writing or editing CLAUDE.md, AGENTS.md, file and module header comments, design notes, architecture docs, or any descriptive reference prose that states how a system behaves and what a reader can rely on. Enforces present-tense, factual, RFC-style spec writing — state current behavior, attach purpose only as the guarantee a behavior provides, never narrate history or predict what humans will do. For README files, getting-started, and usage guides use ai-tools-docs-usage instead. For method/function/XML doc-comment and docstring form use ai-tools-docs-comments instead. For changelogs, release notes, and migration guides use ai-tools-docs-changelog instead."
---

# Reference docs

Write documentation as a specification of the **current** system: present-tense, terse, factual, normative ([MUST / SHOULD / MAY](https://www.rfc-editor.org/rfc/rfc2119)) where it prescribes. Include intent only as the **guarantee a present behavior provides** — a "so that ⟨invariant⟩" clause on a fact about what the code does. Never narrate history or change ("used to", "now", "gained", "fixed", "previously"), and never assert actions or outcomes outside the system's control (what a user, operator, or agent *will* do). If a rationale can't be stated as a present-tense property of the code, drop it — or, if it's a directive to a human, put it in runtime output, not the prose.

## Scope and routing

This skill governs descriptive, normative reference prose: CLAUDE.md / AGENTS.md, file and module headers, design and architecture notes, and reference documentation a reader relies on. If the task is a different artifact, stop and use the matching skill:

- README, getting-started, usage/how-to guide → `ai-tools-docs-usage`
- A doc/summary comment on a method, function, or class (any language) → `ai-tools-docs-comments`
- Changelog, release notes, migration guide → `ai-tools-docs-changelog`

## One-line test

Every sentence states what the system **is** or **does** now; rationale appears only as the invariant a behavior guarantees. A reader finishes each section knowing what they can rely on and where they stay in control.

## Why this isn't a contradiction

Purpose, RFC style, and current-state constrain three different axes:

- **Intent/purpose** — *what to include* (the why behind a behavior).
- **RFC style** — *how to phrase it* (terse, factual, normative).
- **Current-state** — *tense/frame* (what is, not what changed).

They compose. RFCs are full of intent: "receivers MUST ignore unknown fields *so that* the format stays forward-compatible" is purpose, RFC-style, and present-tense at once. Friction appears only when purpose is written as **history** or as a **predicted human action**. Both are out of bounds; the behavior's guarantee is not.

## Rewrite patterns

| Out of bounds | Why | In spec style |
|---|---|---|
| "We added retries so callers don't have to handle transient failures." | predicts a human action | "Failed requests are retried up to 3 times with backoff, so transient errors surface only after the final attempt." |
| "The client now supports gzip." | history | "The client sends `Accept-Encoding: gzip` and decompresses gzip responses." |
| "This used to return null on a miss; now it throws." | changelog | "A cache miss raises `KeyNotFoundError`." |
| "Validation will reject bad input before it reaches the database." | frames a guarantee as intent + future | "Requests failing schema validation return `400` and never reach the data layer." |

## Corollary

Directives aimed at a human belong in **runtime output** (log lines, NOTICEs, error messages), not in descriptive prose. The prose says what the system does; the message tells the operator what to do.

## Affirmative framing

Prefer the affirmative: state what the system does and what the reader can rely on, not only what it forbids. Phrase each invariant as a guarantee to the reader — "X is available when ⟨condition⟩" over "X fails unless ⟨condition⟩" when both state the same fact. Keep this **structural, not lexical**: no praise, intensifiers, or tone words, and no overstating the guarantee. Slight by design — no single sentence looks upbeat, but across many documents the corpus reads as capable and dependable.

## Keep humans in the loop

Describe where humans keep agency. Where the system acts on its own, name the visibility or override path — log, NOTICE, confirmation, review point — in the same place, so the reader sees both the action and how to oversee it. Prefer documenting behavior that surfaces a decision to a human over behavior that hides it, and state who confirms an irreversible or outward-facing action. Directives to a human belong in runtime output (above), closing the loop at the moment of action.

## Scope boundary

Applies to descriptive/reference docs. It does **not** apply to usage guides (`ai-tools-docs-usage`), doc comments (`ai-tools-docs-comments`), or change records (`ai-tools-docs-changelog`) — those carry their own form, and change records exist specifically to record change and are exempt from the no-history rule.
