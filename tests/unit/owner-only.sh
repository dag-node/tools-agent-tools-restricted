#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/owner-only.sh
# Unit test for the shared seal primitives (owner-only.lib.sh), which ai-tools-setgid,
# ai-tools-setfacl, ai-tools-lockdown and ai-tools-chown all source: the owner-only predicate
# that decides which paths the operator sealed, and the residue strip that makes a seal hold.
#
# The property under test is one-directional: a strip may only ever REMOVE the sandbox's reach.
# Every case therefore asserts the mode is not widened, on top of asserting the residue is gone
# -- a strip that silently raised the ACL mask would leave the residue "removed" and the path
# more open than before, which is the exact failure the -n flag exists to prevent.
#
# It also pins the three platform behaviours the design rests on (see "platform assumptions"),
# so a change in coreutils/acl semantics fails here rather than silently unsealing trees.
# Run as root via sudo (the suite contract); root is needed to chgrp fixtures to a third party.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly LIB="/usr/local/lib/ai-tools/owner-only.lib.sh"
section "owner-only: seal predicate + residue strip (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "owner-only primitives" "library not readable at ${LIB}"; finish; exit
fi
if ! command -v setfacl >/dev/null 2>&1 || ! command -v getfacl >/dev/null 2>&1; then
    skip "owner-only primitives" "setfacl/getfacl not available"; finish; exit
fi
# shellcheck source=/dev/null
if ! source "${LIB}"; then
    skip "owner-only primitives" "could not source ${LIB}"; finish; exit
fi
if ! declare -F ai_tools_is_owner_only >/dev/null 2>&1 \
        || ! declare -F ai_tools_strip_sandbox_residue >/dev/null 2>&1; then
    skip "owner-only primitives" "library defines no guards (pre-fix install?)"; finish; exit
fi

readonly SBX="${AI_TOOLS_SANDBOX_GROUP}"          # the lib's own idea of the sandbox group
mktestdir

# A group that is neither the sandbox group nor the operator's, standing in for a group the
# operator set deliberately. 'root' always exists; fall back to skipping that one case.
THIRD=root
if [[ "${THIRD}" == "${SBX}" || "${THIRD}" == "${PROJECTS_GROUP}" ]]; then THIRD=""; fi

mode_of() { stat -c '%a' "$1"; }
has_acl()  { getfacl -c -- "$2" 2>/dev/null | grep -q "^$1"; }

