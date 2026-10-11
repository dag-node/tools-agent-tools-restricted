#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/control-plane.sh
# Unit test for the unit search path chain in control-plane.lib.sh: the converge, the readers `ai-tools-admin status`
# reports from, and the report parser both installers render from (tests.rule.md).
#
# Run as root via sudo: the converge chowns, and the fixture chains are account-owned. Every fixture is in the testdir.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root
umask 022

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="/usr/local/lib/ai-tools/control-plane.lib.sh"
[[ -r "${LIB}" ]] || LIB="${ROOT}/src/usr/local/lib/ai-tools/control-plane.lib.sh"

section "control-plane: the sandbox unit search path (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "unit search path chain" "library not readable at ${LIB}"; finish; exit
fi
# shellcheck source=/dev/null
source "${LIB}" 2>/dev/null || true
if ! declare -F ai_tools_control_plane__ensure_unit_search_path_closed >/dev/null 2>&1 \
        || ! declare -F ai_tools_control_plane__find_unit_search_path_drift >/dev/null 2>&1 \
        || ! declare -F ai_tools_control_plane__find_unexpected_unit_search_path_entries >/dev/null 2>&1; then
    skip "unit search path chain" "the deployed library predates the unit search path readers"; finish; exit
fi

mktestdir

# mkchain <home> : an account-owned chain in the shape a release before this layout created, plus a stamp and one
# ordinary XDG entry the account legitimately keeps.
mkchain() {
    install -d -o "${SANDBOX_USER}" -g "${SANDBOX_GROUP}" -m 0750 \
        "$1/.local" "$1/.local/share" "$1/.local/share/systemd" "$1/.local/share/systemd/timers" "$1/.local/share/NuGet"
    install -o "${SANDBOX_USER}" -g "${SANDBOX_GROUP}" -m 0644 /dev/null \
        "$1/.local/share/systemd/timers/stamp-nvm-update.timer"
}

# converge <home> : run the converge, printing its tagged lines then `rc=<status>`.
converge() {
    local rc=0
    ai_tools_control_plane__ensure_unit_search_path_closed "$1" "${SANDBOX_USER}" "${SANDBOX_GROUP}" 2>&1 || rc=$?
    printf 'rc=%s\n' "${rc}"
}

state() { stat -c '%U:%G %a' -- "$1" 2>/dev/null; }

# ── The chain ends root-owned at its declared modes, and the stamp directory stays the account's ──────────────
HOME_A="${TESTDIR}/home-a"
mkchain "${HOME_A}"
out="$(converge "${HOME_A}")"
if grep -qx 'rc=0' <<<"${out}"; then
    pass "a converge over an account-owned chain reports success"
else
    fail "converge over an account-owned chain: ${out}"
fi
chain_ok=1
for spec in ".local root:${SANDBOX_GROUP} 3770" ".local/share root:${SANDBOX_GROUP} 3770" \
            ".local/share/systemd root:${SANDBOX_GROUP} 2750"; do
    rel="${spec%% *}"; want="${spec#* }"
    got="$(state "${HOME_A}/${rel}")"
    [[ "${got}" == "${want}" ]] || { fail "${rel} is ${got}, want ${want}"; chain_ok=0; }
done
(( chain_ok )) && pass "each directory on the chain is root-owned at the mode control-plane.lib.sh declares"
got="$(state "${HOME_A}/.local/share/systemd/timers")"
if [[ "${got}" == "${SANDBOX_USER}:${SANDBOX_GROUP} 750" ]]; then
    pass "the timer-stamp directory stays the account's, so its own manager keeps writing the Persistent= stamps"
else
    fail "the timer-stamp directory is ${got}, want ${SANDBOX_USER}:${SANDBOX_GROUP} 750"
fi
if [[ -f "${HOME_A}/.local/share/systemd/timers/stamp-nvm-update.timer" ]]; then
    pass "an existing stamp file is left where it is"
else
    fail "the stamp file did not survive the converge"
fi
if [[ -d "${HOME_A}/.local/share/NuGet" ]]; then
    pass "an ordinary XDG entry the account keeps under .local/share is untouched"
else
    fail "the converge removed an ordinary XDG entry"
fi
if grep -q "^changed ${HOME_A}/.local " <<<"${out}"; then
    pass "each directory it changed is reported on its own tagged line"
