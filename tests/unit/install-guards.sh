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
# A name reaches the decision by three routes -- SUDO_USER, --operator, and the interactive
# prompt -- and the second is what makes the other refusals testable at all: the prompt reads from
# /dev/tty, so its branch cannot be driven here, while --operator carries a name past the same
# operator_refusal without a terminal. Every refusal below is therefore asserted through the flag,
# and the file asserts the flag's own arithmetic too (a missing value, the = form, and that it
# decides the ENROLLED account without touching who invoked sudo).
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

# run_installer <SUDO_USER value> [arg...] -- run the installer with an unrecognized action plus
# any extra arguments, printing its combined output. An empty value runs with SUDO_USER unset.
run_installer() {
    local sudo_user="$1"; shift
    if [[ -n "${sudo_user}" ]]; then
        SUDO_USER="${sudo_user}" bash "${INSTALLER}" __no_such_action__ "$@" 2>&1 || true
    else
        env -u SUDO_USER bash "${INSTALLER}" __no_such_action__ "$@" 2>&1 || true
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

# (5) The same root refusal on the --operator route. Both routes reach one decision, so a name
# that is refused when it arrives from sudo must be refused when it is typed as a flag.
out="$(run_installer "${PROJECTS_USER}" --operator root)"
if grep -qi 'must be a normal login user, not root' <<<"${out}" && ! grep -q 'usage: sudo' <<<"${out}"; then
    pass "--operator root is refused, before the dispatch"
else
    fail "--operator root was not refused ahead of the dispatch: ${out}"
fi

# (6) The sandbox account: enrolling it would put the account the agent runs as into ai-ops, which
# ai-tools-run refuses to launch for -- so the host would install and then never launch.
out="$(run_installer "${PROJECTS_USER}" --operator "${SANDBOX_USER}")"
if grep -q "must not be the sandbox account ${SANDBOX_USER}" <<<"${out}"; then
    pass "--operator ${SANDBOX_USER} is refused"
else
    fail "--operator ${SANDBOX_USER} was not refused: ${out}"
fi

# (7) A name no account answers to. Left unrefused it would enrol a name the ownership helpers
# can never resolve to an owner.
out="$(run_installer "${PROJECTS_USER}" --operator "no-such-account-${RANDOM}${RANDOM}")"
if grep -q 'no such user:' <<<"${out}"; then
    pass "--operator with an unknown account is refused"
else
    fail "--operator with an unknown account was not refused: ${out}"
fi

# (8) The flag's own arithmetic: a trailing --operator has no name to enrol, and must say so
# rather than reading the next thing as one or enrolling an empty name.
out="$(SUDO_USER="${PROJECTS_USER}" bash "${INSTALLER}" __no_such_action__ --operator 2>&1 || true)"
if grep -q -- '--operator needs an account name' <<<"${out}"; then
    pass "a valueless --operator is refused"
else
    fail "a valueless --operator was not refused: ${out}"
fi

# (9) The = form names the same account as the spaced form, so a script may use either.
out="$(run_installer "${PROJECTS_USER}" "--operator=${PROJECTS_USER}")"
if grep -q 'usage: sudo' <<<"${out}"; then
    pass "--operator=${PROJECTS_USER} is admitted and reaches the dispatch"
else
    fail "--operator=${PROJECTS_USER} was refused: ${out}"
fi

# (10) The flag decides who is ENROLLED, not how the script was invoked: a root-owned sudo context
# that names a usable operator passes, which is the unattended provisioning case (case 1 shows the
# same context refused when it names nobody).
out="$(run_installer root --operator "${PROJECTS_USER}")"
if grep -q 'usage: sudo' <<<"${out}"; then
    pass "--operator ${PROJECTS_USER} is admitted even from a SUDO_USER=root invocation"
else
    fail "--operator did not override SUDO_USER=root: ${out}"
fi

finish
