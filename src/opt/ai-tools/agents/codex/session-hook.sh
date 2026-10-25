#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# /opt/ai-tools/.codex/session-hook.sh
# Codex's session hook: declared for Stop (no argument), SessionStart ("session-start", matcher startup|resume)
# and SessionEnd ("session-end") among the managed hooks /etc/codex/requirements.toml carries. Codex holds a Stop hook
# to the timeout that file declares (600 s) and kills it hard past that, and caps SessionEnd at 3 s whatever is
# declared, so the library clears the clean-exit marker before the session-end .git reclaim. These hooks are
# the per-turn CADENCE of the handback, not its guarantee: codex's manifest declares handback=none, so ai-tools-run
# sweeps the project once more when the session exits, whether or not these hooks ran (agent-codex.rule.md). The body is
# /usr/local/lib/ai-tools/session-sweep.lib.sh, which this stub sources and calls with its mode and its own directory
# (ownership-and-hooks.rule.md). A library that does not load is reported as a warning and the hook exits 0.
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
    warn MSG-N6U2 "${SWEEP_LIB} did not load -- no handback ran this turn; reinstall ai-tools-base (sudo ai-tools-admin system layout names the row)"
    exit 0
fi

ai_tools_session_sweep__run "${1:-stop}" "${HOOK_DIR}"
