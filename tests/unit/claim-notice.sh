#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/claim-notice.sh
# Hermetic check of what the claim reports ahead of its first write. The live-session notice is the live-session
# reader's one unprivileged caller: `projects claim` reads the state as the operator ahead of its first sudo,
# and the notice shows on `live` alone, `unreadable` being left to the helper's refusal at the label step (cli.rule.md,
# ref-section-e6c6). The owner-only refusal reads the owner-side read's mode of the project root and refuses a mode
# without a group or other bit, under one code for a root no registry line names and another for a listed one.
#
# note_live_session is a function nested in cmd_project_claim, so it is read out of the checkout's ai-tools.sh as text
# by its indentation and run in a fresh shell with the reader, the renderers and the pending-label state stubbed. A stub
# returning `live` that reaches the renderer is the control that the extraction found the function and that the function
# calls the reader. require_open_project_root is read the same way, through extract_function, with die stubbed to print
# its code and exit 1; a 750 root passing is its control. Pure: no install, no root, no command of the CLI's. Skips
# outside a checkout.

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
if [[ "${out}" == *"headline: NOTICE: a process of the sandbox account is running"* && "${out}" == *"say:"*"atr stop"* ]]; then
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

section "ai-tools projects claim: an owner-only project root is refused before the first write (unit)"
refusal_text="$(extract_function "${CLI}" require_open_project_root)"
if [[ -z "${refusal_text}" ]]; then
    fail "ai-tools.sh does not define require_open_project_root() in the form this file reads"
    finish; exit
fi
# refusal_run <mode> <has-entry> : run the extracted function over /p with <mode> and <has-entry>; prints the stubbed
#   die's code where it refuses, then `rc=<status>`.
# shellcheck disable=SC2016  # the inner shell expands these, not this one
refusal_run() {
    "${BASH}" -c '
        set -euo pipefail
        CREATE_LEFT_TREE=""
        die() { printf "%s\n" "$1"; exit 1; }
        eval "$1"
        rc=0; ( require_open_project_root /p "$2" "$3" ) || rc=$?
        printf "rc=%s\n" "${rc}"
    ' _ "${refusal_text}" "$1" "$2" 2>/dev/null
}
# refusal_left <mode> <has-entry> <create-left-tree> : the CREATE_LEFT_TREE the function leaves before its exit.
# shellcheck disable=SC2016  # the inner shell expands these, not this one
refusal_left() {
    "${BASH}" -c '
        set -euo pipefail
        CREATE_LEFT_TREE="$4"
        die() { printf "left=%s\n" "${CREATE_LEFT_TREE}"; exit 1; }
        eval "$1"
        require_open_project_root /p "$2" "$3"
        printf "left=%s\n" "${CREATE_LEFT_TREE}"
    ' _ "${refusal_text}" "$1" "$2" "$3" 2>/dev/null || true
}

out="$(refusal_run 750 false)"
if [[ "${out}" == "rc=0" ]]; then
    pass "a 750 root passes, with no code printed (control)"
else
    fail "control: a 750 root did not pass, so the refusals below cannot be told from a function that refuses every mode: $(_san "${out}")"
fi
for row in "700 false MSG-H6J3 a first claim of a 700 root" "600 false MSG-H6J3 a first claim of a 600 root" \
           "500 false MSG-H6J3 a first claim of a 500 root" "2700 false MSG-H6J3 a first claim of a setgid 2700 root" \
           "700 true MSG-B5D2 a re-claim of a listed project whose root is 700"; do
    read -r mode has_entry code what <<<"${row}"
    out="$(refusal_run "${mode}" "${has_entry}")"
    if [[ "${out}" == "${code}"$'\n'"rc=1" ]]; then
        pass "${what} is refused under ${code} with exit 1"
    else
        fail "${what}: expected ${code} and rc=1, got $(_san "${out}")"
    fi
done
for mode in 710 701 755 ""; do
    out="$(refusal_run "${mode}" true)"
    [[ "${out}" == "rc=0" ]] && pass "a root at mode '${mode}' passes" \
        || fail "a root at mode '${mode}' printed: $(_san "${out}")"
done
out="$(refusal_left 700 false /p)"
[[ "${out}" == "left=" ]] \
    && pass "the refusal of a root projects create made clears the leftover-directory name, which would name a claim" \
    || fail "the refusal left the create's leftover-directory name set: $(_san "${out}")"
out="$(refusal_left 700 false /other)"
[[ "${out}" == "left=/other" ]] && pass "a leftover-directory name for another directory is kept" \
    || fail "the refusal changed another directory's leftover-directory name: $(_san "${out}")"

finish
