#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/admin-operator-add.sh
# Unit test for report_operator_role -- the lines `ai-tools-admin operators add` prints to say which
# of the two operator shapes the enrolment just produced: one that can claim projects, or one whose
# projects another operator claims for it.
#
# Worth pinning because the verdict is read out of sudo, the class that was already wrong once in
# this stack: `sudo -l` refuses SILENTLY (non-zero, no output), so a reading of it that matched a
# refusal MESSAGE matched a message sudo never sends. The property under test here is the other
# half of that lesson -- a sudo which fails for its OWN reasons must read as undetermined, never as
# a verdict about the account, because an administrator acts on this line at the moment of the
# decision and a false "no grant" sends them to a `--for` workflow they do not need.
#
# Each case runs in its own bash, because the helper and the harness both declare SANDBOX_USER
# readonly. sudo is stubbed as a shell FUNCTION, which overrides the PATH lookup, so no executable
# shim is needed (and the test works where /tmp is noexec) and no real sudoers is consulted. The
# helper is SOURCED, not run: its root check and its dispatch are guarded for exactly this, so one
# function is driven with no host to administer and no state written anywhere.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Installed copy first, then the source tree. The only substitution the install applies to this
# file is the sandbox account name, which this function does not read.
HELPER="/usr/local/libexec/ai-tools/ai-tools-admin"
[[ -r "${HELPER}" ]] || HELPER="${ROOT}/src/usr/local/libexec/ai-tools/ai-tools-admin.sh"

section "ai-tools-admin operators add: the sudo-grant report (unit)"

if [[ ! -r "${HELPER}" ]]; then
    skip "operators add report" "helper not readable (neither installed nor in a checkout)"
    finish; exit
fi

# run_report <command-probe-rc> <list-probe-rc> -- source the helper in a fresh shell with sudo
# stubbed, drive report_operator_role for one account, and echo everything it said. The stub keys
# on the claim helper's path, which is the operand of the first probe and absent from the second,
# so the two probes are answered independently.
run_report() {
    bash -c '
        set -euo pipefail
        # shellcheck source=/dev/null
        source "$1"
        declare -F report_operator_role >/dev/null 2>&1 || { printf "NO SUCH FUNCTION\n"; exit 0; }
        CMD_RC="$2"; LIST_RC="$3"
        sudo() {
            local arg
            for arg in "$@"; do
                [[ "${arg}" == */ai-tools-lockdown ]] && return "${CMD_RC}"
            done
            return "${LIST_RC}"
        }
        report_operator_role svc-op
    ' _ "${HELPER}" "$1" "$2" 2>&1 || true
}

out="$(run_report 0 0)"
if [[ "${out}" == *"NO SUCH FUNCTION"* ]]; then
    fail "sourcing ${HELPER} did not define report_operator_role"
    finish; exit
fi

# 1. The grant is there: sudo answers for the claim helper, and the account does not need a further step.
if [[ "${out}" == *"holds a general sudo grant"* && "${out}" != *"--for"* ]]; then
    pass "a listed claim helper reports the grant, with no --for advice"
else
    fail "grant present should report the grant alone, got: ${out}"
fi

# 2. Refused while sudo answers: the ai-ops-only account this report exists for. It is a supported
#    shape, so the line names the command another operator claims with rather than refusing.
out="$(run_report 1 0)"
if [[ "${out}" == *"holds no general sudo grant"* \
        && "${out}" == *"ai-tools --project-claim --for svc-op"* ]]; then
    pass "a refused claim helper reports no grant and names the --for command"
else
    fail "refusal should report no grant plus the --for command, got: ${out}"
fi

# 3. sudo failing for its own reasons: indistinguishable from case 2 on the first probe alone, and
#    the reason the second exists. It must not become a verdict about the account.
out="$(run_report 1 1)"
if [[ "${out}" == *"undetermined"* && "${out}" != *"holds no general sudo grant"* ]]; then
    pass "a sudo that answers nothing reports undetermined, not a verdict"
else
    fail "an unanswering sudo must not read as a missing grant, got: ${out}"
fi

# 4. No sudo at all: no account on the host can claim, which is a statement about the host rather than
#    about this account, and the enrolment it just did still stands.
out="$(bash -c '
    set -euo pipefail
    # shellcheck source=/dev/null
    source "$1"
    # Emptied only after the helper is loaded, so the shell itself still started: what is under
    # test is the branch that runs when sudo cannot be found, not a shell without a PATH.
    PATH="$2"
    report_operator_role svc-op
