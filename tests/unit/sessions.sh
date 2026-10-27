#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/sessions.sh
# Unit test for sessions.lib.sh, the reader the recursive relabels gate on. Two properties carry it.
#
# THE TWIN. The library's enumeration is a copy of ai-tools-stop's, which does not load a project library and so cannot
# source this one (stop.rule.md, ref-section-e8k5). Each copied function is held equal to the helper's
# through `declare -f` after the substitution this file spells out, so a fix to either copy fails here until it reaches
# the other.
#
# THE FAIL DIRECTION. The gate refuses a walk on `live` and on `unreadable`, so a reading that cannot be made must never
# come back `none`: no cgroup v2 mount, no uid, a user.slice the caller cannot enter, and a cgroup.procs it cannot read
# are each driven. A fixture cgroup tree under TESTDIR stands in for /sys/fs/cgroup, reached by stubbing the mount
# reader after its twin is pinned; no host cgroup is read.
#
# Runs as root with the rest of the suite and unprivileged during development. The unreadable-file case holds only
# for an unprivileged caller, since root reads any mode, so a root run drives it as the projects user through runuser.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"

section "sessions: the live-session reader (unit)"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# The deployed copies are preferred, the checkout's the fallback, as in stop.sh.
STOP_HELPER="/usr/local/libexec/ai-tools/ai-tools-stop"
[[ -r "${STOP_HELPER}" ]] || STOP_HELPER="${ROOT}/src/usr/local/libexec/ai-tools/ai-tools-stop.sh"
LIB="/usr/local/lib/ai-tools/sessions.lib.sh"
[[ -r "${LIB}" ]] || LIB="${ROOT}/src/usr/local/lib/ai-tools/sessions.lib.sh"
if [[ ! -r "${STOP_HELPER}" || ! -r "${LIB}" ]]; then
    skip "sessions" "the stop helper or sessions.lib.sh is readable at neither the installed nor the source path"
    finish; exit
fi

mktestdir

# The helper and the harness both declare SANDBOX_USER readonly, so that one error is expected on source (stop.sh states
# the same); sourcing the helper is otherwise inert.
# shellcheck source=/dev/null
source "${STOP_HELPER}" 2>/dev/null || true
# shellcheck source=/dev/null
source "${LIB}"
if ! declare -F find_session_cgroups >/dev/null 2>&1 \
        || ! declare -F ai_tools_sessions__read_live_session_state >/dev/null 2>&1; then
    fail "sourcing the stop helper and ${LIB} did not define the functions this file compares"
    finish; exit
fi

# ── The twin ─────────────────────────────────────────────────────────────────────────────────
section "the enumeration is the stop helper's"

# twin_substitute -- the whole difference between each helper body and its library copy: the names, and the two walk
# globals the helper reads, which the library takes as its first and second arguments.
# shellcheck disable=SC2016  # the $1, $2 and ${...} in the expressions are the text sed matches and writes
twin_substitute() {
    sed -e 's/\bcgroup2_mount\b/ai_tools_sessions__read_cgroup2_mount/g' \
        -e 's/\bhas_own_tasks\b/_ai_tools_sessions__has_own_tasks/g' \
        -e 's/\bfind_session_cgroups\b/_ai_tools_sessions__list_session_cgroups/g' \
        -e 's/\bcgroup_is_live\b/_ai_tools_sessions__is_cgroup_live/g' \
        -e 's/"\${SANDBOX_SLICE}"/"$1"/g' \
        -e 's/"\${MANAGER_SERVICE}"/"$2"/g'
}

twin_pairs=(
    cgroup2_mount:ai_tools_sessions__read_cgroup2_mount
    has_own_tasks:_ai_tools_sessions__has_own_tasks
    find_session_cgroups:_ai_tools_sessions__list_session_cgroups
    cgroup_is_live:_ai_tools_sessions__is_cgroup_live
)
for pair in "${twin_pairs[@]}"; do
    original="${pair%%:*}"; twin="${pair#*:}"
    if [[ "$(declare -f "${original}" | twin_substitute)" == "$(declare -f "${twin}")" ]]; then
        pass "${twin} is ai-tools-stop's ${original} under the stated substitution"
    else
        fail "${twin} has drifted from ai-tools-stop's ${original}: $(diff <(declare -f "${original}" | twin_substitute) <(declare -f "${twin}") | head -n 6 | tr '\n' ' ')"
    fi
