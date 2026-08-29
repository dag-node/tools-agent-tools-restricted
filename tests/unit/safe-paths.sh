#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/safe-paths.sh
# Unit test for the protected-paths backstop (safe-paths.lib.sh), the shared list and guard
# the launch wrapper, the claim CLI, and every elevated helper source to refuse acting on a
# system directory even when the allowlist (mis)includes it. Pins the matching contract
# hermetically: it sources the deployed library and asserts the exact-or-ancestor rule --
# a system directory (and "/") is protected, a user home root is protected exactly, while
# a real project nested under an operator home or the sandbox-clone area passes. Also checks the assert emits a refusal and returns
# non-zero on a protected target and is silent + zero on a safe one, and pins the second,
# narrower predicate beside it -- ai_tools_traverse_grant_allowed, which admits the acting
# operator's own home root for a traverse-only ACL and nothing else. Run as root via sudo
# (the suite contract); the only case needing privilege (a foreign-owned fixture) skips without
# it, so the file also runs directly as an operator.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

readonly LIB="/usr/local/lib/ai-tools/safe-paths.lib.sh"
section "protected-paths backstop: shared list + guard (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "protected-paths backstop" "library not readable at ${LIB}"; finish; exit
fi
# shellcheck source=/dev/null
if ! source "${LIB}"; then
    skip "protected-paths backstop" "could not source ${LIB}"; finish; exit
fi

# (1) System directories -- and the filesystem root -- are protected (exact or ancestor).
#     A trailing slash and bare root normalise to the same verdict.
protected_ok=true
for p in / /etc /var /var/tmp /usr /usr/bin /usr/local /home /root /boot /opt /opt/ai-tools \
         /srv /dev /proc /sys /run /tmp /mnt /media /etc/ /usr/bin/; do
    if ! ai_tools_protected_path_match "${p}" >/dev/null; then
        fail "should be protected: ${p}"; protected_ok=false
    fi
done
${protected_ok} && pass "system directories and / are protected"

# (2) Real project trees nested under a protected parent are NOT protected -- descendants
#     pass, so operator homes and sandbox clones keep working.
safe_ok=true
for p in /home/alice/project /home/bob/code/app /var/opt/ai-tools/sandbox-projects/myrepo \
         /opt/myapp/work /usr/local/share-not-a-real-project/x /srv/www/site; do
    if ai_tools_protected_path_match "${p}" >/dev/null; then
        fail "descendant should be allowed: ${p}"; safe_ok=false
    fi
done
${safe_ok} && pass "project trees nested under a protected parent are allowed"

# (2b) A user home ROOT (direct child of /home) is protected exactly -- claiming a whole
#      home would hand the agent every dotfile and key in it -- while deeper paths pass
#      (asserted in (2) above). A trailing slash normalises to the same verdict.
home_ok=true
for p in /home/alice /home/bob /home/svc-ci/; do
    if ! ai_tools_protected_path_match "${p}" >/dev/null; then
        fail "user home root should be protected: ${p}"; home_ok=false
    fi
done
${home_ok} && pass "user home roots are protected"

# (3) An ancestor that CONTAINS a protected entry is itself protected (e.g. /opt contains
#     /opt/ai-tools). The match prints the offending entry.
if ai_tools_protected_path_match /opt >/dev/null; then
    pass "an ancestor containing a protected entry is protected"
else
    fail "/opt (ancestor of /opt/ai-tools) should be protected"
fi

# (4) ai_tools_assert_safe_target refuses a protected target: non-zero exit + a refusal
#     naming the path (rendered plain here since the captured fd is not a tty).
rc=0
err="$(ai_tools_assert_safe_target /etc "claim" 2>&1)" || rc=$?
if (( rc != 0 )) && [[ "${err}" == *"/etc"* ]]; then
    pass "assert refuses a protected target (non-zero exit, refusal emitted)"
else
    fail "assert should refuse /etc (rc=${rc}, msg='${err}')"
fi

# (5) ai_tools_assert_safe_target passes a safe target silently with a zero exit.
rc=0
err="$(ai_tools_assert_safe_target /home/tester/myproject "claim" 2>&1)" || rc=$?
if (( rc == 0 )) && [[ -z "${err}" ]]; then
    pass "assert passes a safe target silently (zero exit, no output)"
