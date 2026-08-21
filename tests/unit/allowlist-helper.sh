#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/allowlist-helper.sh
# Hermetic unit tests for the deployed ai-tools-allowlist helper: the privileged seam behind
# `ai-tools ... --for <operator>`, which reads and edits ANOTHER enrolled operator's
# allowed-projects. Because that file is a LAUNCH GATE, every gate on the way to it is asserted to
# fire and to leave the registry byte-identical: an absent sudo context, an unenrolled caller, an
# unenrolled or non-operator target, and a protected system directory as the path.
#
# This is the runtime half of the pair -- that each refusal actually fires. The boundary half, that
# the sandbox account cannot reach the helper at all, is in tests/boundary/access.sh.
#
# The add/remove/print mechanics are exercised with the target set to the PRIMARY operator, since
# that is the identity the AI_TOOLS_ALLOWLIST fixture hook models (operator.lib.sh redirects only
# the primary's path); the cross-operator routing itself is covered in tests/integration/cli.sh.
# Run against a /tmp testdir as root.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly HELPER="/usr/local/libexec/ai-tools/ai-tools-allowlist"
section "ai-tools-allowlist: cross-operator registry helper (unit)"

if [[ ! -x "${HELPER}" ]]; then
    skip "ai-tools-allowlist" "not installed at ${HELPER}"; finish; exit
fi

mktestdir
proj="${TESTDIR}/proj"
mkdir -p "${proj}"
chmod 0755 "${TESTDIR}" "${proj}"

mk_allowlist "# fixture allowlist"
mk_operator
readonly ALLOWFILE="${TESTDIR}/allowed-projects"
OPERATOR_UID="$(id -u "${PROJECTS_USER}")"
readonly OPERATOR_UID

# run_helper <sudo-uid> <args...>: invoke the helper as root with an explicit SUDO_UID, the
# kernel-supplied caller identity it authorizes against. An empty <sudo-uid> unsets it, modelling a
# bare root call with no sudo context.
run_helper() {
    local uid="$1"; shift
    if [[ -z "${uid}" ]]; then
        env -u SUDO_UID \
            AI_TOOLS_ALLOWLIST="${ALLOWFILE}" \
            AI_TOOLS_OPERATOR_CONF="${TESTDIR}/operator.conf" \
            "${HELPER}" "$@" 2>&1
    else
        env SUDO_UID="${uid}" \
            AI_TOOLS_ALLOWLIST="${ALLOWFILE}" \
            AI_TOOLS_OPERATOR_CONF="${TESTDIR}/operator.conf" \
            "${HELPER}" "$@" 2>&1
    fi
}

# refuses <label> <expect-substring> <sudo-uid> <args...>: the helper must exit non-zero, say why,
# and leave the allowlist unchanged. The unchanged-file assertion is the point: a gate that refuses
# after a partial write would still have widened a launch gate.
refuses() {
    local label="$1" want="$2" uid="$3"; shift 3
    local before after out rc
    before="$(md5sum < "${ALLOWFILE}")"
    out="$(run_helper "${uid}" "$@")" && rc=0 || rc=$?
    after="$(md5sum < "${ALLOWFILE}")"
    if (( rc == 0 )); then
        fail "${label}: helper succeeded where it must refuse: ${out}"
    elif ! grep -qi -- "${want}" <<<"${out}"; then
        fail "${label}: refused (rc=${rc}) but did not say why -- wanted '${want}', got: ${out}"
    elif [[ "${before}" != "${after}" ]]; then
        fail "${label}: refused but the allowlist changed"
    else
        pass "${label}"
    fi
}

# (1) No sudo context. A direct root call carries no operator identity, so there is nobody to
# authorize the edit; defaulting to some operator is exactly the fail-open this refuses.
refuses "refuses a bare root call (no SUDO_UID)" "no SUDO_UID" \
    "" --operator "${PROJECTS_USER}" --add "${proj}"

# (2) The caller must be enrolled. uid 0 resolves to root, which is never in OPERATORS.
refuses "refuses a caller that is not a configured operator" "not a configured ai-tools operator" \
    0 --operator "${PROJECTS_USER}" --add "${proj}"

