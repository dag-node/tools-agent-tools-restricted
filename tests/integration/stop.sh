#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# tests/integration/stop.sh
# Integration test for the session-stop helper (ai-tools-stop): the kill path itself, driven
# against REAL processes in a REAL cgroup, on the running kernel.
#
# WHAT THIS COVERS THAT THE UNIT TEST CANNOT. unit/stop.sh pins enumeration and liveness against a
# fixture tree of ordinary files; nothing there is a process and nothing is signalled. The property
# this helper exists for -- a stop that is reported as done HAS happened, including everything the
# session spawned -- is a kernel property, and the three ways a child escapes a process-tree walk
# (a plain fork, setsid(2), and the double fork that re-parents the child away from the session)
# can only be demonstrated by running them.
#
# WHY A FIXTURE CGROUP AND NOT A LIVE SESSION. The helper walks one subtree, named by two globals.
# Pointing those at a cgroup this test creates and owns gives the real mechanism -- cgroup.procs,
# cgroup.kill, /proc verification -- over processes this test spawned and reaps, with no dependency
# on a session running, no operator's allowlist read, and no way for a defect here to reach the
# sandbox account's own slice. The one form that must run against the real slice is `--all`, which
# by construction ends every session on the host including the one running the suite: it is proven
# by hand from a plain root shell, and lives in tests/manual/verify-live-flows.sh.
#
# The helper is SOURCED (inert by construction, see its entry point) so the fixture globals can be
# set. Only unit_working_directory is stubbed: the fixture cgroups are not systemd units, and
# attribution is best-effort and never decides liveness.
#
# Needs root (writing cgroup.procs and cgroup.kill) and a cgroup v2 hierarchy; skips without them.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
require_root

section "session stop: the kill path against real processes (integration)"

readonly STOP_HELPER="/usr/local/libexec/ai-tools/ai-tools-stop"
if [[ ! -r "${STOP_HELPER}" ]]; then
    skip "session stop" "ai-tools-stop is not installed -- run: sudo ai-tools-admin postupgrade"
    finish; exit
fi

# The v2 mount, read the way the helper reads it: from /proc/mounts, never assumed.
CGROUP2_ROOT=""
while read -r _ mount_point fstype _; do
    [[ "${fstype}" == "cgroup2" ]] && { CGROUP2_ROOT="${mount_point}"; break; }
done < /proc/mounts
if [[ -z "${CGROUP2_ROOT}" || ! -d "${CGROUP2_ROOT}" ]]; then
    skip "session stop" "no cgroup v2 hierarchy on this host"
    finish; exit
fi

mktestdir
FIXTURE_SLICE="${CGROUP2_ROOT}/ai-tools-stoptest-$$.slice"
GO="${TESTDIR}/release-the-payloads"

# Teardown owns the fixture unconditionally: a payload that ignores SIGTERM, a run that aborts
# mid-assertion, and a helper defect all leave processes running, and every one of them is inside
# the fixture cgroup. cgroup.kill takes the whole subtree in one write; rmdir then succeeds once
# the kernel has reaped. Registered before the first cgroup is created.
stop_fixture_cleanup() {
    local dir
    local _attempt
    [[ -d "${FIXTURE_SLICE}" ]] || return 0
    while IFS= read -r dir; do
        [[ -e "${dir}/cgroup.kill" ]] && printf '1' > "${dir}/cgroup.kill" 2>/dev/null
    done < <(find "${FIXTURE_SLICE}" -type d 2>/dev/null)
    for _attempt in 1 2 3 4 5 6 7 8 9 10; do
        find "${FIXTURE_SLICE}" -depth -type d -exec rmdir {} + 2>/dev/null
        [[ -d "${FIXTURE_SLICE}" ]] || return 0
        sleep 0.5
    done
    return 0
}
on_teardown stop_fixture_cleanup

if ! mkdir -p "${FIXTURE_SLICE}/sess-a.service" "${FIXTURE_SLICE}/sess-b.service" \
              "${FIXTURE_SLICE}/sess-c.service" 2>/dev/null; then
    skip "session stop" "cannot create a cgroup under ${CGROUP2_ROOT}"
    finish; exit
fi
pass "a fixture cgroup subtree can be created and is owned by this test"

