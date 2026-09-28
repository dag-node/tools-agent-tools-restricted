#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/project-permissions.sh
# Unit test for the ACL specification a claim grants (project-permissions.lib.sh), which ai-tools-setfacl applies
# and the claim's verifier checks. It pins the exact specification string the helper applied before the function
# existed, so the move does not change any grant; the numeric form the verifier passes; and the refusals that keep
# an identity from adding an entry of its own (a `,` or `:` in a name).
#
# It loads the CHECKOUT's library by path and prints it first, so a change in the checkout is what runs; the installed
# copy is covered by tests/integration/perms.sh and by tests/unit/setfacl.sh. Runs unprivileged.

# shellcheck disable=SC2154  # the output variables are assigned by the library's `printf -v`
# shellcheck disable=SC2015  # `check && pass || fail`: pass returns 0, so fail runs only on a failed check
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${ROOT}/src/usr/local/lib/ai-tools/project-permissions.lib.sh"
printf 'project-permissions: %s\n' "${LIB}"

section "project-permissions: the claim's ACL specification (unit)"
if [[ ! -r "${LIB}" ]]; then
    fail "library not readable at ${LIB}"; finish; exit
fi
# shellcheck source=SCRIPTDIR/../../src/usr/local/lib/ai-tools/project-permissions.lib.sh
source "${LIB}"

spec='unset'
if ai_tools_project_permissions_build_acl_specification spec alice ai-tools \
        && [[ "${spec}" == "user:alice:rwX,group:ai-tools:rwX,other::---" ]]; then
    pass "names: the specification ai-tools-setfacl applied before the move"
else
    fail "names: got '${spec}'"
fi

spec='unset'
if ai_tools_project_permissions_build_acl_specification spec 1000 985 \
        && [[ "${spec}" == "user:1000:rwX,group:985:rwX,other::---" ]]; then
    pass "numeric ids: the form getfacl --numeric prints"
else
    fail "numeric ids: got '${spec}'"
fi

spec='unset'
if ai_tools_project_permissions_build_acl_specification spec first.last_name-2 ai-tools \
        && [[ "${spec}" == "user:first.last_name-2:rwX,group:ai-tools:rwX,other::---" ]]; then
    pass "a name with dot, underscore and hyphen is kept as given"
else
    fail "dot/underscore/hyphen name: got '${spec}'"
fi

for bad in "" "alice,user:mallory" "alice:rwx" "alice bob" "-alice" $'alice\nbob' "élise"; do
    spec='unset' rc=0
    ai_tools_project_permissions_build_acl_specification spec "${bad}" ai-tools || rc=$?
    if (( rc == 1 )) && [[ -z "${spec}" ]]; then
        pass "operator '$(printf '%q' "${bad}")' refused, variable emptied"
    else
        fail "operator '$(printf '%q' "${bad}")': rc=${rc}, spec='${spec}'"
    fi
    spec='unset' rc=0
    ai_tools_project_permissions_build_acl_specification spec alice "${bad}" || rc=$?
    if (( rc == 1 )) && [[ -z "${spec}" ]]; then
        pass "group '$(printf '%q' "${bad}")' refused, variable emptied"
    else
        fail "group '$(printf '%q' "${bad}")': rc=${rc}, spec='${spec}'"
    fi
done

rc=0
ai_tools_project_permissions_build_acl_specification 'bad-name' alice ai-tools || rc=$?
(( rc == 2 )) && pass "an invalid output-variable name returns 2" || fail "invalid variable name: rc=${rc}"

# Sourcing twice is a no-op (the include guard), so a consumer that loads it directly and transitively does not abort
# under `set -e` on the readonly guard.
# shellcheck source=/dev/null
if ( source "${LIB}" && source "${LIB}" ); then
    pass "include guard: a second source is a no-op"
else
    fail "a second source failed"
fi

finish