done
# The control: a one-character change to the helper's copy must break the equality, or each twin pass in this section
# reads two different bodies as one.
if [[ "$(declare -f has_own_tasks | twin_substitute | sed 's/return 1/return 0/')" \
        != "$(declare -f _ai_tools_sessions__has_own_tasks)" ]]; then
    pass "the comparison tells a changed body from its twin (control)"
else
    fail "the comparison reads a changed body as equal -- every twin pass above is vacuous"
fi

# ── The fixture tree ─────────────────────────────────────────────────────────────────────────
# mkcg <dir> [pid...] -- a cgroup directory whose cgroup.procs lists the pids. No cgroup.events is written, so liveness
# is read through the walk; the events file has a case of its own.
mkcg() {
    local dir="$1" pid; shift
    mkdir -p "${dir}"
    : > "${dir}/cgroup.procs"
    for pid in "$@"; do printf '%s\n' "${pid}" >> "${dir}/cgroup.procs"; done
}

MOUNT="${TESTDIR}/cgroup2"
SLICE="${MOUNT}/user.slice/user-4242.slice"
MANAGER="${SLICE}/user@4242.service"
mkcg "${MOUNT}/user.slice"
mkcg "${SLICE}"
mkcg "${MANAGER}"
mkcg "${MANAGER}/init.scope"                       101
mkcg "${MANAGER}/app.slice"
mkcg "${MANAGER}/app.slice/dbus-broker.service"    102
chmod -R a+rX "${MOUNT}"

# With its twin pinned, the mount reader is stubbed from here on to aim the reader at the fixture.
fixture_mount_ok=1
ai_tools_sessions__read_cgroup2_mount() {
    (( fixture_mount_ok )) || return 1
    printf '%s' "${MOUNT}"
}

state_is() {
    local want="$1" what="$2" uid="${3:-4242}" got
    got="$(ai_tools_sessions__read_live_session_state_for_uid "${uid}")"
    if [[ "${got}" == "${want}" ]]; then
        pass "${what}: ${want}"
    else
        fail "${what}: expected ${want}, read ${got}"
    fi
}

# ── The truth table ──────────────────────────────────────────────────────────────────────────
section "what reads as live"

state_is none "the manager's init.scope and its dbus broker alone"

mkcg "${MANAGER}/app.slice/acme-acme-11.service"   201
state_is live "an acme session unit holding a task"
listed="$(ai_tools_sessions__list_live_sessions 4242)"
if [[ "${listed}" == "${MANAGER}/app.slice/acme-acme-11.service" ]]; then
    pass "the listing names the session unit and leaves the plumbing out"
else
    fail "the listing printed: ${listed//$'\n'/ | }"
fi
rm -rf "${MANAGER}/app.slice/acme-acme-11.service"

mkcg "${MANAGER}/app.slice/acme-acme-12.service"
state_is none "a unit directory left behind with no task"
rm -rf "${MANAGER}/app.slice/acme-acme-12.service"

mkcg "${SLICE}/session-3.scope"                    301
state_is live "a login session scope beside the manager (a process a sudo -u started)"
rm -rf "${SLICE}/session-3.scope"

mkcg "${MANAGER}/app.slice/.hidden.scope"          401
state_is live "a dot-named unit (the walk sees it)"
rm -rf "${MANAGER}/app.slice/.hidden.scope"

mkcg "${MANAGER}/app.slice/evil"
mkcg "${MANAGER}/app.slice/evil/init.scope"        402
state_is live "a cgroup named init.scope away from the manager's own"
rm -rf "${MANAGER}/app.slice/evil"

mkcg "${MANAGER}/app.slice/acme-acme-13.service"   501
printf 'populated 0\nfrozen 0\n' > "${MANAGER}/app.slice/acme-acme-13.service/cgroup.events"
state_is none "a unit whose cgroup.events reports it empty (the kernel's answer wins)"
rm -rf "${MANAGER}/app.slice/acme-acme-13.service"

state_is none "an account with no slice at all" 4343

before="$(shopt -p dotglob nullglob || true)"
ai_tools_sessions__read_live_session_state_for_uid 4242 >/dev/null
after="$(shopt -p dotglob nullglob || true)"
if [[ "${before}" == "${after}" ]]; then
    pass "the walk's glob options do not reach the caller's shell"
