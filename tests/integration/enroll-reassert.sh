#!/usr/bin/env bash
# tests/integration/enroll-reassert.sh
# Integration: the deployed `ai-tools-enroll --reassert` -- the command an RPM %posttrans runs on
# every upgrade to restore control-plane ownership the package unpack reset to root:ai-tools. It
# reads the enrolled operator from operator.conf and re-owns the control plane, or is a no-op when
# the host is unenrolled. This pins the two behaviours of the GATE (the manifest re-own itself is
# unit-tested): an unenrolled host must exit 0 and change nothing (a failing %posttrans would abort
# `dnf install`), and an enrolled host must re-own the tree to the operator. Driven through the
# operator.conf + control-plane-home root-only test hooks against /tmp fixtures. Run as root.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly ENROLL="/usr/local/sbin/ai-tools/ai-tools-enroll"
section "ai-tools-enroll --reassert (control-plane re-own gate)"

if [[ ! -x "${ENROLL}" ]]; then
    skip "enroll --reassert" "not installed at ${ENROLL}"; finish; exit
fi

mktestdir

# (1) Unenrolled host: operator.conf names no operator, so --reassert exits 0, says so, and leaves
# the control plane untouched. The %posttrans relies on this never failing on a fresh box.
unenrolled_conf="${TESTDIR}/unenrolled.conf"
printf '%s\n' '# no operator set' '# PROJECTS_USER=' > "${unenrolled_conf}"
cp_noop="${TESTDIR}/cp-noop"
mkdir -p "${cp_noop}"; chmod 0700 "${cp_noop}"; chown root:root "${cp_noop}"

out="$(AI_TOOLS_OPERATOR_CONF="${unenrolled_conf}" AI_TOOLS_CONTROL_PLANE_HOME="${cp_noop}" \
        "${ENROLL}" --reassert 2>&1)" && rc=0 || rc=$?
if [[ ${rc} -eq 0 ]] && grep -qi 'nothing to re-assert' <<<"${out}"; then
    pass "unenrolled host: --reassert exits 0 and reports nothing to do"
else
    fail "unenrolled --reassert: rc=${rc}, out: ${out}"
fi
# The control plane must be untouched (still the root:root it started as).
check_file "${cp_noop}" root root 700

# (2) Enrolled host: operator.conf names the projects user, so --reassert re-owns the placeholder
# tree to PROJECTS_USER:SANDBOX_GROUP with the boundary modes. mk_operator writes the conf naming
# the real SUDO_USER (a valid chown target) and exports AI_TOOLS_OPERATOR_CONF.
mk_operator
cp_live="${TESTDIR}/cp-live"
mkdir -p "${cp_live}"/{bin,.claude}
chown -R root:root "${cp_live}"

out="$(AI_TOOLS_CONTROL_PLANE_HOME="${cp_live}" "${ENROLL}" --reassert 2>&1)" && rc=0 || rc=$?
if [[ ${rc} -eq 0 ]]; then
    pass "enrolled host: --reassert exits 0"
else
    fail "enrolled --reassert: rc=${rc}, out: ${out}"
fi
# The placeholder tree is now the operator's, with the locked / setgid boundary modes.
check_file "${cp_live}"         "${PROJECTS_USER}" "${SANDBOX_GROUP}" 2750
check_file "${cp_live}/bin"     "${PROJECTS_USER}" "${SANDBOX_GROUP}" 550
check_file "${cp_live}/.claude" "${PROJECTS_USER}" "${SANDBOX_GROUP}" 3770

finish
