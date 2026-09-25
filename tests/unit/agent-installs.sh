#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/agent-installs.sh
# Hermetic unit test for agent-installs.lib.sh: which agents a host carries besides the sandbox's, the reading
# `install.sh` and the ai-tools-base %post report from.
#
# What it must get right is the shape of a host. /bin and /usr/bin are one directory on a usr-merged host, so one file
# answers to two spellings, and reporting that as two installs tells an operator to remove a file they have only one
# of; two separate binaries are two things to decide about. The wrapper itself, found under a merged /usr/local/sbin, is
# not an install at all. The file drives each shape, and the inputs that must report no install: a name outside
# a launcher's charset, a file without the executable bit, and a directory that does not
# exist.
#
# Pure: the search takes its directories as arguments, so the fixtures are a tree this file builds and no system
# directory is read. Run without root.
#
# The fixtures carry the executable bit, which is the property the search asks about, so they need a directory
# where that bit is VISIBLE. `-x` is an access(2) check, which a noexec mount and an SELinux label that withholds
# execute both answer false for whatever the file's mode says, and either would fail every positive case here
# for a property of the host. The testdir is used when it qualifies and a directory beside the operator's home
# otherwise, the fallback integration/cli-flags.sh takes for the same reason.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="/usr/local/lib/ai-tools/agent-installs.lib.sh"
[[ -r "${LIB}" ]] || LIB="${REPO_ROOT}/src/usr/local/lib/ai-tools/agent-installs.lib.sh"

section "agent-installs.lib.sh: the agents a host carries outside the sandbox (unit)"

if [[ ! -r "${LIB}" ]]; then
    skip "agent installs" "library not found at ${LIB}"; finish; exit
fi
# shellcheck source=../../src/usr/local/lib/ai-tools/agent-installs.lib.sh
source "${LIB}"

# x_bit_visible <dir>: succeed when a 0755 file created there reads as executable. Probes rather than reading mount
# options, so it answers for whatever combination of mount flag and filesystem applies here.
x_bit_visible() {
    local probe="$1/.x-probe.$$" ok=1
    printf '' > "${probe}" 2>/dev/null || return 1
    chmod 0755 "${probe}" 2>/dev/null || { rm -f "${probe}"; return 1; }
    [[ -x "${probe}" ]] && ok=0
    rm -f "${probe}"
    return "${ok}"
}

# build_tree <root> -- lay down the usr-merge shape under <root>: one directory reached by two names, holding one agent,
# plus a second directory for the two-installs case.
build_tree() {
    mkdir -p "$1/usr/bin" "$1/opt/bin"
    ln -sfn usr/bin "$1/bin"
    printf '#!/bin/sh\n' > "$1/usr/bin/claude"; chmod 0755 "$1/usr/bin/claude"
}

# The probe runs in the directory the fixtures live in, since what hides the bit is a property of the mount
# or of that directory's own label.
mktestdir
FIXTURE_ROOT="${TESTDIR}"
build_tree "${FIXTURE_ROOT}"
if ! x_bit_visible "${FIXTURE_ROOT}/usr/bin"; then
    mk_fixture_dir FIXTURE_ROOT "${PROJECTS_HOME}" agentinstalls 2>/dev/null || FIXTURE_ROOT=""
    if [[ -n "${FIXTURE_ROOT}" ]]; then
        chmod 0755 "${FIXTURE_ROOT}"
        build_tree "${FIXTURE_ROOT}"
    fi
fi
if [[ -z "${FIXTURE_ROOT}" ]] || ! x_bit_visible "${FIXTURE_ROOT}/usr/bin"; then
    skip "agent installs" "no directory here reports a 0755 file as executable (a noexec mount)"
    finish; exit
fi
SYSDIR="${FIXTURE_ROOT}/usr/bin"

# ── (A) One file under two spellings is one install ──────────────────────────────────────────
mapfile -t installs < <(ai_tools_agent_installs claude "${FIXTURE_ROOT}/bin" "${SYSDIR}")
if [[ "${#installs[@]}" -eq 1 \
   && "${installs[0]}" == "${FIXTURE_ROOT}/bin/claude"$'\t'"${SYSDIR}/claude" ]]; then
    pass "a usr-merged host reports one install, with the other spelling beside it"
else
    fail "one file under two names did not report as one install (${installs[*]-})"
fi

# The order the directories are searched in decides which spelling leads, so a caller that searches /bin first names
# the path the agent's own package installs.
mapfile -t installs < <(ai_tools_agent_installs claude "${SYSDIR}" "${FIXTURE_ROOT}/bin")
if [[ "${installs[0]}" == "${SYSDIR}/claude"$'\t'"${FIXTURE_ROOT}/bin/claude" ]]; then
    pass "the first directory searched is the spelling reported"
else
    fail "the reported spelling does not follow the search order (${installs[*]-})"
fi

