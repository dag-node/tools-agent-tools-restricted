---
name: ai-tools-decide
# ai-tools managed asset — provenance/versioning (RFC-draft lifecycle); the frontmatter name is stable.
x-ai-tools-managed: true
x-ai-tools-status: draft
x-ai-tools-version: 1
x-ai-tools-updated: 2026-09-22
description: "Use when a listing runs longer than the task needs — a search with more than about 30 hits, a `git log`, a checker's findings, a failing build's diagnostics — the task fits one sentence, and the criterion applies to each line on its own. Hands the listing to a bounded classifier and prints the lines that bear on the task; falls back to the full listing on any error. Not for a question about the listing as a whole (which finding is the odd one out, which diagnostic is the root cause), not for security or permission questions, not for a claim that a set is complete, and not a substitute for the check a task owes."
---

# Decide: keep the lines that bear on the task

A listing is piped to the decide command with the task in one sentence. The command prints the lines that bear on it
in full, then one summary line naming the rest by id:

```bash
grep -rn 'parse_config' src tests | node /usr/local/lib/ai-tools/typesafe/decide.mjs filter --task "rename parse_config to load_config in every caller and the test that covers it"
```

```text
src/config/loader.py:42:def parse_config(path):
src/server/startup.py:118:    settings = parse_config(config_path)
tests/config/test_loader.py:27:    assert parse_config(tmp / "app.toml").debug is True
decide: kept 3/12 (uncertain: docs/configuration.md:64); dropped: CHANGELOG.md:88 src/server/metrics.py:31 …; jev-1.13.0, 1 request(s), 1.4s, 2210 tokens
```

Each line's id is its `path:line` prefix where the listing has one, else `L<n>` for the n-th line. A checker's two-line
records take `--format prose-check`, so the rule travels apart from the excerpt:

```bash
python3 /opt/ai-tools/skills/ai-tools-technical-docs/prose-check.py --all docs/*.md | node /usr/local/lib/ai-tools/typesafe/decide.mjs filter --format prose-check --task "which findings are in prose this branch added"
```

A build log takes `--format msbuild`, which keeps the log's diagnostics and sets the rest of it aside:

```bash
dotnet build -v n 2>&1 | node /usr/local/lib/ai-tools/typesafe/decide.mjs filter --format msbuild --task "which diagnostics are the cause rather than a knock-on of another one"
```

Each diagnostic becomes one item -- its location the id, its code the rule, its project the context -- and the
repeat MSBuild prints in its summary collapses into one. The summary line names how many lines were set aside, so
the size of what was skipped stays visible. Use it where a build fails with several diagnostics and the question is
which to act on; a log with one error is read directly.

The command exits non-zero with one line on stderr naming the class (`configuration`, `input`, `provider`, `contract`,
`deadline`) and does not print a result: the listing already in hand is the fallback, and a failed call costs the one
invocation. It asks before it runs, since the lines it is given leave the host.

## Which layer answers which question

A call is paid for per line and answers one bounded judgment, so a question a parser or an exit status already answers
is not sent to it, and a judgment the task owes is not handed to it either:

| Question | Answered by |
|---|---|
| a diagnostic's severity, code, file, line and project | a parser: the fields are in the text |
| whether the build succeeded | the build's exit status |
| whether two diagnostics are the same | string comparison, keeping which project and framework each came from |
| whether a line bears on the task in hand | `decide filter` |
| what caused a diagnostic, and what to change | the agent |

A `dotnet build` log on a host carrying the dotnet integration is the case this most applies to: the log runs
to thousands of lines, an MSBuild diagnostic parses deterministically, and what is left is the question a parser does
not answer — which of the diagnostics that remain bear on the change in hand.

## Four rules

1. **Pipe listings, not file contents.** A line of a grep, a log, or a checker is what the classifier reads; a file's
   body is not a listing and is not sent.
2. **Read the number as a probability.** The answer to each line is P(the line satisfies the task); there is no
   separate confidence field to consult, so a line at 0.55 is a coin-flip on the question asked, not a confident
   "somewhat relevant". The kept set is the lines over the threshold, and the uncertain ids are the band around it.
3. **Keep the dropped ids in view.** The summary line names every line not kept; an `uncertain` id is one the classifier
   could not place, and the agent opens it rather than trusting either side.
4. **Run the deterministic check after the edit.** A kept set narrows what to read first; the grep, the test,
   or the checker that stated the task is run again once the edit is made, and that run is the verification.

## What the result is good for

The command decides one question per line, and the questions in a request are answered independently of each other.
Two consequences set the boundary, and they are what the two rules here rest on:

**Depend on it to decide what to read first.** The kept lines are where to start; the summary names every line not
kept, so a wrong drop costs an id the agent can still open. That is the whole of what it is for.

**Do not depend on it for any of these**, and read the listing instead:

| Not this | Because |
|---|---|
| "these are all the call sites" | a claim that a set is complete rests on the lines it dropped, which is the one thing a keep set does not establish |
| "which of these is the odd one out", "which diagnostic is the root cause" | the judgement is about the set; each question is answered without seeing the others' answers, so a per-line question cannot express it |
| a permission, secret, or security question | answered from the code and the rule that owns it |
| the verification a change owes | the grep, the test or the checker that stated the task is what settles it, re-run after the edit |

A listing that may hold text from outside the project — a compiler echoing a string literal, a dependency's message,
a file another party wrote — is judged with that text in the request. An item carrying a directive does not take
over the answer, and it does move the scores of the lines beside it, so a result over such a listing orders what to
read and does not settle a question on its own.

## When it does not apply

A permission, secret, or security question is answered from the code and the rule that owns it, not from a classifier.
A listing the command refuses as over its bound is narrowed at the source (a tighter pattern, a path) rather than split
by hand. The listing must also carry the evidence the task asks about: `git log --oneline` holds subject lines, so
a task about what a commit's diff touched is not answerable from it. A long item is cut at the command's item
bound, and the summary line says how many were cut: evidence a bound removed reads as evidence the line lacks.
Where the command reports the integration as not enabled or the file as not configured, the host has not turned
it on: read the full listing and say so.
