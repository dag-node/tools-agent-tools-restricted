#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/install-guards.sh
# Hermetic check of install.sh's entry guards -- the ones that decide WHICH account the install enrols as the operator,
# before it writes anything.
#
# The one that matters is root. `ai-tools-admin operators add` refuses it outright, and install.sh reaches the same end
# state by a different route (the @PROJECTS_USER@ substitution plus `usermod -aG ai-ops`), so the two have to refuse
# alike or the dev path produces a host nobody can provision: the CLI refuses root every mutating verb, `--for` refuses
# root as a target, and the ownership handback would restore agent-written files to root:ai-tools.
#
# Root is reachable without meaning to -- sudo invoked from a root shell sets SUDO_USER=root, so `sudo -i` followed
# by `sudo ./install.sh` passes the SUDO_USER check with a resolvable home.
#
# A name reaches the decision by three routes -- SUDO_USER, `--operator`, and the interactive prompt -- and the second
# is what makes the other refusals testable at all: the prompt reads from /dev/tty, so its branch cannot be driven here,
# while `--operator` carries a name past the same operator_refusal without a terminal. Every refusal is therefore
# asserted through the flag, and the file asserts the flag's own arithmetic too (a missing value, the = form,
# and that it decides the ENROLLED account without touching who invoked sudo).
#
# Nothing is installed: each case runs install.sh with an unrecognized ACTION, and the guards sit before the dispatch,
# so a run that reaches the dispatch at all prints usage and exits without touching the system. Needs root, since
# the EUID guard precedes the ones under test.

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

# run_installer <SUDO_USER value> [arg...] -- run the installer with an unrecognized action plus any extra arguments,
# printing its combined output. An empty value runs with SUDO_USER unset.
run_installer() {
    local sudo_user="$1"; shift
    if [[ -n "${sudo_user}" ]]; then
        SUDO_USER="${sudo_user}" bash "${INSTALLER}" __no_such_action__ "$@" 2>&1 || true
    else
        env -u SUDO_USER bash "${INSTALLER}" __no_such_action__ "$@" 2>&1 || true
    fi
}

# (1) root as the operator is refused.
out="$(run_installer root)"
assert_msg MSG-D7C6 "${out}" "install.sh refuses to enrol root as the operator"

# (2) The refusal must precede the dispatch: reaching usage means the guard did not fire.
if ! grep -q 'usage: sudo' <<<"${out}"; then
    pass "the root refusal precedes the action dispatch"
else
    fail "install.sh reached its dispatch with SUDO_USER=root: ${out}"
fi

# (3) An absent SUDO_USER stays refused -- the guard preceding this one, asserted so a rewrite of either cannot silently
# drop it.
out="$(run_installer "")"
if grep -qi 'SUDO_USER not set' <<<"${out}"; then
    pass "install.sh refuses a direct root run (no SUDO_USER)"
else
    fail "install.sh did not refuse an unset SUDO_USER: ${out}"
fi

# (4) A normal login user passes both guards and reaches the dispatch, so the two checks are refusing the principal
# rather than everything.
out="$(run_installer "${PROJECTS_USER}")"
if grep -q 'usage: sudo' <<<"${out}"; then
    pass "install.sh admits ${PROJECTS_USER} and reaches the dispatch"
else
    fail "install.sh refused the operator ${PROJECTS_USER}: ${out}"
fi

# (5) The same root refusal on the `--operator` route. Both routes reach one decision, so a name that is refused when it
# arrives from sudo must be refused when it is typed as a flag.
out="$(run_installer "${PROJECTS_USER}" --operator root)"
assert_msg MSG-D7C6 "${out}" "--operator root is refused by the same code as SUDO_USER=root"
if ! grep -q 'usage: sudo' <<<"${out}"; then
    pass "the --operator root refusal precedes the dispatch"
else
    fail "--operator root reached the dispatch: ${out}"
fi

