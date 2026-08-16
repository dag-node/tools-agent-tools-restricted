#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/setgid.sh
# Hermetic unit tests for the deployed ai-tools-setgid helper: project setgid + group
# normalization, the secret-dir skip, and the owner guard. Installed helper against a /tmp
# testdir with a dummy allowlist; nothing outside the testdir is touched.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly HELPER="/usr/local/libexec/ai-tools/ai-tools-setgid"
section "ai-tools-setgid: project setgid normalization (unit)"

if [[ ! -x "${HELPER}" ]]; then
    skip "ai-tools-setgid" "not installed at ${HELPER}"; finish; exit
fi

mktestdir
proj="${TESTDIR}/proj"
mkdir -p "${proj}/sub" "${proj}/.env/inside"
mk_allowlist "${proj}"
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${proj}"   # legitimate owner (else guard skips)
chmod -R 0770 "${proj}"                                    # start non-setgid, projects group
foreign=false
if id nobody >/dev/null 2>&1; then
    mkdir -p "${proj}/foreign"; chown nobody:nobody "${proj}/foreign"; foreign=true
fi

setsid "${HELPER}" "${proj}" < /dev/null > /dev/null 2>&1 || true

# (A) a dir under the allowed project is regrouped to the sandbox group + setgid.
sg_group="$(stat -c '%G' "${proj}/sub")"; sg_mode="$(stat -c '%a' "${proj}/sub")"
if [[ "${sg_group}" == "${SANDBOX_GROUP}" ]] && (( (8#${sg_mode} & 8#2000) != 0 )); then
    pass "a dir under an allowed project gets group ${SANDBOX_GROUP} + setgid"
else
    fail "sub is ${sg_group} ${sg_mode} (want group ${SANDBOX_GROUP}, setgid set)"
fi

# (A2) a secret-named dir and its subtree are never flipped to the sandbox group.
env_g="$(stat -c '%G' "${proj}/.env")"; envsub_g="$(stat -c '%G' "${proj}/.env/inside")"
if [[ "${env_g}" != "${SANDBOX_GROUP}" && "${envsub_g}" != "${SANDBOX_GROUP}" ]]; then
    pass "a secret-named dir (.env) and its subtree are left untouched"
else
    fail ".env exposed (.env=${env_g} .env/inside=${envsub_g})"
fi

# (A3) owner guard: a third-party-owned dir is not re-owned.
if ${foreign}; then
    if [[ "$(stat -c '%U:%G' "${proj}/foreign")" == "nobody:nobody" ]]; then
        pass "a third-party-owned dir is left untouched (owner guard)"
    else
        fail "foreign-owned dir re-owned to $(stat -c '%U:%G' "${proj}/foreign")"
    fi
else
    skip "owner guard" "user 'nobody' not present"
fi

# (B) a path NOT under any allowed project is left untouched (no setgid).
out="${TESTDIR}/outside"; mkdir -p "${out}/sub"; chmod -R 0770 "${out}"
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${out}"
setsid "${HELPER}" "${out}" < /dev/null > /dev/null 2>&1 || true
if (( (8#$(stat -c '%a' "${out}/sub") & 8#2000) == 0 )); then
    pass "a non-allowlisted path is left untouched"
else
    fail "non-allowlisted ${out}/sub gained setgid"
fi

# ── Owner-only (sealed) paths ────────────────────────────────────────────────
# A second project, so the cases above keep their fixture. These are what make `chmod 700` a
# boundary rather than a mask: the pass must not pull a sealed dir into the agent's group, and
# must strip the residue such a dir carries from having been created inside a claimed tree.
p2="${TESTDIR}/proj2"
mkdir -p "${p2}/plain" "${p2}/sealed/inside" "${p2}/inherited"
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${p2}"
chmod 0770 "${p2}" "${p2}/plain" "${p2}/sealed/inside"
chmod 0700 "${p2}/sealed"
# The inherited-then-sealed case: born group SANDBOX_GROUP + setgid + the project's ACL inside a
# claimed tree, then sealed by the operator. That residue is what a later chmod re-activates.
chgrp "${SANDBOX_GROUP}" "${p2}/inherited"
chmod 2700 "${p2}/inherited"
have_acl=false
if command -v setfacl >/dev/null 2>&1 \
        && setfacl -m "group:${SANDBOX_GROUP}:rwX" "${p2}/inherited" 2>/dev/null; then
    setfacl -d -m "group:${SANDBOX_GROUP}:rwX" "${p2}/inherited" 2>/dev/null || true
    have_acl=true
fi
mk_allowlist "${p2}"
setsid "${HELPER}" "${p2}" < /dev/null > /dev/null 2>&1 || true

# (C) a sealed dir is not normalized into the agent's group, and keeps its mode.
sg="$(stat -c '%G' "${p2}/sealed")"; sm="$(stat -c '%a' "${p2}/sealed")"
if [[ "${sg}" != "${SANDBOX_GROUP}" ]] && (( (8#${sm} & 8#2000) == 0 )); then
    pass "an owner-only dir is not regrouped to ${SANDBOX_GROUP} and gains no setgid"
else
    fail "sealed dir became group ${sg} mode ${sm}"
fi
if [[ "$(perm "${p2}/sealed")" == "700" ]]; then
    pass "an owner-only dir keeps its mode"
else
    fail "sealed dir mode is now $(perm "${p2}/sealed")"
fi

# (C2) a sealed dir takes its subtree with it -- nothing under it is normalized either.
if [[ "$(stat -c '%G' "${p2}/sealed/inside")" != "${SANDBOX_GROUP}" ]]; then
    pass "the subtree of a sealed dir is skipped with it"
else
    fail "a dir under a sealed dir was pulled into ${SANDBOX_GROUP}"
fi

# (C3) the seal is not a blanket opt-out: an ordinary sibling is still normalized.
if [[ "$(stat -c '%G' "${p2}/plain")" == "${SANDBOX_GROUP}" ]]; then
    pass "an ordinary dir alongside a sealed one is still normalized"
else
    fail "an ordinary dir was not normalized ($(stat -c '%G' "${p2}/plain"))"
fi

# (D) the inherited-then-sealed dir has its residue stripped, without widening the mode.
im="$(stat -c '%a' "${p2}/inherited")"
if (( (8#${im} & 8#2000) == 0 )); then
    pass "a sealed dir's inherited setgid bit is cleared"
else
    fail "an inherited setgid bit survived on a sealed dir (${im})"
fi
if [[ "$(stat -c '%G' "${p2}/inherited")" != "${SANDBOX_GROUP}" ]]; then
    pass "a sealed dir's group owner is moved off ${SANDBOX_GROUP}"
else
    fail "a sealed dir is still group ${SANDBOX_GROUP}"
fi
if [[ "$(perm "${p2}/inherited")" == "700" ]]; then
    pass "stripping a sealed dir's residue does not widen its mode"
else
    fail "a sealed dir's mode widened to $(perm "${p2}/inherited")"
fi
if ${have_acl}; then
    if getfacl -c -- "${p2}/inherited" 2>/dev/null \
            | grep -q "^\(default:\)\?group:${SANDBOX_GROUP}:"; then
        fail "the inherited sandbox ACL entry survived on a sealed dir"
    else
        pass "the inherited sandbox ACL entries are removed from a sealed dir"
    fi
else
    skip "sealed dir ACL strip" "setfacl unavailable"
fi

finish
