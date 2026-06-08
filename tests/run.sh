#!/usr/bin/env bash
# tests/run.sh [unit|integration|boundary|all]
# Test dispatcher. Runs the chosen category's test files and aggregates pass/fail by exit
# status. Run via sudo: every category needs root (unit/integration set arbitrary
# ownership and run the deployed helpers; boundary drops to the agent via `sudo -u`).
#
# Categories (see .claude/rules/tests.rule.md):
#   unit         hermetic helper-logic tests (/tmp testdir + dummy allowlist; no live daemon)
#   integration  full-install checks (deployed perms, sudoers, wrapper, handback daemon, systemd)
#   boundary     confinement checks run as the agent (SANDBOX_USER)
#   all          every category
#
# Migration in progress: unit/ holds the relocated helper tests; integration and boundary
# checks not yet relocated still live in the top-level test.sh, which `all` also runs.

set -uo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO="$(cd "${HERE}/.." && pwd)"
mode="${1:-all}"

[[ "${EUID}" -eq 0 ]] || { echo "error: run with sudo (tests need root)" >&2; exit 1; }
[[ -n "${SUDO_USER:-}" ]] || { echo "error: invoke via sudo, not as root directly" >&2; exit 1; }

rc=0

run_dir() {
    local dir="${HERE}/$1" f
    [[ -d "${dir}" ]] || return 0
    for f in "${dir}"/*.sh; do
        [[ -e "${f}" ]] || continue
        printf '\n══════ %s/%s ══════\n' "$1" "$(basename "${f}")"
        bash "${f}" || rc=1
    done
}

run_legacy() {
    [[ -x "${REPO}/test.sh" ]] || return 0
    printf '\n══════ legacy test.sh (integration + boundary, pending relocation) ══════\n'
    "${REPO}/test.sh" || rc=1
}

case "${mode}" in
    unit)        run_dir unit ;;
    integration) run_dir integration; run_legacy ;;
    boundary)    run_dir boundary ;;
    all)         run_dir unit; run_dir integration; run_dir boundary; run_legacy ;;
    *) echo "usage: run.sh [unit|integration|boundary|all]" >&2; exit 2 ;;
esac

printf '\n══════ overall: %s ══════\n' "$([[ ${rc} -eq 0 ]] && echo PASS || echo FAIL)"
exit "${rc}"