# (6) The sandbox account: enrolling it would put the account the agent runs as into ai-ops, which ai-tools-run refuses
# to launch for -- so the host would install and then never launch.
out="$(run_installer "${PROJECTS_USER}" --operator "${SANDBOX_USER}")"
assert_msg MSG-S9C4 "${out}" "--operator ${SANDBOX_USER} is refused"

# (7) A name no account answers to. Left unrefused it would enrol a name the ownership helpers can never resolve
# to an owner.
out="$(run_installer "${PROJECTS_USER}" --operator "no-such-account-${RANDOM}${RANDOM}")"
assert_msg MSG-X4X2 "${out}" "--operator with an unknown account is refused"

# (8) The flag's own arithmetic: a trailing `--operator` has no name to enrol, and must say so rather than reading
# the next thing as one or enrolling an empty name.
out="$(SUDO_USER="${PROJECTS_USER}" bash "${INSTALLER}" __no_such_action__ --operator 2>&1 || true)"
assert_msg MSG-U5E6 "${out}" "a valueless --operator is refused"

# (9) The = form names the same account as the spaced form, so a script may use either.
out="$(run_installer "${PROJECTS_USER}" "--operator=${PROJECTS_USER}")"
if grep -q 'usage: sudo' <<<"${out}"; then
    pass "--operator=${PROJECTS_USER} is admitted and reaches the dispatch"
else
    fail "--operator=${PROJECTS_USER} was refused: ${out}"
fi

# (10) The flag decides who is ENROLLED, not how the script was invoked: a root-owned sudo context that names a usable
# operator passes, which is the unattended provisioning case (case 1 shows the same context refused when it names
# nobody).
out="$(run_installer root --operator "${PROJECTS_USER}")"
if grep -q 'usage: sudo' <<<"${out}"; then
    pass "--operator ${PROJECTS_USER} is admitted even from a SUDO_USER=root invocation"
else
    fail "--operator did not override SUDO_USER=root: ${out}"
fi

# ── The source-tree gate ──────────────────────────────────────────────────────────────────────
# What root deploys is a committed tree the operator reviewed, so an install from a checkout with uncommitted changes is
# refused unless `--allow-uncommitted` states the decision. Driven through `install.sh check-tree`, which runs the gate
# alone, against a FIXTURE checkout: a copy of install.sh with the libraries it sources from its own tree,
# in a repository this test makes. Running the real checkout would report whatever state the developer's tree is
# in, and running `install` against a fixture would install from it if the gate ever failed open.
section "install.sh source-tree gate (unit)"
mktestdir
FIX="${TESTDIR}/checkout"
mkdir -p "${FIX}/src/usr/local/lib"
cp "${INSTALLER}" "${FIX}/install.sh"
cp -r "${ROOT}/src/usr/local/lib/ai-tools" "${FIX}/src/usr/local/lib/ai-tools"
git_fix() { git -C "${FIX}" -c user.name=guard -c user.email=guard@example.invalid -c commit.gpgsign=false -c safe.directory='*' "$@" >/dev/null 2>&1; }
git_fix init -q
git_fix add -A
git_fix commit -q -m "fixture"
# run_gate [arg...] -- the check-tree action on the fixture, its combined output and exit status published in GATE_OUT /
# GATE_RC. Detached from any terminal, as the gate does not prompt. The installed CLI it orders against is a path that
# does not exist, so the version gate passes whatever this host has installed; (13a) drives that gate on its own.
run_gate() {
    set +e
    GATE_OUT="$(AI_TOOLS_INSTALLED_CLI="${TESTDIR}/no-installed-cli" SUDO_USER="${PROJECTS_USER}" setsid -w bash "${FIX}/install.sh" check-tree "$@" 2>&1)"
    GATE_RC=$?
    set -e
}

# (11) A clean checkout passes and names the commit it would deploy.
run_gate
if (( GATE_RC == 0 )) && grep -q 'source tree   : commit' <<<"${GATE_OUT}" && grep -q 'fixture' <<<"${GATE_OUT}"; then
    pass "a clean checkout passes the gate and names its commit"
else
    fail "clean checkout: rc=${GATE_RC}: ${GATE_OUT}"
fi

