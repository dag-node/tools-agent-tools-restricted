#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/sessions.sh
# Unit test for sessions.lib.sh, the reader the recursive relabels gate on. Two properties carry it.
#
# THE TWIN. The library's enumeration is a copy of ai-tools-stop's (stop.rule.md, ref-section-e8k5). Each copied
# function is held equal to the helper's through `declare -f` after the substitution this file spells out, so a fix
# to either copy fails here until it reaches the other.
#
# THE FAIL DIRECTION. The gate refuses a walk on `live` and on `unreadable`, so a reading that cannot be made must never
# come back `none`: no cgroup v2 mount, no uid, a user.slice the caller cannot enter, and a directory
# under the account's slice it cannot list and enter each read `unreadable`, a cgroup.procs or cgroup.events it cannot
# read makes its unit `live`, and an empty unit that sorts last must not turn a complete listing into `unreadable`.
# A fixture cgroup tree under TESTDIR stands in for /sys/fs/cgroup, reached by stubbing the mount reader after its twin
# is pinned; no host cgroup is read. The strict-IFS section reads the host's /proc/mounts through the real mount reader,
# and skips where that does not name a cgroup v2 mount.
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
    fail "the comparison reads a changed body as equal, so no twin pass above can detect a drifted body"
fi

# ── The fixture tree ─────────────────────────────────────────────────────────────────────────
# mk_cgroup <dir> [pid...] -- a cgroup directory whose cgroup.procs lists the pids. No cgroup.events is written,
# so liveness is read through the walk; the events file has a case of its own.
mk_cgroup() {
    local dir="$1" pid; shift
    mkdir -p "${dir}"
    : > "${dir}/cgroup.procs"
    for pid in "$@"; do printf '%s\n' "${pid}" >> "${dir}/cgroup.procs"; done
}

MOUNT="${TESTDIR}/cgroup2"
SLICE="${MOUNT}/user.slice/user-4242.slice"
MANAGER="${SLICE}/user@4242.service"
mk_cgroup "${MOUNT}/user.slice"
mk_cgroup "${SLICE}"
mk_cgroup "${MANAGER}"
mk_cgroup "${MANAGER}/init.scope"                       101
mk_cgroup "${MANAGER}/app.slice"
mk_cgroup "${MANAGER}/app.slice/dbus-broker.service"    102
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

mk_cgroup "${MANAGER}/app.slice/acme-acme-11.service"   201
state_is live "an acme session unit holding a task"
listed="$(ai_tools_sessions__list_live_cgroups 4242)"
if [[ "${listed}" == "${MANAGER}/app.slice/acme-acme-11.service" ]]; then
    pass "the listing names the session unit and leaves the plumbing out"
else
    fail "the listing printed: ${listed//$'\n'/ | }"
fi
rm -rf "${MANAGER}/app.slice/acme-acme-11.service"

mk_cgroup "${MANAGER}/app.slice/acme-acme-12.service"
state_is none "a unit directory left behind with no task"
rm -rf "${MANAGER}/app.slice/acme-acme-12.service"

mk_cgroup "${SLICE}/session-3.scope"                    301
state_is live "a login session scope beside the manager (a process a sudo -u started)"
rm -rf "${SLICE}/session-3.scope"

# A root caller's run as the account (sandbox-exec.lib.sh) is a system-manager scope placed directly under the slice.
mk_cgroup "${SLICE}/ai-tools-sandbox-exec-1-2.scope"    303
state_is live "a run a root caller placed in the account's slice"
listed="$(ai_tools_sessions__list_live_cgroups 4242 || true)"
if [[ "${listed}" == "${SLICE}/ai-tools-sandbox-exec-1-2.scope" ]]; then
    pass "the listing names the run's scope"
else
    fail "the listing with a run's scope printed: ${listed//$'\n'/ | }"
fi
rm -rf "${SLICE}/ai-tools-sandbox-exec-1-2.scope"

mk_cgroup "${MANAGER}/app.slice/.hidden.scope"          401
state_is live "a dot-named unit (the walk sees it)"
rm -rf "${MANAGER}/app.slice/.hidden.scope"

mk_cgroup "${MANAGER}/app.slice/evil"
mk_cgroup "${MANAGER}/app.slice/evil/init.scope"        402
state_is live "a cgroup named init.scope away from the manager's own"
rm -rf "${MANAGER}/app.slice/evil"

# A `*` in a bash pattern matches `/`, so the broker's patterns hold only at their own depth: a unit of the broker's
# name directly under a slice of the manager is plumbing (the baseline's dbus-broker.service, and dbus.service here),
# and one nested a slice deeper is not.
mk_cgroup "${MANAGER}/app.slice/dbus.service"           403
state_is none "a dbus.service directly under a slice of the manager"
rm -rf "${MANAGER}/app.slice/dbus.service"
mk_cgroup "${MANAGER}/app.slice/deep.slice"
mk_cgroup "${MANAGER}/app.slice/deep.slice/dbus.service" 404
state_is live "a unit of the broker's name nested a slice deeper"
rm -rf "${MANAGER}/app.slice/deep.slice"

mk_cgroup "${MANAGER}/app.slice/acme-acme-13.service"   501
printf 'populated 0\nfrozen 0\n' > "${MANAGER}/app.slice/acme-acme-13.service/cgroup.events"
state_is none "a unit whose cgroup.events reports it empty (the kernel's answer wins)"
rm -rf "${MANAGER}/app.slice/acme-acme-13.service"

