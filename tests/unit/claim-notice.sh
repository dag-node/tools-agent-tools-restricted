#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/claim-notice.sh
# Hermetic check of the claim's live-session notice, the live-session reader's one unprivileged caller: `projects claim`
# reads the state as the operator ahead of its first sudo, and the notice shows on `live` alone, `unreadable` being left
# to the helper's refusal at the label step (cli.rule.md, ref-section-e6c6).
#
# note_live_session is a function nested in cmd_project_claim, so it is read out of the checkout's ai-tools.sh as text
# by its indentation and run in a fresh shell with the reader, the renderers and the pending-label state stubbed. A stub
# returning `live` that reaches the renderer is the control that the extraction found the function and that the function
# calls the reader. Pure: no install, no root, no command of the CLI's. Skips outside a checkout.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly CLI="${ROOT}/src/usr/local/bin/ai-tools.sh"
section "ai-tools projects claim: the live-session notice shows on a live reading alone (unit)"

if [[ ! -r "${CLI}" ]]; then
    skip "claim live-session notice" "not a source checkout (no ${CLI})"
    finish; exit
fi

notice_text="$(sed -n '/^    note_live_session() {$/,/^    }$/p' -- "${CLI}")"
if [[ -z "${notice_text}" ]]; then
    fail "ai-tools.sh does not define note_live_session() in the form this file reads"
    finish; exit
fi

# notice_run <reading> <need_label> <drift-count> : run the extracted function with the reader answering <reading>,
#   the label step pending per <need_label> (`true` or `false`, run as a command the way the claim runs it)
#   and <drift-count> drift paths listed; prints each renderer call on its own line.
# shellcheck disable=SC2016  # the inner shell expands these, not this one
notice_run() {
    "${BASH}" -c '
        set -euo pipefail
        SANDBOX_USER=acme C_BOLD="" C_RST=""
        stub_reading="$2"; need_label="$3"
        label_drift=(); for (( i = 0; i < $4; i++ )); do label_drift+=("/p/${i}"); done
        ai_tools_sessions__read_live_session_state() { printf "%s\n" "${stub_reading}"; }
        headline_warn() { printf "headline: %s\n" "$1"; }
        say() { printf "say: %s\n" "$*"; }
        eval "$1"
        note_live_session
    ' _ "${notice_text}" "$1" "$2" "$3" 2>&1
}

out="$(notice_run live true 0)"
if [[ "${out}" == *"headline: NOTICE: a session of the sandbox account is running"* && "${out}" == *"say:"*"ai-tools stop"* ]]; then
    pass "a live reading with the label step pending prints the notice and the stop command (control)"
else
    fail "control: a live reading did not reach the renderer, so the checks below cannot fail: $(_san "${out:-no output}")"
fi
out="$(notice_run unreadable true 0)"
[[ -z "${out}" ]] && pass "an unreadable reading prints no line" \
    || fail "an unreadable reading printed: $(_san "${out}")"
out="$(notice_run none true 0)"
[[ -z "${out}" ]] && pass "a none reading prints no line" || fail "a none reading printed: $(_san "${out}")"
out="$(notice_run live false 1)"
[[ "${out}" == *"headline:"* ]] && pass "a live reading with a drift relabel pending prints the notice" \
    || fail "a live reading with a drift relabel pending printed: $(_san "${out:-no output}")"
out="$(notice_run live false 0)"
[[ -z "${out}" ]] && pass "a live reading with no label step pending prints no line" \
    || fail "a live reading with no label step pending printed: $(_san "${out}")"

finish
