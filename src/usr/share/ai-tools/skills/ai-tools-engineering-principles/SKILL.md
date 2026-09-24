---
name: ai-tools-engineering-principles
# ai-tools managed asset — provenance/versioning (RFC-draft lifecycle); the frontmatter name is stable.
x-ai-tools-managed: true
x-ai-tools-status: draft
x-ai-tools-version: 5
x-ai-tools-updated: 2026-09-24
description: "Use when introducing a new feature (to set its shape before coding), when validating or reviewing a feature implementation against these defaults, or when choosing an approach, architecture, or how much machinery a problem warrants — in any language. Consult it at both ends: before building a feature and when checking the result. Sets the default engineering judgment: resolve trade-offs in the order security, then performance; write in a pragmatic, low-ceremony style (simple, explicit, terse-but-readable, POCO/DTO-first, no speculative abstraction); fail closed on critical components; sanitize with an allowlist not a blocklist; reach for the lightest mechanism that works; spend context and tokens deliberately (amortize discovery through persistent docs, isolate noisy fan-out work, and never downgrade planning to a weaker model); keep humans in the loop for irreversible or outward-facing actions. For prose style defer to ai-tools-technical-docs. Trigger on 'add/implement a feature', 'design this', 'how should I build/structure this', 'which approach', 'review/validate this implementation', 'is this over-engineered', or any design/architecture decision."
---

# Engineering principles

Language-agnostic defaults for how to build and judge code. These are strong defaults, not laws — override
when the problem genuinely demands it, and say so. Language-specific skills, where present, refine them; prose skills
own writing style; this skill owns judgment.

Consult it at **both ends of a feature**: when introducing one, to set its shape before writing code (what's
the simplest secure design, how much machinery does it actually need); and when validating an implementation,
as the checklist to hold it against — priority order respected, no ceremony added, boundaries fail closed, inputs
allow-listed, the change scoped to what it required. The "One-line test" and the anti-patterns double as the review
pass.

## Priority order

When concerns pull against each other, resolve them in this order:

1. **Correctness** — it has to do the right thing; a fast, elegant wrong answer is worthless.
2. **Security** — get the boundary right before the speed. An input that reaches a log, a shell, a query,
   or the filesystem is untrusted until proven otherwise.
3. **Performance** — then make it fast: avoid needless work, allocations, and chatty round-trips; measure
   before micro-optimising.
4. **Everything else** (elegance, extensibility, taste) ranks under these three.

Stated briefly: **security, then performance** — with correctness assumed and cleverness last.

## Style: pragmatic minimalism

Write the simple, direct, boring version. The north star is code a reader steps through and understands in one pass —
the code is the best documentation.

- **Simplicity and explicitness first.** Flat over nested, explicit over implicit, boring over surprising. If
  the control flow is hard to follow, simplify it rather than comment around it.
- **No ceremony, no speculative extensibility.** Build for the problem in front of you, not one you imagine. No
  `IFoo`/`Foo` pair without a real second implementation or test double today; no `GenericService<T>`, mediator,
  repository, or reflection-magic layer that doesn't pay for itself in this codebase. Reject premature generalization.
- **POCO / DTO-first, message-shaped.** Plain data objects at the boundaries; behavior in small, focused, composable
  pieces. Prefer composition and free functions over inheritance hierarchies.
- **Stable over trendy.** Default to proven, debuggable building blocks; add a dependency only when the built-in path is
  genuinely insufficient.
- **DRY, but not at the cost of clarity.** Single-source a fact or a rule; don't fold two things into one abstraction
  just because they look alike today.
- **Descriptive names, self-documenting code.** Full words, no cryptic abbreviations (`Mgr`/`Svc`/`sdlib`); a name
  should say what the thing is. Comments explain *why*, never restate *what*; delete a comment that only echoes
  the code, and keep every comment self-contained for a reader with no access to the conversation that produced it (no
  session shorthand, ticket tags, or "as discussed").
- **Single-source each fact; link, don't repeat.** A given fact lives at exactly one layer — line comment, method doc,
  file header, a reference/rule file, `CLAUDE.md`, README — chosen by altitude; every other layer references it
  by a short link rather than restating it. Keep the layers in sync up through `CLAUDE.md`: **the code is true
  for behaviour, and invariants have to hold.** Where a description disagrees with the code, resolve it toward the code
  and never average two descriptions. Where the *code* contradicts an invariant `CLAUDE.md` or a rule states, that is
  a defect in the code — raise it and leave the invariant standing, because rewriting the invariant to match retires
  a guarantee by editing prose. Where the code is right but grants more than the invariant needs, propose the tightening
  with its cost: prose that only tracks the code ratifies every widening the code has drifted into. A docs-to-code ratio
  climbing toward parity is a signal the *code* must become self-descriptive (a rename, an extraction, a stronger type)
  — not that it needs more prose.
- **Match the surrounding code.** Adopt the file's existing idioms, naming, and comment density rather than importing
  a different house style.

## Judgment defaults

- **Fail closed on anything load-bearing.** A critical component that can't load stops the flow with a clear error —
  never a fail-open no-op stub, never "limp along on a broken install." A broken or half-installed state is not a valid
  state to silently accommodate. (Keep behaviour-preserving fallbacks only for pure *output* paths — a logger
  or formatter — never for a security or correctness gate.) Each gate fails closed on its own; a later check downstream
  does not justify an earlier one failing open.