else
    fail "assert should pass /home/tester/myproject silently (rc=${rc}, msg='${err}')"
fi

# ── The traverse-grant predicate ─────────────────────────────────────────────
# ai_tools_traverse_grant_allowed vets a strictly weaker operation than the target backstop
# above: one `u:ai-tools:--x` entry on ONE directory, which conveys search permission and no
# read. It therefore admits the acting operator's OWN home root, which the backstop refuses as a
# target -- so these assertions are about the difference between the two, and (2b) above still
# stands unchanged. What keeps the carve-out from becoming a hole is the owner argument: it is
# checked before the home-root exemption, so the exemption reaches exactly one account's home.
section "traverse-grant predicate (unit)"

# This file stays runnable unprivileged (it drives a pure library), so the fixture ownership is
# only asserted where it can be arranged: run as root the testdir is root-owned and has to be
# handed over, run as the operator it is already theirs.
mktestdir
owned="${TESTDIR}/owned"; mkdir -p "${owned}"
if [[ "$(id -u)" -eq 0 ]]; then chown "${PROJECTS_USER}:${PROJECTS_GROUP}" "${owned}"; fi

# (6) An ordinary directory the owner holds is grantable -- the case that has always worked.
if ai_tools_traverse_grant_allowed "${owned}" "${PROJECTS_USER}"; then
    pass "an ordinary directory the operator owns is grantable"
else
    fail "an operator-owned directory was refused: ${owned}"
fi

# (7) The owner guard: a directory the operator does not hold is refused.
if [[ "$(id -u)" -eq 0 ]]; then
    foreignowned="${TESTDIR}/root-owned"; mkdir -p "${foreignowned}"   # stays root-owned
    if ai_tools_traverse_grant_allowed "${foreignowned}" "${PROJECTS_USER}"; then
        fail "a directory owned by root was reported grantable: ${foreignowned}"
    else
        pass "a directory the operator does not own is refused"
    fi
else
    skip "owner guard" "cannot create a foreign-owned fixture unprivileged"
fi

# (8) Every system directory stays refused, home roots included -- /home itself is a protected
#     entry and is nobody's home, so no exemption can reach it.
sys_ok=true
for p in / /etc /home /usr /var /opt /opt/ai-tools; do
    if ai_tools_traverse_grant_allowed "${p}" root; then
        fail "system directory reported grantable: ${p}"; sys_ok=false
    fi
done
${sys_ok} && pass "system directories (and /home) are never grantable"

# (9) The carve-out, in both directions: the operator's OWN home root is grantable, and the same
#     path asked for a different account is not. The second is the "any other user's home root"
#     case -- a home root is grantable only to the account whose home it is.
if [[ "${PROJECTS_HOME}" =~ ^/home/[^/]+$ && -d "${PROJECTS_HOME}" ]]; then
    if ai_tools_traverse_grant_allowed "${PROJECTS_HOME}" "${PROJECTS_USER}"; then
        pass "the operator's own home root is grantable (traverse only)"
    else
        fail "the operator's own home root was refused: ${PROJECTS_HOME}"
    fi
    if id nobody >/dev/null 2>&1; then
        if ai_tools_traverse_grant_allowed "${PROJECTS_HOME}" nobody; then
            fail "another account's home root was reported grantable: ${PROJECTS_HOME}"
        else
            pass "a home root is not grantable to an account whose home it is not"
        fi
    else
        skip "foreign home root" "user 'nobody' not present"
    fi
else
    skip "own home root" "${PROJECTS_HOME} is not a /home/<user> home root"
fi

# (10) Fail closed on inputs that name nothing: a missing path, a file rather than a directory,
#      and an empty owner all refuse rather than default to granting.
closed_ok=true
: > "${TESTDIR}/afile"
for args in "${TESTDIR}/does-not-exist ${PROJECTS_USER}" "${TESTDIR}/afile ${PROJECTS_USER}"; do
    # shellcheck disable=SC2086  # deliberate word-splitting of the two-argument case
    if ai_tools_traverse_grant_allowed ${args}; then
        fail "grantable for '${args}'"; closed_ok=false
    fi
done
if ai_tools_traverse_grant_allowed "${owned}" ""; then
    fail "grantable with no owner named"; closed_ok=false
fi
${closed_ok} && pass "a missing path, a non-directory, and an unnamed owner all refuse"

finish
