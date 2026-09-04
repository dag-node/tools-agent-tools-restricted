#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/claude-prompt.sh
# Unit test for the custom-system-prompt resolver (claude-prompt.lib.sh), the wrapper-side logic
# claude.sh applies before it execs a session. The guarantee under test is one instance of "the
# sandbox cannot widen its own surface": a prompt file the sandbox account could influence, or a
# configured prompt that cannot be honoured, must NOT be silently passed to Claude Code -- it either
# leaves the prompt empty (unconfigured) or REFUSES the launch (configured-but-invalid), never a
# fall-back to a prompt the operator did not set. This drives the resolver into each bad state and
# asserts it moves to no-injection or a refusal, never to injecting an untrusted or wrong prompt.
# The agent-side half (the files are not agent-writable) lives in tests/boundary/access.sh.
#
# Hermetic: /tmp fixtures with known content and a root-only AI_TOOLS_PROMPT_BASE_DIR override, no
# host config read. Run as root (needed to create root-owned fixtures the trust predicate accepts).

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly LIB="/usr/local/lib/ai-tools/claude-prompt.lib.sh"
section "claude-prompt: custom system prompt resolution (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "claude-prompt" "library not readable at ${LIB}"; finish; exit
fi
# shellcheck source=/dev/null
if ! source "${LIB}" || ! declare -F ai_tools_claude_resolve_prompt_args >/dev/null 2>&1; then
    fail "could not source ${LIB} or it does not define the resolver"; finish; exit
fi

mktestdir
base="${TESTDIR}/prompts"
install -d -o root -g root -m 755 "${base}"
conf="${TESTDIR}/operator.conf"
prompt="${base}/claude-system-prompt.md"
export AI_TOOLS_PROMPT_BASE_DIR="${base}"

# _resolve <argv...> : run the resolver, leaving $RET (0/1), $ARGS (space-joined result), and $ERR
# (captured stderr) for assertions. The array is populated in THIS shell (no subshell), so stderr is
# captured to a file rather than via $(...), which would discard the array.
_resolve() {
    RESULT=()
    if ai_tools_claude_resolve_prompt_args RESULT "${conf}" "$@" 2>"${TESTDIR}/err"; then RET=0; else RET=1; fi
    ARGS="${RESULT[*]:-}"
    ERR="$(cat "${TESTDIR}/err" 2>/dev/null || true)"
}
# reset the fixture to a known-good trusted state before each case
_reset() {
    install -d -o root -g root -m 755 "${base}"
    printf 'You are a sandboxed agent.\n' > "${prompt}"; chown root:root "${prompt}"; chmod 644 "${prompt}"
    : > "${conf}"; chown root:root "${conf}"; chmod 644 "${conf}"
}
_cfg() { printf '%s\n' "$@" > "${conf}"; chown root:root "${conf}"; chmod 644 "${conf}"; }

expect() {  # <desc> <want-ret> <want-args-substr-or-empty> [want-err-substr]
    local desc="$1" wret="$2" wargs="$3" werr="${4:-}"
    if [[ "${RET}" != "${wret}" ]]; then fail "${desc}: ret ${RET} != ${wret} (args='${ARGS}' err='${ERR}')"; return; fi
    if [[ -n "${wargs}" && "${ARGS}" != *"${wargs}"* ]]; then fail "${desc}: args '${ARGS}' lacks '${wargs}'"; return; fi
    if [[ -z "${wargs}" && -n "${ARGS}" ]]; then fail "${desc}: expected no args, got '${ARGS}'"; return; fi
    if [[ -n "${werr}" && "${ERR}" != *"${werr}"* ]]; then fail "${desc}: err '${ERR}' lacks '${werr}'"; return; fi
    pass "${desc}"
}

# 1) Not configured: no key -> no injection, launch (return 0, empty).
_reset; _resolve
expect "unconfigured -> no args" 0 ""