# ── (B) Two separate binaries are two findings ───────────────────────────────────────────────
printf '#!/bin/sh\n' > "${FIXTURE_ROOT}/opt/bin/claude"; chmod 0755 "${FIXTURE_ROOT}/opt/bin/claude"
mapfile -t installs < <(ai_tools_agent_installs claude "${SYSDIR}" "${FIXTURE_ROOT}/opt/bin")
if [[ "${#installs[@]}" -eq 2 ]]; then
    pass "two agents in two directories are two findings"
else
    fail "a host carrying two agents reported ${#installs[@]} (${installs[*]-})"
fi

# ── (C) What is not an agent a shell can start ───────────────────────────────────────────────
chmod 0644 "${FIXTURE_ROOT}/opt/bin/claude"
if [[ -z "$(ai_tools_agent_installs claude "${FIXTURE_ROOT}/opt/bin" "${FIXTURE_ROOT}/nowhere")" ]]; then
    pass "a file without the executable bit, and a directory that is absent, report nothing"
else
    fail "reported something no shell would run"
fi
if [[ -z "$(ai_tools_agent_installs 'cl;id' "${SYSDIR}")" && -z "$(ai_tools_agent_installs '' "${SYSDIR}")" ]]; then
    pass "a launcher name outside the charset is not turned into a path"
else
    fail "built a path from a launcher name that must never reach one"
fi

# ── (C2) The wrapper itself is not an agent outside the sandbox ─────────────────────────────── Where
# /usr/local/sbin is a symlink to /usr/local/bin, the searched /usr/local/sbin holds the wrappers under another
# spelling. A fixture alias of the real wrapper directory reproduces that on any host with the CLI installed: the file
# found through it is the wrapper and must not be reported, while a copy of the same file is a separate binary and is.
probe_name="ai-tools"
if [[ ! -x "${AI_TOOLS_AGENT_INSTALL_WRAPPER_DIR}/${probe_name}" ]]; then
    skip "wrapper exclusion" "${AI_TOOLS_AGENT_INSTALL_WRAPPER_DIR}/${probe_name} is not installed on this host"
else
    ln -s "${AI_TOOLS_AGENT_INSTALL_WRAPPER_DIR}" "${FIXTURE_ROOT}/merged"
    mkdir -p "${FIXTURE_ROOT}/copy"
    cp "${AI_TOOLS_AGENT_INSTALL_WRAPPER_DIR}/${probe_name}" "${FIXTURE_ROOT}/copy/${probe_name}"
    chmod 0755 "${FIXTURE_ROOT}/copy/${probe_name}"
    if [[ ! -x "${FIXTURE_ROOT}/merged/${probe_name}" ]]; then
        fail "wrapper-exclusion setup: the alias does not reach ${AI_TOOLS_AGENT_INSTALL_WRAPPER_DIR}/${probe_name}"
    elif [[ -z "$(ai_tools_agent_installs "${probe_name}" "${FIXTURE_ROOT}/merged")" ]]; then
        pass "the wrapper reached through a merged alias of its directory is not reported"
    else
        fail "reported the sandbox wrapper as an agent outside the sandbox"
    fi
    mapfile -t installs < <(ai_tools_agent_installs "${probe_name}" "${FIXTURE_ROOT}/merged" "${FIXTURE_ROOT}/copy")
    if [[ "${#installs[@]}" -eq 1 && "${installs[0]%%$'\t'*}" == "${FIXTURE_ROOT}/copy/${probe_name}" ]]; then
        pass "a copy of the wrapper is a separate binary and is reported"
    else
        fail "the copy of the wrapper was not reported alone (${installs[*]-none})"
    fi
fi

# ── (D) The searched set, and the owner lookup's refusals ────────────────────────────────────
# The set is the library's, so a report and the ordering it recommends cover the same directories: the agent's own
# distribution channel installs into /bin, and /usr/local/bin is the wrappers' own.
if [[ " ${AI_TOOLS_AGENT_INSTALL_DIRS[*]} " == *" /bin "* \
   && " ${AI_TOOLS_AGENT_INSTALL_DIRS[*]} " == *" /usr/bin "* \
   && " ${AI_TOOLS_AGENT_INSTALL_DIRS[*]} " != *" /usr/local/bin "* ]]; then
    pass "the searched set covers where an agent lands and leaves out the wrappers' directory"
else
    fail "the searched set is not what a report needs (${AI_TOOLS_AGENT_INSTALL_DIRS[*]})"
fi

# The owner is rendered into a command a person is invited to run, so a value outside a package name's charset yields
# none. The fixture path belongs to no package, which is the same answer a host without rpm gives.
if [[ -z "$(ai_tools_agent_install_owner "${SYSDIR}/claude")" \
   && -z "$(ai_tools_agent_install_owner "")" ]]; then
    pass "a path no package owns, and an empty path, name no package"
else
    fail "named a package for a file no package owns"
fi

finish