else
    fail "the reader changed the caller's glob options: ${before//$'\n'/ } -> ${after//$'\n'/ }"
fi

# ── The fail direction ───────────────────────────────────────────────────────────────────────
section "a reading that cannot be made is unreadable, never none"

fixture_mount_ok=0
state_is unreadable "no cgroup v2 mount"
fixture_mount_ok=1

state_is unreadable "a uid that is not a number" "4242x"

# The account form reads the uid through sandbox-exec.lib.sh, and an empty answer from that reader reads as unreadable.
ai_tools_sandbox_exec__read_sandbox_uid() { printf '%s' "${stub_sandbox_uid}"; }
stub_sandbox_uid=""
got="$(ai_tools_sessions__read_live_session_state)"
[[ "${got}" == unreadable ]] && pass "the account form with no sandbox uid: unreadable" \
    || fail "the account form with no sandbox uid read ${got}"
stub_sandbox_uid=4242
got="$(ai_tools_sessions__read_live_session_state)"
[[ "${got}" == none ]] && pass "the account form reads the sandbox uid's slice (control): none" \
    || fail "the account form with the sandbox uid 4242 read ${got}"

mv "${MOUNT}/user.slice" "${MOUNT}/user.slice.away"
state_is unreadable "no user.slice under the mount"
mv "${MOUNT}/user.slice.away" "${MOUNT}/user.slice"

# The remaining readings turn on a mode, which root reads through, so a root run asks them as the projects user.
# state_unprivileged_is <want> <what> -- the reader's answer for an unprivileged caller, over the same fixture.
# shellcheck disable=SC2016  # $1..$3 are the inner shell's positionals
probe='source "$1"; stub_mount="$2"; ai_tools_sessions__read_cgroup2_mount() { printf "%s" "${stub_mount}"; }; ai_tools_sessions__read_live_session_state_for_uid "$3"'
state_unprivileged_is() {
    local want="$1" what="$2" got who
    if [[ "${EUID}" -ne 0 ]]; then
        got="$(bash -c "${probe}" _ "${LIB}" "${MOUNT}" 4242)"; who="the invoking user"
    elif command -v runuser >/dev/null 2>&1; then
        got="$(runuser -u "${PROJECTS_USER}" -- bash -c "${probe}" _ "${LIB}" "${MOUNT}" 4242 2>/dev/null || true)"
        who="${PROJECTS_USER}"
    else
        skip "${what}" "runuser unavailable to ask the reader unprivileged"; return 0
    fi
    if [[ "${got}" == "${want}" ]]; then
        pass "${what}: ${want} (asked as ${who})"
    else
        fail "${what}: expected ${want}, read ${got:-nothing} as ${who}"
    fi
}

# The fixture is opened explicitly: a root umask of 077 would close each new directory to the projects user,
# and a cgroup it cannot enter reads as removed.
mkcg "${MANAGER}/app.slice/acme-acme-14.service"   601
chmod 0755 "${MANAGER}/app.slice/acme-acme-14.service"
printf 'populated 0\nfrozen 0\n' > "${MANAGER}/app.slice/acme-acme-14.service/cgroup.events"
chmod 0644 "${MANAGER}/app.slice/acme-acme-14.service/cgroup.events"
state_unprivileged_is none "a readable cgroup.events reporting the unit empty (control)"
chmod 000 "${MANAGER}/app.slice/acme-acme-14.service/cgroup.events"
state_unprivileged_is live "a cgroup.events the caller cannot read"
rm -f "${MANAGER}/app.slice/acme-acme-14.service/cgroup.events"
state_unprivileged_is live "a unit holding a task, read through its cgroup.procs (control)"
chmod 000 "${MANAGER}/app.slice/acme-acme-14.service/cgroup.procs"
: > "${MANAGER}/app.slice/acme-acme-14.service/cgroup.threads"
chmod 0644 "${MANAGER}/app.slice/acme-acme-14.service/cgroup.threads"
state_unprivileged_is live "a cgroup.procs the caller cannot read"
rm -rf "${MANAGER}/app.slice/acme-acme-14.service"

# The account slice present but unlistable: the walk would read it as empty.
chmod 0311 "${SLICE}"
state_unprivileged_is unreadable "an account slice the caller cannot list"
chmod 0755 "${SLICE}"

finish