else
    fail "the converge did not report what it changed: ${out}"
fi

# ── A second run is silent: an upgrade's scriptlet prints only what it changed ────────────────────────────────
out="$(converge "${HOME_A}")"
if grep -qx 'rc=0' <<<"${out}" && ! grep -q '^changed ' <<<"${out}"; then
    pass "a second converge changes nothing and reports nothing, so an upgrade is quiet on a converged host"
else
    fail "the converge is not idempotent: ${out}"
fi

# ── The account cannot rename a link of the converged chain aside ───────────────────────────────────────────
# The reason the parents are root-owned: a same-directory rename needs write on the parent alone.
renamed=0
for rel in .local/share .local/share/systemd; do
    if runuser -u "${SANDBOX_USER}" -- mv -- "${HOME_A}/${rel}" "${HOME_A}/${rel}.aside" 2>/dev/null; then
        renamed=1; mv -- "${HOME_A}/${rel}.aside" "${HOME_A}/${rel}"
        fail "the account renamed ${rel} aside, so it could replace the unit search path with its own"
    fi
done
(( renamed )) || pass "the account cannot rename .local/share or .local/share/systemd aside"
if runuser -u "${SANDBOX_USER}" -- mkdir "${HOME_A}/.local/share/own-entry" 2>/dev/null \
        && runuser -u "${SANDBOX_USER}" -- rmdir "${HOME_A}/.local/share/own-entry" 2>/dev/null; then
    pass "the account still creates and removes its own entry under .local/share"
else
    fail "the account cannot manage its own entries under .local/share"
fi

# ── An unexpected entry on the path is reported and left in place ───────────────────────────────────────────
HOME_B="${TESTDIR}/home-b"
mkchain "${HOME_B}"
install -d -o "${SANDBOX_USER}" -g "${SANDBOX_GROUP}" -m 0750 "${HOME_B}/.local/share/systemd/user"
printf '[Service]\nExecStart=/bin/true\n' > "${HOME_B}/.local/share/systemd/user/planted.service"
out="$(converge "${HOME_B}")"
if grep -qx 'rc=1' <<<"${out}" && grep -q "^error ${HOME_B}/.local/share/systemd/user " <<<"${out}"; then
    pass "an entry under .local/share/systemd is an error with a non-zero status"
else
    fail "an unexpected entry: ${out}"
fi
if [[ -f "${HOME_B}/.local/share/systemd/user/planted.service" ]]; then
    pass "it is left where it was found, for the operator to inspect"
else
    fail "the converge moved or removed the unexpected entry"
fi
if [[ "$(state "${HOME_B}/.local/share/systemd")" == "root:${SANDBOX_GROUP} 2750" ]]; then
    pass "the chain above it is still closed, so the account cannot add another"
else
    fail "the chain was left open beside the finding: $(state "${HOME_B}/.local/share/systemd")"
fi
if [[ "$(ai_tools_control_plane__find_unexpected_unit_search_path_entries "${HOME_B}")" == "${HOME_B}/.local/share/systemd/user" ]]; then
    pass "the entries reader names it and passes over the timer-stamp directory"
else
    fail "ai_tools_control_plane__find_unexpected_unit_search_path_entries: $(ai_tools_control_plane__find_unexpected_unit_search_path_entries "${HOME_B}")"
fi

# ── A symlink on the chain is refused and left exactly as it is ───────────────────────────────────────────────
HOME_D="${TESTDIR}/home-d"
install -d -o "${SANDBOX_USER}" -g "${SANDBOX_GROUP}" -m 0750 "${HOME_D}" "${TESTDIR}/elsewhere"
ln -s "${TESTDIR}/elsewhere" "${HOME_D}/.local"
out="$(converge "${HOME_D}")"
if grep -qx 'rc=1' <<<"${out}" && grep -q "^error ${HOME_D}/.local " <<<"${out}"; then
    pass "a symlink on the chain is an error the converge reports, with a non-zero status"
else
    fail "a symlink on the chain: ${out}"
fi
if [[ -L "${HOME_D}/.local" && "$(readlink "${HOME_D}/.local")" == "${TESTDIR}/elsewhere" ]]; then
    pass "it is left exactly as it was -- replacing a path the operator may have made is not this call's to do"
else
    fail "the converge altered the symlink on the chain"
