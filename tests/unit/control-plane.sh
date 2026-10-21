#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/control-plane.sh
# Unit test for the unit search path readers in control-plane.lib.sh, the two `ai-tools-admin status` reports
# from: the drift reader, whose three statuses keep a failed reading apart from a closed chain, and the unexpected-entry
# reader, which names every entry under the chain's last directory other than the timer-stamp directory. The chain is
# brought to its modes by the layout reconcile, which tests/unit/layout.sh drives (tests.rule.md).
#
# Run as root via sudo: the fixture chains are root- and account-owned. Every fixture is in the testdir.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root
umask 022

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="/usr/local/lib/ai-tools/control-plane.lib.sh"
[[ -r "${LIB}" ]] || LIB="${ROOT}/src/usr/local/lib/ai-tools/control-plane.lib.sh"

section "control-plane: the sandbox unit search path readers (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "unit search path readers" "library not readable at ${LIB}"; finish; exit
fi
# shellcheck source=/dev/null
source "${LIB}" 2>/dev/null || true
if ! declare -F ai_tools_control_plane__find_unit_search_path_drift >/dev/null 2>&1 \
        || ! declare -F ai_tools_control_plane__find_unexpected_unit_search_path_entries >/dev/null 2>&1; then
    skip "unit search path readers" "the deployed library predates the unit search path readers"; finish; exit
fi

mktestdir

# mkchain <home> <owner> : a chain at the declared modes under <owner>, plus the stamp directory as the account's,
# a stamp and one ordinary XDG entry the account keeps.
mkchain() {
    local home="$1" owner="$2" relative
    for relative in "${CP_UNIT_SEARCH_PATH_CHAIN[@]}"; do
        install -d -o "${owner}" -g "${SANDBOX_GROUP}" -m "${CP_UNIT_SEARCH_PATH_MODES[${relative}]}" "${home}/${relative}"
        ai_tools_control_plane__apply_mode "${CP_UNIT_SEARCH_PATH_MODES[${relative}]}" "${home}/${relative}"
    done
    install -d -o "${SANDBOX_USER}" -g "${SANDBOX_GROUP}" -m "${CP_TIMER_STAMP_DIR_MODE}" "${home}/${CP_TIMER_STAMP_DIR}"
    install -d -o "${SANDBOX_USER}" -g "${SANDBOX_GROUP}" -m 0750 "${home}/.local/share/NuGet"
    install -o "${SANDBOX_USER}" -g "${SANDBOX_GROUP}" -m 0644 /dev/null \
        "${home}/${CP_TIMER_STAMP_DIR}/${CP_UPDATE_TIMER_STAMP}"
}

# ── The drift reader: three statuses, so a failure is never read as a closed path ─────────────────────────────
HOME_A="${TESTDIR}/home-a"
mkchain "${HOME_A}" root
rc=0; out="$(ai_tools_control_plane__find_unit_search_path_drift "${HOME_A}" "${SANDBOX_GROUP}")" || rc=$?
if [[ "${rc}" -eq 1 && -z "${out}" ]]; then
    pass "a chain at its declared modes reads clean (status 1, no line)"
else
    fail "a converged chain read status ${rc}: ${out}"
fi
HOME_B="${TESTDIR}/home-b"
mkchain "${HOME_B}" "${SANDBOX_USER}"
rc=0; out="$(ai_tools_control_plane__find_unit_search_path_drift "${HOME_B}" "${SANDBOX_GROUP}")" || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -q "^${HOME_B}/.local ${SANDBOX_USER}:${SANDBOX_GROUP} 3770 root:" <<<"${out}"; then
    pass "an account-owned chain is reported as drift (status 0), naming what each path is and what it must be"
else
    fail "an account-owned chain read status ${rc}: ${out}"
fi
HOME_C="${TESTDIR}/home-c"
install -d -o "${SANDBOX_USER}" -g "${SANDBOX_GROUP}" -m 0750 "${HOME_C}" "${TESTDIR}/elsewhere"
ln -s "${TESTDIR}/elsewhere" "${HOME_C}/.local"
rc=0; out="$(ai_tools_control_plane__find_unit_search_path_drift "${HOME_C}" "${SANDBOX_GROUP}")" || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -q "^${HOME_C}/.local symlink root:" <<<"${out}" \
        && grep -q "^${HOME_C}/.local/share absent root:" <<<"${out}"; then
    pass "a symlink on the chain and the absent directories under it are each reported by their word"
else
    fail "a symlinked chain read status ${rc}: ${out}"
fi
rc=0; ai_tools_control_plane__find_unit_search_path_drift "" "" >/dev/null 2>&1 || rc=$?
if [[ "${rc}" -eq 2 ]]; then
    pass "a reading it could not make is status 2, told apart from a clean chain so no caller renders it as closed"
else
    fail "an unmakeable drift reading returned ${rc}, expected 2"
fi

# ── The unexpected-entry reader names what is on the path, and passes over the stamp directory ───────────────
if [[ -z "$(ai_tools_control_plane__find_unexpected_unit_search_path_entries "${HOME_A}")" ]]; then
    pass "a chain holding the timer-stamp directory alone yields no entry"
else
    fail "the entries reader named: $(ai_tools_control_plane__find_unexpected_unit_search_path_entries "${HOME_A}")"
fi
install -d -o "${SANDBOX_USER}" -g "${SANDBOX_GROUP}" -m 0750 "${HOME_A}/.local/share/systemd/user"
printf '[Service]\nExecStart=/bin/true\n' > "${HOME_A}/.local/share/systemd/user/planted.service"
if [[ "$(ai_tools_control_plane__find_unexpected_unit_search_path_entries "${HOME_A}")" == "${HOME_A}/.local/share/systemd/user" ]]; then
    pass "an entry under .local/share/systemd is named, and the timer-stamp directory is not"
else
    fail "ai_tools_control_plane__find_unexpected_unit_search_path_entries: $(ai_tools_control_plane__find_unexpected_unit_search_path_entries "${HOME_A}")"
fi
if [[ -f "${HOME_A}/.local/share/systemd/user/planted.service" ]]; then
    pass "the reader leaves the entry where it was found, for the operator to inspect"
else
    fail "the reader moved or removed the unexpected entry"
fi
# A name the account chose reaches a terminal through this reader, so a byte outside printable ASCII is clamped.
install -d -o "${SANDBOX_USER}" -g "${SANDBOX_GROUP}" -m 0750 "${HOME_A}/.local/share/systemd/"$'odd\x1bname'
if grep -q 'odd?name' <<<"$(ai_tools_control_plane__find_unexpected_unit_search_path_entries "${HOME_A}")"; then
    pass "a name carrying an escape byte is printed with the byte replaced"
else
    fail "the entries reader printed: $(ai_tools_control_plane__find_unexpected_unit_search_path_entries "${HOME_A}" | od -c | head -3)"
fi

finish
