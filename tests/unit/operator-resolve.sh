#!/usr/bin/env bash
# tests/unit/operator-resolve.sh
# Unit test for the operator resolver in operator.lib.sh -- the shared source the handback helpers
# use to decide which operator owns an agent-written path. Pins the two security-critical functions
# against a /tmp fixture tree via the AI_TOOLS_OPERATOR_CONF + AI_TOOLS_ALLOWLIST root-only test
# hooks: ai_tools_allowlist_covers (allow/exclude/nested matching) and ai_tools_resolve_owner (a
# covered path resolves to the operator and exposes the owner's allowlist; an excluded or
# out-of-list path resolves to no owner, so the helpers leave it untouched). Multi-operator
# tie-break resolution needs several real operator accounts and is covered by the integration
# suite. Run as root via sudo (the harness derives the projects user from SUDO_USER).
#
# ai_tools_resolve_owner is exercised in a child shell: it assigns PROJECTS_USER/HOME/GROUP/UID,
# which the harness pins readonly, so it must run where those are not yet frozen.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly LIB="/usr/local/lib/ai-tools/operator.lib.sh"
section "operator resolver (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "operator resolver" "library not readable at ${LIB}"; finish; exit
fi

mktestdir
mkdir -p "${TESTDIR}"/proj/sub "${TESTDIR}"/proj/secret "${TESTDIR}"/other
allow="${TESTDIR}/allowed-projects"
printf '%s\n' "${TESTDIR}/proj" "!${TESTDIR}/proj/secret" > "${allow}"
conf="${TESTDIR}/operator.conf"
printf 'OPERATORS="%s"\n' "${PROJECTS_USER}" > "${conf}"
export AI_TOOLS_OPERATOR_CONF="${conf}" AI_TOOLS_ALLOWLIST="${allow}"

# ── ai_tools_allowlist_covers is pure (no global writes), so source the lib and call it here. ──
# shellcheck source=/dev/null
source "${LIB}"
covers() { ai_tools_allowlist_covers "${allow}" "$1"; }
covers "${TESTDIR}/proj"        && pass "covers: allowed project root"          || fail "covers: allowed root"
covers "${TESTDIR}/proj/sub"    && pass "covers: file under an allowed project" || fail "covers: nested path"
covers "${TESTDIR}/proj/secret" && fail "covers: excluded path matched"         || pass "covers: '!'-excluded path is not covered"
covers "${TESTDIR}/other"       && fail "covers: unlisted path matched"         || pass "covers: unlisted path is not covered"

# ── ai_tools_resolve_owner in a child shell: echo "<rc> <user> <allowlist>". ──
resolve_out() {
    RP="$1" LIBP="${LIB}" bash -c '
        source "${LIBP}"
        if ai_tools_resolve_owner "${RP}"; then
            printf "0 %s %s\n" "${PROJECTS_USER}" "${AI_TOOLS_RESOLVED_ALLOWLIST}"
        else
            printf "1 - -\n"
        fi'
}

read -r rc user al <<< "$(resolve_out "${TESTDIR}/proj/sub")"
if [[ "${rc}" == 0 && "${user}" == "${PROJECTS_USER}" && "${al}" == "${allow}" ]]; then
    pass "resolve_owner: covered path resolves to the operator and exposes the owner's allowlist"
else
    fail "resolve_owner: covered path gave rc=${rc} user=${user} allowlist=${al}"
fi

read -r rc _ _ <<< "$(resolve_out "${TESTDIR}/proj/secret")"
[[ "${rc}" == 1 ]] && pass "resolve_owner: excluded path resolves to no owner" \
                   || fail "resolve_owner: excluded path resolved (rc=${rc})"

read -r rc _ _ <<< "$(resolve_out "${TESTDIR}/other")"
[[ "${rc}" == 1 ]] && pass "resolve_owner: unlisted path resolves to no owner" \
                   || fail "resolve_owner: unlisted path resolved (rc=${rc})"

finish
