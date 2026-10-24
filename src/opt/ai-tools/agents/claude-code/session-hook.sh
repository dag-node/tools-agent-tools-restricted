#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /opt/ai-tools/.claude/session-hook.sh
# Claude Code's session hook: wired to the Stop, SessionStart and SessionEnd hooks in settings.json (the SessionStart
# entry passes "session-start", the SessionEnd entry "session-end"). Claude-code's manifest declares handback=hooks,
# so these hooks are its handback driver and ai-tools-run does not sweep the project at session end. The body is
# /usr/local/lib/ai-tools/session-sweep.lib.sh, which this stub sources and calls with its mode and its own directory
# (ownership-and-hooks.rule.md). A library that does not load is reported as a warning and the hook exits 0, leaving
# the tree's paths with the owner they have.
#
# Installed 750 root:@SANDBOX_GROUP@: the session executes it through the group and cannot rewrite it, which is
# what keeps the sweeps out of the agent's control. The library path is a literal, so the session's environment does not
# choose which file this hook sources.

set -euo pipefail

# This agent's config directory, the one its manifest declares: the sweep keeps its state files beside this stub.
HOOK_DIR="${BASH_SOURCE[0]%/*}"
readonly HOOK_DIR

AI_TOOLS_LOG_TAG="ai-tools-hook"
readonly LOG_LIB="/usr/local/lib/ai-tools/log.lib.sh"
# shellcheck source=SCRIPTDIR/../../../../usr/local/lib/ai-tools/log.lib.sh
if ! source "${LOG_LIB}" 2>/dev/null; then
    ai_tools_log__warn() { :; }
fi

# warn [<code>] <text> -- the plain form the root helpers print: a leading code on its own line, then the prefixed text.
# Journald takes the same line. The one message this stub owns; every other line is the library's.
warn() {
    local IFS=' ' code=""
    if [[ "${1-}" =~ ^MSG-[A-Z][0-9][A-Z][0-9]$ ]]; then code="$1"; shift; printf '%s\n' "${code}" >&2; fi
    printf 'session-hook.sh: %s\n' "$*" >&2
    ai_tools_log__warn "${code:+${code} }$*"
}

readonly SWEEP_LIB="/usr/local/lib/ai-tools/session-sweep.lib.sh"
# shellcheck source=SCRIPTDIR/../../../../usr/local/lib/ai-tools/session-sweep.lib.sh
if ! source "${SWEEP_LIB}" 2>/dev/null || ! declare -F ai_tools_session_sweep__run >/dev/null; then
    warn MSG-N6U2 "the session sweep library ${SWEEP_LIB} did not load -- no handback ran this turn; reinstall ai-tools-base (sudo ai-tools-admin system layout names the row)"
    exit 0
fi

ai_tools_session_sweep__run "${1:-stop}" "${HOOK_DIR}"
