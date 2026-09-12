---
paths:
  - src/usr/local/lib/ai-tools/msg.lib.sh
  - src/usr/local/bin/claude.sh
  - src/usr/local/bin/ai-tools.sh
  - src/opt/ai-tools/bin/ai-tools-run.sh
  - src/opt/ai-tools/agents/*/session-hook.sh
  - src/usr/local/libexec/ai-tools/ai-tools-bootstrap.sh
  - src/usr/local/libexec/ai-tools/ai-tools-stop.sh
  - install.sh
  - selinux/install-selinux.sh
---

# User-facing message formatting

Every refusal, notice, and warning the user reads is rendered through one shared
library, `/usr/local/lib/ai-tools/msg.lib.sh` (`644 root:root`, world-readable — it
does not carry any secrets, and operator, agent, and root principals all source it, exactly like
[logging](logging.rule.md)'s `log.lib.sh`). It exposes `ai_tools_msg <severity> <fd>
<line...>`, the convenience emitters `ai_tools_msg_{error,warn,notice,info,success}`,
the flow-block opener `ai_tools_msg_headline <title> <fd> <line...>`,
`ai_tools_msg_wrap <width> <text>` for callers that need wrapped-but-unframed text to
embed elsewhere, the three question renderers `ai_tools_msg_pick`,
`ai_tools_msg_confirm` and `ai_tools_msg_challenge` — every menu, every yes/no prompt, and
every typed-name challenge in the project renders and
defaults through them — the command renderer `ai_tools_cmd_display`, and the umbrella banner
`ai_tools_msg_banner` (with its `ai_tools_msg_version` helper).

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
  shell comment: pasted into a prompt by accident, it executes as a comment. The border character
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

## Message codes: the identity of a situation

A message that names a **situation** — a refusal, a warning a test asserts, a guidance screen — carries
a code, a reftag of the `MSG-` family (the grammar and the minter are the technical-docs skill's;
the index is `.claude/references.md`). The code is what a test, a document, and a user with the
message on their screen identify the situation by — the token typed into a search engine — so it
stays fixed through every rewording: a rewrite keeps the code, and a new code is minted only for
a new situation, with the old one retired. A question (`confirm`, `pick`, `challenge`) and a
`headline` carry none, since a question is not a situation and a headline is flow structure, and
the outcome a question produces is what the decision audit trail records instead.

The code is an **optional leading argument** to an alert emitter and to `ai_tools_msg_block`,
detected by its form through `ai_tools_msg_is_code` (`MSG-` and a four-character
letter-digit-letter-digit id, anchored on both ends), so an uncoded call is unchanged and no
message begins with the token by accident:

```bash
ai_tools_msg_error MSG-F6Z3 "This project directory is owner-only, so the agent cannot read it."
ai_tools_msg_block MSG-F6Z3 "Set up this project for the sandboxed agent" "${lines[@]}"
```

Where it renders follows from the two modes. On a terminal it joins the **box title** —
`#-- ERROR MSG-F6Z3 ----#` for an alert, after the caller's title for a block — a slot outside
the alert class's 46-column text budget. In plain mode, where the alert and block
titles are dropped, it is emitted as its **own leading line** before the caller's lines, never as
a prefix on the first line: the guarantee that each caller-supplied line is emitted whole holds
byte for byte, so every existing grep on a message line keeps matching and a component takes codes
one call site at a time. A block's code is one per screen, in the title; the body stays uncoded.

A code is a reftag, so it resolves through the reference index; runtime output carries a reftag
and never a URL, a Markdown link, or an HTML anchor. `ai_tools_msg_is_code` is the one predicate
a leading code is detected with, so a component's local `die()`/`warn()` that routes to the
emitters (`claude.sh`, `ai-tools.sh`, `ai-tools-run`, `ai-tools-stop`) recognises a code exactly
as the library does.

The components that report without the library — the root helpers and the two installers, each
with a `printf` `die()`/`warn()` of its own — match the same anchored form inline and render it the
same way plain mode does: the code on its own line, then the helper's prefixed message whole. A
refusal that answers **before** the library is loaded takes the same treatment even in a component
that goes on to source it: `ai-tools.sh` refuses the sandbox account, refuses root, and refuses a
`--for` with no operator name ahead of every load, through a `refuse_early` carrying that inline
matcher, and `install.sh` refuses a valueless `--operator` and a non-root caller through one of its
own. A `${VAR:?message}` guard is printed by bash itself, so it does not carry a code and a test
keeps its prose grep. One
shape everywhere is what lets the harness's `assert_msg` read a code with a single whole-line
match, and what keeps every prose grep on a helper's message intact; `tests/unit/msg.sh` holds each
inline copy to the library's constant, so a copy cannot drift into printing a code as prose.

`ai-tools-stop` carries that inline matcher for a third reason: its emitters have **two branches**.
`say_error`, `say_warn` and `say_notice` hand the code to the library where it loaded and render it
themselves where it did not, since that one helper does not require any library
([cli](cli.rule.md)) — and
the branch running without the renderer is the branch a reader most needs a searchable token from.
The `ai-tools-stop: ` prefix belongs to those emitters, so a message text does not carry one of its
own: the code identifies the situation, the prefix names the component that raised it, and each is
stated once.

### One situation, two processes: a deliberate twin

A situation two processes both report carries **one code**, emitted at each site. `ai-tools --stop`
and `ai-tools-stop` each refuse a path, and each refuse an unknown option, in texts that are
deliberate twins — `refuse_positional_argument`'s header states why neither side can source the
other — so an operator meets the same token whichever side answered.

The code is **defined once and cited at the other site**. A definition is the emit-call shape the
reference index reads (the token as the command's first argument, then the quoted message it
labels; a code in a later argument is a citation, which is what a test's parameterised assertion
helper carries), so the CLI's
`die_stop_usage MSG-A3M9 "…"` names the message while the helper's `printf 'MSG-A3M9\n…'` prints
the token without declaring a second message under that name. The index then lists the helper among
the files citing the code, which is the record a twin needs: one message, two places it reaches a
terminal. A twin that instead passed the code to an emitter would declare the same reftag twice,
which `ref-index.py` reports as a duplicate. The installers hold one such pair: `install.sh` defines
the non-root refusal and `selinux/install-selinux.sh` prints its code.

### A refusal carried as a value defines its code where the value is made

A function that returns a refusal as a value, for a caller to print, is where the code is defined:
each branch names its own code beside its text, and the value carries the code on its first line
and the text on the second, so the site printing it need not know which branch produced it.
`install.sh`'s `operator_refusal` is the instance — each branch a situation carrying a code of its
own, reaching a terminal from the entry-point validation, the enrolment prompt, and the binding in
`do_install` — and its `emit_coded` hands such a value to `warn` or `die` as the code and text they
read. One code for the whole family would send a reader searching it to unrelated answers.
`ai-tools-admin`'s `admin_command_check` is the second: its conformance refusals reach a `die` from
the dispatch and a `warn` from full-scope provisioning, so its `emit_coded` takes a prefix as well
and the warning still names the integration the refusal is about.

**A value that is a clause rather than a message takes no code, and its consuming site takes one.**
`conf.lib.sh`'s `_ai_tools_conf_merge_reason` is that shape: each branch sets a fragment
(`the deployed file is not valid JSON`) that every caller interpolates into a sentence of its own —
`install.sh` and `ai-tools-admin` each say what the merge did not do, and there is no line the code
could lead. The situation a reader searches is the outcome the caller reports, so the code is
defined there. The test is where the value reaches a terminal: whole, and the factory defines it;
mid-sentence, and the caller does.

## Three renderers: alert, headline, block

The emitters (`ai_tools_msg_*`) **wrap every line** — right for a short refusal or notice,
but a wrap splits a multi-word command across lines, so command-bearing prose handed to an
emitter must keep its command on a separate plain line (the session NOTICE does this: boxed
prose, reconcile command printed under the frame).

`ai_tools_msg_headline <title> <fd> <line...>` opens a **self-contained flow block** —
the structure the `ai-tools` claim/sandbox flows are built from: a wide (80-column) box
carrying the block's caller-composed title (verbatim, not uppercased: `Claim project (in
place)`, `WARNING: interior permission drift`) and its summary prose, with the block's
details — path lists, per-step results, its confirm prompt — printed **plain and indented
under the box** so long paths stay copy-pasteable, and a closing `✓` (or a fail-closed
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

`ai_tools_msg_pick <default_index|none> <label...>` is the question companion: it draws a
numbered menu under a block and echoes the chosen 1-based index. It draws on `/dev/tty` and
emits only the index on stdout, so the caller reads it with `$(...)`.

A label is `<label>` or `<label><TAB><consequence>`: the labels align on a column computed
from the longest one, drawn bold against a dim consequence, so each option states what it does
and what it costs **on one line**. That is where a screen's options are stated — **once**. A
block preceding a menu says what the screen is *about*; a block that also lists the options makes
the reader match two renderings of the same three choices, which is what made the launch
wrapper's screen read as a wall of text.

The first argument picks one of two answering modes:

- **A default index** — that option is annotated `(default)` and is the answer on empty input,
  an out-of-range number, or no terminal, so an unattended or piped run takes the safe default
  and never blocks. Returns 0.
- **`none`** — there is no default. Empty or out-of-range input **re-asks** (three attempts,
  each miss saying what is expected), and closed input (Ctrl-D), no terminal, or three
  unanswered attempts return **non-zero with empty stdout**. The library declines to
  answer for the user; the caller decides what an unanswered menu means.

Anything else is a caller error (`return 2`), never an assumed answer — the same rule
`ai_tools_msg_confirm` applies to its default.

**`none` does not weaken the safe-default rule; it moves where that rule is satisfied.** The
guarantee is that an unattended run never blocks and never lands on the unsafe side, and a
caller using `none` meets it in its own `have_tty` branch — `claude.sh` decides Cancel there
and never reaches the menu, so no terminal means no session, decided by the caller rather than
by an index. A caller that cannot state that outcome itself has no business using `none`.

## `ai_tools_cmd_display` — a command the user can type

`ai_tools_cmd_display <abs-path>` renders a command for **printing**: the bare name
(`ai-tools`) when `command -v` resolves that name to the same absolute path on this PATH, and
the absolute path otherwise. A printed command is meant to be typed, and `/usr/local/bin/ai-tools
--project-claim` beside a `claude` the operator just ran reads as a second, unrelated tool; the
resolve check is what keeps the short form honest, so a host whose PATH does not carry the
directory still gets a command that works. Every site that prints a component's own path for
the user to run goes through it.

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

### The stop confirmation defaults YES, and that is the rule, not an exception to it

`ai-tools --stop` inverts that direction: its confirmation defaults **YES**, so a bare Enter,
a pipe, a cron run and an absent `msg.lib.sh` all proceed, and only a deliberate `n` declines. The
principle is unchanged — *give it the default that is the safe outcome* — and it is **which outcome
is safe** that flips: for the one control whose job is to end a session already running, declining
is the failure. `--dry-run` is how that command is looked at without acting, and
`AI_TOOLS_ASSUME_YES=1` fast-tracks it like any other default-yes question.

The inversion is bounded to the *confirmation*, not to argument handling. The same command
**refuses** an unexpected positional argument (a path) rather than proceeding: defaulting toward
action covers a known intent with something environmental in the way, not an ambiguous request
whose most destructive reading would be to terminate every session on the host. Its refusal prints
the alternative commands **plain, outside the frame**, since the wrapping emitters would break a
command across lines (see *Quirks*).

Because the no-terminal path is legitimate here rather than degraded, that helper records **which**
path gave consent (`flag`, `prompt`, `fallback-prompt`, `no-tty`) rather than only the answer. Full
reasoning: [docs/session-stop.md](../../docs/session-stop.md).

## `ai_tools_msg_challenge` — the typed-name challenge

`ai_tools_msg_challenge <question> <expected>` draws the question, reads one line from
`/dev/tty`, and returns 0 only on an **exact** match with `<expected>`. A mismatch, empty
input, closed input (Ctrl-D), and **no terminal** all return non-zero.

**It does not take a default, and that is the mechanism rather than an omission.** A confirm exists so
that Enter can mean something, which is why it must state which way it falls; a challenge exists
so the answer costs something a reflex cannot supply, which leaves an absent answer with only one
reading. That also settles the unattended case without a rule of its own — a run with no terminal
cannot type a name, so it declines — and it is what makes a destructive verb behind one
unreachable from cron by construction, without depending on a `-y` convention.

`<expected>` is **echoed in the prompt**: this is a deliberateness check, not a secret, and hiding
what to type would make it a guessing game. It is the caller's job to have already printed what is
about to happen; the challenge only asks the user to re-type the name of the thing.

**A mistyped answer is recorded, and it is treated as untrusted input.** The trail for a
destructive verb is worth more showing what was typed than showing only that something was, so a
mismatch logs the answer — through the shared allowlist sanitizer (`ai_tools_log_sanitize`) and
clamped to a bounded length, the same treatment every other untrusted string reaching a log sink
or a terminal gets ([logging](logging.rule.md)). Without that sanitizer — the logger is loaded
best-effort here — the answer is **omitted** rather than recorded raw; the decision itself is
recorded either way.

Where a caller pre-answers it (`ai-tools --project-remove -y`), that is the same explicit
per-invocation flag rule as a default-NO confirm, and the flag is the auditable decision.

## Decision audit trail

`ai_tools_msg_confirm`, `ai_tools_msg_pick` and `ai_tools_msg_challenge` are the project's three
decision points, so
each records its outcome through the shared logger ([logging](logging.rule.md)): one INFO
line naming the question and the answer (`confirm: <question> -> yes|no (answered | default
| assume-yes | no-tty-default)`) or the menu choice (`menu: chose <n>/<N> (<label>)`). A menu
that ends **without** a choice is audited too, naming which way it ended (`menu: no terminal
and no default -- no answer`, `menu: input closed -- no answer`, `menu: no answer after 3
attempts`), so the trail distinguishes a declined menu from one never drawn. This
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
banner shows three — `Claude Code`, `Node`, `ai-tools` — from **`ai-tools-run`**, which runs as
the sandbox account so it can read each from the toolchain, and logs them (`logger -t
ai-tools-run`) as a record of which versions a session ran.

## The library is required — one implementation, no per-consumer fallback

`msg.lib.sh` carries the project's yes/no decisions, not just formatting, so every
consumer **requires** it the way they require `safe-paths.lib.sh`: a valid install ships
the lib (`tests/integration/perms.sh` is the single test asserting every deployed
library's presence, owner, and mode), and a broken one fails closed rather than running
through a private re-implementation. Root helpers bare-`source` it under `set -e`; the
user-facing entry points (`claude.sh`, `ai-tools`, `ai-tools-run`) refuse with a reinstall
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
  refusal is framed at one chokepoint; converts its standalone `safe.directory` NOTICE prose;
  and frames **both** guidance screens with `ai_tools_msg_block`. Titles name the action, not
  the refusal ("Set up this project for the sandboxed agent", "Finish setting up this project
  for the agent"), and commands print as bare names through `ai_tools_cmd_display`. Neither
  screen repeats paths: the claim/clone commands default to the current directory.

  The **setup** screen carries one line of prose and **no commands**; its options live in the
  `ai_tools_msg_pick none` menu under it, each with the consequence that distinguishes it —
  **1)** Create sandbox (*the session runs in the copy, not here*), **2)** Claim here (*its
  group becomes `ai-tools`*), **3)** Cancel. Because the block does not name a command, the Cancel
  path — which is also the no-terminal and unanswered-menu path — prints both commands itself,
  plain and under the frame. The **finish-setup** screen keeps its per-gap bullets, its
  embedded `--sandbox-create` command (its prompt is a yes/no confirm offering only the claim,
  so the alternative has nowhere else to appear), and its severity-based default.
- **`ai-tools.sh`** routes `die()` and `warn()` through the error/warning emitters, and
  builds the `--project-claim` / `--sandbox-create` flows from `ai_tools_msg_headline`
  blocks (Review, Secret lockdown, `.git` history, Reachability, Apply — see
  [cli](cli.rule.md)). The flows carry **no sudo-password notices**: the first sudo prompt
  (the secret scan) lands directly under the Secret-lockdown headline, and sudo's own
  prompt is self-explanatory.
- **`ai-tools-run.sh`** routes its pre-launch refusals and the podman NOTICE.
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
  each box; a non-interactive run takes the default without drawing one. A closing
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
  on the same line; framing a one-line question with the cursor under the box reads worse
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