# (3) The target must be enrolled: ai-tools-setfacl and the handback helpers resolve a path's owner
# over OPERATORS, so an entry for an unenrolled name is a launch gate nothing can act on.
refuses "refuses an unenrolled target operator" "not a configured ai-tools operator" \
    "${OPERATOR_UID}" --operator "definitely-not-an-operator" --add "${proj}"

# (4) The sandbox account is not an operator and must never own projects -- it would be the agent
# holding its own launch gate.
refuses "refuses the sandbox account as the target" "not an operator" \
    "${OPERATOR_UID}" --operator "${SANDBOX_USER}" --add "${proj}"

# (5) Protected-paths backstop: a system directory is refused as a target even for a fully
# authorized caller and target.
refuses "refuses a protected system directory as the path" "refus" \
    "${OPERATOR_UID}" --operator "${PROJECTS_USER}" --add /etc

# (6) A path that does not exist cannot be canonicalized, so it never reaches the registry.
refuses "refuses a non-existent path" "not an existing path" \
    "${OPERATOR_UID}" --operator "${PROJECTS_USER}" --add "${TESTDIR}/no-such-dir"

# (7) A file is not a project directory.
: > "${TESTDIR}/afile"
refuses "refuses a non-directory path" "not a directory" \
    "${OPERATOR_UID}" --operator "${PROJECTS_USER}" --add "${TESTDIR}/afile"

# (8) Usage: an action is required, and only one may be given.
refuses "refuses with no action" "is required" \
    "${OPERATOR_UID}" --operator "${PROJECTS_USER}"
refuses "refuses two actions at once" "only one action" \
    "${OPERATOR_UID}" --operator "${PROJECTS_USER}" --print --add "${proj}"
refuses "refuses a missing --operator" "required" \
    "${OPERATOR_UID}" --print

# ── Mechanics: add / print / remove against the primary operator's fixture registry ──────────
out="$(run_helper "${OPERATOR_UID}" --operator "${PROJECTS_USER}" --add "${proj}")" && rc=0 || rc=$?
if (( rc == 0 )) && grep -q "^${proj}$" "${ALLOWFILE}"; then
    pass "--add writes the project into the target's allowlist"
else
    fail "--add did not register ${proj} (rc=${rc}): ${out}"
fi

# The allowlist is the operator's own data, so the helper must not take it over as root.
owner="$(stat -c '%U' "${ALLOWFILE}")"
mode="$(stat -c '%a' "${ALLOWFILE}")"
if [[ "${owner}" == "${PROJECTS_USER}" && "${mode}" == "600" ]]; then
    pass "--add preserves the allowlist's owner and mode (${owner}, ${mode})"
else
    fail "--add left the allowlist as ${owner} ${mode}, expected ${PROJECTS_USER} 600"
fi

before="$(md5sum < "${ALLOWFILE}")"
out="$(run_helper "${OPERATOR_UID}" --operator "${PROJECTS_USER}" --add "${proj}")" && rc=0 || rc=$?
if (( rc == 0 )) && [[ "$(md5sum < "${ALLOWFILE}")" == "${before}" ]]; then
    pass "--add is idempotent (a listed project is not duplicated)"
else
    fail "--add duplicated an existing entry (rc=${rc}): ${out}"
fi

out="$(run_helper "${OPERATOR_UID}" --operator "${PROJECTS_USER}" --print)" && rc=0 || rc=$?
if (( rc == 0 )) && grep -q "^${proj}$" <<<"${out}"; then
    pass "--print reads back the target's allowlist"
else
    fail "--print did not report ${proj} (rc=${rc}): ${out}"
fi

out="$(run_helper "${OPERATOR_UID}" --operator "${PROJECTS_USER}" --remove "${proj}")" && rc=0 || rc=$?
if (( rc == 0 )) && ! grep -q "^${proj}$" "${ALLOWFILE}"; then
    pass "--remove drops the entry from the target's allowlist"
else
    fail "--remove left ${proj} listed (rc=${rc}): ${out}"
fi

out="$(run_helper "${OPERATOR_UID}" --operator "${PROJECTS_USER}" --remove "${proj}")" && rc=0 || rc=$?
if (( rc == 0 )); then
    pass "--remove on an unlisted project is a clean no-op"
else
    fail "--remove failed on an already-removed project (rc=${rc}): ${out}"
fi

finish