# (11b) The gate reads the operator's repository without writing it. A tree copied or unpacked onto a host carries
# a stale stat cache in .git/index, which a plain `git status` refreshes by rewriting the index -- and a root-written
# index is root-owned, so the operator's next `git add` cannot write it. The fixture is handed to the projects user,
# a touch stales the cache, and a plain root `git status` is the control that the state rewrites the index at all.
chown -R "${PROJECTS_USER}:" "${FIX}"
index_owner() { stat -c %U "${FIX}/.git/index"; }
touch -d '2001-01-01' "${FIX}/install.sh"
git -c safe.directory='*' -C "${FIX}" status --porcelain >/dev/null 2>&1 || true
if [[ "$(index_owner)" == root ]]; then
    chown "${PROJECTS_USER}:" "${FIX}/.git/index"
    touch -d '2002-02-02' "${FIX}/install.sh"
    run_gate
    if (( GATE_RC == 0 )) && [[ "$(index_owner)" == "${PROJECTS_USER}" ]]; then
        pass "the gate leaves .git/index with the operator when the stat cache is stale"
    else
        fail "the gate rewrote .git/index as $(index_owner): rc=${GATE_RC}: ${GATE_OUT}"
    fi
else
    skip "the gate leaves .git/index with the operator" "a root git status did not rewrite a stale index on this git, so the case has no control"
fi

# (12) An uncommitted change is refused, the path is listed, and the refusal names the flag. The edit is a comment:
# the file is the script under test, and a run that passes the gate (14, 15) executes to its end, where an appended word
# would run as a command.
printf '# edited\n' >> "${FIX}/install.sh"
: > "${FIX}/untracked.txt"
run_gate
assert_msg MSG-U8C9 "${GATE_OUT}" "an uncommitted tree is refused"
if (( GATE_RC != 0 )) \
        && grep -qE '^ +M +install\.sh' <<<"${GATE_OUT}" && grep -qE '^ +\?\? +untracked\.txt' <<<"${GATE_OUT}" \
        && grep -q -- '--allow-uncommitted' <<<"${GATE_OUT}"; then
    pass "an uncommitted tree is refused, its paths listed, and the flag named as the way through"
else
    fail "uncommitted tree: rc=${GATE_RC}: ${GATE_OUT}"
fi

# (13a) The version gate, driven through the same action over the same fixture: the checkout's packaging/VERSION
# against the AI_TOOLS_VERSION line of a fixture "installed CLI" reached through AI_TOOLS_INSTALLED_CLI. Each direction
# is driven -- a newer installation refuses and names the flag, the flag admits it with the warning that states
# what the next post-upgrade will read, an equal and an older installation pass in silence, and an installation
# whose version cannot be read passes with the line saying so. `--allow-uncommitted` keeps the source-tree gate
# out of the way, since these runs share the fixture with the cases that dirty it.
mkdir -p "${FIX}/packaging"; printf '0.21.0\n' > "${FIX}/packaging/VERSION"
INSTALLED_CLI="${TESTDIR}/installed-cli"
run_version_gate() {  # run_version_gate <installed version line> [arg...]
    local line="$1"; shift
    printf '#!/usr/bin/env bash\n%s\n' "${line}" > "${INSTALLED_CLI}"
    set +e
    GATE_OUT="$(AI_TOOLS_INSTALLED_CLI="${INSTALLED_CLI}" SUDO_USER="${PROJECTS_USER}" setsid -w bash "${FIX}/install.sh" check-tree --allow-uncommitted "$@" 2>&1)"
    GATE_RC=$?
    set -e
}
run_version_gate 'AI_TOOLS_VERSION="0.22.0"'
assert_msg MSG-W6B3 "${GATE_OUT}" "a checkout older than the installed version is refused"
if (( GATE_RC != 0 )) && grep -q '0.21.0' <<<"${GATE_OUT}" && grep -q '0.22.0' <<<"${GATE_OUT}" \
        && grep -qE "sudo (dnf remove 'ai-tools-\*'|\./install\.sh uninstall)" <<<"${GATE_OUT}" \
        && grep -q -- '--allow-downgrade' <<<"${GATE_OUT}"; then
    pass "the refusal names both versions, the removal by the installed version's own tool, and the in-place flag after it"
