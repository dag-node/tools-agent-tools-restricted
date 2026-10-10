#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tools/checkers/assets-conformance.sh -- hold base's asset-set validator to the conformance fixtures of the release
# of dag-node/ai-tools-assets-tools that tools/checkers/assets-tools.pin names. Base's resolver (assets.lib.sh) enforces
# a subset of format 1 under the publisher's rule ids; the fixtures are where the two validators are shown to agree
# on that subset.
#
#     ```text
#     bash tools/checkers/assets-conformance.sh verify             fetch the pinned release archive and exit 1 unless
#                                                                    it matches the pin and its signature verifies
#     bash tools/checkers/assets-conformance.sh run                verify, then run the validator over every fixture
#     bash tools/checkers/assets-conformance.sh run --checkout DIR read the fixtures from a checkout of the tools
#                                                                    instead, and report that the pin was bypassed
#     ```
#
# The archive verifies when its sha256 equals the pin's and the one its release publishes, and its detached signature is
# made by a key whose primary fingerprint is the dag-node package-signing primary, read through the key base itself
# ships (src/usr/local/lib/ai-tools/keys/dag-node-package-signing.asc), so the anchor is the one every set binding
# names. A fixture is selected when its `rule=` is one AI_TOOLS_ASSETS_ENFORCED_RULES lists; the job then asserts
# the validator returns 1 reporting that rule and no other, and over every `pass/` fixture that it returns 0 reporting
# nothing (run_fixtures states the disagreements). Three selections are narrower than the rule: of `name.asset-prefix`,
# the `.reserved` variant alone, since base enforces the reserved half and the `<set>-` prefix is the publisher's check;
# of `body.dynamic-injection`, every variant but `.not-allowed*`, whose outcome turns on publisher.conf, a file
# that does not reach a host; and of `frontmatter.syntax`, the variants `selected` names, the shapes base's bounded
# reader refuses, so a variant a later release adds is skipped until base claims it. Every other fixture is counted
# and skipped.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIN="${ROOT}/tools/checkers/assets-tools.pin"
LIB_DIR="${ROOT}/src/usr/local/lib/ai-tools"
RELEASE_URL="https://github.com/dag-node/ai-tools-assets-tools/releases/download"
SIGNING_KEY="${LIB_DIR}/keys/dag-node-package-signing.asc"
SIGNING_PRIMARY_FPR="67F42DC18BF764B42D82F14256D2F802CF9832E4"   # DagNode Package Signing

die() { printf 'assets-conformance: %s\n' "$*" >&2; exit 1; }

# pin_value <key>: print the value of `<key>=` in the pin; exit 1 when the pin does not carry it.
pin_value() {
    local line
    line="$(grep -E "^$1=" "${PIN}")" || die "${PIN} does not carry $1"
    printf '%s\n' "${line#*=}"
}

# fetch <url> <out>: download over HTTPS alone, retried, to a file.
fetch() {
    curl -fsSL --proto '=https' --retry 5 --retry-delay 3 --retry-all-errors --connect-timeout 20 -o "$2" "$1" \
        || die "cannot download $1"
}

# fetch_release <workdir>: download the pinned archive with its .sha256 and .asc, verify all three, unpack it
# into <workdir>, and print the unpacked tree's path.
fetch_release() {
    local work="$1" tag archive want published status
    tag="$(pin_value tag)"; archive="$(pin_value archive)"; want="$(pin_value archive_sha256)"
    [[ "${archive}" =~ ^ai-tools-assets-tools-[0-9][0-9A-Za-z.+-]*\.tar\.gz$ ]] || die "the pin names an archive outside the release's naming: ${archive}"
    fetch "${RELEASE_URL}/${tag}/${archive}" "${work}/${archive}"
    fetch "${RELEASE_URL}/${tag}/${archive}.sha256" "${work}/${archive}.sha256"
    fetch "${RELEASE_URL}/${tag}/${archive}.asc" "${work}/${archive}.asc"
    [[ "$(sha256sum < "${work}/${archive}" | cut -c1-64)" == "${want}" ]] || die "${archive} does not match the pin's sha256"
    published="$(cut -c1-64 < "${work}/${archive}.sha256")"
    [[ "${published}" == "${want}" ]] || die "the release publishes ${published} for ${archive}, the pin ${want}"
    bash -c '. "$1" && ai_tools_assets_write_binary_keyring "$2" "$3"' _ \
        "${LIB_DIR}/assets-verify.lib.sh" "${SIGNING_KEY}" "${work}/keyring.gpg" \
        || die "the package-signing key did not dearmor into a keyring"
    status="$(gpgv --status-fd 1 --keyring "${work}/keyring.gpg" "${work}/${archive}.asc" "${work}/${archive}" 2>/dev/null)" \
        || die "gpgv refuses the signature over ${archive}"
    grep -qE "^\[GNUPG:\] VALIDSIG .* ${SIGNING_PRIMARY_FPR}$" <<< "${status}" \
        || die "${archive} is not signed by the primary ${SIGNING_PRIMARY_FPR}"
    tar -xzf "${work}/${archive}" -C "${work}"
    printf '%s/%s\n' "${work}" "${archive%.tar.gz}"
}

# selected <fixture-name> <rule> : succeed when the fixture is one base is held to.
selected() {
    local name="$1" rule="$2"
    local -a syntax_variants=( frontmatter.syntax frontmatter.syntax.alias-item frontmatter.syntax.colon
                               frontmatter.syntax.colon-tab frontmatter.syntax.empty-item frontmatter.syntax.escape
                               frontmatter.syntax.flow-comment-item frontmatter.syntax.flow-reserved-indicator
                               frontmatter.syntax.flow-tab-comment )
    [[ " ${AI_TOOLS_ASSETS_ENFORCED_RULES[*]} " == *" ${rule} "* ]] || return 1
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
        expect="$(ai_tools_conf_get "${conf}" expect || true)"
        rule="$(ai_tools_conf_get "${conf}" rule || true)"
        profile="$(ai_tools_conf_get "${conf}" profile || true)"
        # `warn` is a finding the publisher reports and does not refuse on; base does not report a warning, so it is skipped.
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
        output="$(ai_tools_assets_validate_set "${set_dir}" "${profile:-source}")" || status=$?
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

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
case "${1:-}" in
    verify)
        fetch_release "${work}" >/dev/null
        printf 'assets-conformance: %s verifies against the pin and the package-signing key\n' "$(pin_value archive)" ;;
    run)
        if [[ "${2:-}" == --checkout ]]; then
            [[ -d "${3:-}/fixtures" ]] || die "--checkout takes a checkout of ai-tools-assets-tools, which holds fixtures/"
            printf 'assets-conformance: BYPASS -- reading the fixtures of the checkout %s at %s, not the pinned release %s\n' \
                "$3" "$(git -C "$3" rev-parse --short HEAD 2>/dev/null || printf 'an unknown commit')" "$(pin_value tag)"
            run_fixtures "$3/fixtures"
        else
            tree="$(fetch_release "${work}")"
            run_fixtures "${tree}/fixtures"
        fi ;;
    *)  die "usage: assets-conformance.sh verify | run [--checkout DIR]" ;;
esac
