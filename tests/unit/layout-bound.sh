#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/layout-bound.sh
# Hermetic check of the deadline `ai-tools-admin system layout reconcile` holds its run to (AI_TOOLS_LAYOUT_RUN_BOUND,
# a root-only test hook, tests.rule.md). The library holds the layout lock while it runs, and an open blocked on a FIFO
# at a row's path would hold it until the host restarts; the command stops a run past the deadline and reports it.
#
# The checkout's ai-tools-admin.sh is sourced in a fresh shell, which stops at the guard ahead of its dispatch,
# with the library's loader, its table check and the reconcile itself stubbed: a reconcile that sleeps past a bound
# of two seconds without printing must return within a few seconds at exit 1 under MSG-H8U2, its collector gone,
# and a control that prints one `changed` line and exits 0 must come back at exit 0 without the code. Each case runs
# in its own bash, because the helper and the harness both declare SANDBOX_USER readonly. Unprivileged.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly HELPER="${ROOT}/src/usr/local/libexec/ai-tools/ai-tools-admin.sh"
section "ai-tools-admin: the layout reconcile runs under a deadline (unit)"

if [[ ! -r "${HELPER}" ]]; then
    skip "the reconcile deadline" "not a source checkout (no ${HELPER})"
    finish; exit
fi
mktestdir

# run_reconcile <stub-mode> <bound>: source the helper, stub the library, and run layout_reconcile, printing everything
# it said, then `status=<n> elapsed=<s>` and `alive=<0|1>` for the stub's process on the last lines. The stub writes its
# own PID to the testdir first, so the case can read whether the collector outlived the command.
run_reconcile() {
    AI_TOOLS_LAYOUT_RUN_BOUND="$2" bash -c '
        set -euo pipefail
        # shellcheck source=/dev/null
        source "$1" >/dev/null 2>&1 || { printf "NOT SOURCED\n"; exit 0; }
        declare -F layout_reconcile >/dev/null 2>&1 || { printf "NO SUCH FUNCTION\n"; exit 0; }
        stub_mode="$2" stub_pid_file="$3"
        layout_load() { :; }
        layout_require_table() { :; }
        ai_tools_layout__parse_stream_line() {
            local -n stub_fields="$2"
            IFS=$'"'"'\t'"'"' read -r -a stub_fields <<< "$1"
        }
        ai_tools_layout__reconcile() {
            printf "%s\n" "${BASHPID}" > "${stub_pid_file}"
            case "${stub_mode}" in
                hang)    sleep 30 ;;
                changed) printf "changed\t/fixture/row\tmode\t0700\t0755\n" ;;
            esac
        }
        status=0; started="${SECONDS}"
        layout_reconcile || status=$?
        printf "status=%s elapsed=%s\n" "${status}" "$(( SECONDS - started ))"
        sleep 0.2
        if kill -0 "$(cat "${stub_pid_file}")" 2>/dev/null; then printf "alive=1\n"; else printf "alive=0\n"; fi
    ' _ "${HELPER}" "$1" "${TESTDIR}/stub.pid" 2>&1 || true
}

out="$(run_reconcile changed 2)"
if [[ "${out}" == *"NOT SOURCED"* || "${out}" == *"NO SUCH FUNCTION"* ]]; then
    fail "sourcing ${HELPER} did not define layout_reconcile: $(_san "${out}")"
    finish; exit
fi
if [[ "${out}" == *"status=0 "* && "${out}" == *"changed /fixture/row mode"* ]] && ! grep -qxF MSG-H8U2 <<< "${out}"; then
    pass "a reconcile that finishes inside the bound is reported line by line at its own exit 0 (control)"
else
    fail "the control reconcile: $(_san "${out}")"
fi

out="$(run_reconcile hang 2)"
elapsed="$(sed -n 's/^status=[0-9]* elapsed=\([0-9]*\)$/\1/p' <<< "${out}")"
assert_msg MSG-H8U2 "${out}" "a reconcile past its bound is reported under its code"
if [[ "${out}" == *"status=1 "* && -n "${elapsed}" ]] && (( elapsed < 10 )); then
    pass "a reconcile past a 2s bound returns at exit 1 after ${elapsed}s, short of the stub's 30s sleep"
else
    fail "the bounded reconcile: $(_san "${out}")"
fi
if [[ "${out}" == *"alive=0"* ]]; then
    pass "the collector does not outlive the stopped run"
else
    fail "the collector is still running after the stopped run: $(_san "${out}")"
fi

out="$(run_reconcile changed not-a-number)"
[[ "${out}" == *"status=0 "* ]] && ! grep -qxF MSG-H8U2 <<< "${out}" \
    && pass "a malformed bound takes the default" || fail "a malformed bound: $(_san "${out}")"

finish