# shellcheck source=/dev/null
source "${STOP_HELPER}" 2>/dev/null || true
if ! declare -F end_session >/dev/null 2>&1; then
    fail "sourcing ${STOP_HELPER} defined nothing -- the helper is not inert on source"
    finish; exit
fi

# Aim the walk at the fixture. The two structural exemptions are pointed at names that do not
# exist, so nothing in the fixture is skipped or descended-into by special case.
# shellcheck disable=SC2034  # all three are read by the sourced helper
SANDBOX_SLICE="${FIXTURE_SLICE}"
# shellcheck disable=SC2034
MANAGER_SERVICE="${FIXTURE_SLICE}/no-such-manager.service"
# shellcheck disable=SC2034
MANAGER_INIT_SCOPE="${MANAGER_SERVICE}/init.scope"
# shellcheck disable=SC2034
CALLER="${PROJECTS_USER}"
FORCE_KILL=false
mkdir -p "${TESTDIR}/project"
unit_working_directory() { printf '%s' "${TESTDIR}/project"; }

# start_payload <cgroup-dir> <release-file> <bash-body> -- start a process, place it in the cgroup,
# and publish its pid in PAYLOAD_PID. Each payload blocks until its release file appears, so it is
# moved into the fixture BEFORE it forks anything: a child inherits its parent's cgroup at fork,
# which is the whole mechanism under test, and a child forked before the move would inherit the
# suite's own cgroup.
#
# TWO THINGS HERE ARE LOAD-BEARING, and both are about file descriptors rather than about stopping:
#
#   The pid is published in a GLOBAL, never returned through `$(...)`. A command substitution reads
#   until its pipe reaches EOF, and a background process started inside it INHERITS that pipe -- so
#   `pid="$(start_payload …)"` does not return until the payload exits, which for a `sleep 300`
#   payload is a hung test run rather than a failed assertion.
#
#   The payload's own stdio goes to /dev/null for the same class of reason: it must hold no
#   descriptor this suite writes results on. `disown` then keeps bash from printing its own
#   "Killed" job notice when the helper does exactly what the test asked it to.
PAYLOAD_PID=""
start_payload() {
    local cgroup_directory="$1" release="$2" body="$3"
    bash -c "while [[ ! -e '${release}' ]]; do sleep 0.05; done; ${body}" >/dev/null 2>&1 &
    PAYLOAD_PID=$!
    printf '%s\n' "${PAYLOAD_PID}" > "${cgroup_directory}/cgroup.procs"
    disown "${PAYLOAD_PID}" 2>/dev/null || true
}

