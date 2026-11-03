#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/relabel-agent.sh
# Unit test for how ai-tools-relabel-agent closes a run over the labelling library's status lines: what it files
# per agent for ai-tools status, which code it prints, and its exit status. The helper runs as root and labels the host,
# so its closing functions (render_label_report, record_label_outcomes, report_live_sessions) and its emitters are read
# out of it as text (extract_function) and driven in a fresh bash per case, with record_label_outcome stubbed to print
# what would be filed.
#
# The case that carries the file is a config directory the live-session gate left: at the type the agent writes, the run
# warns and exits 0; at another type, which no session of the agent can write, it files the failure and exits 1,
# so ai-tools-relabel.service reads failed.
#
# The deployed helper is preferred where this account can read it and it defines the functions, the checkout's
# otherwise; a non-root run reads the checkout, since the deployed helper is 750 root:root.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

section "relabel-agent: closing a run over the library's status lines (unit)"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="/usr/local/libexec/ai-tools/ai-tools-relabel-agent"
if [[ ! -r "${HELPER}" ]] || ! command grep -q '^report_live_sessions() {' "${HELPER}"; then
    HELPER="${ROOT}/src/usr/local/libexec/ai-tools/ai-tools-relabel-agent.sh"
fi
note "the closing functions" "read from ${HELPER}"

mktestdir

# The functions a case runs, in the order the helper defines them; every one must come out of the helper non-empty.
functions=(say warn die render_label_report record_label_outcomes report_live_sessions)
extracted="${TESTDIR}/closing.sh"
: > "${extracted}"
missing=()
for name in "${functions[@]}"; do
    body="$(extract_function "${HELPER}" "${name}")"
    if [[ -z "${body}" ]]; then missing+=("${name}"); continue; fi
    printf '%s\n' "${body}" >> "${extracted}"
done
if (( ${#missing[@]} )); then
    fail "${HELPER} does not define ${missing[*]}, so the run's close cannot be driven"
    finish; exit
fi
pass "the helper defines each function the cases drive (control)"

# The probe sources the extracted functions with the logger and the record writer stubbed, then closes a run
# over the status lines it is given, as the helper's top level does. Both streams on stdout, the exit status last.
probe="${TESTDIR}/probe.sh"
cat > "${probe}" <<'PROBE'
set -euo pipefail
source "$1"
ai_tools_log__info() { :; }; ai_tools_log__warn() { :; }; ai_tools_log__error() { :; }
record_label_outcome() { printf 'record %s %s %s\n' "$1" "$2" "${3:-}"; }
render_label_report "$2"
record_label_outcomes
report_live_sessions
PROBE

# close_run <status-lines> : sets OUT (both streams) and RC.
close_run() {
    RC=0; OUT="$(bash "${probe}" "${extracted}" "$1" 2>&1)" || RC=$?
}
has_line() {
    if command grep -qxF -- "$2" <<< "${OUT}"; then pass "$1"; else fail "$1: '$2' absent: ${OUT//$'\n'/ | }"; fi
}

# ── A config directory at the type the agent writes ──────────────────────────────────────────
section "a walk left over a config directory at its own type is a warning (control)"
close_run $'live acme ai_tools_home_t its config directory\nagent acme live-session'
has_line "the agent is filed as skipped for its live session" "record acme skipped live-session"
assert_msg MSG-E4E8 "${OUT}" "the run names the walk it left"
if command grep -qxF MSG-G6D2 <<< "${OUT}"; then
    fail "a directory at its own type is reported as one the agent cannot write"
else
    pass "a directory at its own type is not reported as one the agent cannot write"
fi
if [[ "${RC}" -eq 0 ]]; then pass "the run exits 0"; else fail "the run exits ${RC} over a directory at its own type"; fi

# ── A config directory at a type the agent cannot write ──────────────────────────────────────
section "a walk left over a config directory at another type fails the run"
close_run $'live acme usr_t its config directory\nagent acme live-session-mislabelled'
has_line "the agent is filed as failed for its live session" "record acme failed live-session"
assert_msg MSG-G6D2 "${OUT}" "the run names a directory the agent cannot write"
if command grep -qF 'acme: usr_t' <<< "${OUT}"; then
    pass "the refusal names the agent and the type its directory carries"
else
    fail "the refusal does not name 'acme: usr_t': ${OUT//$'\n'/ | }"
fi
if command grep -qF 'systemctl start ai-tools-relabel.service' <<< "${OUT}"; then
    pass "the refusal names the start that re-runs the walk"
else
    fail "the refusal does not name the service start: ${OUT//$'\n'/ | }"
fi
if [[ "${RC}" -eq 1 ]]; then pass "the run exits 1"; else fail "the run exits ${RC} over a directory the agent cannot write"; fi

# Both classes in one run: each agent filed as its class, the warning ahead of the refusal.
close_run $'live acme ai_tools_home_t its config directory\nagent acme live-session\nlive beta usr_t its config directory\nagent beta live-session-mislabelled'
has_line "the usable agent is filed as skipped beside the other" "record acme skipped live-session"
has_line "the other agent is filed as failed beside the usable one" "record beta failed live-session"
codes="$(command grep -xE 'MSG-(E4E8|G6D2)' <<< "${OUT}" | tr '\n' ' ' || true)"
if [[ "${codes}" == "MSG-E4E8 MSG-G6D2 " ]]; then
    pass "the warning for the usable class precedes the refusal"
else
    fail "the codes in order read '${codes}', expected 'MSG-E4E8 MSG-G6D2 '"
fi
if command grep -qF 'carries a type the agent cannot write (beta: usr_t)' <<< "${OUT}"; then
    pass "the refusal counts the other agent alone"
else
    fail "the refusal does not name beta alone: ${OUT//$'\n'/ | }"
fi
if [[ "${RC}" -eq 1 ]]; then pass "the run with both classes exits 1"; else fail "the run with both classes exits ${RC}"; fi

finish
