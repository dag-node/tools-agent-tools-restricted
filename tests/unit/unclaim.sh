#!/usr/bin/env bash
# tests/unit/unclaim.sh
# Hermetic unit tests for the deployed ai-tools-unclaim helper: the filesystem hand-back it
# performs at project unclaim -- clear the agent ACL + default ACL, regroup to a target
# group, drop group write, and clear the setgid bit on directories -- plus its owner guard,
# secret skip, and target-group validation. Installed helper against a /tmp testdir.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

readonly HELPER="/usr/local/sbin/ai-tools/ai-tools-unclaim"
section "ai-tools-unclaim: filesystem hand-back + revocation (unit)"

if [[ ! -x "${HELPER}" ]]; then
    skip "ai-tools-unclaim" "not installed at ${HELPER}"; finish; exit
elif ! command -v setfacl >/dev/null 2>&1 || ! command -v getfacl >/dev/null 2>&1; then
    skip "ai-tools-unclaim" "setfacl/getfacl not available"; finish; exit
fi

mktestdir
proj="${TESTDIR}/proj"
mkdir -p "${proj}/d" "${proj}/.env"
mk_allowlist "${proj}"

if ! setfacl -m g:"${SANDBOX_GROUP}":rwX "${proj}" 2>/dev/null; then
    skip "ai-tools-unclaim" "filesystem does not support ACLs"; finish; exit
fi
setfacl -b "${proj}" 2>/dev/null || true

# Simulate the claimed state: setgid dir, group-rw file, 400 file, a secret, and the
# group-permission ACL claim applies.
: > "${proj}/f";  chmod 0660 "${proj}/f"
chmod 2770 "${proj}/d"                         # setgid dir, as claim leaves it
: > "${proj}/ro"; chmod 0400 "${proj}/ro"
: > "${proj}/.env/secret"
chown -R "${PROJECTS_USER}:${PROJECTS_GROUP}" "${proj}"
setfacl -R -m "g:${SANDBOX_GROUP}:rwX,o::-" "${proj}"
find "${proj}" -type d -exec setfacl -d -m "g:${SANDBOX_GROUP}:rwX,o::-" {} +
foreign=false
if id nobody >/dev/null 2>&1; then
    : > "${proj}/foreign"; setfacl -m "g:${SANDBOX_GROUP}:rwX" "${proj}/foreign"
    chown nobody:nobody "${proj}/foreign"; foreign=true
fi

setsid "${HELPER}" "${proj}" "${PROJECTS_GROUP}" < /dev/null > /dev/null 2>&1 || true

agentacl() { getfacl -p "$1" 2>/dev/null | grep -qE "^group:${SANDBOX_GROUP}:"; }

# (A) 660 file -> 640, regrouped to the target, agent ACL cleared.
if [[ "$(perm "${proj}/f")" == 640 && "$(stat -c '%G' "${proj}/f")" == "${PROJECTS_GROUP}" ]] \
        && ! agentacl "${proj}/f"; then
    pass "660 file -> 640, regrouped to target, agent ACL cleared"
else
    fail "f is $(stat -c '%a' "${proj}/f") $(stat -c '%G' "${proj}/f") (want 640 ${PROJECTS_GROUP}, no agent ACL)"
fi

# (B) 770 setgid dir -> clean 750 (setgid cleared), regrouped, ACL + default ACL gone.
d_mode="$(stat -c '%a' "${proj}/d")"
if [[ "${d_mode}" == 750 && "$(stat -c '%G' "${proj}/d")" == "${PROJECTS_GROUP}" ]] \
        && ! getfacl -p "${proj}/d" 2>/dev/null | grep -qE "^default:|^group:${SANDBOX_GROUP}:"; then
    pass "770 setgid dir -> clean 750 (setgid cleared), regrouped, ACL + default cleared"
else
    fail "d is ${d_mode} $(stat -c '%G' "${proj}/d") (want 750 ${PROJECTS_GROUP}, no setgid/ACL/default)"
fi

# (C) a 400 file stays 400.
if [[ "$(perm "${proj}/ro")" == 400 ]]; then pass "a 400 file stays 400 (group already has no write)"
else fail "ro is $(stat -c '%a' "${proj}/ro") (want 400)"; fi

# (D) a secret-named path is left untouched (keeps its agent ACL / not regrouped).
if agentacl "${proj}/.env/secret"; then pass "a secret-named path is left untouched"
else fail "a secret path was regrouped/cleared"; fi

# (E) owner guard: a third-party-owned file is left untouched.
if ${foreign}; then
    if [[ "$(stat -c '%U' "${proj}/foreign")" == nobody ]] && agentacl "${proj}/foreign"; then
        pass "a third-party-owned file is left untouched (owner guard)"
    else
        fail "foreign-owned file was modified"
    fi
else
    skip "owner guard" "user 'nobody' not present"
fi

# (F) an unknown target group is rejected (helper exits non-zero, nothing changed).
if ! "${HELPER}" "${proj}" "no_such_group_$$" < /dev/null > /dev/null 2>&1; then
    pass "an unknown target group is rejected"
else
    fail "accepted a nonexistent target group"
fi

finish
