---
paths:
  - src/usr/local/lib/ai-tools/msg.lib.sh
  - src/usr/local/bin/claude.sh
  - src/usr/local/bin/ai-tools.sh
  - src/opt/ai-tools/bin/claude-run.sh
  - src/opt/ai-tools/.claude/session-hook.sh
  - install.sh
  - selinux/install-selinux.sh
---

# User-facing message formatting

Every refusal, notice, and warning the user reads is rendered through one shared
library, `/usr/local/lib/ai-tools/msg.lib.sh` (`644 root:root`, world-readable — it
carries no secrets and operator, agent, and root principals all source it, exactly like
[logging](logging.rule.md)'s `log.lib.sh`). It exposes `ai_tools_msg <severity> <fd>
<line...>`, the convenience emitters `ai_tools_msg_{error,warn,notice,info,success}`, and
`ai_tools_msg_wrap <width> <text>` for callers that need wrapped-but-unframed text to
embed elsewhere.

## What the library guarantees

- **Wrapped within 80 columns.** Long messages reflow to fit a standard terminal.
- **No line ends on a tie-word, no one-word widow.** A TeX-style tie glues each article,
  coordinating conjunction, preposition, or wh-/relative word to the word after it, so a
  line break never strands one at the right margin (the set lives in `_AI_TOOLS_MSG_TIES`).
  Orphan control then rebalances the final line: a last line that would be a single unit
  pulls the previous tie-glued unit down, so the tail reads as a phrase rather than a lone
  stranded word.
- **A single token is never split.** A path or command longer than the wrap width
  overflows its own line intact rather than breaking mid-token, so copy-paste survives.
- **The frame is paste-safe.** On a terminal the text is drawn in a titled box whose
  every line — top rule, content, bottom rule — begins with `#`, so the whole block is a
  shell comment: pasted into a prompt by accident, nothing executes. The border character
  is `#`, not `|`, for exactly this reason.
- **Uniform width on demand.** A box sizes to its content by default; `AI_TOOLS_MSG_FULLWIDTH=1`
  pins it to a fixed 80-column frame, so a *sequence* of boxes (an install flow's prompts)
  aligns instead of each shrinking to its own text.
- **Boxes self-separate.** A blank line precedes every box, so consecutive boxes (or a box
  after other output) are visually separated without the caller inserting spacing. The blank
  is not a `#` comment line, so a paste-safety check must ignore blank lines.

## TTY-gating: box on a terminal, plain when captured

`ai_tools_msg` renders the box **only when the target file descriptor is a tty**.
Piped, redirected, captured by the test suite, written to a log, or fed to a hook's
`additionalContext`, it emits the caller's lines **plain and unwrapped** instead. This is
load-bearing two ways: the box is terminal decoration that would be noise in a log or a
JSON string, and — critically — the test suite asserts on message substrings with
line-based `grep`, which a wrap could split across lines. Plain mode keeps each
caller-supplied line whole, so those assertions keep matching. `AI_TOOLS_MSG_PLAIN=1`
forces plain even on a tty; `AI_TOOLS_MSG_BOX=1` forces the box even off one (the unit
test and the session-hook NOTICE use the latter to render a box into captured output).

## Two renderers: alert vs block

The emitters (`ai_tools_msg_*`) **wrap every line** — right for a short refusal or notice,
but a wrap splits a multi-word command across lines, so command-bearing prose handed to an
emitter must keep its command on a separate plain line (the session NOTICE does this: boxed
prose, reconcile command printed below the frame).

`ai_tools_msg_block <title> <line...>` is the renderer for a multi-line guidance screen
that *contains* commands (the `claude.sh` not-yet-claimed screen). It frames a titled `#`
box but preserves author layout: a flush-left line wraps as prose, while an **indented or
blank** line is kept **verbatim** — never reflowed — so a command stays on one line and the
numbering/indentation survives. A verbatim line wider than the box **overflows** past the
right border intact rather than breaking, so a long, non-separable command is never
mangled. Every line still begins with `#`, so the block stays a paste-safe comment; a user
copying a command selects the command text after the `# ` prefix.

`ai_tools_msg_pick <default_index> <label...>` is the question companion: it draws a
numbered menu under a block, echoes the chosen 1-based index, and returns the default on
empty input, an out-of-range number, or no terminal — so an unattended or piped run takes
the safe default (typically Cancel) and never blocks on input. It draws on `/dev/tty` and
emits only the index on stdout, so the caller reads it with `$(...)`.

## The source-with-fallback idiom

Each consumer sources the library best-effort and defines no-op/plain fallbacks if it is
absent, mirroring how the hooks source `log.lib.sh`:

```sh
readonly MSG_LIB="/usr/local/lib/ai-tools/msg.lib.sh"
if ! source "${MSG_LIB}" 2>/dev/null; then
    ai_tools_msg_error()  { printf '%s\n' "$@" >&2; }
    ai_tools_msg_notice() { printf '%s\n' "$@" >&2; }
fi
```

The fallback reproduces the prior plain-stderr behaviour, so a consumer (and its tests)
keep working unchanged if the library is not yet deployed. The library only formats; like
`log.lib.sh` it never changes the exit status of the operation whose outcome it reports.

## Where it is wired

- **`claude.sh`** routes its central `die()` through `ai_tools_msg_error`, so every fatal
  refusal is framed at one chokepoint; converts its standalone `safe.directory` NOTICE
  prose; and frames **both** guidance screens with `ai_tools_msg_block` — the not-accessible
  screen (title "This directory is not accessible to sandbox user", options `a)` create
  sandbox / `b)` claim in place) and the not-fully-claimed screen (per-gap bullets kept).
  Neither repeats paths: the claim/clone commands default to the current directory. The
  not-accessible screen drives an `ai_tools_msg_pick` menu — **1)** Create sandbox, **2)**
  Claim in place, **3)** Cancel (the default, so an unattended/piped run refuses safely).
