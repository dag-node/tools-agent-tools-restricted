---
paths:
  - src/usr/local/lib/ai-tools/msg.lib.sh
  - src/usr/local/bin/claude.sh
  - src/usr/local/bin/ai-tools.sh
  - src/opt/ai-tools/bin/claude-run.sh
  - src/opt/ai-tools/.claude/session-hook.sh
  - src/usr/local/sbin/ai-tools/ai-tools-bootstrap.sh
  - install.sh
  - selinux/install-selinux.sh
---

# User-facing message formatting

Every refusal, notice, and warning the user reads is rendered through one shared
library, `/usr/local/lib/ai-tools/msg.lib.sh` (`644 root:root`, world-readable — it
carries no secrets and operator, agent, and root principals all source it, exactly like
[logging](logging.rule.md)'s `log.lib.sh`). It exposes `ai_tools_msg <severity> <fd>
<line...>`, the convenience emitters `ai_tools_msg_{error,warn,notice,info,success}`,
the flow-block opener `ai_tools_msg_headline <title> <fd> <line...>`,
`ai_tools_msg_wrap <width> <text>` for callers that need wrapped-but-unframed text to
embed elsewhere, the two question renderers `ai_tools_msg_pick` and
`ai_tools_msg_confirm` — every menu and every yes/no prompt in the project renders and
defaults through them — and the umbrella banner `ai_tools_msg_banner` (with its
`ai_tools_msg_version` helper).

## What the library guarantees

- **Two frame classes make a visual hierarchy.** The severity alerts (`ai_tools_msg_*`)
  frame within **50 columns** — a narrow box reads as an inline alert — while the
  structural boxes (`ai_tools_msg_block`, `ai_tools_msg_headline`) frame within **80**,
  so a wide box reads as a section headline or a guidance screen. Long messages reflow to
  fit their class's width.
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
  pins it to its class's fixed frame (alerts 50 columns, blocks/headlines 80), so a
  *sequence* of boxes (an install flow's prompts, a claim's flow blocks) aligns per class
  instead of each shrinking to its own text.
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

## Three renderers: alert, headline, block

The emitters (`ai_tools_msg_*`) **wrap every line** — right for a short refusal or notice,
but a wrap splits a multi-word command across lines, so command-bearing prose handed to an
emitter must keep its command on a separate plain line (the session NOTICE does this: boxed
prose, reconcile command printed below the frame).

`ai_tools_msg_headline <title> <fd> <line...>` opens a **self-contained flow block** —
the structure the `ai-tools` claim/sandbox flows are built from: a wide (80-column) box
carrying the block's caller-composed title (verbatim, not uppercased: `Claim project (in
place)`, `WARNING: interior permission drift`) and its summary prose, with the block's
details — path lists, per-step results, its confirm prompt — printed **plain and indented
below the box** so long paths stay copy-pasteable, and a closing `✓` (or a fail-closed
error) ending the block. In plain (non-tty) mode the title is emitted as a content line —
it is block structure, not decoration, so logs and test greps still see which block
opened.

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

## `ai_tools_msg_confirm` — the single yes/no prompt

`ai_tools_msg_confirm <question> <y|n>` is the one renderer for the project's yes/no
questions, in the standard bracketed notation with the Enter outcome spelled out:

```
Do you want to download updates? [Y/n] (default: Yes):
Do you want to wipe the cache? [y/N] (default: No):
```

It draws and reads on `/dev/tty` and returns 0 for yes, 1 for no. Wording rules for call
sites: frame the question **positively** (ask about the action, never its negation — a
"No" to a negative is a double negative), and give it the default that is the **safe**
outcome, because Enter *and any run without a terminal* take the default — an unattended
or piped run never blocks and never lands on the unsafe side. The default is a required,
validated argument: every call site states which way its question falls, and a missing or
invalid value is an error, never an assumed answer.

Pre-answering is two distinct mechanisms, by direction:

- `AI_TOOLS_ASSUME_YES=1` (environment; unattended runs, tests) skips the prompt and
  answers yes **only when the default is already `y`** — it fast-tracks safe-direction
  questions and never flips a default-NO question.
- A default-NO question is pre-answered only by an **explicit per-invocation flag** on the
  command that owns it — `ai-tools --project-claim -y/--yes` (the launch wrapper's
  delegated claim, covering just the proceed prompt), `ai-tools-lockdown --yes`,
  `ai-tools-chown --yes` (the batch caller's per-path skip) — an auditable operator
  decision, never ambient state.

## Decision audit trail

`ai_tools_msg_confirm` and `ai_tools_msg_pick` are the project's two decision points, so
each records its outcome through the shared logger ([logging](logging.rule.md)): one INFO
line naming the question and the answer (`confirm: <question> -> yes|no (answered | default
| assume-yes | no-tty-default)`) or the menu choice (`menu: chose <n>/<N> (<label>)`). This
gives every user action taken through this library **one consistent trail** at the single
chokepoint, rather than each call site logging its own outcome (or, as before, mostly not).
It lands in journald always and in the root-only file sink under the caller's
`AI_TOOLS_LOG_FILE` when a root helper set one; a non-root caller (the wrapper, the CLI)
audits to journald only. `msg.lib.sh` sources `log.lib.sh` from its sibling path for this,
best-effort — a missing logger drops the audit line, never the prompt — and both libs carry
an include guard so a consumer that sources both loads each once. The audit never alters the
decision's exit status, the same guarantee the emitters give.

## Umbrella banner

`ai_tools_msg_banner <subtitle> [dim_line...]` renders the **AI-TOOLS** brand mark — the
single-sourced ANSI-Shadow figlet (`_AI_TOOLS_BANNER_ART`) that heads the installer, the
launch, and any sibling tool that sources this lib. Each tool supplies its own `subtitle`
(`<product> — <what it does>`) and dim meta lines while the art stays constant, so the brand
reads the same everywhere. `AI-TOOLS` is a brand mark, so product names stay descriptive
(`Agent Tools Restricted`, `Claude Code Restricted`). It draws on a terminal only.

Meta lines are composed via `ai_tools_msg_version`, which `v`-prefixes a bare version number
(`0.1.0` → `v0.1.0`) and passes a build id or `dev` through unchanged. The installer shows
one line (`installer · v0.1.0`, the package version `ai-tools --version` reports). The launch
banner shows three — `Claude Code`, `Node`, `ai-tools` — from **`claude-run`**, which runs as
the sandbox account so it can read each from the toolchain, and logs them (`logger -t
claude-run`) as a record of which versions a session ran.

## The library is required — one implementation, no per-consumer fallback

`msg.lib.sh` carries the project's yes/no decisions, not just formatting, so every
consumer **requires** it the way they require `safe-paths.lib.sh`: a valid install ships
the lib (`tests/integration/perms.sh` is the single test asserting every deployed
library's presence, owner, and mode), and a broken one fails closed rather than running
through a private re-implementation. Root helpers bare-`source` it under `set -e`; the
user-facing entry points (`claude.sh`, `ai-tools`, `claude-run`) refuse with a reinstall
hint; the installers source it from the source tree and abort if the checkout is broken.
Consumers call the lib's functions directly — no `declare -F` probing, no stub branches.

The library carries an **include guard** (`_AI_TOOLS_MSG_LIB_LOADED`), so a consumer that
sources it directly *and* receives it transitively (`safe-paths.lib.sh` requires it too)
re-sources a no-op; without the guard the `readonly` constants would abort the second
source under `set -e`.

One deliberate exception: `session-hook.sh` keeps a plain-text fallback, because it only
*emits* (never prompts) and its sweep is itself the safety action — the handback must run
even on an install broken enough to lose the formatter, so fail-closing there would skip a
security sweep. Every consumer that *prompts or refuses* fails closed instead — including
`ai-tools-bootstrap`, whose git-identity prompt is gated on the control plane already being
present (the gitconfig exists), where `msg.lib` is deployed too, so it requires the lib past
that gate rather than carrying a fallback. The emitters still only format: they never change
the exit status of the operation whose outcome they report.

## Where it is wired

- **`claude.sh`** routes its central `die()` through `ai_tools_msg_error`, so every fatal
  refusal is framed at one chokepoint; converts its standalone `safe.directory` NOTICE
  prose; and frames **both** guidance screens with `ai_tools_msg_block` — the not-accessible
  screen (title "This directory is not accessible to sandbox user", options `a)` create
  sandbox / `b)` claim in place) and the not-fully-claimed screen (per-gap bullets kept).
  Neither repeats paths: the claim/clone commands default to the current directory. The
  not-accessible screen drives an `ai_tools_msg_pick` menu — **1)** Create sandbox, **2)**
  Claim in place, **3)** Cancel (the default, so an unattended/piped run refuses safely).
- **`ai-tools.sh`** routes `die()` and `warn()` through the error/warning emitters, and
  builds the `--project-claim` / `--sandbox-create` flows from `ai_tools_msg_headline`
  blocks (Review, Secret lockdown, `.git` history, Reachability, Apply — see
  [cli](cli.rule.md)). The flows carry **no sudo-password notices**: the first sudo prompt
  (the secret scan) lands directly under the Secret-lockdown headline, and sudo's own
  prompt is self-explanatory.
- **`claude-run.sh`** routes its pre-launch refusals and the podman NOTICE.
- **`session-hook.sh`** frames the interrupted-session `SessionStart` NOTICE (see
  [ownership-and-hooks](ownership-and-hooks.rule.md)).
- **`ai-tools-bootstrap.sh`** frames its git-identity offer with `ai_tools_msg_block` and
  drives an `ai_tools_msg_pick` menu (adopt the operator's identity / keep the default / edit
  by hand). It sources the lib from the deployed path, gated on the control plane being
  present, so it requires it there like every other prompting consumer (see
  [updater](updater.rule.md)).
- **`install.sh` and `selinux/install-selinux.sh`** frame their interactive prompts
  uniformly. `install.sh` routes every prompt through one helper, `confirm_boxed <title>
  <y|n> <question> [context-line...]`: a fixed 80-column box (`AI_TOOLS_MSG_FULLWIDTH`)
  titled <title> — named for its action (`Review install`, `Existing file`, `SELinux
  confinement`, …) — framing the context, then the shared inline yes/no prompt — all on
  `/dev/tty`, because `do_install` tees stdout+stderr to the install log and a prompt must
  reach the real terminal. Consecutive prompts separate via the lib's leading blank before
  each box; a non-interactive run draws nothing and takes the default. A closing
  `confirm_boxed` gates the whole verification phase, which runs **last — after the
  optional SELinux bring-up** so it sees the final labelled state: the installed-files
  summary (`do_summary`), then the full test suite (`tests/run.sh all`), which includes
  the permissions check (`tests/integration/perms.sh`, the single source for
  installed-artifact ownership/modes). It is interactive only (a non-interactive install
  skips all of it) and defaults to run; `install.sh check-perms` (which runs `perms.sh`)
  and `tests/run.sh` remain available on demand. The SELinux installer does not tee, so
  its full-width boxes go to stderr directly. Both source the lib from the **source
  tree** (`${SCRIPT_DIR}/src/...` / `${DIR}/../src/...`), since the installed copy may not
  exist yet, and abort if it cannot load.

`ai_tools_msg_block` doubles as the **prompt-context renderer**: it shows the title *as
given* (so an action-named title like `Existing file` stays title-case, unlike the
uppercased severity emitters) and keeps an indented path line verbatim. The per-item
selection loop in the SELinux installer (optional policy groups) stays a compact inline
list, not one box per option.

## Quirks

- **Commands and the wrapping emitters do not mix.** A wrapping emitter (`ai_tools_msg_*`)
  would break a multi-word command across lines, so a command handed to one stays on a
  separate plain line outside the frame (the session NOTICE's reconcile command). A
  multi-line screen whose commands belong *inside* the frame uses `ai_tools_msg_block`
  instead, which keeps indented command lines verbatim and overflows the long ones.
- **Short prompts stay inline.** Yes/no prompts keep the inline hint form with the cursor
  on the same line; framing a one-line question with the cursor below the box reads worse
  than it helps. The hint is the standard bracketed notation with the Enter outcome
  spelled out — `[Y/n] (default: Yes):` for a yes default, `[y/N] (default: No):` for a no
  default — and every yes/no prompt in the project renders through
  `ai_tools_msg_confirm`, so there is exactly one form.
- **Routine progress is not framed.** Per-line status (`ok`/`say`/`section`) stays plain;
  a box is either an attention alert (errors, warnings, notices) or a flow-block headline —
  never a per-tick frame. Inside a headline block, results stay plain lines under the box.
- **The wrap pins `IFS` locally.** The library is sourced into callers that set their own
  `IFS` — the claude wrapper uses `IFS=$'\n\t'` (no space). The wrap's word-splitting
  (`read -ra`, `$*`) must split on spaces regardless, so `ai_tools_msg_wrap` sets a local
  `IFS=$' \t\n'`; without it a whole line collapses into one unbreakable unit and overflows
  the frame unwrapped. Any new word-splitting in the lib must not depend on the caller's `IFS`.
