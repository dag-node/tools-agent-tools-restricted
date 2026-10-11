#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tools/checkers/assets-conformance.sh -- hold base's asset-set validator to the conformance fixtures of the release
# of dag-node/ai-tools-assets-tools that tools/lib/assets-tools.pin names. Base's resolver (assets.lib.sh) enforces
# a subset of format 1 under the publisher's rule ids; the fixtures are where the two validators are shown to agree
# on that subset.
#
#     ```text
#     bash tools/checkers/assets-conformance.sh run     run the validator over every fixture of the pinned release
#     ```
#
# The fixtures are read through tools/lib/assets.sh, which verified the release before it unpacked it (`fetch`, then
# `verify`, which CI runs first); with the pin not in the cache the run exits 1 naming the fetch command,
# and AI_TOOLS_DEV_ASSETS_TOOLS reads a checkout of the tools instead, reported as a bypass of the pin. A fixture is
# selected when its `rule=` is one AI_TOOLS_ASSETS__ENFORCED_RULES lists; the job then asserts the validator returns 1
# reporting that rule and no other, and over every `pass/` fixture that it returns 0 reporting nothing (run_fixtures
# states the disagreements). Three selections are narrower than the rule: of `name.asset-prefix`, the `.reserved`
# variant alone, since base enforces the reserved half and the `<set>-` prefix is the publisher's check;
# of `body.dynamic-injection`, every variant but `.not-allowed*`, whose outcome turns on publisher.conf, a file
# that does not reach a host; and of `frontmatter.syntax`, the variants `selected` names, the shapes base's bounded
# reader refuses, so a variant a later release adds is skipped until base claims it. Every other fixture is counted
# and skipped.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB_DIR="${ROOT}/src/usr/local/lib/ai-tools"
# shellcheck source=SCRIPTDIR/../lib/assets.sh
source "${ROOT}/tools/lib/assets.sh"

die() { printf 'assets-conformance: %s\n' "$*" >&2; exit 1; }

# selected <fixture-name> <rule> : succeed when the fixture is one base is held to.
selected() {
    local name="$1" rule="$2"
    local -a syntax_variants=( frontmatter.syntax frontmatter.syntax.alias-item frontmatter.syntax.colon
                               frontmatter.syntax.colon-tab frontmatter.syntax.empty-item frontmatter.syntax.escape
                               frontmatter.syntax.flow-comment-item frontmatter.syntax.flow-reserved-indicator
                               frontmatter.syntax.flow-tab-comment )
    [[ " ${AI_TOOLS_ASSETS__ENFORCED_RULES[*]} " == *" ${rule} "* ]] || return 1
    [[ "${rule}" == name.asset-prefix && "${name}" != name.asset-prefix.reserved ]] && return 1
    [[ "${name}" == body.dynamic-injection.not-allowed* ]] && return 1
    [[ "${rule}" == frontmatter.syntax && " ${syntax_variants[*]} " != *" ${name} "* ]] && return 1
    return 0
}

# run_fixtures <fixtures-dir> : the validator over every fixture; prints each disagreement and the counts, and exits 1
# on a disagreement or when no fixture was checked. The validator's output and its status are read apart: a pass fixture
# holds when it returns 0 with no finding, a fail fixture when it returns 1 with its rule alone, and any other status is
# a disagreement. A fixture whose `expect` is not pass, fail or warn, whose `profile` is neither source nor release,
# or which does not hold exactly one set directory is a disagreement before the validator runs; a `warn` fixture is
# skipped.
run_fixtures() {
    local fixtures="$1" fixture name conf expect rule profile set_dir output rules status checked=0 skipped=0 failed=0
    local -a set_dirs=()
    # shellcheck source=SCRIPTDIR/../../src/usr/local/lib/ai-tools/assets.lib.sh
    source "${LIB_DIR}/assets.lib.sh" || die "assets.lib.sh did not load"
    for fixture in "${fixtures}"/fail/* "${fixtures}"/pass/*; do
        [[ -d "${fixture}" ]] || continue
        name="${fixture##*/}"; conf="${fixture}/fixture.conf"
        expect="$(ai_tools_conf__print_value "${conf}" expect || true)"
        rule="$(ai_tools_conf__print_value "${conf}" rule || true)"
        profile="$(ai_tools_conf__print_value "${conf}" profile || true)"
        # `warn` is a finding the publisher reports and does not refuse on; base does not report a warning, so it is
        # skipped.
        if [[ "${expect}" == warn ]]; then skipped=$(( skipped + 1 )); continue; fi
        if [[ "${expect}" != fail && "${expect}" != pass ]]; then
            printf 'FAIL %s: expect=%s; a fixture expects pass, fail or warn\n' "${name}" "${expect:-(absent)}"; failed=$(( failed + 1 )); continue
        fi
        if [[ "${expect}" == fail ]] && ! selected "${name}" "${rule}"; then skipped=$(( skipped + 1 )); continue; fi
        if [[ -n "${profile}" && "${profile}" != source && "${profile}" != release ]]; then
            printf 'FAIL %s: profile=%s; the validator reads source or release\n' "${name}" "${profile}"; failed=$(( failed + 1 )); continue
        fi
        mapfile -t set_dirs < <(find "${fixture}" -mindepth 1 -maxdepth 1 -type d)
        if (( ${#set_dirs[@]} != 1 )); then
            printf 'FAIL %s: the fixture does not hold exactly one set directory\n' "${name}"; failed=$(( failed + 1 )); continue
        fi
        set_dir="${set_dirs[0]}"
        status=0
        output="$(ai_tools_assets__validate_set "${set_dir}" "${profile:-source}")" || status=$?
        rules=""
        [[ -z "${output}" ]] || rules="$(cut -f1 <<< "${output}" | LC_ALL=C sort -u | tr '\n' ' ')"
        checked=$(( checked + 1 ))
        if [[ "${expect}" == pass && ( "${status}" != 0 || -n "${output}" ) ]]; then
            output="${output//$'\n'/ | }"
            printf 'FAIL %s: a pass fixture, status %s, reported: %s\n' "${name}" "${status}" "${output:-nothing}"
            failed=$(( failed + 1 ))
        elif [[ "${expect}" == fail && ( "${status}" != 1 || "${rules}" != "${rule} " ) ]]; then
            printf 'FAIL %s: want %s alone at status 1, status %s, reported: %s\n' "${name}" "${rule}" "${status}" "${rules:-nothing}"
            failed=$(( failed + 1 ))
        fi
    done
    printf 'assets-conformance: %d fixtures checked, %d disagree, %d skipped (a rule base does not enforce, a variant base does not claim or that turns on publisher.conf, or a warning)\n' \
        "${checked}" "${failed}" "${skipped}"
    (( checked > 0 )) || die "no fixture was checked under ${fixtures}"
    (( failed == 0 ))
}

case "${1:-}" in
    run)
        fixtures="$(ai_tools_dev_assets__resolve_tool fixtures)" \
            || die "the fixtures of the pinned tools release are not in the cache; run: ${AI_TOOLS_DEV_ASSETS__FETCH_COMMAND}"
        run_fixtures "${fixtures}" ;;
    *)  die "usage: assets-conformance.sh run" ;;
esac
