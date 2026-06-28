#!/usr/bin/env bash
# tests/run.sh [unit|integration|boundary|all]
# Test dispatcher. Runs the chosen category's test files and aggregates pass/fail by exit
# status. On any failure it reprints the failing files' FAIL lines as an end-of-run summary,
# so a long run needs no scrolling; an all-green run prints no summary. Run via sudo: every
# category needs root (unit/integration set arbitrary ownership and run the deployed helpers;
# boundary drops to the agent via `sudo -u`).
#
# Categories (see .claude/rules/tests.rule.md):
#   unit         hermetic helper-logic tests (/tmp testdir + dummy allowlist; no live daemon)
#   integration  full-install checks (deployed perms, sudoers, wrapper, handback daemon, systemd)
#   boundary     confinement checks run as the agent (SANDBOX_USER)
#   all          every category

set -uo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode="${1:-all}"

[[ "${EUID}" -eq 0 ]] || { echo "error: run with sudo (tests need root)" >&2; exit 1; }
[[ -n "${SUDO_USER:-}" ]] || { echo "error: invoke via sudo, not as root directly" >&2; exit 1; }

rc=0
declare -a _failed=()                 # "category/file" of each test file that failed
_summary="$(mktemp)"                  # accumulates the FAIL lines, grouped by file
trap 'rm -f "${_summary}"' EXIT

run_dir() {
    local dir="${HERE}/$1" f name out st
    [[ -d "${dir}" ]] || return 0
    for f in "${dir}"/*.sh; do
        [[ -e "${f}" ]] || continue
        name="$1/$(basename "${f}")"
        printf '\n══════ %s ══════\n' "${name}"
        # Stream output live (tee) while capturing it, so a failed file's FAIL lines can be
        # reprinted in the end-of-run summary. PIPESTATUS[0] is the test's status, not tee's.
        out="$(mktemp)"
        bash "${f}" 2>&1 | tee "${out}"
        st="${PIPESTATUS[0]}"
        if [[ "${st}" -ne 0 ]]; then
            rc=1
            _failed+=("${name}")
            { printf '\n%s\n' "${name}"; grep -E '^[[:space:]]*FAIL' "${out}" || true; } >> "${_summary}"
        fi
        rm -f "${out}"
    done
}

case "${mode}" in
    unit)        run_dir unit ;;
    integration) run_dir integration ;;
    boundary)    run_dir boundary ;;
    all)         run_dir unit; run_dir integration; run_dir boundary ;;
    *) echo "usage: run.sh [unit|integration|boundary|all]" >&2; exit 2 ;;
esac

# Failure summary: which files failed and their FAIL lines, so a long run does not have to
# be scrolled. Printed only when something failed; an all-green run stays quiet.
if [[ "${rc}" -ne 0 ]]; then
    printf '\n══════ failures (%d file%s) ══════\n' \
        "${#_failed[@]}" "$([[ "${#_failed[@]}" -eq 1 ]] || echo s)"
    cat "${_summary}"
fi

printf '\n══════ overall: %s ══════\n' "$([[ ${rc} -eq 0 ]] && echo PASS || echo FAIL)"
exit "${rc}"
