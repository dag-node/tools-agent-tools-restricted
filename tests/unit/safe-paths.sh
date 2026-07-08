#!/usr/bin/env bash
# tests/unit/safe-paths.sh
# Unit test for the protected-paths backstop (safe-paths.lib.sh), the shared list and guard
# the launch wrapper, the claim CLI, and every elevated helper source to refuse acting on a
# system directory even when the allowlist (mis)includes it. Pins the matching contract
# hermetically: it sources the deployed library and asserts the exact-or-ancestor rule --
# a system directory (and "/") is protected, a user home root is protected exactly, while
# a real project nested under an operator home or the sandbox-clone area passes. Also checks the assert emits a refusal and returns
# non-zero on a protected target and is silent + zero on a safe one. Run as root via sudo
# (the suite contract); needs no privilege of its own.

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

finish
