---
paths:
  - "src/usr/local/lib/ai-tools/filters.lib.sh"
  - "src/usr/local/lib/ai-tools/filters.d/**"
  - "src/opt/ai-tools/agents/claude-code/filter-hook.sh"
---

# Token-saving command filters

A session's most expensive output is the part no one reads: six lines of `git log` header per
commit, a build's per-project restore chatter, a progress bar redrawn two hundred times. Two
transforms remove it — a **command rewrite** that makes the tool print less, and a **noise
strip** that removes terminal control bytes from what it printed — driven by an agent's hook
system and decided by root-owned rule data.

## This is token economy, not a boundary

A rewrite decides how verbose a command is, never what the agent may run. The hook returns
`updatedInput` and no permission decision, so the harness runs its full permission pipeline on
the **rewritten** command: an `allow` entry must still match it, and a `deny` entry still
overrides ([claude-settings](claude-settings.rule.md)). A rules file is therefore an input to
`settings.json`, never a way around it.

The refusal directions follow from that. Every way filtering can fail — an untrusted rules file,
an unparseable line, a command the engine does not fully parse, an absent library, a missing
`jq` — ends in **pass-through**: the command the agent wrote, run unchanged, with its output
untouched. Failing here costs tokens and nothing else, which is why the hook adapter fails
**soft** where the security gates fail closed ([shellcheck](shellcheck.rule.md) states that
split; this is the "pure output path" case).

## Three layers

| layer | path | shipped by |
|---|---|---|
| engine — pure rewrite and noise-strip logic | `/usr/local/lib/ai-tools/filters.lib.sh` | `ai-tools-base` |
| rules — data, parsed never sourced | `/usr/local/lib/ai-tools/filters.d/<name>.rules` | base ships `core.rules`; a package with commands of its own ships its set |
| adapter — one agent's hook JSON | `<agent config>/filter-hook.sh` | that agent's package |

Only the adapter is agent-specific: hook event names and their JSON shapes belong to the agent
product, while which commands are worth narrowing does not. A second agent reuses every rule set
with an adapter of its own, which is why `filters.d` is keyed by provider name the same way
`session-env.d` is (see [providers](providers.rule.md)) rather than living under an agent's
directory.

## The rule grammar

Four TAB-separated columns per line; `#` begins a whole-line comment; a line with fewer than four
columns is skipped.

```
match       the literal leading words a command must start with        git log
action      args -- insert <payload> right after those words
            wrap -- prepend <payload> as a wrapper command
blocking    words that cancel the rule, comma- or whitespace-separated;
            a lone `-` means nothing blocks it                          --format,--stat
payload     verbatim shell text, inserted as written                    --format='%h %s'
```

**The payload lands after the matched words, never at the end.** A trailing insertion changes what
a command means: `git log -- src/x.c` reads an appended `--format=…` as a pathspec. Inserting at
the head of the arguments keeps every rule clear of pathspecs, `--`, and subcommand arguments
generally.

**The agent's own flag always wins.** A rule cancels itself when any word after the match is one of
its blocking words, in either the bare or the `word=value` form — so `git log --stat` and
`git log --format=%H` run exactly as written. A rule that narrows what a command prints lists the
flags that control the same thing, and the narrowing applies only where the agent expressed no
preference.

**The payload is root-owned data and is inserted verbatim**, so it may carry quotes the agent's
command may not (`--format='%h %ad %an %s'`).

### What may be rewritten

A command is eligible only when every character of it is a letter, a digit, a space, or one of
`_ . / = : , + @ -`. This is a positive allowlist, so a metacharacter nobody enumerated is
excluded by construction: a pipeline, a redirect, a command list, a substitution, a quote, an
escape, a glob, or a newline all pass through untouched, because inserting words into a command
the engine has not fully parsed could change what runs.

### Which rule wins

The applying rule with the most matched words, and on a tie the one loaded **last**. `core.rules`
loads first, so a provider's set overrides a core rule by matching the same words — the seam a
wrapper-style tool uses to take a command over from the native rule.

## The two hook events

Claude Code's adapter (`filter-hook.sh`, declared in `settings.json`) is one script dispatched on
its argument, the way `session-hook.sh` dispatches its session phases:

- **`pre-tool-use`** → `PreToolUse` on `Bash`. Emits
  `hookSpecificOutput.updatedInput` when a rule applies. `updatedInput` replaces the whole tool
  input, so it is built from the original object with only `.command` changed — a key the agent
  set (a timeout, a background flag) survives the rewrite. A returned input that fails the tool's
  own schema is refused by the harness, so a malformed rewrite denies rather than runs.
- **`post-tool-use`** → `PostToolUse` on `Bash`. Emits
  `hookSpecificOutput.updatedToolOutput` when the output carried noise. The result shape is read
  from the event rather than assumed: an object carrying `stdout`/`stderr` strings has those
  filtered in place and its other keys preserved, a bare string is filtered whole, anything else
  is left alone. Output that carried no noise emits nothing at all, which is the common case.

## Noise stripping is byte-level only

