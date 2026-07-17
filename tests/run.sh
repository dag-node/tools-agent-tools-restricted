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
#
# A green exit proves coverage only when something PASSed: a file whose run recorded zero
# passes (every check skipped, or no harness result line at all) and a category with no test
# files are listed in an end-of-run "no coverage" notice. The default stays lenient -- a
# partial/dev install legitimately skips -- and AI_TOOLS_TEST_STRICT=1 turns the notice into
# a failure, the mode the full-install CI gate runs.

set -uo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode="${1:-all}"

[[ "${EUID}" -eq 0 ]] || { echo "error: run with sudo (tests need root)" >&2; exit 1; }
[[ -n "${SUDO_USER:-}" ]] || { echo "error: invoke via sudo, not as root directly" >&2; exit 1; }

rc=0
declare -a _failed=()                 # "category/file" of each test file that failed
declare -a _nocoverage=()             # green files with zero PASSes; categories with no files
_summary="$(mktemp)"                  # accumulates the FAIL lines, grouped by file
trap 'rm -f "${_summary}"' EXIT

run_dir() {
    local dir="${HERE}/$1" f name out st line ran=0
    local re='^[[:space:]]*([0-9]+) passed, [0-9]+ failed, ([0-9]+) skipped$'
    if [[ ! -d "${dir}" ]]; then _nocoverage+=("$1/ (no test files)"); return 0; fi
    for f in "${dir}"/*.sh; do
        [[ -e "${f}" ]] || continue
        ran=$(( ran + 1 ))
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
        else
            # A green exit proves coverage only when something PASSed: classify from the
            # harness finish() line (the only line matching this shape).
            line="$(grep -E "${re}" "${out}" | tail -1)"
            if [[ "${line}" =~ ${re} ]]; then
                [[ "${BASH_REMATCH[1]}" -gt 0 ]] \
                    || _nocoverage+=("${name} (0 passed, ${BASH_REMATCH[2]} skipped)")
            else
                _nocoverage+=("${name} (no result summary)")
            fi
        fi
        rm -f "${out}"
    done
    [[ "${ran}" -gt 0 ]] || _nocoverage+=("$1/ (no test files)")
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

# No-coverage notice: green-by-status files that proved nothing, and empty categories.
# Lenient by default; AI_TOOLS_TEST_STRICT=1 (the full-install CI gate) fails the run, so a
# broken prerequisite cannot hide behind skips.
if [[ ${#_nocoverage[@]} -gt 0 ]]; then
    printf '\n══════ no coverage (%d) ══════\n' "${#_nocoverage[@]}"
    printf '  %s\n' "${_nocoverage[@]}"
    if [[ "${AI_TOOLS_TEST_STRICT:-0}" == "1" ]]; then
        printf '  AI_TOOLS_TEST_STRICT=1: no-coverage is a failure\n'
        rc=1
    fi
fi

printf '\n══════ overall: %s ══════\n' "$([[ ${rc} -eq 0 ]] && echo PASS || echo FAIL)"
exit "${rc}"