fi
# The descent must end there (the converge's header states why); this pins it.
if [[ ! -e "${TESTDIR}/elsewhere/share" ]]; then
    pass "no directory was created through the symlink, so the converge wrote nothing outside the home"
else
    fail "the converge created $(ls -d "${TESTDIR}/elsewhere/share") through the symlink on the chain"
fi

# ── The converge refuses a caller that is not root ────────────────────────────────────────────────────────────
# A non-root run cannot chown, so one that reported success would leave an open path looking closed.
HOME_E="${TESTDIR}/home-e"
mkchain "${HOME_E}"
chmod 0777 "${TESTDIR}"
if ! command -v runuser >/dev/null 2>&1; then
    skip "the converge's root check" "runuser unavailable"
else
    rc=0
    # shellcheck disable=SC2016  # the $1/$2 are the inner bash's own arguments, not this shell's
    runuser -u "${PROJECTS_USER}" -- bash -c '
        source "$1"; ai_tools_control_plane__ensure_unit_search_path_closed "$2" x y' _ "${LIB}" "${HOME_E}" >/dev/null 2>&1 || rc=$?
    if [[ "${rc}" -eq 2 ]]; then
        pass "a non-root caller is refused with status 2 rather than reporting a converge it could not make"
    else
        fail "a non-root converge returned ${rc}, expected 2"
    fi
    if [[ "$(state "${HOME_E}/.local")" == "${SANDBOX_USER}:${SANDBOX_GROUP} 750" ]]; then
        pass "and it changed nothing"
    else
        fail "a non-root converge changed ${HOME_E}/.local to $(state "${HOME_E}/.local")"
    fi
fi

# ── The drift reader: three statuses, so a failure is never read as a closed path ─────────────────────────────
rc=0; out="$(ai_tools_control_plane__find_unit_search_path_drift "${HOME_A}" "${SANDBOX_GROUP}")" || rc=$?
if [[ "${rc}" -eq 1 && -z "${out}" ]]; then
    pass "a converged chain reads clean (status 1, no line)"
else
    fail "a converged chain read status ${rc}: ${out}"
fi
rc=0; out="$(ai_tools_control_plane__find_unit_search_path_drift "${TESTDIR}/home-e" "${SANDBOX_GROUP}")" || rc=$?
if [[ "${rc}" -eq 0 ]] && grep -q "^${TESTDIR}/home-e/.local ${SANDBOX_USER}:${SANDBOX_GROUP} 750 root:" <<<"${out}"; then
    pass "an account-owned chain is reported as drift (status 0), naming what each path is and what it must be"
else
    fail "an account-owned chain read status ${rc}: ${out}"
fi
rc=0; ai_tools_control_plane__find_unit_search_path_drift "" "" >/dev/null 2>&1 || rc=$?
if [[ "${rc}" -eq 2 ]]; then
    pass "a reading it could not make is status 2, told apart from a clean chain so no caller renders it as closed"
else
    fail "an unmakeable drift reading returned ${rc}, expected 2"
fi

# ── The report parser both installers render from ─────────────────────────────────────────────────────────────
# <before> is `owner:group mode` or the single word `absent`, so the split is asserted for each shape.
parsed_changed=(); parsed_failed=()
ai_tools_control_plane__parse_unit_search_path_report parsed_changed parsed_failed <<'REPORT'
changed /h/.local ai-tools:ai-tools 750 root:ai-tools 3770
changed /h/.local/share/systemd/timers absent ai-tools:ai-tools 750
error /h/.local/share/systemd/user is on the account's unit search path
REPORT
if [[ "${parsed_changed[0]:-}" == "/h/.local: ai-tools:ai-tools 750 -> root:ai-tools 3770" \
        && "${parsed_changed[1]:-}" == "/h/.local/share/systemd/timers: absent -> ai-tools:ai-tools 750" \
        && "${parsed_failed[0]:-}" == "/h/.local/share/systemd/user: is on the account's unit search path" \
        && ${#parsed_changed[@]} -eq 2 && ${#parsed_failed[@]} -eq 1 ]]; then
    pass "the report parser splits changed and error lines, with either shape of <before>"
else
    fail "the report parser read: changed=(${parsed_changed[*]-}) failed=(${parsed_failed[*]-})"
fi

finish