# The walk's status is the last unit's test, so an empty unit that sorts after the broker is the order that would read
# a complete listing as failed.
mk_cgroup "${MANAGER}/app.slice/zzz-empty.service"
state_is none "an empty unit that sorts after the broker"
mk_cgroup "${MANAGER}/app.slice/acme-acme-15.service"   502
state_is live "a live unit followed by an empty one"
listed="$(ai_tools_sessions__list_live_cgroups 4242 || true)"
if [[ "${listed}" == "${MANAGER}/app.slice/acme-acme-15.service" ]]; then
    pass "the listing names the live unit alone when an empty unit follows it"
else
    fail "the listing with an empty unit after the live one printed: ${listed//$'\n'/ | }"
fi
rm -rf "${MANAGER}/app.slice/acme-acme-15.service" "${MANAGER}/app.slice/zzz-empty.service"

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
mk_cgroup "${MANAGER}/app.slice/acme-acme-14.service"   601
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

# A slice nested under the manager, unlistable, holding a session: under nullglob the walk reads it as empty.
mk_cgroup "${MANAGER}/sealed.slice"
mk_cgroup "${MANAGER}/sealed.slice/acme-acme-16.service" 701
chmod 0755 "${MANAGER}/sealed.slice/acme-acme-16.service"
chmod 0644 "${MANAGER}/sealed.slice/cgroup.procs" "${MANAGER}/sealed.slice/acme-acme-16.service/cgroup.procs"
chmod 0755 "${MANAGER}/sealed.slice"
state_unprivileged_is live "a session in a nested slice the caller can list (control)"
chmod 0311 "${MANAGER}/sealed.slice"
state_unprivileged_is unreadable "a session in a nested slice the caller cannot list"
chmod 0755 "${MANAGER}/sealed.slice"
rm -rf "${MANAGER}/sealed.slice"

# ── A caller's IFS ───────────────────────────────────────────────────────────────────────────
section "the reading holds under a caller's strict-mode IFS"

# install-selinux.sh and ai-tools.sh set IFS=$'\n\t' and call the reader in-process, where a space-split `read` keeps
# a whole line in one field. Each probe runs in a fresh bash, the IFS set ahead of the source as those callers set it.
#
# The mount probe keeps the library's real mount reader under another name and stubs the public one to call it, record
# what it read, and aim the walk at the fixture: the real body then runs at the depth the reader calls it
# from, under whatever IFS the reader's entry gives it. `direct` calls the real body at the top level instead.
mount_probe="${TESTDIR}/mount-probe.sh"
cat > "${mount_probe}" <<'PROBE'
mode="$1"; lib="$2"; fixture_mount="$3"
[[ "${mode}" == *strict ]] && IFS=$'\n\t'
source "${lib}"
eval "$(declare -f ai_tools_sessions__read_cgroup2_mount | sed '1s/^ai_tools_sessions__read_cgroup2_mount/probe_real_mount/')"
if [[ "${mode}" == direct-* ]]; then
    rc=0; real="$(probe_real_mount)" || rc=$?
    printf 'rc=%s mount=[%s]\n' "${rc}" "${real}"
    exit 0
fi
ai_tools_sessions__read_cgroup2_mount() {
    local real rc=0
    real="$(probe_real_mount)" || rc=$?
    printf 'rc=%s mount=[%s]\n' "${rc}" "${real}" > "${fixture_mount}.read"
    printf '%s' "${fixture_mount}"
}
ai_tools_sessions__read_live_session_state_for_uid 4242 >/dev/null
cat "${fixture_mount}.read"
PROBE

mount_read() { bash "${mount_probe}" "$1" "${LIB}" "${MOUNT}"; }
host_read="$(mount_read direct-default)"
if [[ "${host_read}" != "rc=0 mount=["?*"]" ]]; then
    skip "the mount read under a strict IFS" "this host's /proc/mounts names no cgroup v2 mount (${host_read})"
else
    pass "the mount read under the default IFS, called directly (control): ${host_read}"
    got="$(mount_read direct-strict)"
    if [[ "${got}" == "rc=1 mount=[]" ]]; then
        pass "the same read called directly under IFS=\$'\\n\\t' fails, so the cases below run under an IFS that breaks it (control)"
    else
        fail "the strict IFS does not break the direct read (${got}), so the cases below do not show the reader's pin"
    fi
    for mode in default strict; do
        got="$(mount_read "entry-${mode}")"
        if [[ "${got}" == "${host_read}" ]]; then
            pass "the mount read beneath the reader, ${mode} IFS: ${got}"
        else
            fail "the mount read beneath the reader, ${mode} IFS: expected ${host_read}, read ${got}"
        fi
    done
fi

# The whole reader over the fixture, the mount stubbed. The unit's cgroup.events decides it: under a strict IFS
# an unpinned read keeps `populated 0` in one field, does not match a `populated` line, and reads the idle unit live.
state_probe="${TESTDIR}/state-probe.sh"
cat > "${state_probe}" <<'PROBE'
mode="$1"; lib="$2"; stub_mount="$3"
[[ "${mode}" == strict ]] && IFS=$'\n\t'
source "${lib}"
ai_tools_sessions__read_cgroup2_mount() { printf '%s' "${stub_mount}"; }
ai_tools_sessions__read_live_session_state_for_uid 4242
PROBE

unit="${MANAGER}/app.slice/acme-acme-17.service"
mk_cgroup "${unit}"
for populated in 0 1; do
    printf 'populated %s\nfrozen 0\n' "${populated}" > "${unit}/cgroup.events"
    want=none; (( populated )) && want=live
    for mode in default strict; do
        got="$(bash "${state_probe}" "${mode}" "${LIB}" "${MOUNT}")"
        if [[ "${got}" == "${want}" ]]; then
            pass "a unit whose cgroup.events reads populated ${populated}, ${mode} IFS: ${want}"
        else
            fail "a unit whose cgroup.events reads populated ${populated}, ${mode} IFS: expected ${want}, read ${got}"
        fi
    done
done
rm -rf "${unit}"

finish