# process_parent <pid> -- PRINT the ppid from /proc/<pid>/stat. Read after the LAST ')', since comm
# may contain one; the fields there are `state ppid ...`.
process_parent() {
    local stat_line fields
    [[ -r "/proc/$1/stat" ]] || return 1
    stat_line="$(< "/proc/$1/stat")" || return 1
    read -ra fields <<< "${stat_line##*) }"
    (( ${#fields[@]} > 1 )) || return 1
    printf '%s' "${fields[1]}"
}

# live_count <cgroup> -- how many of the cgroup's tasks are still in /proc. The helper's own
# verification is cgroup-based; this asks the process table separately, so a "stopped" claim is
# checked against something other than the mechanism that made it.
live_count() {
    local pid count=0
    while read -r pid; do [[ -d "/proc/${pid}" ]] && count=$(( count + 1 )); done \
        < <(cgroup_pids "$1")
    printf '%s' "${count}"
}

# ── The payloads: every way a child escapes a process-tree walk ───────────────────────────────
# sess-a: a plain child, a setsid(2) child (leaves the process group), and a double-forked
#         grandchild (re-parented away from the session, so it drops out of the ppid graph). All
#         three stay in the cgroup, which is why the cgroup is what this helper enumerates.
#
# EVERY SPAWN IS BACKGROUNDED, including the setsid one. `setsid sleep 300` without `&` runs in the
# FOREGROUND for its full 300 seconds, so the payload never reaches the lines after it and the case
# the test is named for is never created -- a fixture that quietly tests less than it claims.
start_payload "${FIXTURE_SLICE}/sess-a.service" "${GO}" \
    'sleep 300 & setsid sleep 300 & bash -c "sleep 300 &"; sleep 300'
sess_a_leader="${PAYLOAD_PID}"
# sess-b: ignores SIGTERM, so the graceful pass cannot end it and the run must escalate.
start_payload "${FIXTURE_SLICE}/sess-b.service" "${GO}" \
    'trap "" TERM; while :; do sleep 1; done'
# sess-c: exits promptly on SIGTERM -- the payload --force must kill anyway.
start_payload "${FIXTURE_SLICE}/sess-c.service" "${GO}" 'sleep 300'
touch "${GO}"

# Give the payloads a moment to fork their children before anything is asserted about the set.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    (( $(live_count "${FIXTURE_SLICE}/sess-a.service") >= 4 )) && break
    sleep 0.5
done

mapfile -t a_tasks < <(cgroup_pids "${FIXTURE_SLICE}/sess-a.service")
if (( ${#a_tasks[@]} >= 4 )); then
    pass "a session's descendants are all in its cgroup (${#a_tasks[@]} tasks: fork, setsid, double fork)"
else
    fail "expected at least 4 tasks in sess-a, found ${#a_tasks[@]}: ${a_tasks[*]}"
fi

# The double-forked grandchild is the case a ppid walk cannot see. What makes it unreachable is not
# that its parent became PID 1 specifically -- an ancestor marked PR_SET_CHILD_SUBREAPER adopts it
# instead, and a `systemd --user` session is one -- but that its parent is OUTSIDE the cgroup. So
# that is what is asserted: a task in the cgroup, other than the leader, whose parent is not in the
# cgroup. A walk rooted at the session leader cannot reach it whichever process adopted it.
declare -A a_task_set=()
for task_pid in "${a_tasks[@]}"; do a_task_set["${task_pid}"]=1; done
reparented=false
for task_pid in "${a_tasks[@]}"; do
    [[ "${task_pid}" == "${sess_a_leader}" ]] && continue
    task_parent="$(process_parent "${task_pid}" || true)"
    [[ -n "${task_parent}" && -z "${a_task_set[${task_parent}]:-}" ]] && reparented=true
done
if ${reparented}; then
    pass "a re-parented (double-forked) descendant is still found -- a ppid walk would miss it"
else
    fail "no descendant was re-parented out of the session; the double-fork payload did not take effect"
fi

# ── The graceful pass ─────────────────────────────────────────────────────────────────────────
outcome="$(end_session "${FIXTURE_SLICE}/sess-a.service")"
if [[ "${outcome}" == "terminated" ]]; then
    pass "a session that honours SIGTERM is reported as terminated"
else
    fail "expected 'terminated' for sess-a, got '${outcome}'"
fi
if [[ "$(live_count "${FIXTURE_SLICE}/sess-a.service")" == "0" ]] \
        && ! cgroup_is_live "${FIXTURE_SLICE}/sess-a.service"; then
    pass "every task of the stopped session is gone from /proc, not merely from the cgroup"
else
    fail "sess-a still has live tasks after a reported stop"
fi

# ── The escalation ────────────────────────────────────────────────────────────────────────────
# A payload that ignores SIGTERM must cost the grace period and then be killed -- and the trail
# must say which pass ended it, because that is the most useful line in it after an incident.
outcome="$(end_session "${FIXTURE_SLICE}/sess-b.service")"
if [[ "${outcome}" == "killed" ]]; then
    pass "a session that ignores SIGTERM escalates to SIGKILL and is reported as killed"
else
    fail "expected 'killed' for the SIGTERM-ignoring session, got '${outcome}'"
fi
if [[ "$(live_count "${FIXTURE_SLICE}/sess-b.service")" == "0" ]]; then
    pass "SIGKILL is not refusable: the ignoring session is gone from /proc"
else
    fail "the SIGTERM-ignoring session survived"
fi

# ── --force ───────────────────────────────────────────────────────────────────────────────────
# --force must never report `terminated`: it skips the graceful pass entirely, so the trail cannot
# claim a process was given the chance to flush anything.
FORCE_KILL=true
outcome="$(end_session "${FIXTURE_SLICE}/sess-c.service")"
FORCE_KILL=false
if [[ "${outcome}" == "killed" ]]; then
    pass "--force reports killed, never terminated -- no grace period was given"
else
    fail "expected 'killed' under --force, got '${outcome}'"
fi
if [[ "$(live_count "${FIXTURE_SLICE}/sess-c.service")" == "0" ]]; then
    pass "--force ends the session outright"
else
    fail "--force left live tasks"
fi

# ── The whole command, end to end ─────────────────────────────────────────────────────────────
# main() against the fixture slice: selection, confirmation, the kill, the verification sweep, the
# exit status and the trail -- the same code path an operator runs, over processes this test owns.
mkdir -p "${FIXTURE_SLICE}/sess-d.service"
GO_D="${TESTDIR}/release-the-payloads-2"
start_payload "${FIXTURE_SLICE}/sess-d.service" "${GO_D}" 'sleep 300 & sleep 300'
d_pid="${PAYLOAD_PID}"
touch "${GO_D}"
for _ in 1 2 3 4 5 6 7 8 9 10; do
    (( $(live_count "${FIXTURE_SLICE}/sess-d.service") >= 2 )) && break
    sleep 0.5
done

# run_main <all?> <dry-run?> -- set the request the way the argument parser would and run main(),
# capturing its output and status. Always --yes: the confirmation is covered in unit/stop.sh, and a
# prompt here would block the suite on a terminal read.
# shellcheck disable=SC2034  # the request globals are read by the sourced helper's main()
run_main() {
    STOP_EVERY_SESSION="$1"; TARGET_PROJECT=""; DRY_RUN="$2"; ASSUME_YES=true; FORCE_KILL=false
    set +e
    MAIN_OUTPUT="$(main 2>&1)"
    MAIN_STATUS=$?
    set -e
}

run_main true true
if (( MAIN_STATUS == 0 )) && [[ -d "/proc/${d_pid}" ]] \
        && grep -qi 'dry run' <<< "${MAIN_OUTPUT}"; then
    pass "a dry run reports the session and changes nothing (exit 0, the session still runs)"
else
    fail "dry run: status ${MAIN_STATUS}, leader alive=$([[ -d "/proc/${d_pid}" ]] && echo yes || echo no)"
fi

run_main true false
if (( MAIN_STATUS == 0 )); then
    pass "the stop completes and reports success (exit 0)"
else
    fail "stop: expected exit 0, got ${MAIN_STATUS}: ${MAIN_OUTPUT}"
fi
if [[ ! -d "/proc/${d_pid}" ]] && [[ "$(live_count "${FIXTURE_SLICE}/sess-d.service")" == "0" ]]; then
    pass "the reported success is true: the session and its children are gone from /proc"
else
    fail "a success was reported while tasks remained"
fi
if grep -q "${TESTDIR}/project" <<< "${MAIN_OUTPUT}"; then
    pass "the run names the project to reclaim, since a stop cannot run the session-end handback"
else
    fail "no reclaim guidance for the stopped project: ${MAIN_OUTPUT}"
fi

stop_log="${AI_TOOLS_LOG_DIR}/stop.log"
if grep -q "stopped session" "${stop_log}" 2>/dev/null \
        && grep -q "verified empty" "${stop_log}" 2>/dev/null; then
    pass "the trail records each session ended and that the result was verified"
else
    fail "the trail does not record the stop: $(tail -5 "${stop_log}" 2>&1)"
fi

# Nothing running is a successful stop, not an error -- the idempotence an operator relies on when
# re-running the command after an interrupted one.
run_main true false
if (( MAIN_STATUS == 0 )); then
    pass "re-running the stop with nothing left is exit 0 (the command is idempotent)"
else
    fail "second run: expected exit 0, got ${MAIN_STATUS}: ${MAIN_OUTPUT}"
fi

# ── The mechanism the guarantee prefers ───────────────────────────────────────────────────────
# cgroup.kill (5.14+) is what makes the kill atomic against a fork. Its absence is a supported
# fallback, so this asserts which one this host actually used rather than requiring either.
if [[ -e "${FIXTURE_SLICE}/sess-d.service/cgroup.kill" ]]; then
    if grep -q "no cgroup.kill on this kernel" "${stop_log}" 2>/dev/null; then
        fail "cgroup.kill exists on this host but the run reported it absent"
    else
        pass "the atomic cgroup.kill path is available and was not reported as absent"
    fi
else
    skip "cgroup.kill" "kernel predates 5.14; the per-pid fallback carried the run"
fi

finish