' _ "${HELPER}" "${TESTDIR:-/nonexistent}/no-such-bin-dir" 2>&1 || true)"
if [[ "${out}" == *"no sudo on this host"* && "${out}" == *"can still launch agent sessions"* ]]; then
    pass "no sudo on PATH reports the host limit, not a verdict about the account"
else
    fail "a host without sudo should report the host limit, got: ${out}"
fi

# --- wire_init_file: the PATH ordering line reaches the operator's bash init ---
# The guard line is what ranks /usr/local/bin (the wrapper) ahead of the nvm shims, so a shell that
# never sources it resolves `claude` to the nvm-managed binary instead. Driven against fixture
# files in TESTDIR: the function takes the file as an argument, so no real home is touched.
section "ai-tools-admin operator add: bash init wiring (unit)"

mktestdir
GUARD_LINE="/usr/local/lib/ai-tools/path-order.sh"

# wire_file <file> [login-chain] : source the helper in a fresh shell and wire one fixture file.
wire_file() {
    bash -c '
        set -euo pipefail
        # shellcheck source=/dev/null
        source "$1"
        declare -F wire_init_file >/dev/null 2>&1 || { printf "NO SUCH FUNCTION\n"; exit 0; }
        wire_init_file "$2" "$3" "$4" "${5-}"
    ' _ "${HELPER}" "$1" "${PROJECTS_USER}" "${PROJECTS_GROUP}" "${2-}" 2>&1 || true
}

out="$(wire_file "${TESTDIR}/.bashrc")"
if [[ "${out}" == *"NO SUCH FUNCTION"* ]]; then
    fail "sourcing ${HELPER} did not define wire_init_file"
    finish; exit
fi
if grep -qF "${GUARD_LINE}" "${TESTDIR}/.bashrc"; then
    pass "a created .bashrc carries the PATH ordering guard line"
else
    fail "a created .bashrc has no guard line: $(cat "${TESTDIR}/.bashrc")"
fi

# A created .bash_profile opens with the .bashrc source EL's skel carries. bash reads
# .bash_profile ALONE at login, so one holding only the guard line leaves a login shell without
# the account's own init -- its nvm init among it, which the guard line is placed after.
wire_file "${TESTDIR}/.bash_profile" login-chain >/dev/null
printf 'export AI_TOOLS_TEST_MARKER=from_bashrc\n' >> "${TESTDIR}/.bashrc"
marker="$(HOME="${TESTDIR}" bash -lc 'printf "%s" "${AI_TOOLS_TEST_MARKER:-unset}"' 2>/dev/null || true)"
if [[ "${marker}" == "from_bashrc" ]]; then
    pass "a login shell reads .bashrc through the created .bash_profile"
else
    fail "the created .bash_profile left a login shell without .bashrc (marker '${marker}')"
fi

# An init file the operator already has is appended to, never replaced, and a second run leaves
# the file as it found it: `operator add` is accumulating and idempotent, and this runs on every re-enrolment.
# shellcheck disable=SC2016  # the fixture's ${HOME} is init-file text, expanded by the shell reading it
printf '# my own bashrc\nexport NVM_DIR="${HOME}/.nvm"\n' > "${TESTDIR}/.bashrc"
wire_file "${TESTDIR}/.bashrc" >/dev/null
out="$(wire_file "${TESTDIR}/.bashrc")"
if [[ "$(grep -cF "${GUARD_LINE}" "${TESTDIR}/.bashrc")" == 1 \
        && "${out}" == *"already wired"* ]] && grep -qF '# my own bashrc' "${TESTDIR}/.bashrc"; then
    pass "an existing init file keeps its content and takes one guard line"
else
    fail "re-wiring changed an existing file:"$'\n'"$(cat "${TESTDIR}/.bashrc")"
fi

# --- ensure_config_home: the config home an operator's allowlist is seeded inside ---
# `operators add` refuses a first enrolment it cannot seed, so whether this function creates
# ~/.config decides whether an account with no config home can be enrolled at all. Driven against
# fixture homes in TESTDIR, owned by the caller, so the chown is unprivileged and no real home is
# touched. Each case runs its own umask, which is what the mode is read from.
section "ai-tools-admin operators add: the operator's config home (unit)"

