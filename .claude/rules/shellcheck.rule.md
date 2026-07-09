---
paths:
  - "src/**/*.sh"
  - ".shellcheckrc"
---

# ShellCheck baseline and conventions

Every shell source under `src/` is `bash` and lints under ShellCheck (0.10) with the
repository configuration. This rule states that configuration, the cross-library following
it turns on, and the findings the code keeps by idiom.

## Configuration

`.shellcheckrc` at the repository root governs every lint in the tree (ShellCheck walks up
from each file to find it):

- **`external-sources=true`** follows the `source` directives below. Each library `source`
  names its target with a `# shellcheck source=SCRIPTDIR/<rel>` directive, resolved relative
  to the script; `src/` mirrors the install tree, so one directive resolves both in-repo and
  on the installed system. Following keeps cross-library references honest at lint time: a
  name shared across the source boundary resolves to its definition, and a stale source path
  shows up as `SC1091`.
- **`disable=SC2317,SC2053,SC2010,SC2012`** turns off the four codes in "Accepted findings"
  below repo-wide, so CI's plain `shellcheck` run (no `--severity` override) gates on
  everything else while these stay silent without a per-line disable anywhere. SC2317
  (command appears unreachable) marks the fail-soft
  `if ! source "${LIB}"; then <stubs>; fi` fallbacks and functions dispatched indirectly
  (traps, name lookup), both reachable by design.
- **`SC2034`** (variable appears unused) stays on. A library that sets a name for a sourcing
  script or the test suite to read carries an inline `# shellcheck disable=SC2034` at the
  definition, naming the reader — the control-plane constants, the `ai_tools_resolve_owner`
  outputs (`operator.lib.sh`), the `safe-paths` protected-path list, and the `skip-dirs`
  public output. The check then still catches a genuinely unused name in any consumer.

## Runtime load is fail-closed

The `source` directives are lint-only; the runtime load gates. A missing critical library
fails closed: the launch wrapper and the CLI verify `safe-paths.lib.sh`'s guard functions
and `die` otherwise; the root helpers bare-`source` it under `set -e`; `ai-tools-chown` and
`ai-tools-lockdown` `exit 1` when `secret-patterns.lib.sh` will not load; and `msg.lib.sh`
is required the same way — it carries the yes/no decisions (`ai_tools_msg_confirm`), so
its consumers refuse rather than run through a private fallback, with `session-hook.sh`
the one emit-only exception (see [safe-paths](safe-paths.rule.md),
[secret-handling](secret-handling.rule.md), [messaging](messaging.rule.md), and the
fail-closed invariant in the root `CLAUDE.md`). The logger (`log.lib.sh`) and the owner
resolver (`operator.lib.sh`) carry faithful fallbacks, because they log or resolve rather
than gate — a missing one degrades output or yields "no owner" (which stops the
operation), never a bypassed security decision.

## Accepted findings

These stay reported and are correct as written; the rationale lives here so the code carries
no per-line disable for them.

- **SC2053** — unquoted right-hand side of `==` in `[[ ]]`. The secret-name and
  protected-path loops match a value against a *pattern* (`[[ "${base}" == ${pat} ]]`), and
  the operand arrangement is the secure one: the variable, possibly agent-influenced operand
  (the filename or path) is **quoted** and matches literally, while the **unquoted** glob is
  the pattern, sourced only from operator/root-owned config (the `allowed-projects` `!`-globs,
  `secret-patterns`). Quoting the right side would match the pattern literally and defeat the
  match, so it stays unquoted.
- **SC2010 / SC2012** — reading a SELinux context from `ls -Zd`. Each call inspects a single,
  quoted path, so the result is one line and the non-alphanumeric-filename concern these
  checks raise does not apply. `stat -c '%C'` is the lint-clean equivalent; the `ls -Z` read
  stays for the enforcing-only paths, where a mechanism change is verified on an enforcing
  host.

## Design notes

- **Fix in preference to suppress.** A finding that names an avoidable foot-gun is rewritten.
  `SC2015` (`A && B || C`) reads as `if`/`else`; `msg.lib.sh` writes to its caller-chosen
  descriptor and guards the exit status alone (`>&"${fd}" || true`), so a real write error
  surfaces (`SC2261` cleared). Following also surfaced set-but-unread assignments — the
  `skip-dirs` fallback stubs and a `relabel` fallback branch — removed at the source.
- **Rationale is centralized.** The repo-wide settings and the accepted findings above are
  documented here. An inline `# shellcheck disable=` is reserved for a local one-off with its
  own reason comment: the `safe-paths`-style `SC2034` exports, and the single-quoted `sed`
  regex in `ai-tools-safedir.sh` whose `$`/`()` are literal metacharacters (`SC2016`).
- **A new finding is reviewed, not auto-accepted.** A code outside the accepted set, or an
  accepted code in a context where its rationale does not hold, is a signal to read the code.