- **`ai-tools.sh`** routes `die()` and `warn()` through the error/warning emitters.
- **`claude-run.sh`** routes its pre-launch refusals and the podman NOTICE.
- **`session-hook.sh`** frames the interrupted-session `SessionStart` NOTICE (see
  [ownership-and-hooks](ownership-and-hooks.rule.md)).
- **`install.sh` and `selinux/install-selinux.sh`** frame their interactive prompts
  uniformly. `install.sh` routes every prompt through one helper, `ask <title> <question>
  <context-line...>`: a fixed 80-column box (`AI_TOOLS_MSG_FULLWIDTH`) titled <title> with
  the inline <question> below it — all on `/dev/tty`, because `do_install` tees stdout+stderr
  to the install log and a prompt must reach the real terminal. Consecutive prompts separate
  via the lib's leading blank before each box. `ask` echoes the raw reply on stdout (empty when
  non-interactive, so the caller picks the default). A closing `ask` prompt gates the whole
  verification phase, which runs **last — after the optional SELinux bring-up** so it sees
  the final labelled state: the installed-files summary (`do_summary`), then the full test
  suite (`tests/run.sh all`), which includes the permissions check
  (`tests/integration/perms.sh`, the single source for installed-artifact ownership/modes).
  It is interactive only (a non-interactive install skips all of it) and defaults to run;
  `install.sh check-perms` (which runs `perms.sh`) and `tests/run.sh` remain available on
  demand. The SELinux installer does not tee, so its
  full-width boxes go to stderr directly. Both source the lib from the **source
  tree** (`${SCRIPT_DIR}/src/...` / `${DIR}/../src/...`), since the installed copy may not
  exist yet, with a plain fallback.

`ai_tools_msg_block` doubles as the **prompt-context renderer**: it shows the title *as
given* (so "Awaiting input" stays title-case, unlike the uppercased severity emitters) and
keeps an indented path line verbatim. The per-item selection loop in the SELinux installer
(optional policy groups) stays a compact inline list, not one box per option.

## Quirks

- **Commands and the wrapping emitters do not mix.** A wrapping emitter (`ai_tools_msg_*`)
  would break a multi-word command across lines, so a command handed to one stays on a
  separate plain line outside the frame (the session NOTICE's reconcile command). A
  multi-line screen whose commands belong *inside* the frame uses `ai_tools_msg_block`
  instead, which keeps indented command lines verbatim and overflows the long ones.
- **Short prompts stay inline.** Yes/no prompts keep the inline hint form with the cursor
  on the same line; framing a one-line question with the cursor below the box reads worse
  than it helps. The hint brackets the default in uppercase and lowercases the alternative
  — `[Y]/n` for a yes default, `y/[N]` for a no default — and every yes/no prompt in the
  project uses this one form. Each question names the affirmative as the action proposed,
  so the default reads as a plain yes.
- **Routine progress is not framed.** Per-line status (`ok`/`say`/`section`) stays plain;
  the box is for attention messages — errors, warnings, and notices — not every tick.
- **The wrap pins `IFS` locally.** The library is sourced into callers that set their own
  `IFS` — the claude wrapper uses `IFS=$'\n\t'` (no space). The wrap's word-splitting
  (`read -ra`, `$*`) must split on spaces regardless, so `ai_tools_msg_wrap` sets a local
  `IFS=$' \t\n'`; without it a whole line collapses into one unbreakable unit and overflows
  the frame unwrapped. Any new word-splitting in the lib must not depend on the caller's `IFS`.