# run_ensure <home> <umask> [confirm-rc] : source the helper in a fresh shell, run one umask, and
# drive ensure_config_home for the calling account. Every case answers the prompt WITHOUT drawing
# it: AI_TOOLS_ASSUME_YES fast-tracks the default-yes question, and a confirm-rc stubs the shared
# prompt to that status, which is how the declined case is reached. A case that let the prompt
# render would read /dev/tty and block the suite on an answer no test can give -- the reason
# tests/unit/managed-assets.sh drives its own no-terminal case under setsid.
run_ensure() {
    AI_TOOLS_ASSUME_YES=1 bash -c '
        set -euo pipefail
        # shellcheck source=/dev/null
        source "$1"
        declare -F ensure_config_home >/dev/null 2>&1 || { printf "NO SUCH FUNCTION\n"; exit 0; }
        umask "$3"
        if [[ -n "${4-}" ]]; then eval "ai_tools_msg_confirm() { return $4; }"; fi
        rc=0; ensure_config_home "$(id -un)" "$(id -gn)" "$2" || rc=$?
        printf "RC=%s\n" "${rc}"
    ' _ "${HELPER}" "$1" "$2" "${3-}" 2>&1 || true
}

out="$(run_ensure "${TESTDIR}/home-022" 022)"
if [[ "${out}" == *"NO SUCH FUNCTION"* ]]; then
    fail "sourcing ${HELPER} did not define ensure_config_home"
    finish; exit
fi
mkdir -p "${TESTDIR}/home-022" "${TESTDIR}/home-027"

# 1 + 2. A missing .config is created, and the HOST's umask decides its mode: the same function
#        under two umasks produces the two modes the host asked for. The account owns it either
#        way, which is what lets the operator write its own config home afterwards.
out="$(run_ensure "${TESTDIR}/home-022" 022)"
mode_022="$(stat -c '%a' "${TESTDIR}/home-022/.config" 2>/dev/null || echo none)"
out2="$(run_ensure "${TESTDIR}/home-027" 027)"
mode_027="$(stat -c '%a' "${TESTDIR}/home-027/.config" 2>/dev/null || echo none)"
if [[ "${out}" == *"RC=0"* && "${mode_022}" == 755 && "${out2}" == *"RC=0"* && "${mode_027}" == 750 ]]; then
    pass "a missing .config is created, at the mode the host umask gives (755 / 750)"
else
    fail "expected 755 under umask 022 and 750 under 027, got '${mode_022}' / '${mode_027}': ${out} ${out2}"
fi

# 3. No terminal, and no fast-track: the confirm's /dev/tty open fails, so it takes its default and
#    the directory is created. This is the unattended install -- an enrolment from a scriptlet or a
#    CI job seeds the account instead of waiting at a prompt.
mkdir -p "${TESTDIR}/home-notty"
# shellcheck disable=SC2016  # the inner shell's own positional parameters, passed after the _
setsid bash -c '
    set -euo pipefail
    # shellcheck source=/dev/null
    source "$1"
    ensure_config_home "$(id -un)" "$(id -gn)" "$2"
' _ "${HELPER}" "${TESTDIR}/home-notty" </dev/null >/dev/null 2>&1 || true
if [[ -d "${TESTDIR}/home-notty/.config" ]]; then
    pass "with no terminal the confirm defaults to yes and the config home is created"
else
    fail "a no-terminal run did not create .config -- an unattended enrolment would be refused"
fi

# 4. An existing one is left as it stands. Other applications keep their config there, so a mode
#    the account chose is not re-asserted on every re-enrolment.
chmod 711 "${TESTDIR}/home-022/.config"
out="$(run_ensure "${TESTDIR}/home-022" 022)"
if [[ "${out}" == *"RC=0"* && "$(stat -c '%a' "${TESTDIR}/home-022/.config")" == 711 ]]; then
    pass "an existing .config keeps its own mode"
else
    fail "an existing .config was re-moded to $(stat -c '%a' "${TESTDIR}/home-022/.config"): ${out}"
fi

# 5. Declined: the directory is left uncreated, the refusal carries its code, and the non-zero
#    status is what makes `operators add` refuse the enrolment instead of reporting a seed.
mkdir -p "${TESTDIR}/home-declined"
out="$(run_ensure "${TESTDIR}/home-declined" 022 1)"
if [[ "${out}" == *"RC=1"* && "${out}" == *"MSG-B6P3"* && ! -e "${TESTDIR}/home-declined/.config" ]]; then
    pass "a declined prompt leaves the home as it found it and returns non-zero"
else
    fail "a declined prompt should refuse and create nothing, got: ${out}"
fi

# 6. A .config that is a file: `mkdir` refuses it, and the condition is named here, where an
#    administrator reads it, instead of surfacing later as a seed that failed for no stated reason.
mkdir -p "${TESTDIR}/home-file"
: > "${TESTDIR}/home-file/.config"
out="$(run_ensure "${TESTDIR}/home-file" 022)"
if [[ "${out}" == *"RC=1"* && "${out}" == *"MSG-Z6V4"* ]]; then
    pass "a .config that is not a directory is reported and refused"
else
    fail "a non-directory .config should be refused with MSG-Z6V4, got: ${out}"
fi

finish