- **Sanitize with a fail-closed allowlist, not a blocklist.** Permit a known-safe subset and reject everything else
  by construction. A blocklist is open-ended and never provably complete; an allowlist does not need maintenance to stay
  safe. Prefer the simple, foolproof rule over exhaustive enumeration.
- **Lightest mechanism that works.** Resolve an inconsistency at write-time against ground truth (the code) rather than
  building tooling to police it later; reach for a lint/CI gate only for a mechanical slip a reasoning pass can't catch.
  Ask when the correct answer is genuinely unclear instead of guessing or leaving a known inconsistency for a later
  gate.
- **Spend context and tokens deliberately.** The quiet cost is *repeated discovery* — re-deriving "where/what is X"
  every session — and a top-level context bloated with raw intermediate material. Pay discovery once by investing
  in a persistent, auto-loaded navigation layer (an index/router doc → scoped reference prose → in-file headers, each
  coupled to the code) rather than re-searching each session or delegating discovery to a subagent that starts cold
  on every spawn. When a task must sift a lot — many search hits, long files, parallel probes — keep that raw output
  *out* of the main thread: isolate it in a subagent (or write it to a file) and bring back only the distilled
  conclusion; the saving is context hygiene and running the sift on a cheaper tier, not caching. Reserve that delegation
  for genuinely fan-out-heavy, isolatable work — a couple of lookups are cheaper done inline. Discovery
  (locate/read/report) may run on a cheaper model, but never route planning or judgment to a weaker one to save tokens.
- **Keep humans in the loop for irreversible or outward-facing actions.** Surface the decision at the point of action;
  don't take autonomous VCS actions (merge, push, force-push) or other hard-to-reverse / externally-visible steps unless
  asked. Where the system acts on its own, give it a visible override or review path.
- **Scope a change to what it requires.** Touch only what the change needs — reconcile the doc passages it actually
  invalidates, don't ride unsolicited cross-cutting refactors or new doc sections along with a fix. Raise a broader idea
  separately. A small defect found while working is never left alone. Fix it in the same change when the code is already
  being touched; otherwise raise it in a form that invites a wider search for the same pattern, so the fix is not
  an isolated one-off.
- **A check proves its own setup before its verdict.** Do not silence the step that creates the state under test, assert
  that the state exists, and print a known-good control beside the measurement. An input the check cannot read never
  reads as the negative answer: test a predicate with its input unreadable and a tool it calls missing, not only
  with valid input. A check that cannot pass is worse than none, because it teaches the reader to discount it.
  When a check contradicts independent evidence that the operation succeeded — a trace, the resulting state — examine
  the check as closely as the code. A verdict about a branch the check did not take is an inference, and is written
  as one.
- **Decide which side is wrong against the source of truth, not by which is easier to change.** An existing test
  that passes and does not cover the code being written holds by default: a change that breaks it is presumed wrong,
  and the test changes only when it is shown to be wrong or contradicts a truth that outranks it — an invariant,
  the contract it asserts. A test written for the new code changes with that code's contract, in the same commit,
  so a reviewer reads the two changes together. When a linter or checker reports a finding the source does not deserve —
  the source follows the rule the checker states — fix the checker and its stated rule and add the case to its tests,
  since reshaping the source to dodge the finding makes its formatting load-bearing. A repaired check keeps a case
  that still fails on the defect it exists to catch.
- **Trace, don't guess.** When a call claims success but the expected effect is missing, observe the running behaviour
  (trace, exit status, log) before forming a theory. A silent no-op does not show itself by static inspection. Once
  the trace has identified the cause, fix that cause. Do not silence the symptom.

## Routing

- **Prose** — comments, docs, headers, READMEs, changelogs, commit messages, runtime output — is owned
  by `ai-tools-technical-docs`. This skill governs the code and the decision, not the wording; that skill carries
  the terse, present-tense, affirmative, mechanism-named voice.

## Anti-patterns

| Out of style | In style |
|---|---|
| Optimise the hot path before the input is validated | Get the security boundary right, then profile and optimise |
| `IService`/`Service` pair, `GenericRepository<T>`, a mediator — for one call site | The direct call; add an abstraction when a second implementation or a test double actually exists |
| A missing security lib silently degrades to a permissive no-op | Fail closed: refuse with a clear error and enough to debug it |
| Blocklist of "dangerous" characters, extended forever | Allowlist a known-safe subset; reject the rest by construction |
| A pre-commit hook to police rule↔code drift | Resolve the drift while editing, against the code |
| `setup 2>/dev/null`, then measure; an unreadable input read as "none found" | Assert the setup, print a control, and report an unreadable input as unknown |
| Edit a failing test, or split a line, until the check goes green | Settle which side is wrong against the contract or the stated rule; keep a case that fails on the real defect |
| Change what reports the failure until the report goes away | Trace to the cause and fix it there |
| Bundle a broad refactor / new doc section into a small fix | Keep the fix scoped; propose the rest separately |
| `var mgr`, `// increment i`, "Gap A (see chat)" | Descriptive names; comments that give the why, self-contained |
| Re-grep the same landmarks every session; spawn a cold subagent for two lookups; route planning to a weaker model | Persistent router/headers so discovery is paid once; delegate only fan-out-heavy work, returning a distilled result; cheaper model for discovery only |

## Relation to the other skills

The four docs skills own how things are *written*. This skill is the language-agnostic root they specialise.