# strip <path> <ftype> <group> [operator-group] -- pin the inode and run the strip exactly as
# the helpers do (through /proc/self/fd), asserting on the way out that the mode never widened.
# Sets STRIP_RC and STRIP_MODE_BEFORE/AFTER.
strip() {
    local p="$1" ftype="$2" grp="$3" opgrp="${4:-}" fd
    STRIP_MODE_BEFORE="$(mode_of "${p}")"
    exec {fd}< "${p}"
    STRIP_RC=0
    ai_tools_strip_sandbox_residue "${fd}" "${ftype}" "${grp}" "${STRIP_MODE_BEFORE}" "${opgrp}" \
        || STRIP_RC=$?
    exec {fd}<&-
    STRIP_MODE_AFTER="$(mode_of "${p}")"
    # The one-directional property: no group or other bit may be gained.
    local before_go=$(( 8#${STRIP_MODE_BEFORE} & 077 )) after_go=$(( 8#${STRIP_MODE_AFTER} & 077 ))
    if (( (after_go & ~before_go) != 0 )); then
        fail "strip WIDENED ${p}: ${STRIP_MODE_BEFORE} -> ${STRIP_MODE_AFTER}"
        return 1
    fi
    return 0
}

# ── platform assumptions ──────────────────────────────────────────────────────────────────
# The two OS behaviours that make a strip necessary at all: sealing a path with chmod removes
# neither the setgid bit (the reason harness.sh carries `perm`) nor the default ACL. If a
# platform ever stopped behaving this way, the corresponding arm of the strip is dead code and
# should be retired -- so assert it rather than assume it. Mode is read raw here, not through
# `perm`, precisely because the setgid bit is what is under test.
mkdir -p "${TESTDIR}/plat"
chgrp "${SBX}" "${TESTDIR}/plat" 2>/dev/null || true
chmod 2770 "${TESTDIR}/plat"
setfacl    -m "group:${SBX}:rwX" "${TESTDIR}/plat"
setfacl -d -m "group:${SBX}:rwX" "${TESTDIR}/plat"
chmod 700 "${TESTDIR}/plat"

if (( ( 8#$(mode_of "${TESTDIR}/plat") & 8#2000 ) != 0 )); then
    pass "platform: a 3-digit numeric chmod does NOT clear a directory's setgid"
else
    fail "platform: numeric chmod cleared setgid -- the setgid arm of the strip is now dead code"
fi
if has_acl "default:group:${SBX}:" "${TESTDIR}/plat"; then
    pass "platform: chmod does not touch the default ACL (sealing alone leaves inheritance)"
else
    fail "platform: chmod cleared the default ACL -- the default-entry arm is now dead code"
fi

# ── the predicate ─────────────────────────────────────────────────────────────────────────
pred_ok=true
for m in 600 700 2700 400 000; do
    ai_tools_is_owner_only "${m}" || { fail "mode ${m} should read as owner-only"; pred_ok=false; }
done
for m in 640 660 750 770 604; do
    ai_tools_is_owner_only "${m}" && { fail "mode ${m} must NOT read as owner-only"; pred_ok=false; }
done
${pred_ok} && pass "owner-only predicate: no group and no other bits, setgid forms included"

# An unreadable mode must resolve to sealed -- the direction that costs access, never grants it.
if ai_tools_is_owner_only "" && ai_tools_is_owner_only "not-a-mode"; then
    pass "an empty or unparseable mode reads as sealed (fail-closed)"
else
    fail "an unparseable mode must read as sealed, or a failed stat would grant the path"
fi

# ── sealed file: masked entry removed, everything else preserved ──────────────────────────
: > "${TESTDIR}/f"
chown "${PROJECTS_USER}:${SBX}" "${TESTDIR}/f"
setfacl -m "user:${PROJECTS_USER}:rwX,group:${SBX}:rwX" "${TESTDIR}/f"
chmod 600 "${TESTDIR}/f"
strip "${TESTDIR}/f" "regular file" "${SBX}" "${PROJECTS_GROUP}"
[[ "${STRIP_RC}" -eq 0 ]] && pass "sealed file: strip reports a change" \
                          || fail "sealed file: strip reported nothing to do"
[[ "${STRIP_MODE_AFTER}" == "600" ]] && pass "sealed file: mode still 600 (mask preserved)" \
                                     || fail "sealed file: mode became ${STRIP_MODE_AFTER}"
has_acl "group:${SBX}:" "${TESTDIR}/f" \
    && fail "sealed file: the sandbox ACL entry survived" \
    || pass "sealed file: the sandbox ACL entry is gone"
has_acl "user:${PROJECTS_USER}:" "${TESTDIR}/f" \
    && pass "sealed file: the operator's own ACL entry is preserved" \
    || fail "sealed file: the operator's own ACL entry was removed"
[[ "$(stat -c '%G' "${TESTDIR}/f")" == "${PROJECTS_GROUP}" ]] \
    && pass "sealed file: group moved off the sandbox account" \
    || fail "sealed file: group is still $(stat -c '%G' "${TESTDIR}/f")"

# ── sealed directory: access + default entries, setgid, group ─────────────────────────────
mkdir "${TESTDIR}/d"
chown "${PROJECTS_USER}:${SBX}" "${TESTDIR}/d"
setfacl    -m "user:${PROJECTS_USER}:rwX,group:${SBX}:rwX" "${TESTDIR}/d"
setfacl -d -m "user:${PROJECTS_USER}:rwX,group:${SBX}:rwX" "${TESTDIR}/d"
chmod 2700 "${TESTDIR}/d"
strip "${TESTDIR}/d" directory "${SBX}" "${PROJECTS_GROUP}"
[[ "${STRIP_MODE_AFTER}" == "700" ]] \
    && pass "sealed dir: setgid cleared, 700 kept" \
    || fail "sealed dir: mode is ${STRIP_MODE_AFTER}, expected 700"
has_acl "group:${SBX}:" "${TESTDIR}/d" \
    && fail "sealed dir: the access entry survived" || pass "sealed dir: access entry removed"
has_acl "default:group:${SBX}:" "${TESTDIR}/d" \
    && fail "sealed dir: the default entry survived -- children would still inherit it" \
    || pass "sealed dir: default entry removed (children no longer inherit the grant)"

# Nothing inside a sealed, stripped directory is born reachable any more.
mkdir "${TESTDIR}/d/child"
: > "${TESTDIR}/d/child/file"
if [[ "$(stat -c '%G' "${TESTDIR}/d/child/file")" == "${SBX}" ]]; then
    fail "a file born inside a stripped dir is still group ${SBX}"
else
    pass "a file born inside a stripped dir is no longer group ${SBX}"
fi
has_acl "group:${SBX}:" "${TESTDIR}/d/child/file" \
    && fail "a file born inside a stripped dir still carries the sandbox ACL entry" \
    || pass "a file born inside a stripped dir carries no sandbox ACL entry"

# ── third-party group: setgid is kept and surfaced, never removed ─────────────────────────
if [[ -z "${THIRD}" ]]; then
    skip "third-party setgid" "no group available that is neither ${SBX} nor ${PROJECTS_GROUP}"
else
    mkdir "${TESTDIR}/d3"
    chown "${PROJECTS_USER}:${THIRD}" "${TESTDIR}/d3"
    chmod 2700 "${TESTDIR}/d3"
    strip "${TESTDIR}/d3" directory "${THIRD}" "${PROJECTS_GROUP}"
    [[ "${STRIP_MODE_AFTER}" == "2700" ]] \
        && pass "third-party setgid: left exactly as found" \
        || fail "third-party setgid: mode changed to ${STRIP_MODE_AFTER}"
    [[ "${AI_TOOLS_RESIDUE_SURFACE}" -eq 1 ]] \
        && pass "third-party setgid: surfaced for the caller to report" \
        || fail "third-party setgid: not surfaced, so the operator is never told"
    [[ "$(stat -c '%G' "${TESTDIR}/d3")" == "${THIRD}" ]] \
        && pass "third-party group: ownership untouched" \
        || fail "third-party group: regrouped to $(stat -c '%G' "${TESTDIR}/d3")"
fi

# ── the operator's own group: setgid is ours to clear ─────────────────────────────────────
mkdir "${TESTDIR}/d4"
chown "${PROJECTS_USER}:${PROJECTS_GROUP}" "${TESTDIR}/d4"
chmod 2700 "${TESTDIR}/d4"
strip "${TESTDIR}/d4" directory "${PROJECTS_GROUP}" "${PROJECTS_GROUP}"
[[ "${STRIP_MODE_AFTER}" == "700" ]] \
    && pass "operator-group setgid: cleared" \
    || fail "operator-group setgid: mode is ${STRIP_MODE_AFTER}, expected 700"
[[ "${AI_TOOLS_RESIDUE_SURFACE}" -eq 0 ]] \
    && pass "operator-group setgid: not surfaced (nothing for the operator to decide)" \
    || fail "operator-group setgid: surfaced unnecessarily"

# ── a file's setgid is never touched ──────────────────────────────────────────────────────
: > "${TESTDIR}/f2"
chown "${PROJECTS_USER}:${SBX}" "${TESTDIR}/f2"
chmod 2600 "${TESTDIR}/f2"
strip "${TESTDIR}/f2" "regular file" "${SBX}" "${PROJECTS_GROUP}"
[[ "$(stat -c '%a' "${TESTDIR}/f2")" == "2600" ]] \
    && pass "a file's setgid bit is left untouched (an sgid binary is not silently altered)" \
    || fail "a file's setgid bit was cleared: $(stat -c '%a' "${TESTDIR}/f2")"

# ── idempotence: a clean sealed path has nothing to strip ─────────────────────────────────
strip "${TESTDIR}/d" directory "${PROJECTS_GROUP}" "${PROJECTS_GROUP}"
[[ "${STRIP_RC}" -eq 1 ]] \
    && pass "a already-stripped path reports nothing to do (idempotent, silent on re-runs)" \
    || fail "a second strip claimed another change"

# ── a tree that never met a claim is left byte-for-byte alone ─────────────────────────────
mkdir "${TESTDIR}/virgin"
chown "${PROJECTS_USER}:${PROJECTS_GROUP}" "${TESTDIR}/virgin"
chmod 700 "${TESTDIR}/virgin"
before="$(stat -c '%a %U:%G' "${TESTDIR}/virgin")"
strip "${TESTDIR}/virgin" directory "${PROJECTS_GROUP}" "${PROJECTS_GROUP}"
[[ "$(stat -c '%a %U:%G' "${TESTDIR}/virgin")" == "${before}" && "${STRIP_RC}" -eq 1 ]] \
    && pass "a path with no sandbox residue is left exactly as found" \
    || fail "a residue-free path was modified: ${before} -> $(stat -c '%a %U:%G' "${TESTDIR}/virgin")"

finish