else
    fail "downgrade refusal: rc=${GATE_RC}: ${GATE_OUT}"
fi
if grep -q 'sudo dnf remove' <<<"${GATE_OUT}"; then
    if rpm -q ai-tools-base >/dev/null 2>&1; then
        pass "the removal named is dnf's, since ai-tools-base is an rpm on this host"
    else
        fail "the refusal names dnf on a host where ai-tools-base is not an rpm"
    fi
elif rpm -q ai-tools-base >/dev/null 2>&1; then
    fail "the refusal names the from-source uninstall on a host where ai-tools-base is an rpm"
else
    pass "the removal named is the installed version's own install.sh uninstall, since ai-tools-base is not an rpm here"
fi
run_version_gate 'AI_TOOLS_VERSION="0.22.0"' --allow-downgrade
assert_msg MSG-W7G8 "${GATE_OUT}" "--allow-downgrade admits the older checkout with a warning"
if (( GATE_RC == 0 )) && ! grep -q 'MSG-W6B3' <<<"${GATE_OUT}" && grep -q 'system post-upgrade' <<<"${GATE_OUT}"; then
    pass "the admitted downgrade passes and the warning names what the next post-upgrade reads"
else
    fail "admitted downgrade: rc=${GATE_RC}: ${GATE_OUT}"
fi
for line in 'AI_TOOLS_VERSION="0.21.0"' 'AI_TOOLS_VERSION="0.20.5"' 'AI_TOOLS_VERSION="dev"' 'AI_TOOLS_VERSION="@AI_TOOLS_VERSION@"'; do
    run_version_gate "${line}"
    if (( GATE_RC == 0 )) && ! grep -qE 'MSG-W6B3|MSG-W7G8' <<<"${GATE_OUT}" && grep -q 'version       : 0.21.0' <<<"${GATE_OUT}"; then
        pass "an installation reading ${line#AI_TOOLS_VERSION=} passes the version gate, the version line printed"
    else
        fail "installed ${line}: rc=${GATE_RC}: ${GATE_OUT}"
    fi
done
rm -f "${INSTALLED_CLI}"
run_version_gate ''
rm -f "${INSTALLED_CLI}"
if (( GATE_RC == 0 )) && grep -q 'no installed version to order against' <<<"${GATE_OUT}"; then
    pass "no installed CLI passes the version gate, saying there is nothing to order against"
else
    fail "no installed CLI: rc=${GATE_RC}: ${GATE_OUT}"
fi

# (13) A path the sandbox account owns is marked: that is a session's write no one has committed.
chown "${SANDBOX_USER}:${SANDBOX_GROUP}" "${FIX}/untracked.txt"
run_gate
if grep -qE 'untracked\.txt +\[agent\]' <<<"${GATE_OUT}" && grep -q '1 of the listed owned by the sandbox account' <<<"${GATE_OUT}"; then
    pass "a path the sandbox account owns is marked [agent] and counted"
else
    fail "agent-owned path not marked: ${GATE_OUT}"
fi

# (14) `--allow-uncommitted` admits the same tree, warning rather than refusing.
run_gate --allow-uncommitted
assert_msg MSG-E2B9 "${GATE_OUT}" "--allow-uncommitted warns rather than refusing"
if (( GATE_RC == 0 )); then
    pass "--allow-uncommitted admits the tree"
else
    fail "--allow-uncommitted did not admit the tree: rc=${GATE_RC}: ${GATE_OUT}"
fi

# (15) A tree that is not a repository has no commit to name and passes: the tarball install.
rm -rf "${FIX}/.git"
run_gate
if (( GATE_RC == 0 )) && grep -q 'not a git checkout' <<<"${GATE_OUT}"; then
    pass "a checkout that is not a repository passes with no commit to name"
else
    fail "non-repository tree: rc=${GATE_RC}: ${GATE_OUT}"
fi

finish
