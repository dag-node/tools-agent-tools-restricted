---
name: ai-tools-docs-changelog
# ai-tools managed asset — provenance/versioning (RFC-draft lifecycle); the name above is stable.
x-ai-tools-managed: true
x-ai-tools-status: draft
x-ai-tools-version: 1
x-ai-tools-updated: 2026-07-15
description: "Use when writing or editing changelogs, release notes, or migration guides — any prose whose job is to record what changed between versions. Enforces the change-record style: past-tense, change-oriented entries grouped by impact, written for a reader deciding whether and how to upgrade. This is the inverse of ai-tools-docs-reference: history is the point, not a violation. For CLAUDE.md, file headers, and current-state reference prose use ai-tools-docs-reference instead. For READMEs and usage guides use ai-tools-docs-usage instead. For doc/summary comments use ai-tools-docs-comments instead. Trigger on 'write the changelog', 'draft release notes', 'write a migration guide', 'summarize what changed in this release', or 'CHANGELOG entry'."
---

# Change docs

A change record states what changed between two versions, for a reader deciding whether and how to upgrade. Unlike reference docs, history is the subject: entries are change-oriented and reference the prior state. This skill governs the **writing style** of change records; it does not generate or maintain the file mechanically.

## Scope and routing

This skill governs changelog, release-note, and migration-guide prose. If the task is a different artifact, stop and use the matching skill:

- CLAUDE.md, file/module headers, design notes, current-state reference docs → `ai-tools-docs-reference`
- README, getting-started, usage guide → `ai-tools-docs-usage`
- A doc/summary comment on a method, function, or class → `ai-tools-docs-comments`

For the mechanical side — a CHANGELOG.md format and a git hook that appends entries from commits — that is a separate concern from this writing-style skill.

## One-line test

Each entry names what changed and the impact on a reader who is upgrading, grouped by kind of change, recent versions first. A reader scanning a release knows in one pass whether it touches them and what they must do.

## Core properties

**Change-oriented, past or imperative.** An entry records a change: "Added gRPC support", "Fixed the race in the cache writer", "Removed the deprecated `v1` endpoints". History is correct here — the no-history rule of `ai-tools-docs-reference` does not apply.

**Grouped by impact.** Use the [Keep a Changelog](https://keepachangelog.com/) sections — Added, Changed, Deprecated, Removed, Fixed, Security — so a reader finds breaking and security changes without reading prose. Surface breaking changes prominently; a reader scanning for what will break finds it in one place.

**Reader-facing, not commit-facing.** An entry describes the effect on a user of the software, not the internal commit. "Reduced cold-start latency by caching the schema" over "refactored SchemaCache.cs". Internal-only churn (tests, formatting, CI) produces no entry.

**Terse and concrete.** One line per change where possible; name the affected API, flag, or behavior. Link to the issue/PR or the relevant doc for depth rather than expanding the entry.

**Migration guides are task-shaped.** A migration guide is written as the steps a reader follows to move between versions: what broke, what to change, in what order. Show the before and after side by side; state the minimum that makes an upgrade compile and run, then the optional follow-ups.

## Anti-patterns

| Out of style | In style |
|---|---|
| "Various bug fixes and improvements" | "Fixed `HttpClient` retry on 429; corrected timezone parsing in date fields" |
| Changelog entry mirroring a commit message verbatim | Entry describing the reader-facing effect |
| Breaking change buried mid-list | Breaking change called out, grouped under Changed/Removed |
| Migration guide that only lists what changed | Migration guide with before/after and the upgrade steps in order |

## Relation to the other skills

`ai-tools-docs-reference`, `ai-tools-docs-usage`, and `ai-tools-docs-comments` describe the **current** system and exclude history by design. Change records are exactly where history belongs, so this skill is their complement: when those skills say "this is a changelog, exempt", the change being recorded is written here.
