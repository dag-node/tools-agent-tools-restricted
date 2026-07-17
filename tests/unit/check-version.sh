#!/usr/bin/env bash
# tests/unit/check-version.sh
# Unit test for packaging/check-version.sh, the release-metadata gate the release job runs
# at tag time (and `make -C packaging check-version` locally). Pins the tag grammar and the
# agreement rules hermetically on a TESTDIR copy with fixture VERSION/spec files: a bare run
# and a final vX.Y.Z tag require the three-way match, a vX.Y.Z-rc.N tag compares its base
# and relaxes only the %changelog match (surfacing a note), any other dashed tag is refused,
# and a missing %changelog entry stays fatal for every form. Exercises the repo's own copy
# (the script is not a deployed artifact); needs no privilege beyond the suite contract.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../packaging" && pwd)/check-version.sh"
readonly SRC
section "release-metadata gate: tag grammar + agreement (unit)"

if [[ ! -r "${SRC}" ]]; then
    skip "check-version" "script not readable at ${SRC}"; finish; exit
fi

mktestdir
cp "${SRC}" "${TESTDIR}/check-version.sh"

# write_fixture <version> <changelog-head|-> : VERSION plus a minimal spec whose newest
# %changelog entry names <changelog-head>; '-' writes a spec with no %changelog entry.
write_fixture() {
    printf '%s\n' "$1" > "${TESTDIR}/VERSION"
    {
        printf 'Name: ai-tools\n%%changelog\n'
        [[ "$2" == - ]] || printf '* Thu Jul 17 2026 dagnode <tools@dagnode.com> - %s-1\n- entry\n' "$2"
    } > "${TESTDIR}/ai-tools.spec"
}

# expect <ok|refused> <description> [tag]: run the TESTDIR copy (via bash, not execve --
# /tmp is noexec) and assert its exit status.
expect() {
    local want="$1" what="$2"; shift 2
    local st=0
    bash "${TESTDIR}/check-version.sh" "$@" >/dev/null 2>&1 || st=$?
    if [[ "${want}" == ok && "${st}" -eq 0 ]] || [[ "${want}" == refused && "${st}" -ne 0 ]]; then
        pass "${what}"
    else
        fail "${what}: exit ${st}, expected ${want}"
    fi
}

write_fixture 0.6.2 0.6.2
expect ok      "bare run, VERSION == %changelog head"
expect ok      "final tag matching VERSION"              v0.6.2
expect refused "final tag != VERSION"                    v0.6.3
expect ok      "rc tag, base matches VERSION"            v0.6.2-rc.1
expect refused "rc tag, base != VERSION"                 v0.6.3-rc.1
expect refused "dashed non-rc tag, matching base"        v0.6.2-beta.1
expect refused "dashed non-rc tag"                       v0.6.3-dev.1

write_fixture 0.6.2 0.6.1
expect refused "bare run, %changelog head behind VERSION"
expect refused "final tag with stale %changelog"         v0.6.2
expect ok      "rc tag relaxes the %changelog match"     v0.6.2-rc.1
if bash "${TESTDIR}/check-version.sh" v0.6.2-rc.1 2>&1 | grep -q '^note:'; then
    pass "relaxed rc mismatch surfaces a note"
else
    fail "relaxed rc mismatch prints no note"
fi

write_fixture 0.6.2 -
expect refused "no %changelog entry, bare"
expect refused "no %changelog entry, rc tag"             v0.6.2-rc.1

finish