The strip removes ANSI CSI and OSC sequences, stray escapes, and collapses carriage-return
redraws to the final state a terminal would have shown. **No line is dropped, truncated,
reordered, or summarized**, so nothing the model would have read is lost — the transform is
reversible in information content, not merely in volume. Its one cost is a line that uses a
carriage return as data rather than as a redraw (CR-only line endings), which keeps its last
segment.

Truncation, deduplication, and grouping are **not** part of this layer. They discard content, so
they need a recovery path the agent can reach, and they are deferred until one exists.

## Enablement

`operator.conf` `AI_TOOLS_FILTERS`, in the shared `KEY=value` grammar (`conf.lib.sh`):

- **key absent** → every installed rule set applies. This is the default: filtering widens no
  surface, adds no egress, and ships no binary.
- **key present** → exactly the named sets. An **empty value is the kill switch** — no filtering
  at all, the switch to reach for when a session's command output looks unexpected. The kill
  switch covers both transforms: the rewrite path loads no rules under it, and the adapter gates
  its noise strip on the same verdict (`ai_tools_filter_enabled`), so a switched-off session's
  output reaches the model byte-identical to what the tool produced. A named list narrows which
  rule sets load, never the strip.
- **untrusted or unreadable `operator.conf`** → the installed sets, which can only ever be
  root-owned rules.

Rule sets are **not** gated on provider enablement. A rule is inert unless the agent runs the
command it matches, so the gate would decide nothing, and this resolution runs on every Bash call.
A package's rules therefore install and are removed with that package, and that is the whole of
their lifecycle.

## Trust

Every rules file, and the directory holding it, is honored only while `ai_tools_conf_is_trusted`
holds — root-owned, not a symlink, writable by neither group nor other. The predicate gates the
file's **content**, not its location, which is what makes `AI_TOOLS_FILTERS_DIR` safe to leave
readable from inside a session (a project settings layer can add to the hook process's
environment): an override chooses only where to look, and anywhere the sandbox account can write
is refused, so it reaches root-owned rules or none. The engine is sourced
**as the agent**, in the agent's own process, on every Bash call, so a writable engine or rule set
would be arbitrary code and arbitrary rewrites on that path. A refusal is recorded in journald
and drops that input; it is deliberately not written to stderr, where a per-call warning would
flood the transcript with the tokens this layer exists to save.

The deployed permissions are asserted from both ends, as every guarantee here is
([tests](tests.rule.md)): `tests/unit/filters.sh` drives each untrusted state through the loader
and asserts it resolves to pass-through, and `tests/boundary/filters.sh` probes the same files
**as the agent** and asserts none of them is agent-writable.

## The shipped rule sets

`core.rules` (base) covers three commands. `git diff`, `git show`, `git blame`, `find` and `grep`
are absent: every terse mode they have discards content the agent asked for by running them.

| command | payload | what it removes |
|---|---|---|
| `git log` | `--date=short --format='%h %ad %an %s'` | five of six lines per commit. No count is imposed, so `git log -5` keeps meaning five. |
| `git status` | `--short --branch` | the per-file instructional hints; `--branch` keeps the ahead/behind line. |
| `tree` | `-L 3 --filelimit 100` | an unbounded walk into a package directory. Both caps announce themselves in tree's own output, so a truncated branch is visible rather than silent. |

`dotnet.rules` (`ai-tools-integration-dotnet`) sets `-v q` on `build`, `publish`,
`restore`, `run` and `test`. The SDK's verbosity has no environment-variable form — the per-project
restore chatter and the target summary are MSBuild console-logger settings, settable only per
invocation. Quiet verbosity keeps errors and warnings, which is what the agent acts on. The banner
is left to `DOTNET_NOLOGO` (set globally by `session-env.d/dotnet.env.sh`), so no rule carries
`--nologo`: it is redundant with that variable, and — inserted ahead of a positional — it breaks
`dotnet run <file>.cs`, where .NET 10 stops resolving the file as a file-based app. These rules
live with the integration for the reason its session-env fragment does: they are .NET knowledge,
and they install and are removed with the package that has it (see [providers](providers.rule.md)).

## Cost

The `PreToolUse` adapter runs on **every** Bash call: one `jq` pass, a rule-set load, and the
match. The rule sets are re-read per call rather than cached in the session, so an operator's edit
to a rules file or to `AI_TOOLS_FILTERS` takes effect on the next command with no session restart.
Resolving the set once at launch and passing it through `ai-tools-run`'s environment allowlist is
the available optimization if the per-call cost measures.

## Deferred

- **Output compression** — truncation, deduplication and grouping, with the untruncated output
  written where the agent can read it back. `updatedToolOutput` already carries whatever this
  layer returns, so the mechanism is the recovery path, not the hook.
- **A wrapper-style integration.** The `wrap` action exists and is unit-tested; no shipped rule
  set uses it. A command runner reached that way needs its own `allow` entries, because the
  matcher sees the wrapper as the command — and an entry broad enough to cover
  `<wrapper> <anything>` is broader than the inspection-only criterion the allow list holds to
  ([claude-settings](claude-settings.rule.md)). Narrow per-command entries are the form that fits.
