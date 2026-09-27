---
paths:
  - "src/usr/local/lib/ai-tools/records-base.lib.sh"
  - "src/usr/local/lib/ai-tools/records-tsv.lib.sh"
  - "tests/unit/records.sh"
---

# Record streams

A report that a cron job or a monitoring backend reads writes its findings as a **record stream**: a header row, then
one tab-separated row per finding, with an exit status that states whether the reading was complete. The public contract
— the columns and their meaning, the byte escape, the item framing, the identity recipe, the completion rules
and a reference decoder — is `ai-tools-records(5)`, `src/usr/local/share/man/man5/ai-tools-records.5`, and a consumer is
written from that page alone. This rule holds what the page does not: how the two libraries divide the work,
and the rules a report follows when it calls them.

Two shared libraries carry it, both `644 root:root`, sourced by every principal that prints a report, and neither
sourcing `msg.lib.sh`, so a root helper sources the data layer alone:

- **`records-base.lib.sh`** is the model and the report state: the column registry `AI_TOOLS_RECORDS_COLUMNS`
  (`name:class` in stream order, the one code-side declaration of the header), the severity and subject-type token sets,
  the two exit constants (the only place 4 and 5 are spelled in code), and the fold that turns the severities a run
  noted into `ai_tools_records_get_exit_status`. It is format-independent, so a later JSON writer reuses its predicate
  and its state.
- **`records-tsv.lib.sh`** is the wire format: the canonical escape and its strict decoder, the item framing, the record
  identity (the hash is over the TSV encoding, which is why the identity helper lives here) and the row writer.

## The fold moves in one direction, and a library function does not fail a report

Every consumer runs under `set -euo pipefail`, so a library function does not return non-zero for a report-level
condition: an invalid row or a failed hash is noted as `unreadable` in the state, the writer prints nothing for that row
and returns 0, and the script reaches its exit, where `ai_tools_records_get_exit_status` reports 5. The one non-zero
return from the writer is a failed write (a closed pipe), after which the command exits non-zero anyway. The fold itself
only rises: `attention` over `ok`, `unreadable` over both, and a token outside the set folds as `unreadable`, so no
consumer reads a run as clean because of a token the library did not know. A report ends with one status path,
`ai_tools_records_get_exit_status || exit $?`, or on a command that changes the host the combination
`ai-tools-records(5)` states under EXIT STATUS (1 over 5 over 4).

## Rules for a report calling the libraries

- **State changes run in the report's own shell.** Every `ai_tools_records_*` call that changes state — `begin_report`,
  `accumulate_severity`, `write_record` — is made in the report's own shell, never inside `$(...)`, a pipeline stage
  or the producer side of `< <(...)`, where it would update a subshell's copy that the exit status never reads.
- **A collector's PID is saved on the statement that opens it, and waited for after its output is consumed.**
  `wait "$pid"` returns the process substitution's exit status only when `pid` was taken from `$!` right
  after the substitution was opened; a bare `wait $!` after a loop whose body opened another substitution waits
  for that inner one and returns 0. The shape is `exec {fd}< <(collector); pid=$!`, the read loop, `exec {fd}<&-`, then
  `wait "${pid}"` with the failure written as an `error` row. `mapfile -t rows < <(collector); pid=$!` is the same rule
  for a consumer that does not run a command between the two statements.
- **Records cross between a collector and its consumer in the internal framing**, which keeps every field exact: each
  field `ENC`-encoded, fields tab-separated, one record per line feed. The consumer decodes each field
  with `ai_tools_records_tsv_decode_field`, and a record that does not decode, or has the wrong field count, is
  an `error` row. A collector that reads paths reads them NUL-separated (`find -print0`, `read -d ''`), so a name
  holding a line feed reaches the encoder whole. The post-upgrade collectors are the exception: they keep the line
  and `|` framing the interactive report reads them with, and their header states what a planted name costs — extra
  rows, which add findings to a run and do not make one read as clean.
- **A line an upstream tool prints that the parser does not recognize is an `error` row, not a guess.** Line output
  (`restorecon -v`) is ambiguous for a path holding a line feed, which is why a claim verifies each path it reports
  on its own rather than trusting the scan's text.
- **A shell reader does not split a row with `IFS=$'\t' read`.** Tab is IFS whitespace, and bash collapses adjacent
  empty fields, so positions are lost; `cut -f` or a manual split keeps them.

## Caps: a deliberate stop stays apart from a failure

A cap is enforced by the **collector**, so that stopping on purpose and failing are distinguishable, and no `head` sits
between a collector and its consumer: under `pipefail`, `head -n 201` reports a deliberate truncation as the producer's
SIGPIPE, exit 141, which the consumer would read as exit 5.

1. The collector takes the cap `N` as an argument, emits at most `N + 1` complete records, and stops reading its
   upstream after the `N + 1`th.
2. It saves its upstream's PID, closes the upstream's fd, and waits for it. It accepts exit 141 (SIGPIPE) or 143
   (SIGTERM) **only when it stopped on purpose**; any other non-zero exit, and a 141 or 143 when it did not stop, make
   the collector exit non-zero.
3. It exits 0 after a deliberate stop.
4. The consumer counts complete records: at `N + 1` it keeps the first `N`, drops the last, and emits the `scan-capped`
   row (severity `attention`, `item` holding the cap), so exactly `N` hits and more than `N` hits stay distinguishable.

## Output variables and dynamic scope

The functions that write into a caller's variable do so with `printf -v`, which bash resolves through its dynamic scope,
so a callee local carrying the caller's name would catch the write. Every local in the two libraries starts
with `_records_` and a per-function stem, and a function taking an output variable refuses a name that starts
with `_records_` or `_AI_TOOLS_RECORDS_`, names `LC_ALL`, or falls outside the identifier shape `[A-Za-z_][A-Za-z0-9_]*`
— returning 1 without writing. The encoder's `local LC_ALL=C` is what makes bash index a string by bytes for that one
function (a UTF-8 caller locale indexes by code point and would print one hex pair for the two bytes of an e-acute),
which is why the name is on the refused list.

## Tests

`tests/unit/records.sh` loads the **checkout's** libraries by path and prints the two paths first: after an install,
an installed-first test would pass against the installed copy while the checkout's code changes. It pins the schema
against the page's COLUMNS section, the escape against known answers a `python3` snippet writes from the page's rules (a
round trip alone would share the encoder's defect), the page's Python decoder — extracted between its two marker
comments, rendered with `groff -man -Tascii -P-cbou` and dedented — over the same fixtures as the shell decoder,
the reader rules over whole streams, the item framing, the published identity vectors, every severity fold, an invalid
row under `set -euo pipefail`, a write to a closed pipe, and the rules of [Rules for a report calling
the libraries](#rules-for-a-report-calling-the-libraries) and [Caps](#caps-a-deliberate-stop-stays-apart-from-a-failure)
through a fixture collector. `groff`, `python3` and `sha256sum` are dependencies there: a missing one fails rather than
skips, so the page's decoder is checked on every platform the suite runs on, and the container selftest images install
`groff-base` for it. The installed copies are covered by `tests/integration/perms.sh`, and each consumer's own suite
drives the real collectors.
