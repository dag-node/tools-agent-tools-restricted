#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/install-guards.sh
# Hermetic check of install.sh's entry guards -- the ones that decide WHICH account the install
# enrols as the operator, before it writes anything.
#
# The one that matters is root. `ai-tools-admin operator add` refuses it outright, and install.sh
# reaches the same end state by a different route (the @PROJECTS_USER@ substitution plus
# `usermod -aG ai-ops`), so the two have to refuse alike or the dev path produces a host nobody
# can provision: the CLI refuses root every mutating verb, --for refuses root as a target, and the
# ownership handback would restore agent-written files to root:ai-tools.
#
# Root is reachable without meaning to -- sudo invoked from a root shell sets SUDO_USER=root, so
# `sudo -i` followed by `sudo ./install.sh` passes the SUDO_USER check with a resolvable home.
#
# Nothing is installed: each case runs install.sh with an unrecognized ACTION, and the guards sit
# above the dispatch, so a run that reaches the dispatch at all prints usage and exits without
# touching the system. Needs root, since the EUID guard precedes the ones under test.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly INSTALLER="${ROOT}/install.sh"
section "install.sh entry guards (unit)"

if [[ ! -r "${INSTALLER}" ]]; then
    skip "install.sh entry guards" "not a source checkout (no ${INSTALLER})"
    finish; exit
fi

# run_installer <SUDO_USER value> -- run the installer with an unrecognized action, printing its
# combined output. An empty value runs with SUDO_USER unset.
run_installer() {
    local sudo_user="$1"
    if [[ -n "${sudo_user}" ]]; then
        SUDO_USER="${sudo_user}" bash "${INSTALLER}" __no_such_action__ 2>&1 || true
    else
        env -u SUDO_USER bash "${INSTALLER}" __no_such_action__ 2>&1 || true
    fi
}

# (1) root as the operator is refused, and the refusal names the account it wants instead.
out="$(run_installer root)"
if grep -qi 'must be a normal login user, not root' <<<"${out}"; then
    pass "install.sh refuses to enrol root as the operator"
else
    fail "install.sh did not refuse SUDO_USER=root: ${out}"
fi

# (2) The refusal must precede the dispatch: reaching usage means the guard did not fire.
if ! grep -q 'usage: sudo' <<<"${out}"; then
    pass "the root refusal precedes the action dispatch"
else
    fail "install.sh reached its dispatch with SUDO_USER=root: ${out}"
fi

# (3) An absent SUDO_USER stays refused -- the guard above this one, asserted so a rewrite of
# either cannot silently drop it.
out="$(run_installer "")"
if grep -qi 'SUDO_USER not set' <<<"${out}"; then
    pass "install.sh refuses a direct root run (no SUDO_USER)"
else
    fail "install.sh did not refuse an unset SUDO_USER: ${out}"
fi

# (4) A normal login user passes both guards and reaches the dispatch, so the checks above are
# refusing the principal rather than everything.
out="$(run_installer "${PROJECTS_USER}")"
if grep -q 'usage: sudo' <<<"${out}"; then
    pass "install.sh admits ${PROJECTS_USER} and reaches the dispatch"
else
    fail "install.sh refused the operator ${PROJECTS_USER}: ${out}"
fi

finish
