#!/usr/bin/env bash
# tests/unit/setgid.sh
# Hermetic unit tests for the deployed ai-tools-setgid helper: project setgid + group
# normalization, the secret-dir skip, and the owner guard. Installed helper against a /tmp
# testdir with a dummy allowlist; nothing outside the testdir is touched.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly HELPER="/usr/local/sbin/ai-tools/ai-tools-setgid"
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

finish
