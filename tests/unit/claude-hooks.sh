#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/claude-hooks.sh
# Unit test for the reply claude-code's PostToolUse hook gives when the root helper prints a NOTICE. Claude Code does
# not pass a hook's stderr to the model at exit 0, so a secret-file NOTICE reaches the session only through the hook's
# JSON reply: the hook keeps what the handback client relays, and when a relayed line is a message code it prints one
# PostToolUse reply carrying the helper's lines as additionalContext and the first of them as systemMessage.
# The functions are read out of the checkout's hook as text and driven with the client stubbed as a shell function,
# so no socket or root helper is reached. Needs jq, which the hook needs too. Runs unprivileged or as root.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${ROOT}/src/opt/ai-tools/agents/claude-code/post-tool-hook.sh"
section "claude-code PostToolUse: a helper NOTICE reaches the model as additionalContext (unit)"

if ! command -v jq >/dev/null 2>&1; then skip "PostToolUse reply" "jq is not installed"; finish; exit; fi
if [[ ! -r "${HOOK}" ]]; then skip "PostToolUse reply" "${HOOK} is absent"; finish; exit; fi

mktestdir
functions="${TESTDIR}/functions.sh"
{
    printf 'readonly MAX_NOTICE_CONTEXT_LENGTH=%s\n' \
        "$(sed -n 's/^readonly MAX_NOTICE_CONTEXT_LENGTH=//p' "${HOOK}")"
    extract_function "${HOOK}" hand_back_path
    extract_function "${HOOK}" emit_notice_context
} > "${functions}"
# A hook without the two functions or the bound is a hook this file's cases cannot drive: say so and stop, rather than
# let the first case end the file on an undefined function.
if ! grep -q '^hand_back_path() {' "${functions}" || ! grep -q '^emit_notice_context() {' "${functions}" \
        || ! grep -qE '^readonly MAX_NOTICE_CONTEXT_LENGTH=[0-9]+$' "${functions}"; then
    fail "the hook does not define hand_back_path, emit_notice_context and MAX_NOTICE_CONTEXT_LENGTH"
    finish; exit
fi

# reply <stub-stderr> [<calls>] : in a shell of its own, define the stub client to print <stub-stderr> on stderr, make
# <calls> handback calls (default 1), then emit the reply; stdout in OUT, the hook's stderr in ERR.
OUT=""; ERR=""
reply() {
    local err="${TESTDIR}/err"
    # shellcheck disable=SC2016  # the inner shell's own expansions
    OUT="$(bash -c 'set -euo pipefail; source "$1"; stub_stderr="$2"; calls="$3"
        stub_client() { [[ -z "${stub_stderr}" ]] || printf "%s\n" "${stub_stderr}" >&2; return 1; }
        HANDBACK_CLIENT=stub_client; handback_relay=""
        for (( i = 0; i < calls; i++ )); do hand_back_path "/p/${i}"; done
        emit_notice_context' _ "${functions}" "$1" "${2:-1}" 2>"${err}")"
    ERR="$(<"${err}")"
}

notice='ai-tools-chown: NOTICE: secret-named file written by agent considered breached, rotate the secret: /p/.env'
reply "MSG-A6D8"$'\n'"${notice}"$'\n'"ai-tools-handback-client: helper exited 0"
if [[ -n "${OUT}" ]] && jq -e . >/dev/null 2>&1 <<<"${OUT}"; then
    pass "a relayed message code yields one JSON reply"
else
    fail "a relayed message code: reply '${OUT:0:200}'"
fi
context="$(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"${OUT}" 2>/dev/null || true)"
event="$(jq -r '.hookSpecificOutput.hookEventName // empty' <<<"${OUT}" 2>/dev/null || true)"
message="$(jq -r '.systemMessage // empty' <<<"${OUT}" 2>/dev/null || true)"
if [[ "${event}" == PostToolUse && "${context}" == *MSG-A6D8* && "${context}" == *"${notice}"* ]]; then
    pass "the reply is a PostToolUse additionalContext carrying the code and the NOTICE"
else
    fail "the reply's context: event '${event}', context '${context:0:200}'"
fi
if [[ "${context}" != *ai-tools-handback-client:* ]]; then
    pass "the client's own error line is left out of the context"
else
    fail "the context carries the client's error line"
fi
if [[ "${message}" == "${notice}" ]]; then
    pass "systemMessage is the NOTICE line, not its code"
else
    fail "systemMessage: '${message}'"
fi
if [[ "${ERR}" == *"${notice}"* ]]; then
    pass "the relayed lines still reach the hook's stderr (the debug log)"
else
    fail "the hook's stderr lost the relayed lines: '${ERR:0:200}'"
fi

reply "ai-tools-handback-client: helper exited 1"
if [[ -z "${OUT}" ]]; then
    pass "a relay without a message code prints no reply"
else
    fail "a relay without a code printed '${OUT:0:200}'"
fi
reply ""
if [[ -z "${OUT}" ]]; then
    pass "a call that relayed nothing prints no reply"
else
    fail "an empty relay printed '${OUT:0:200}'"
fi

# Lines from several calls in one event share one reply, bounded.
reply "MSG-A6D8"$'\n'"${notice}" 60
context="$(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"${OUT}" 2>/dev/null || true)"
bound="$(sed -n 's/^readonly MAX_NOTICE_CONTEXT_LENGTH=//p' "${HOOK}")"
if [[ "$(grep -c '^{' <<<"${OUT}")" == 1 && -n "${context}" && "${#context}" -le "${bound}" ]]; then
    pass "60 calls with a NOTICE each yield one reply, its context within ${bound} characters"
else
    fail "60 calls: $(grep -c '^{' <<<"${OUT}") reply line(s), context length ${#context}"
fi

# ── The hook routes every handback through the function, and replies after it ──────────────────────────────────────
section "claude-code PostToolUse: every handback call is relayed, and the reply follows the handback"
# The two greps match the hook's source text literally.
hook_text="$(<"${HOOK}")"
relay_text="$(extract_function "${HOOK}" hand_back_path)"
# shellcheck disable=SC2016
direct_calls="$(grep -c '"${HANDBACK_CLIENT}" CHOWN' <<<"${hook_text}" || true)"
# shellcheck disable=SC2016
if [[ "${direct_calls}" == 1 ]] && grep -qF '"${HANDBACK_CLIENT}" CHOWN' <<<"${relay_text}"; then
    pass "the one direct client call is inside hand_back_path"
else
    fail "${direct_calls} direct client call(s) in the hook, expected 1 inside hand_back_path"
fi
main_text="$(extract_function "${HOOK}" main)"
if grep -qzE 'hand_back_written_path "\$\{hook_event_json\}"[[:space:]]+emit_notice_context' <<<"${main_text}"; then
    pass "main emits the reply after the handback"
else
    fail "main does not call emit_notice_context after hand_back_written_path"
fi

finish