# 2) Append (default mode).
_reset; _cfg "CLAUDE_SYSTEM_PROMPT_FILE=${prompt}"; _resolve
expect "append default -> --append-system-prompt-file" 0 "--append-system-prompt-file ${prompt}"

# 3) Replace mode.
_reset; _cfg "CLAUDE_SYSTEM_PROMPT_FILE=${prompt}" "CLAUDE_SYSTEM_PROMPT_MODE=replace"; _resolve
expect "replace -> --system-prompt-file" 0 "--system-prompt-file ${prompt}"

# 4) An empty inert file is valid (the shipped default): append contributes an empty string but still applies.
_reset; : > "${prompt}"; _cfg "CLAUDE_SYSTEM_PROMPT_FILE=${prompt}"; _resolve
expect "empty inert file -> append" 0 "--append-system-prompt-file ${prompt}"

# 5) Unknown mode -> fail closed (configured but invalid).
_reset; _cfg "CLAUDE_SYSTEM_PROMPT_FILE=${prompt}" "CLAUDE_SYSTEM_PROMPT_MODE=frobnicate"; _resolve
expect "unknown mode -> refuse" 1 "" "unknown CLAUDE_SYSTEM_PROMPT_MODE"

# 6) A per-invocation flag suppresses the operator.conf default (deterministic override).
_reset; _cfg "CLAUDE_SYSTEM_PROMPT_FILE=${prompt}"; _resolve --append-system-prompt-file /somewhere/else.md
expect "cli flag overrides conf -> no injection" 0 ""

# 7) Path outside the trusted base -> fail closed (confined session cannot read it).
_reset; outside="${TESTDIR}/outside.md"; printf 'x\n' > "${outside}"; chown root:root "${outside}"
_cfg "CLAUDE_SYSTEM_PROMPT_FILE=${outside}"; _resolve
expect "path outside base -> refuse" 1 "" "not under"

# 8) Missing file -> fail closed.
_reset; _cfg "CLAUDE_SYSTEM_PROMPT_FILE=${base}/nope.md"; _resolve
expect "missing file -> refuse" 1 ""

# 9) Binary file -> fail closed (a system prompt must be text).
_reset; printf '\x00\x01\x02ELF\x00' > "${prompt}"; _cfg "CLAUDE_SYSTEM_PROMPT_FILE=${prompt}"; _resolve
expect "binary file -> refuse" 1 "" "not a text file"

# 10) Flag smuggling via the path value: the value is a single argument to realpath, so it does not name a
#     file and is refused -- it can never split into a second CLI flag.
_reset; _cfg "CLAUDE_SYSTEM_PROMPT_FILE=${prompt} --dangerous-flag"; _resolve
expect "flag smuggle in value -> refuse, no extra arg" 1 ""

# --- Trust: states a NON-ROOT writer could create must be refused (the surface-widening guard) ---
# 11) A group/other-writable prompt file -> refuse (the sandbox could swap its content).
_reset; chmod 664 "${prompt}"; _cfg "CLAUDE_SYSTEM_PROMPT_FILE=${prompt}"; _resolve
expect "group-writable file -> refuse" 1 ""

# 12) A symlinked prompt file -> refuse outright (a link could redirect the read).
_reset; ln -sf "${prompt}" "${base}/link.md"; _cfg "CLAUDE_SYSTEM_PROMPT_FILE=${base}/link.md"; _resolve
expect "symlink file -> refuse" 1 ""

# 13) A group/other-writable prompts base -> refuse (a writable dir lets the file be replaced).
_reset; chmod 777 "${base}"; _cfg "CLAUDE_SYSTEM_PROMPT_FILE=${prompt}"; _resolve
expect "world-writable base -> refuse" 1 ""
chmod 755 "${base}"

# 14) A group/other-writable operator.conf -> refuse (its pointer is no longer trustworthy).
_reset; _cfg "CLAUDE_SYSTEM_PROMPT_FILE=${prompt}"; chmod 646 "${conf}"; _resolve
expect "world-writable operator.conf -> refuse" 1 ""

finish
